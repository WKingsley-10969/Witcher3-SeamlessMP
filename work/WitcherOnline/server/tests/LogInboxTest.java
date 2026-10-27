import com.sun.net.httpserver.HttpServer;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URL;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;
import java.util.stream.Stream;

// LogInbox: a connected player's log is written byte for byte under its name; unknown addresses,
// bad names and oversize logs are refused; a player keeps only the newest KEEP_FILES logs.
public final class LogInboxTest
{
    private static int assertions;

    public static void main(String[] args) throws Exception
    {
        Path root = Paths.get(args.length > 0 ? args[0] : ".", "log-inbox");
        SaveShareTest.clear(root);
        Path logs = root.resolve("player-logs");
        List<InetAddress> clients = new ArrayList<>();
        List<String> console = new ArrayList<>();
        AtomicLong clock = new AtomicLong(1_000_000_000L);
        LogInbox inbox = new LogInbox(logs, () -> new ArrayList<>(clients), console::add, clock::get);
        HttpServer server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
        server.createContext("/log", inbox::handle);
        server.start();
        try
        {
            String base = "http://127.0.0.1:" + server.getAddress().getPort() + "/log";
            byte[] log = bytes(300_000, 5);

            check(post(base + "?name=Bajra&session=s1", log, false) == 403, "an address that never played is refused");
            check(!Files.exists(logs), "nothing written for a refused address");

            clients.add(InetAddress.getByName("127.0.0.1"));
            check(post(base + "?name=Bajra&session=20261026-153000-native", log, false) == 200, "a connected player's log is accepted");
            Path folder = logs.resolve("Bajra");
            List<Path> files = logFiles(folder);
            check(files.size() == 1, "one log file written");
            String fileName = files.get(0).getFileName().toString();
            check(fileName.matches("\\d{8}-\\d{6}-20261026-153000-native\\.log"), "file name is time-session.log: " + fileName);
            check(Arrays.equals(Files.readAllBytes(files.get(0)), log), "log stored byte for byte");
            check(console.size() == 1 && console.get(0).equals("Logs from Bajra saved to " + folder.toAbsolutePath().normalize()),
                    "the host console names the folder: " + console);
            check(post(base + "?name=Bajra&session=s2", log, true) == 200, "a chunked upload is accepted");
            check(console.size() == 1, "the folder is announced once per player");

            // the game has closed: the second PC is no longer a client, but was one recently
            inbox.rememberClients();
            clients.clear();
            clock.addAndGet(29L * 60 * 1000);
            check(post(base + "?name=Bajra&session=s3", log, false) == 200, "accepted 29 minutes after the player left");
            clock.addAndGet(2L * 60 * 1000);
            check(post(base + "?name=Bajra&session=s4", log, false) == 403, "refused 31 minutes after the player left");
            clients.add(InetAddress.getByName("127.0.0.1"));

            for (String name : new String[] {"a", "Bad%20Name", "..%2Fx", "none", "abcdefghijklmnopq", "B%C3%A4jra", ""})
                check(post(base + "?name=" + name + "&session=s5", log, false) == 400, "bad name refused: " + name);
            check(post(base + "?session=s5", log, false) == 400, "missing name refused");
            for (String session : new String[] {"..%2F..%2Fx", "a.b", "", "x%00y"})
                check(post(base + "?name=Bajra&session=" + session, log, false) == 400, "bad session refused: " + session);
            check(post(base + "?name=Bajra&session=s6", new byte[0], false) == 400, "an empty log is refused");
            check(get(base + "?name=Bajra&session=s7") == 405, "only POST");
            check(!Files.exists(logs.resolve("x")) && !Files.exists(root.resolve("x")), "no path outside the player folder");

            int before = logFiles(folder).size();
            byte[] over = bytes((int) LogInbox.MAX_BYTES + 1, 3);
            check(post(base + "?name=Bajra&session=big", over, false) == 413, "oversize log refused by its length");
            check(post(base + "?name=Bajra&session=big", over, true) == 413, "oversize chunked log refused while reading");
            check(logFiles(folder).size() == before && !Files.exists(folder.resolve(".upload.part")), "nothing kept of an oversize log");
            check(post(base + "?name=Bajra&session=max", bytes((int) LogInbox.MAX_BYTES, 3), false) == 200, "a log of exactly the cap is accepted");

            // retention: the newest KEEP_FILES stay
            clock.addAndGet(LogInbox.UPLOAD_WINDOW_MS + 1);
            for (int i = 1; i <= LogInbox.KEEP_FILES + 3; i++)
                check(post(base + "?name=Keeper&session=r" + String.format("%02d", i), ("log " + i).getBytes(), false) == 200, "retention upload " + i);
            List<Path> kept = logFiles(logs.resolve("Keeper"));
            check(kept.size() == LogInbox.KEEP_FILES, "only the newest " + LogInbox.KEEP_FILES + " logs kept: " + kept.size());
            check(kept.stream().noneMatch(file -> file.getFileName().toString().matches(".*-r0[123]\\.log")), "the oldest logs were removed");
            check(kept.stream().anyMatch(file -> file.getFileName().toString().endsWith("-r23.log")), "the newest log kept");

            // rate limit per address
            clock.addAndGet(LogInbox.UPLOAD_WINDOW_MS + 1);
            int accepted = 0;
            int limited = 0;
            for (int i = 0; i < LogInbox.MAX_UPLOADS_PER_WINDOW + 2; i++)
            {
                int status = post(base + "?name=Flood&session=f" + i, "x".getBytes(), false);
                if (status == 200) accepted++;
                if (status == 429) limited++;
            }
            check(accepted == LogInbox.MAX_UPLOADS_PER_WINDOW && limited == 2, "uploads per address are rate-limited: " + accepted + "/" + limited);
        }
        finally
        {
            server.stop(0);
        }
        System.out.println("LogInboxTest passed: " + assertions + " assertions");
    }

    private static List<Path> logFiles(Path folder) throws IOException
    {
        List<Path> files = new ArrayList<>();
        if (!Files.isDirectory(folder)) return files;
        try (Stream<Path> list = Files.list(folder))
        {
            list.filter(file -> file.getFileName().toString().endsWith(".log")).sorted().forEach(files::add);
        }
        return files;
    }

    // the status, or 413 when the server closed the connection on an oversize body
    private static int post(String address, byte[] body, boolean chunked) throws IOException
    {
        HttpURLConnection connection = (HttpURLConnection) new URL(address).openConnection();
        connection.setRequestMethod("POST");
        connection.setDoOutput(true);
        if (chunked) connection.setChunkedStreamingMode(65536);
        else connection.setFixedLengthStreamingMode(body.length);
        try
        {
            try (OutputStream out = connection.getOutputStream())
            {
                out.write(body);
            }
            int status = connection.getResponseCode();
            drain(status < 400 ? connection.getInputStream() : connection.getErrorStream());
            return status;
        }
        catch (IOException e)
        {
            if (body.length > LogInbox.MAX_BYTES) return 413;
            throw e;
        }
        finally
        {
            connection.disconnect();
        }
    }

    private static int get(String address) throws IOException
    {
        HttpURLConnection connection = (HttpURLConnection) new URL(address).openConnection();
        int status = connection.getResponseCode();
        drain(status < 400 ? connection.getInputStream() : connection.getErrorStream());
        return status;
    }

    private static void drain(InputStream in) throws IOException
    {
        if (in == null) return;
        try (in)
        {
            in.transferTo(new ByteArrayOutputStream());
        }
    }

    private static byte[] bytes(int size, int seed)
    {
        byte[] data = new byte[size];
        for (int i = 0; i < size; i++) data[i] = (byte) (i * seed + seed);
        return data;
    }

    private static void check(boolean condition, String what)
    {
        assertions++;
        if (!condition) throw new AssertionError("FAIL " + what);
    }
}
