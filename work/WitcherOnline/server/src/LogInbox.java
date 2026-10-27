import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.Deque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;
import java.util.function.LongSupplier;
import java.util.function.Supplier;
import java.util.regex.Pattern;
import java.util.stream.Stream;

/**
 * Co-op logs from the second PC, on the save share's port. After a session the joining player's
 * launcher sends its game's logs here, so the host has them without going to that PC.
 *
 * POST /log?name=NAME&session=ID   body: one log file, at most MAX_BYTES. Accepted only from an
 *                                  address that is a connected game client or was one in the last
 *                                  CLIENT_MEMORY_MS. Written to FOLDER/NAME/yyyyMMdd-HHmmss-ID.log;
 *                                  only the newest KEEP_FILES of a player are kept.
 *
 * The content is stored as bytes: never parsed, interpreted or executed.
 */
final class LogInbox
{
    static final long MAX_BYTES = 8L * 1024 * 1024;
    static final int KEEP_FILES = 20;
    static final long CLIENT_MEMORY_MS = 30L * 60 * 1000;
    static final int MAX_UPLOADS_PER_WINDOW = 30;
    static final long UPLOAD_WINDOW_MS = 10L * 60 * 1000;

    private static final Pattern PLAYER_NAME = Pattern.compile("[A-Za-z0-9_]{2,16}");
    private static final Pattern SESSION = Pattern.compile("[A-Za-z0-9_-]{1,64}");
    private static final DateTimeFormatter STAMP = DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss");

    private final Path folder;
    private final Supplier<? extends Collection<InetAddress>> clients;
    private final Consumer<String> console;
    private final LongSupplier clock;
    private final Map<String, Long> recentClients = new HashMap<>();     // address -> last seen (ms)
    private final Map<String, Deque<Long>> uploads = new HashMap<>();    // address -> upload times
    private final Set<String> announced = new HashSet<>();
    private ScheduledExecutorService poller;

    LogInbox(Path folder, Supplier<? extends Collection<InetAddress>> clients, Consumer<String> console, LongSupplier clock)
    {
        this.folder = folder.toAbsolutePath().normalize();
        this.clients = clients;
        this.console = console;
        this.clock = clock;
    }

    /** Serves POST /log on the save share's HTTP server; clients: the connected game clients' addresses. */
    static LogInbox attach(HttpServer server, Path folder, Supplier<? extends Collection<InetAddress>> clients)
    {
        LogInbox inbox = new LogInbox(folder, clients, System.out::println, System::currentTimeMillis);
        server.createContext("/log", inbox::handle);
        // remember who was connected, so a log sent after the game closed is still accepted
        inbox.poller = Executors.newSingleThreadScheduledExecutor(task -> {
            Thread thread = new Thread(task, "log-inbox-clients");
            thread.setDaemon(true);
            return thread;
        });
        inbox.poller.scheduleWithFixedDelay(inbox::rememberClients, 0, 2, TimeUnit.SECONDS);
        return inbox;
    }

    Path folder()
    {
        return folder;
    }

    void stop()
    {
        if (poller != null) poller.shutdownNow();
    }

    synchronized void rememberClients()
    {
        long now = clock.getAsLong();
        try
        {
            Collection<InetAddress> current = clients.get();
            if (current != null) for (InetAddress address : current) recentClients.put(key(address), now);
        }
        catch (RuntimeException ignored)
        {
            // the player table is read while it changes; the next round sees it again
        }
        recentClients.values().removeIf(seen -> now - seen > CLIENT_MEMORY_MS);
    }

    void handle(HttpExchange exchange) throws IOException
    {
        try
        {
            int status;
            String reply;
            synchronized (this)
            {
                String[] result = receive(exchange);
                status = Integer.parseInt(result[0]);
                reply = result[1];
            }
            SaveShare.send(exchange, status, "text/plain; charset=utf-8", (reply + "\n").getBytes(StandardCharsets.UTF_8));
        }
        finally
        {
            exchange.close();
        }
    }

    // {status, reply}
    private String[] receive(HttpExchange exchange) throws IOException
    {
        if (!"/log".equals(exchange.getRequestURI().getPath())) return new String[] {"404", "not found"};
        if (!"POST".equals(exchange.getRequestMethod())) return new String[] {"405", "POST only"};
        rememberClients();
        long now = clock.getAsLong();
        String address = key(exchange.getRemoteAddress().getAddress());
        if (!recentClients.containsKey(address)) return new String[] {"403", "not a connected player"};
        Deque<Long> times = uploads.computeIfAbsent(address, unused -> new ArrayDeque<>());
        while (!times.isEmpty() && now - times.peekFirst() > UPLOAD_WINDOW_MS) times.removeFirst();
        if (times.size() >= MAX_UPLOADS_PER_WINDOW) return new String[] {"429", "too many logs, try later"};

        Map<String, String> query = query(exchange.getRequestURI().getRawQuery());
        String name = query.get("name");
        String session = query.get("session");
        if (name == null || !PLAYER_NAME.matcher(name).matches() || name.equalsIgnoreCase("none"))
            return new String[] {"400", "bad player name"};
        if (session == null || !SESSION.matcher(session).matches()) return new String[] {"400", "bad session"};
        String length = exchange.getRequestHeaders().getFirst("Content-Length");
        if (length != null)
        {
            try { if (Long.parseLong(length.trim()) > MAX_BYTES) return new String[] {"413", "log over " + MAX_BYTES + " bytes"}; }
            catch (NumberFormatException e) { return new String[] {"400", "bad length"}; }
        }

        times.addLast(now);
        Path playerFolder = Files.createDirectories(folder.resolve(name));
        Path partial = playerFolder.resolve(".upload.part");
        long size = 0;
        try (InputStream in = exchange.getRequestBody(); OutputStream out = Files.newOutputStream(partial))
        {
            byte[] buffer = new byte[65536];
            for (int read; (read = in.read(buffer)) > 0; )
            {
                size += read;
                if (size > MAX_BYTES)
                {
                    out.close();
                    Files.deleteIfExists(partial);
                    return new String[] {"413", "log over " + MAX_BYTES + " bytes"};
                }
                out.write(buffer, 0, read);
            }
        }
        catch (IOException e)
        {
            Files.deleteIfExists(partial);
            throw e;
        }
        if (size == 0)
        {
            Files.deleteIfExists(partial);
            return new String[] {"400", "empty log"};
        }
        String base = LocalDateTime.now().format(STAMP) + "-" + session;
        Path target = playerFolder.resolve(base + ".log");
        for (int n = 2; Files.exists(target); n++) target = playerFolder.resolve(base + "-" + n + ".log");
        Files.move(partial, target, StandardCopyOption.ATOMIC_MOVE);
        prune(playerFolder);
        if (announced.add(name.toLowerCase(java.util.Locale.ROOT)))
            console.accept("Logs from " + name + " saved to " + playerFolder);
        return new String[] {"200", "saved " + target.getFileName()};
    }

    // Keeps the newest KEEP_FILES logs of a player (by time written, then name).
    private static void prune(Path playerFolder) throws IOException
    {
        List<Path> logs = new ArrayList<>();
        Map<Path, Long> written = new HashMap<>();
        try (Stream<Path> files = Files.list(playerFolder))
        {
            for (Path file : (Iterable<Path>) files::iterator)
            {
                if (!file.getFileName().toString().endsWith(".log") || !Files.isRegularFile(file)) continue;
                logs.add(file);
                written.put(file, Files.getLastModifiedTime(file).toMillis());
            }
        }
        if (logs.size() <= KEEP_FILES) return;
        logs.sort(Comparator.comparing((Path file) -> written.get(file)).thenComparing(Comparator.naturalOrder()));
        for (Path old : logs.subList(0, logs.size() - KEEP_FILES)) Files.deleteIfExists(old);
    }

    private static String key(InetAddress address)
    {
        return address == null ? "" : address.getHostAddress();
    }

    private static Map<String, String> query(String raw)
    {
        Map<String, String> values = new LinkedHashMap<>();
        if (raw == null || raw.isEmpty()) return values;
        for (String pair : raw.split("&"))
        {
            int at = pair.indexOf('=');
            if (at <= 0) continue;
            try
            {
                values.put(URLDecoder.decode(pair.substring(0, at), StandardCharsets.UTF_8), URLDecoder.decode(pair.substring(at + 1), StandardCharsets.UTF_8));
            }
            catch (IllegalArgumentException ignored)
            {
                // a malformed escape: the value stays absent and is refused
            }
        }
        return values;
    }
}
