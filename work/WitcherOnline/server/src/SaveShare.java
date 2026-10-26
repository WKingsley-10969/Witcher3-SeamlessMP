import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.regex.Pattern;
import java.util.stream.Stream;

/**
 * Co-op session: shares the host's co-op saves over the LAN, read-only, so joining players load the
 * same game as the host. Serves one directory (the host's gamesaves) and nothing else.
 *
 * GET /session                 "host=NAME\nsave=BASENAME\nsize=BYTES\nmodified=EPOCHMS\n" for the
 *                              newest .sav (save= empty when there is none)
 * GET /session/save/FILE       a .sav or .png file of that directory, by plain file name
 */
public final class SaveShare
{
    private static final Pattern FILE_NAME = Pattern.compile("[A-Za-z0-9_.-]{1,120}\\.(sav|png)");

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
        if (!Files.isDirectory(directory)) throw new IllegalArgumentException("Save directory does not exist: " + directory);
        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        SaveShare share = new SaveShare(directory.toRealPath(), hostName == null ? "" : hostName, server);
        server.createContext("/session", share::handle);
        CoopLobby.attach(server, share);
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
            text.append("save=").append(name, 0, name.length() - ".sav".length()).append('\n');
            text.append("size=").append(Files.size(newest)).append('\n');
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
        send(exchange, 200, "application/octet-stream", Files.readAllBytes(file));
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
