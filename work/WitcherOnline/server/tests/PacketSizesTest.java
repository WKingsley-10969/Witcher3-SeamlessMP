import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/** PacketSizes (datagram sizes against internet path limits) and the server's handling of large datagrams over real UDP. */
public final class PacketSizesTest {
    private static int assertions;
    private static void eq(Object expected, Object actual) { assertions++; if (!Objects.equals(expected, actual)) throw new AssertionError("Expected " + expected + " got " + actual); }
    private static void check(boolean condition, String what) { assertions++; if (!condition) throw new AssertionError(what); }

    public static void main(String[] args) throws Exception {
        bands();
        types();
        warnings();
        summary();
        if (args.length >= 3) udp(args[0], Paths.get(args[1]).toAbsolutePath().toString(), Paths.get(args[2]));
        System.out.println("PacketSizesTest passed: " + assertions + " assertions");
    }

    private static void bands() {
        eq(0, PacketSizes.band(1)); eq(0, PacketSizes.band(1200));
        eq(1, PacketSizes.band(1201)); eq(1, PacketSizes.band(1252));
        eq(2, PacketSizes.band(1253)); eq(2, PacketSizes.band(1472));
        eq(3, PacketSizes.band(1473)); eq(3, PacketSizes.band(2772));
        eq(4, PacketSizes.band(2773)); eq(4, PacketSizes.band(8192));
        eq(5, PacketSizes.band(8193)); eq(5, PacketSizes.band(65507));
        check(PacketSizes.RECEIVE_BUFFER_BYTES > 65507, "the receive buffer holds the largest UDP payload");
        check(PacketSizes.pathNote(1300).contains("Tailscale"), "1300 bytes are fragmented over Tailscale");
        check(PacketSizes.pathNote(2000).contains("1500-byte"), "2000 bytes are fragmented on ordinary internet paths");
        check(PacketSizes.pathNote(3000).contains("ZeroTier"), "3000 bytes are fragmented over ZeroTier");
    }

    private static void types() {
        eq("MOVE", PacketSizes.typeOf("MOVE\tBotA\t1\t2"));
        eq("UPDATE1A", PacketSizes.typeOf("UPDATE1A\t3\tBotA\t1"));
        eq("COOP/en", PacketSizes.typeOf("COOP\tBotA\ten\t1\t2"));
        eq("COOP/en", PacketSizes.typeOf("COOP\t12\tBotA\ten\t1\t2"));
        eq("COOP/np", PacketSizes.typeOf("COOP\t-1\tBotA\tnp"));
        eq("COOP/sc", PacketSizes.typeOf("COOP\t2147483647\tSCServer\tsc\t1"));
        eq("COOP/?", PacketSizes.typeOf("COOP\t12"));
        eq("COOP/?", PacketSizes.typeOf("COOP\tBotA"));
        eq("COOP/?", PacketSizes.typeOf("COOP\tBotA\twaytoolongchannel\t1"));
        eq("COOP/?", PacketSizes.typeOf("COOP\tBotA\tbad%chan"));
        eq("ERROR", PacketSizes.typeOf("ERROR\tBANNED"));
        eq("KICK", PacketSizes.typeOf("KICK"));
        eq("?", PacketSizes.typeOf(""));
        eq("?", PacketSizes.typeOf("\u0001\u0002\tx"));
        eq("COOP/hurt", PacketSizes.type("COOP", List.of("hurt", "1")));
        eq("COOP/?", PacketSizes.type("COOP", List.of()));
        eq("UPDATE3", PacketSizes.type("UPDATE3", List.of("1")));
    }

    private static void warnings() {
        AtomicLong now = new AtomicLong(1_000L);
        PacketSizes sizes = new PacketSizes(now::get);
        eq(null, sizes.record("in", "COOP/en", 1200, 1, "1.2.3.4:5"));
        String first = sizes.record("in", "COOP/en", 2922, 1, "1.2.3.4:5");
        check(first != null && first.contains("in COOP/en from 1.2.3.4:5, 2922 bytes") && first.contains("ZeroTier"), "first large datagram warns: " + first);
        eq(null, sizes.record("in", "COOP/en", 3000, 1, "1.2.3.4:5"));
        eq(null, sizes.record("in", "COOP/en", 1300, 4, "1.2.3.4:5"));
        String other = sizes.record("out", "COOP/en", 1300, 2, "BotA");
        check(other != null && other.contains("out COOP/en of BotA"), "each direction and type warns on its own: " + other);
        check(sizes.record("in", "COOP/np", 1500, 1, "x") != null, "another type warns on its own");
        now.addAndGet(PacketSizes.WARN_INTERVAL_NANOS - 1);
        eq(null, sizes.record("in", "COOP/en", 1500, 1, "1.2.3.4:5"));
        now.addAndGet(1);
        String later = sizes.record("in", "COOP/en", 1250, 1, "1.2.3.4:5");
        check(later != null && later.contains("(6 more over 1200 bytes since the last warning)"), "a warning every 30 s with the count in between: " + later);
        eq(3000, sizes.largest("in", "COOP/en"));
        eq(1L, sizes.datagrams("in", "COOP/en", 0));
        eq(1L, sizes.datagrams("in", "COOP/en", 1));
        eq(4L, sizes.datagrams("in", "COOP/en", 2));
        eq(1L, sizes.datagrams("in", "COOP/en", 3));
        eq(2L, sizes.datagrams("in", "COOP/en", 4));
        eq(null, sizes.record("in", "COOP/en", 5000, 0, "nobody"));
        eq(3000, sizes.largest("in", "COOP/en"));
        String refused = sizes.refuse("COOP/en", 9000, "BotA");
        check(refused != null && refused.contains("Not relayed: COOP/en of BotA is 9000 bytes"), "refusal warns: " + refused);
        eq(null, sizes.refuse("COOP/en", 9100, "BotA"));
        eq(9100, sizes.largest("out", "COOP/en"));
        // types from the network cannot grow the table without bound
        for (int i = 0; i < 2 * PacketSizes.MAX_TYPES; i++) sizes.record("in", "COOP/c" + i, 10, 1, "x");
        check(sizes.summary().contains("in other"), "types past the limit are counted as other");
        eq(0, sizes.largest("in", "COOP/c" + (PacketSizes.MAX_TYPES + 10)));
    }

    private static void summary() {
        PacketSizes sizes = new PacketSizes(() -> 0L);
        check(sizes.summary().contains("none"), "empty summary");
        sizes.record("in", "MOVE", 80, 10, "x");
        sizes.record("in", "COOP/np", 2370, 3, "x");
        sizes.record("out", "COOP/np", 2370, 6, "BotA");
        sizes.refuse("COOP/en", 9805, "BotA");
        String text = sizes.summary();
        check(text.contains("in MOVE") && text.contains("10 datagrams, largest     80"), text);
        check(text.contains("in COOP/np") && text.contains("largest   2370, 1473-2772: 3"), text);
        check(text.contains("out COOP/np") && text.contains("1473-2772: 6"), text);
        check(text.contains("out COOP/en") && text.contains("largest   9805, not relayed: 1"), text);
        check(text.contains("all by size: <=1200: 10, 1201-1252: 0, 1253-1472: 0, 1473-2772: 9, 2773-8192: 0, >8192: 0"), text);
    }

    // A real server: a 3000-byte snapshot is relayed whole; a 9000-byte one used to be cut to 8192 bytes and the
    // stump relayed, which the game client cannot even receive; now it is not relayed and the log says so.
    private static void udp(String java, String classes, Path root) throws Exception {
        Files.createDirectories(root);
        Path dir = Files.createTempDirectory(root, "packet-sizes-");
        Path log = dir.resolve("server.log");
        int port; try (DatagramSocket free = new DatagramSocket(0, InetAddress.getLoopbackAddress())) { port = free.getLocalPort(); }
        ProcessBuilder builder = new ProcessBuilder(java, "-cp", classes, "WitcherServer", Integer.toString(port));
        builder.directory(dir.toFile());
        builder.redirectErrorStream(true).redirectOutput(log.toFile());
        Process server = builder.start();
        try (Peer leader = new Peer(port); Peer member = new Peer(port)) {
            ready(member, server);
            member.send("COOP\tMember\thit\t1");
            String snapshot = "s".repeat(3000);
            for (int i = 0; i < 5; i++) leader.send("COOP\tLeader\ten\t" + snapshot);
            String big = "b".repeat(9000);
            leader.send("COOP\tLeader\tbig\t" + big);
            leader.send("COOP\tLeader\tok\tsmall");
            boolean gotSnapshot = false, gotSmall = false; int bigSeen = 0, largest = 0;
            long until = System.nanoTime() + 1_500_000_000L;
            while (System.nanoTime() < until) {
                String text;
                try { text = member.receive(); } catch (SocketTimeoutException e) { continue; }
                largest = Math.max(largest, text.getBytes(StandardCharsets.UTF_8).length);
                String[] f = text.split("\t", -1);
                if (f.length < 5 || !f[0].equals("COOP") || !f[2].equals("Leader")) continue;
                if (f[3].equals("en")) { eq(snapshot, f[4]); gotSnapshot = true; }
                if (f[3].equals("big")) bigSeen++;
                if (f[3].equals("ok")) gotSmall = true;
            }
            check(gotSnapshot, "a 3000-byte snapshot is relayed whole");
            check(gotSmall, "other channels are still relayed");
            eq(0, bigSeen);
            check(largest <= PacketSizes.CLIENT_RECEIVE_BYTES, "nothing over the client's receive buffer is sent: " + largest);
        } finally {
            server.getOutputStream().write("stop\n".getBytes(StandardCharsets.UTF_8));
            server.getOutputStream().flush();
            if (!server.waitFor(5, TimeUnit.SECONDS)) { server.destroyForcibly(); server.waitFor(); throw new AssertionError("Graceful server stop timed out"); }
        }
        String out = Files.readString(log, StandardCharsets.UTF_8);
        eq(1, count(out, "Large datagram: in COOP/en from 127.0.0.1:"));
        eq(1, count(out, "Large datagram: out COOP/en of Leader"));
        check(out.contains("Large datagram: in COOP/big from") && out.contains("over the game client's 8192-byte receive buffer"), out);
        eq(1, count(out, "Not relayed: COOP/big of Leader is 9018 bytes"));
        check(out.contains("Datagram sizes in bytes"), "summary at shutdown: " + out);
        check(lineWith(out, "  in COOP/en ").contains("5 datagrams, largest   3015, 2773-8192: 5"), out);
        check(lineWith(out, "  in COOP/big ").contains("largest   9016, >8192: 1"), out);
        check(lineWith(out, "  out COOP/big ").contains("not relayed:"), out);
        check(lineWith(out, "  out COOP/en ").contains("largest   3017"), out);
        check(!out.contains("bbbbbbbb") && !out.contains("ssssssss"), "contents are never logged");
    }

    private static int count(String text, String part) {
        int n = 0;
        for (int i = text.indexOf(part); i >= 0; i = text.indexOf(part, i + 1)) n++;
        return n;
    }

    private static String lineWith(String text, String part) {
        for (String line : text.split("\\R")) if (line.contains(part)) return line;
        throw new AssertionError("No line with '" + part + "' in:\n" + text);
    }

    private static void ready(Peer peer, Process server) throws Exception {
        for (int attempt = 0; attempt < 50; attempt++) {
            if (!server.isAlive()) throw new AssertionError("Server exited during startup");
            try { peer.send("MOVE\t "); eq("ERROR\tINVALID_USERNAME", peer.receive()); return; }
            catch (SocketTimeoutException | PortUnreachableException ignored) { Thread.sleep(30); }
        }
        throw new AssertionError("Server did not become ready");
    }

    private static final class Peer implements AutoCloseable {
        final DatagramSocket socket;
        Peer(int port) throws Exception { socket = new DatagramSocket(0, InetAddress.getLoopbackAddress()); socket.connect(InetAddress.getLoopbackAddress(), port); socket.setSoTimeout(200); }
        void send(String message) throws Exception { byte[] bytes = message.getBytes(StandardCharsets.UTF_8); socket.send(new DatagramPacket(bytes, bytes.length)); }
        String receive() throws Exception { byte[] buffer = new byte[65536]; DatagramPacket packet = new DatagramPacket(buffer, buffer.length); socket.receive(packet); return new String(packet.getData(), 0, packet.getLength(), StandardCharsets.UTF_8); }
        public void close() { socket.close(); }
    }
}
