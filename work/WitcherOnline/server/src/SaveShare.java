import com.sun.net.httpserver.Filter;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.function.Predicate;
import java.util.regex.Pattern;
import java.util.stream.Stream;

/**
 * Co-op session: shares the host's co-op saves over the LAN, read-only, so joining players load the
 * same game as the host. Serves one directory (the host's gamesaves) and nothing else.
 *
 * GET /session                 "host=NAME\nsave=BASENAME\nsize=BYTES\nsha256=HEX\nmodified=EPOCHMS\n"
 *                              for the newest .sav (save= empty when there is none)
 * GET /session/save/FILE       a .sav, .png or .json file of that directory, by plain file name (the game
 *                              writes a .json of metadata beside each save it makes), with
 *                              "X-Content-SHA256: HEX" (of the whole file) and "Accept-Ranges: bytes":
 *                              a single "Range: bytes=FIRST-[LAST]" or "bytes=-SUFFIX" is answered 206
 *                              with Content-Range (416 outside the file), so a second PC whose
 *                              connection dropped resumes instead of starting over
 */
public final class SaveShare
{
    private static final Pattern FILE_NAME = Pattern.compile("[A-Za-z0-9_.-]{1,120}\\.(sav|png|json)");

    private final Path directory;
    private final String hostName;
    private final HttpServer server;

    private SaveShare(Path directory, String hostName, HttpServer server)
    {
        this.directory = directory;
        this.hostName = hostName;
        this.server = server;
    }

    public static SaveShare start(Path directory, int port, String hostName) throws IOException
    {
        return start(directory, port, hostName, address -> true);
    }

    // allowed: which PCs may use the share and the lobby (the join password, JoinGate); others get 403.
    public static SaveShare start(Path directory, int port, String hostName, Predicate<InetAddress> allowed) throws IOException
    {
        if (!Files.isDirectory(directory)) throw new IllegalArgumentException("Save directory does not exist: " + directory);
        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        SaveShare share = new SaveShare(directory.toRealPath(), hostName == null ? "" : hostName, server);
        Filter gate = new Filter()
        {
            @Override
            public void doFilter(HttpExchange exchange, Chain chain) throws IOException
            {
                if (allowed.test(exchange.getRemoteAddress().getAddress())) { chain.doFilter(exchange); return; }
                try { send(exchange, 403, "text/plain; charset=utf-8", "join password required\n".getBytes(StandardCharsets.UTF_8)); }
                finally { exchange.close(); }
            }

            @Override
            public String description()
            {
                return "join password";
            }
        };
        server.createContext("/session", share::handle).getFilters().add(gate);
        CoopLobby.attach(server, share).getFilters().add(gate);
        server.setExecutor(null);
        server.start();
        return share;
    }

    // the HTTP server, for the log inbox (LogInbox) on the same port
    HttpServer httpServer()
    {
        return server;
    }

    public int port()
    {
        return server.getAddress().getPort();
    }

    public void stop()
    {
        server.stop(0);
    }

    private void handle(HttpExchange exchange) throws IOException
    {
        try
        {
            String path = exchange.getRequestURI().getPath();
            if (!"GET".equals(exchange.getRequestMethod()))
                send(exchange, 405, "text/plain; charset=utf-8", "GET only\n".getBytes(StandardCharsets.UTF_8));
            else if ("/session".equals(path))
                send(exchange, 200, "text/plain; charset=utf-8", describe().getBytes(StandardCharsets.UTF_8));
            else if (path.startsWith("/session/save/"))
                sendFile(exchange, path.substring("/session/save/".length()));
            else
                send(exchange, 404, "text/plain; charset=utf-8", "not found\n".getBytes(StandardCharsets.UTF_8));
        }
        finally
        {
            exchange.close();
        }
    }

    // The newest .sav of the directory, or null.
    Path newestSave() throws IOException
    {
        Path newest = null;
        long newestTime = Long.MIN_VALUE;
        try (Stream<Path> files = Files.list(directory))
        {
            for (Path file : (Iterable<Path>) files::iterator)
            {
                String name = file.getFileName().toString();
                if (!name.endsWith(".sav") || !FILE_NAME.matcher(name).matches() || !Files.isRegularFile(file)) continue;
                long time = Files.getLastModifiedTime(file).toMillis();
                if (time > newestTime)
                {
                    newest = file;
                    newestTime = time;
                }
            }
        }
        return newest;
    }

    // A save's base name (no .sav), as the game and the lobby name it; "" for none.
    static String baseName(Path save)
    {
        if (save == null) return "";
        String name = save.getFileName().toString();
        return name.substring(0, name.length() - ".sav".length());
    }

    boolean hasSave(String baseName)
    {
        String name = baseName + ".sav";
        return FILE_NAME.matcher(name).matches() && Files.isRegularFile(directory.resolve(name));
    }

    String hostName()
    {
        return hostName;
    }

    // The newest save, as key=value lines.
    String describe() throws IOException
    {
        Path newest = newestSave();
        long newestTime = newest == null ? 0 : Files.getLastModifiedTime(newest).toMillis();
        StringBuilder text = new StringBuilder();
        text.append("host=").append(hostName).append('\n');
        if (newest == null)
        {
            text.append("save=\n");
        }
        else
        {
            String name = newest.getFileName().toString();
            byte[] bytes = Files.readAllBytes(newest);
            text.append("save=").append(name, 0, name.length() - ".sav".length()).append('\n');
            text.append("size=").append(bytes.length).append('\n');
            text.append("sha256=").append(sha256(bytes)).append('\n');
            text.append("modified=").append(newestTime).append('\n');
        }
        return text.toString();
    }

    private void sendFile(HttpExchange exchange, String name) throws IOException
    {
        Path file = directory.resolve(name).normalize();
        if (!FILE_NAME.matcher(name).matches() || !directory.equals(file.getParent()) || !Files.isRegularFile(file))
        {
            send(exchange, 404, "text/plain; charset=utf-8", "not found\n".getBytes(StandardCharsets.UTF_8));
            return;
        }
        // one read: the checksum header and the bytes served are of the same file contents
        byte[] bytes = Files.readAllBytes(file);
        exchange.getResponseHeaders().set("Accept-Ranges", "bytes");
        exchange.getResponseHeaders().set("X-Content-SHA256", sha256(bytes));
        long[] range = range(exchange.getRequestHeaders().getFirst("Range"), bytes.length);
        if (range == null)
        {
            send(exchange, 200, "application/octet-stream", bytes);
        }
        else if (range.length == 0)
        {
            exchange.getResponseHeaders().set("Content-Range", "bytes */" + bytes.length);
            send(exchange, 416, "text/plain; charset=utf-8", "range not satisfiable\n".getBytes(StandardCharsets.UTF_8));
        }
        else
        {
            exchange.getResponseHeaders().set("Content-Range", "bytes " + range[0] + "-" + range[1] + "/" + bytes.length);
            send(exchange, 206, "application/octet-stream", java.util.Arrays.copyOfRange(bytes, (int) range[0], (int) range[1] + 1));
        }
    }

    // A Range header for a file of length bytes: {first, last} (inclusive) for one range in it, an
    // empty array for one wholly outside it (416), null for no header or one this share ignores
    // (several ranges, other units, malformed: the whole file, 200).
    static long[] range(String header, long length)
    {
        if (header == null) return null;
        java.util.regex.Matcher spec = RANGE.matcher(header.trim());
        if (!spec.matches() || (spec.group(1).isEmpty() && spec.group(2).isEmpty())) return null;
        if (spec.group(1).isEmpty())
        {
            long suffix = Long.parseLong(spec.group(2));
            if (suffix == 0 || length == 0) return new long[0];
            return new long[] { Math.max(0, length - suffix), length - 1 };
        }
        long first = Long.parseLong(spec.group(1));
        if (first >= length) return new long[0];
        long last = spec.group(2).isEmpty() ? length - 1 : Math.min(Long.parseLong(spec.group(2)), length - 1);
        return last < first ? null : new long[] { first, last };
    }

    private static final Pattern RANGE = Pattern.compile("bytes=(\\d{0,18})-(\\d{0,18})");

    static String sha256(byte[] bytes)
    {
        try
        {
            return java.util.HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256").digest(bytes));
        }
        catch (java.security.NoSuchAlgorithmException e)
        {
            throw new IllegalStateException("SHA-256 is part of every Java runtime", e);
        }
    }

    static void send(HttpExchange exchange, int status, String type, byte[] body) throws IOException
    {
        exchange.getResponseHeaders().set("Content-Type", type);
        exchange.sendResponseHeaders(status, body.length);
        try (OutputStream out = exchange.getResponseBody())
        {
            out.write(body);
        }
    }
}
