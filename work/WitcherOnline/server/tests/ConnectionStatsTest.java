import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Properties;
import java.util.concurrent.TimeUnit;

// ConnectionStats: the host console's per-player connection view (status command and periodic
// summary). Unit checks on a fake clock, then a real server subprocess driven over loopback UDP
// with "status" typed on its console. No game involved.
public final class ConnectionStatsTest
{
    private static final long S = 1_000_000_000L;
    private static final long T0 = 5_000L * S;
    private static int assertions;

    public static void main(String[] args) throws Exception
    {
        rates();
        loss();
        duplicatesReorderAndRestart();
        gapsAndLastPacket();
        summaryTiming();
        configuration();
        unknownEndpoints();
        statusTable();
        if (args.length >= 3)
        {
            realServer(args[0], args[1], Paths.get(args[2]));
        }
        System.out.println("ConnectionStatsTest passed: " + assertions + " assertions");
    }

    private static void rates() throws Exception
    {
        ConnectionStats stats = new ConnectionStats();
        ClientEndpoint guest = endpoint("10.147.17.23", 50211);
        PlayerSession session = new PlayerSession(2, "GuestWitcher", guest, T0);
        for (int second = 0; second < 12; second++)
        {
            for (int i = 0; i < 20; i++)
            {
                long at = T0 + second * S + i * (S / 20);
                stats.packetIn(guest, at);
                stats.packetOut(guest, at);
                stats.packetOut(guest, at);
            }
        }
        String row = row(stats.statusLines(List.of(session), T0 + 12 * S), "GuestWitcher");
        check(row.contains(" 20.0 ") && row.contains(" 40.0 "), "20 packets/s in and 40 out over the last 10 s: " + row);
        check(row.contains("10.147.17.23:50211"), "the address is shown with its port: " + row);
        check(row.trim().endsWith("n/a"), "ping is n/a: " + row);
        check(row.contains("  12s  "), "online for 12 s: " + row);

        ConnectionStats young = new ConnectionStats();
        young.packetIn(guest, T0 + S / 2);
        String fresh = row(young.statusLines(List.of(session), T0 + S - 1), "GuestWitcher");
        check(fresh.contains("   -  "), "no rate before a complete second: " + fresh);
    }

    private static void loss() throws Exception
    {
        ConnectionStats stats = new ConnectionStats();
        ClientEndpoint guest = endpoint("100.64.0.7", 41000);
        PlayerSession session = new PlayerSession(2, "GuestWitcher", guest, T0);
        // 300 sequence numbers over 10 s; one in 10 never arrives
        for (int n = 0; n < 300; n++)
        {
            long at = T0 + n * (10 * S / 300);
            if (n % 10 == 5) continue;
            stats.packetIn(guest, at);
            stats.sequence(guest, n % 2 == 0 ? "MOVE" : "UPDATE1A", seqFields(n % 2 == 0 ? "MOVE" : "UPDATE1A", 1000 + n), at);
        }
        String row = row(stats.statusLines(List.of(session), T0 + 10 * S), "GuestWitcher");
        check(row.contains(" 10.0% "), "10 % loss: " + row);

        ConnectionStats few = new ConnectionStats();
        few.packetIn(guest, T0);
        few.sequence(guest, "MOVE", seqFields("MOVE", 7), T0);
        few.sequence(guest, "MOVE", seqFields("MOVE", 9), T0 + S / 2);
        String early = row(few.statusLines(List.of(session), T0 + 2 * S), "GuestWitcher");
        check(early.contains(" n/a "), "too few numbers for an estimate: " + early);

        ConnectionStats other = new ConnectionStats();
        other.packetIn(guest, T0);
        for (int n = 1; n <= 50; n++)
        {
            other.sequence(guest, "UPDATE2A", Arrays.asList(Integer.toString(n), Integer.toString(n)), T0 + n * (S / 20));
            other.sequence(guest, "COOP", Arrays.asList("en", Integer.toString(n * 3)), T0 + n * (S / 20));
        }
        check(row(other.statusLines(List.of(session), T0 + 3 * S), "GuestWitcher").contains(" n/a "),
                "only MOVE and UPDATE1A/1B carry the movement sequence");
    }

    private static void duplicatesReorderAndRestart() throws Exception
    {
        ConnectionStats stats = new ConnectionStats();
        ClientEndpoint guest = endpoint("192.168.1.20", 52000);
        PlayerSession session = new PlayerSession(2, "GuestWitcher", guest, T0);
        stats.packetIn(guest, T0);
        long seq = 500;
        for (int n = 0; n < 100; n++)
        {
            long at = T0 + n * (S / 10);
            // UPDATE1A and UPDATE1B carry the same number; both arrive, sometimes twice
            stats.sequence(guest, "UPDATE1A", seqFields("UPDATE1A", seq), at);
            stats.sequence(guest, "UPDATE1B", seqFields("UPDATE1B", seq), at);
            if (n % 7 == 0) stats.sequence(guest, "UPDATE1B", seqFields("UPDATE1B", seq), at);
            seq++;
        }
        check(row(stats.statusLines(List.of(session), T0 + 10 * S), "GuestWitcher").contains(" 0.0% "),
                "duplicates are not counted twice");

        ConnectionStats late = new ConnectionStats();
        late.packetIn(guest, T0);
        for (int n = 0; n < 100; n += 2)
        {
            long at = T0 + n * (S / 10);
            late.sequence(guest, "MOVE", seqFields("MOVE", 2000 + n + 1), at);   // pairs arrive swapped
            late.sequence(guest, "MOVE", seqFields("MOVE", 2000 + n), at);
        }
        check(row(late.statusLines(List.of(session), T0 + 10 * S), "GuestWitcher").contains(" 0.0% "),
                "late packets are not loss: " + row(late.statusLines(List.of(session), T0 + 10 * S), "GuestWitcher"));

        ConnectionStats restart = new ConnectionStats();
        restart.packetIn(guest, T0);
        for (int n = 0; n < 50; n++) restart.sequence(guest, "MOVE", seqFields("MOVE", 10 + n), T0 + n * (S / 10));
        for (int n = 0; n < 50; n++) restart.sequence(guest, "MOVE", seqFields("MOVE", 90_000_000 + n), T0 + 5 * S + n * (S / 10));
        for (int n = 0; n < 20; n++) restart.sequence(guest, "MOVE", seqFields("MOVE", 3 + n), T0 + 9 * S + n * (S / 40));
        check(row(restart.statusLines(List.of(session), T0 + 10 * S), "GuestWitcher").contains(" 0.0% "),
                "a restarted or wrapped counter is a new stream, not loss");

        ConnectionStats junk = new ConnectionStats();
        junk.packetIn(guest, T0);
        for (String bad : new String[] {"", "-5", "0", "12x", "99999999999999999999"})
        {
            junk.sequence(guest, "MOVE", Arrays.asList(bad, "0"), T0 + S);
        }
        junk.sequence(guest, "MOVE", List.of(), T0 + S);
        junk.sequence(guest, "UPDATE1A", List.of("5"), T0 + S);
        check(row(junk.statusLines(List.of(session), T0 + 3 * S), "GuestWitcher").contains(" n/a "), "malformed numbers are ignored");
    }

    private static void gapsAndLastPacket() throws Exception
    {
        ConnectionStats stats = new ConnectionStats();
        ClientEndpoint guest = endpoint("10.0.0.2", 50000);
        PlayerSession session = new PlayerSession(2, "GuestWitcher", guest, T0);
        for (int n = 0; n < 10; n++) stats.packetIn(guest, T0 + n * (S / 10));
        stats.packetIn(guest, T0 + S - S / 10 + 3 * S);          // after 3 s of silence
        stats.packetIn(guest, T0 + 4 * S);
        String row = row(stats.statusLines(List.of(session), T0 + 6 * S + S / 2), "GuestWitcher");
        check(row.contains("  3.0s  "), "the 3 s silence is the gap: " + row);
        check(row.contains("  2.5s  "), "last packet 2.5 s ago: " + row);
        String later = row(stats.statusLines(List.of(session), T0 + 70 * S), "GuestWitcher");
        check(later.contains("  0.0s  "), "the gap is forgotten after 60 s: " + later);
    }

    private static void summaryTiming() throws Exception
    {
        ConnectionStats stats = new ConnectionStats();
        ClientEndpoint host = endpoint("127.0.0.1", 61234);
        ClientEndpoint guest = endpoint("10.147.17.23", 50211);
        List<PlayerSession> none = List.of();
        List<PlayerSession> two = List.of(new PlayerSession(2, "GuestWitcher", guest, T0), new PlayerSession(1, "HostWitcher", host, T0));

        check(stats.tick(none, T0) == null, "no summary without players");
        String first = null;
        int lines = 0;
        for (int second = 0; second <= 130; second++)
        {
            long now = T0 + second * S;
            stats.packetIn(host, now);
            stats.packetIn(guest, now);
            String summary = stats.tick(two, now);
            if (summary != null)
            {
                lines++;
                if (first == null) first = second + ":" + summary;
            }
        }
        check(lines == 2, "a summary at 60 s and 120 s: " + lines);
        check(first != null && first.startsWith("60:Connections (last 10 s): HostWitcher 127.0.0.1 in 1.0/s"), "first after a full minute, host first: " + first);
        check(first.contains(" | GuestWitcher 10.147.17.23 in ") && first.endsWith("(type status for details)"), "both players on one line: " + first);
        check(!first.contains("50211"), "the summary leaves out ports");

        check(stats.tick(none, T0 + 131 * S) == null, "players gone: no summary");
        check(stats.tick(two, T0 + 132 * S) == null, "players back: the minute starts again");
        check(stats.tick(two, T0 + 191 * S) == null && stats.tick(two, T0 + 192 * S) != null, "then the next summary after 60 s");

        ConnectionStats off = new ConnectionStats();
        off.setSummarySeconds(0);
        boolean any = false;
        for (int second = 0; second <= 200; second++) any |= off.tick(two, T0 + second * S) != null;
        check(!any, "0 turns the summary off");
    }

    private static void configuration()
    {
        ConnectionStats stats = new ConnectionStats();
        check(stats.summarySeconds() == 60, "60 s by default");
        stats.configure(props("15"));
        check(stats.summarySeconds() == 15, "server.properties sets the interval");
        stats.configure(props("0"));
        check(stats.summarySeconds() == 0, "0 is off");
        stats.configure(props("soon"));
        check(stats.summarySeconds() == 0, "a bad value keeps the current one");
        stats.configure(props("-3"));
        check(stats.summarySeconds() == 0, "a negative value is refused");
        stats.configure(new Properties());
        check(stats.summarySeconds() == 0, "no key, no change");
    }

    private static void unknownEndpoints() throws Exception
    {
        ConnectionStats stats = new ConnectionStats();
        ClientEndpoint stranger = endpoint("10.9.9.9", 1234);
        stats.packetOut(stranger, T0);
        check(stats.trackedEndpoints() == 0, "sending to an endpoint that never sent creates nothing");
        for (int n = 0; n < 400; n++) stats.packetIn(endpoint("10.1." + (n / 200) + "." + (n % 200 + 1), 40000), T0);
        check(stats.trackedEndpoints() == 256, "at most 256 endpoints are tracked: " + stats.trackedEndpoints());
        stats.packetIn(stranger, T0 + 11 * S);
        check(stats.trackedEndpoints() == 1, "silent ones make room for a new sender: " + stats.trackedEndpoints());

        ClientEndpoint guest = endpoint("10.147.17.23", 50211);
        stats.packetIn(guest, T0 + 11 * S);
        stats.tick(List.of(new PlayerSession(2, "GuestWitcher", guest, T0)), T0 + 30 * S);
        check(stats.trackedEndpoints() == 1, "an idle endpoint without a player is forgotten, a player's is kept");
    }

    private static void statusTable() throws Exception
    {
        ConnectionStats stats = new ConnectionStats();
        List<String> empty = stats.statusLines(List.of(), T0);
        check(empty.size() == 2 && empty.get(1).equals("No players connected."), "an empty server says so: " + empty);

        ClientEndpoint guest = endpoint("10.147.17.23", 50211);
        PlayerSession unseen = new PlayerSession(4, "NoCounters", guest, T0 - 2 * S);
        String row = row(stats.statusLines(List.of(unseen), T0), "NoCounters");
        check(row.contains("  2.0s  ") && row.contains(" n/a "), "a player without counters still shows the last packet: " + row);
        List<String> lines = stats.statusLines(List.of(unseen), T0);
        check(lines.get(1).contains("address") && lines.get(1).contains("loss") && lines.get(1).contains("ping"), "a header names the columns");
        check(lines.get(lines.size() - 1).startsWith("ping: n/a"), "the footer explains ping");
    }

    // A real server: two simulated players send numbered movement, one loses every 10th packet;
    // "status" typed on the console lists both with their address, rates and loss.
    private static void realServer(String java, String classes, Path root) throws Exception
    {
        Files.createDirectories(root);
        Path log = root.resolve("connection-status-server.log");
        int port;
        try (DatagramSocket free = new DatagramSocket(0, InetAddress.getLoopbackAddress())) { port = free.getLocalPort(); }
        ProcessBuilder builder = new ProcessBuilder(java, "-cp", Paths.get(classes).toAbsolutePath().toString(), "WitcherServer", Integer.toString(port));
        builder.redirectErrorStream(true).redirectOutput(log.toFile());
        Process server = builder.start();
        try (DatagramSocket alice = socket(port); DatagramSocket bob = socket(port))
        {
            ready(alice, server);
            long until = System.nanoTime() + 2_600_000_000L;
            int n = 0;
            while (System.nanoTime() < until)
            {
                if (n % 10 != 9) send(alice, "MOVE\tAlice\t" + (100 + n) + "\t1\t2\t3\t1\t0\t0\t0");
                send(bob, "UPDATE1A\tBob\t" + (n + 1) + "\t" + (7000 + n) + "\t1\t2\t3\t1\t0\t0\t0");
                send(bob, "UPDATE1B\tBob\t" + (n + 1) + "\t" + (7000 + n) + "\tx");
                n++;
                Thread.sleep(10);
            }
            type(server, "help");
            type(server, "status");
            String output = waitFor(log, "ping: n/a, the game");
            String aliceRow = lineWith(output, " Alice ");
            String bobRow = lineWith(output, " Bob ");
            check(output.contains("status                    - each player's connection"), "help lists status");
            check(output.contains("---- Connection status: 2 players;"), "both players counted: " + output);
            check(aliceRow.contains("127.0.0.1:" + alice.getLocalPort()), "Alice's address and port: " + aliceRow);
            check(bobRow.contains("127.0.0.1:" + bob.getLocalPort()), "Bob's address and port: " + bobRow);
            double aliceLoss = lossOf(aliceRow), bobLoss = lossOf(bobRow);
            check(aliceLoss >= 5.0 && aliceLoss <= 15.0, "Alice loses about 10 %: " + aliceRow);
            check(bobLoss == 0.0, "Bob's paired UPDATE1A/1B lose nothing: " + bobRow);
            check(!aliceRow.contains("   -  ") && !aliceRow.contains(" ? "), "Alice has rates: " + aliceRow);
            check(aliceRow.trim().endsWith("n/a"), "ping n/a");
        }
        finally
        {
            if (server.isAlive())
            {
                type(server, "stop");
                if (!server.waitFor(5, TimeUnit.SECONDS)) { server.destroyForcibly(); server.waitFor(); }
            }
        }
        check(server.exitValue() == 0, "server stops cleanly");
    }

    private static double lossOf(String row)
    {
        for (String token : row.trim().split("\\s+"))
        {
            if (token.endsWith("%")) return Double.parseDouble(token.substring(0, token.length() - 1));
        }
        throw new AssertionError("no loss column: " + row);
    }

    private static String waitFor(Path log, String marker) throws Exception
    {
        long until = System.nanoTime() + 5_000_000_000L;
        String text = "";
        while (System.nanoTime() < until)
        {
            text = Files.exists(log) ? new String(Files.readAllBytes(log), StandardCharsets.UTF_8) : "";
            if (text.contains(marker)) return text;
            Thread.sleep(50);
        }
        throw new AssertionError("server never printed '" + marker + "':\n" + text);
    }

    private static String lineWith(String text, String part)
    {
        for (String line : text.substring(Math.max(0, text.lastIndexOf("---- Connection status"))).split("\\R"))
        {
            if (line.contains(part) && line.contains("127.0.0.1:")) return line;
        }
        throw new AssertionError("no line with '" + part + "' in:\n" + text);
    }

    private static void type(Process server, String command) throws IOException
    {
        server.getOutputStream().write((command + "\n").getBytes(StandardCharsets.UTF_8));
        server.getOutputStream().flush();
    }

    private static DatagramSocket socket(int port) throws Exception
    {
        DatagramSocket socket = new DatagramSocket(0, InetAddress.getLoopbackAddress());
        socket.connect(InetAddress.getLoopbackAddress(), port);
        socket.setSoTimeout(300);
        return socket;
    }

    private static void send(DatagramSocket socket, String text) throws IOException
    {
        byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
        socket.send(new DatagramPacket(bytes, bytes.length));
    }

    private static void ready(DatagramSocket socket, Process server) throws Exception
    {
        for (int attempt = 0; attempt < 30; attempt++)
        {
            if (!server.isAlive()) throw new AssertionError("server exited during startup");
            try
            {
                send(socket, "MOVE\t ");
                byte[] buffer = new byte[512];
                DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
                socket.receive(packet);
                if (new String(buffer, 0, packet.getLength(), StandardCharsets.UTF_8).equals("ERROR\tINVALID_USERNAME")) return;
            }
            catch (IOException ignored)
            {
                Thread.sleep(30);
            }
        }
        throw new AssertionError("server did not become ready");
    }

    private static List<String> seqFields(String opcode, long sequence)
    {
        List<String> fields = new ArrayList<>();
        if (!"MOVE".equals(opcode)) fields.add("77");     // UPDATE1A/1B: update sequence first
        fields.add(Long.toString(sequence));
        fields.addAll(Arrays.asList("1", "2", "3", "1", "0", "0", "0"));
        return fields;
    }

    private static String row(List<String> lines, String name)
    {
        for (String line : lines)
        {
            if (line.contains(" " + name + " ")) return line;
        }
        throw new AssertionError("no row for " + name + ": " + lines);
    }

    private static ClientEndpoint endpoint(String ip, int port) throws Exception
    {
        return new ClientEndpoint(InetAddress.getByName(ip), port);
    }

    private static Properties props(String value)
    {
        Properties properties = new Properties();
        properties.setProperty(ConnectionStats.SUMMARY_PROPERTY, value);
        return properties;
    }

    private static void check(boolean condition, String message)
    {
        assertions++;
        if (!condition) throw new AssertionError(message);
    }
}
