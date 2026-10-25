import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;

/** Real subprocess + UDP tests; no game, native DLL, installed game files or saves involved. */
public final class SeamlessUdpIntegrationTest {
    private static int assertions;
    private static final String TOKEN = "udp-test-host-proof-long", H = "host_udp_session_0001", G = "guest_udp_session_001";
    private static void eq(Object expected, Object actual) { assertions++; if (!Objects.equals(expected, actual)) throw new AssertionError("Expected " + expected + " got " + actual); }
    private static void status(String expected, List<String> reply) { eq("COOP", reply.get(0)); eq("2147483647", reply.get(1)); eq("SCServer", reply.get(2)); eq(expected, reply.get(9)); }
    public static void main(String[] args) throws Exception {
        String java = args[0], classes = Paths.get(args[1]).toAbsolutePath().toString();
        Path root = Paths.get(args[2]); Files.createDirectories(root); Path state = Files.createTempDirectory(root, "udp-");
        int port; try (DatagramSocket free = new DatagramSocket(0, InetAddress.getLoopbackAddress())) { port = free.getLocalPort(); }
        Process server = start(java, classes, state, port, "first.log");
        try (Peer host = new Peer(port, "Host", H); Peer guest = new Peer(port, "SecondPC", G); Peer forged = new Peer(port, "Host", H)) {
            ready(host, server);
            status("HOST_AUTH_FAILED", forged.send(1, "HELLO", "host", "wrong", "fact,journal"));
            status("HOST_AUTH_FAILED", forged.send(1, "HELLO", "guest", "-", "fact,journal"));
            List<String> welcome = host.send(1, "HELLO", "host", TOKEN, "fact,journal"); status("WELCOME", welcome); String epoch = welcome.get(5);
            status("WELCOME", guest.send(1, "HELLO", "guest", "-", "fact,journal"));
            // Deliver request 3 before request 2, then retry the gap after committing 2.
            status("BAD_SEQUENCE", host.send(3, "OPEN", epoch, "hostConv", "quest", "questA"));
            List<String> first = host.send(2, "OPEN", epoch, "hostConv", "quest", "questA"); status("OK", first);
            // Deliberately discard the first success as if the UDP response was lost.
            List<String> retry = host.send(2, "OPEN", epoch, "hostConv", "quest", "questA"); status("OK", retry);
            eq(first.subList(9, first.size()), retry.subList(9, retry.size())); eq(false, first.get(6).equals(retry.get(6)));
            status("REQUEST_CONFLICT", host.send(2, "OPEN", epoch, "tampered", "quest", "questA"));
            status("STATE", host.send(3, "GET_STATE", epoch, "0", "hostConv"));
        } finally {
            if (server.isAlive()) stop(server);
        }
        // Full restart/crash and transaction scenario uses a fresh campaign so packet sequence is explicit.
        state = Files.createTempDirectory(root, "udp-recovery-"); server = start(java, classes, state, port, "before-crash.log");
        try (Peer host = new Peer(port, "Host", H); Peer guest = new Peer(port, "SecondPC", G); Peer evil = new Peer(port, "Host", H)) {
            ready(host, server);
            List<String> welcome = host.send(1, "HELLO", "host", TOKEN, "fact,journal"); status("WELCOME", welcome); String epoch = welcome.get(5);
            status("WELCOME", guest.send(1, "HELLO", "guest", "-", "fact,journal"));
            status("OK", host.send(2, "OPEN", epoch, "hostConv", "quest", "questA"));
            status("OK", guest.send(2, "OPEN", epoch, "guestConv", "quest", "questB"));
            status("BUSY", guest.send(3, "OPEN", epoch, "steal", "quest", "questA"));
            status("NOT_OWNER", guest.send(4, "CHOICE", epoch, "hostConv", "forged"));
            status("HELLO_REQUIRED", evil.send(3, "CHOICE", epoch, "hostConv", "forged"));
            status("OK", host.send(3, "TX_BEGIN", epoch, "tx-wire", "hostConv", "2", "2"));
            status("OK", host.send(4, "TX_EFFECT", epoch, "tx-wire", "m1", "fact", "fact_wire", "7", "-"));
            status("INCOMPLETE_TRANSACTION", host.send(5, "TX_COMMIT", epoch, "tx-wire"));
            status("OK", host.send(6, "TX_EFFECT", epoch, "tx-wire", "m2", "journal", "journal_wire", "2", "-"));
            status("OK", host.send(7, "TX_COMMIT", epoch, "tx-wire"));
            status("OK", host.send(7, "TX_COMMIT", epoch, "tx-wire"));
            List<String> event = guest.send(5, "GET_STATE", epoch, "2", "guestConv"); status("STATE", event);
            eq("3", event.get(10)); eq("TRANSACTION", event.get(20)); eq("tx-wire", event.get(22)); eq("2", event.get(26));
            status("STALE_EPOCH", host.send(8, "GET_STATE", "1", "0", "hostConv"));
            status("OK", host.send(8, "ACK", epoch, "3"));
            // Reserved pseudo-server identity cannot be registered through legacy MOVE or an explicit player id.
            eq("ERROR\tRESERVED_IDENTITY", evil.raw("MOVE\tSCServer\t0\t0\t0\t0\t0\t0\t0\t0"));
            eq("ERROR\tRESERVED_IDENTITY", evil.raw("MOVE\t2147483647\tAnyName\t0\t0\t0\t0\t0\t0\t0\t0"));
            // Same-IP legacy endpoint/name takeover does not authenticate the separate campaign session.
            evil.rawSend("MOVE\tHost\t0\t0\t0\t0\t0\t0\t0\t0"); evil.drain();
            status("HELLO_REQUIRED", evil.send(9, "CLOSE", epoch, "hostConv"));
            // The committed response was observed before an abrupt process kill; restart must retain it.
            server.destroyForcibly(); if (!server.waitFor(5, TimeUnit.SECONDS)) throw new AssertionError("Server did not terminate");
            server = start(java, classes, state, port, "after-crash.log"); ready(host, server);
            status("HELLO_REQUIRED", host.send(9, "GET_STATE", epoch, "0", "hostConv"));
            status("WELCOME", host.send(9, "HELLO", "host", TOKEN, "fact,journal"));
            status("OK", host.send(10, "TX_COMMIT", epoch, "tx-wire"));
            List<String> replay = host.send(11, "GET_STATE", epoch, "2", "-"); status("STATE", replay);
            eq("TRANSACTION", replay.get(20)); eq("tx-wire", replay.get(22)); eq("", replay.get(12));
            eq("5", replay.get(10));
            status("WELCOME", guest.send(6, "HELLO", "guest", "-", "fact,journal"));
            status("NOT_OWNER", guest.send(7, "TX_COMMIT", epoch, "tx-wire"));
        } finally { if (server.isAlive()) stop(server); }
        dialogueInstances(java, classes, root, port);
        factRemovals(java, classes, root, port);
        coopChannels(java, classes, root, port);
        System.out.println("SeamlessUdpIntegrationTest passed: " + assertions + " assertions (loss/duplicate/reorder/auth/crash/replay)");
    }
    // A party leader's game keeps one co-op state per channel, 14 of them by now: every one must reach
    // the other player (the server dropped channels past 12 without a word).
    private static void coopChannels(String java, String classes, Path root, int port) throws Exception {
        Path state = Files.createTempDirectory(root, "udp-channels-"); Process server = start(java, classes, state, port, "channels.log");
        try (Peer leader = new Peer(port, "Leader", H); Peer member = new Peer(port, "Member", G)) {
            ready(leader, server);
            member.rawSend("COOP\tMember\thit\t1");
            Set<String> wanted = new TreeSet<>(), seen = new TreeSet<>();
            for (String channel : "en hurt jr fx np nq cv dn tr ss lt lc rw xx".split(" ")) {
                wanted.add(channel);
                leader.rawSend("COOP\tLeader\t" + channel + "\tstate-" + channel);
            }
            long until = System.nanoTime() + 3_000_000_000L;
            while (System.nanoTime() < until && !seen.equals(wanted)) {
                try {
                    List<String> fields = Arrays.asList(member.receive().split("\t", -1));
                    if (fields.size() > 4 && fields.get(0).equals("COOP") && fields.get(2).equals("Leader")) { eq("state-" + fields.get(3), fields.get(4)); seen.add(fields.get(3)); }
                } catch (SocketTimeoutException ignored) {}
            }
            eq(wanted, seen);
        } finally { if (server.isAlive()) stop(server); }
    }
    private static void factRemovals(String java, String classes, Path root, int port) throws Exception {
        Path state = Files.createTempDirectory(root, "udp-removal-"); Process server = start(java, classes, state, port, "removal-first.log");
        try (Peer host = new Peer(port, "Host", H); Peer guest = new Peer(port, "SecondPC", G)) {
            ready(host, server);
            List<String> welcome = host.send(1, "HELLO", "host", TOKEN, "fact,fact_remove"); status("WELCOME", welcome); String epoch = welcome.get(5);
            status("WELCOME", guest.send(1, "HELLO", "guest", "-", "fact,fact_remove"));
            status("OK", guest.send(2, "OPEN", epoch, "guestRemoval", "quest", "questRemoval"));
            status("OK", guest.send(3, "EFFECT", epoch, "zero", "guestRemoval", "fact", "sc_test_removed", "0"));
            List<String> removed = guest.send(4, "EFFECT", epoch, "remove", "guestRemoval", "fact", "sc_test_removed", "absent"); status("OK", removed);
            // Drop the observed response and resend the same request, then a new-sequence duplicate.
            List<String> retry = guest.send(4, "EFFECT", epoch, "remove", "guestRemoval", "fact", "sc_test_removed", "absent"); status("OK", retry);
            eq(removed.subList(9, removed.size()), retry.subList(9, retry.size()));
            List<String> duplicate = guest.send(5, "EFFECT", epoch, "remove", "guestRemoval", "fact", "sc_test_removed", "absent"); status("OK", duplicate); eq("DUPLICATE", duplicate.get(11));
            List<String> event = host.send(2, "GET_STATE", epoch, "2", "-"); status("STATE", event);
            eq("3", event.get(10)); eq("TRANSACTION", event.get(20)); eq("absent", event.get(30));
            status("TRANSACTION_CONFLICT", guest.send(6, "EFFECT", epoch, "remove", "guestRemoval", "fact", "sc_test_removed", "0"));
            // Kill only this test's owned server after durable removal and recover its ledger.
            server.destroyForcibly(); if (!server.waitFor(5, TimeUnit.SECONDS)) throw new AssertionError("Removal server did not stop");
            server = start(java, classes, state, port, "removal-restart.log"); ready(host, server);
            status("CAPABILITY_REQUIRED", host.send(3, "HELLO", "host", TOKEN, "fact"));
            status("WELCOME", host.send(3, "HELLO", "host", TOKEN, "fact,fact_remove"));
            List<String> replay = host.send(4, "GET_STATE", epoch, "2", "-"); status("STATE", replay);
            eq("absent", replay.get(30)); eq("remove", replay.get(22));
            status("WELCOME", guest.send(7, "HELLO", "guest", "-", "fact,fact_remove"));
            status("OK", guest.send(8, "EFFECT", epoch, "remove", "guestRemoval", "fact", "sc_test_removed", "absent"));
            List<String> tail = host.send(5, "GET_STATE", epoch, "3", "-"); status("STATE", tail);
            eq("CLOSE", tail.get(20)); eq("4", tail.get(10)); // no second removal event
        } finally { if (server.isAlive()) stop(server); }
    }
    private static void dialogueInstances(String java, String classes, Path root, int port) throws Exception {
        Path state = Files.createTempDirectory(root, "udp-dialogue-"); Process server = start(java, classes, state, port, "dialogue-first.log");
        try (DialogPeer host = new DialogPeer(port, "Host", H); DialogPeer guest = new DialogPeer(port, "SecondPC", G)) {
            ready(host.wire, server);
            List<String> welcome = host.hello("host", TOKEN); status("WELCOME", welcome); String epoch = welcome.get(5);
            status("WELCOME", guest.hello("guest", "-")); host.epoch = guest.epoch = epoch;
            List<String> opened = host.op("OPEN", "talk", "npc", "npcA"); status("OK", opened); String lease = opened.get(11);
            status("OK", guest.op("LISTEN", "talk"));
            status("OK", host.op("CHOICES", "talk", lease, "prompt1", "yes,no", "true"));
            List<String> dialogue = guest.op("GET_DIALOGUE", "talk"); status("DIALOGUE", dialogue);
            eq(22, dialogue.size()); eq("talk", dialogue.get(10)); eq(lease, dialogue.get(11)); eq("prompt1", dialogue.get(12)); eq("Host", dialogue.get(21));
            status("NOT_OWNER", guest.op("CHOICE", "talk", lease, "prompt1", "yes"));
            // The future sequence arrives before the request at the gap; it must not mutate the prompt.
            status("BAD_SEQUENCE", host.wire.send(host.seq + 1, "CHOICE", epoch, "talk", lease, "prompt1", "yes"));
            status("VOTE_REQUIRED", host.op("CHOICE", "talk", lease, "prompt1", "yes"));
            status("CHOICE_INSTANCE_REQUIRED", host.op("CHOICE", "talk", "yes"));
            List<String> openedVote = host.op("VOTE_OPEN", "talk", lease, "prompt1"); status("OK", openedVote); String vote = openedVote.get(10);
            // Lose a vote-open ACK and retransmit exactly; no second event/vote may be created.
            List<String> retriedVote = host.wire.send(host.seq - 1, "VOTE_OPEN", epoch, "talk", lease, "prompt1"); status("OK", retriedVote);
            eq(openedVote.subList(9, openedVote.size()), retriedVote.subList(9, retriedVote.size()));
            status("STALE_CHOICE_INSTANCE", guest.op("VOTE_CAST", vote, lease, "oldPrompt", "no"));
            status("OK", host.op("VOTE_CAST", vote, lease, "prompt1", "yes"));
            List<String> tied = guest.op("VOTE_CAST", vote, lease, "prompt1", "no"); status("OK", tied); eq("yes", tied.get(11));
            status("VOTE_BINDING", host.op("CHOICE", "talk", lease, "prompt1", "no"));
            List<String> accepted = host.op("CHOICE", "talk", lease, "prompt1", "yes"); status("OK", accepted); String acceptedEvent = accepted.get(13);
            eq("false", accepted.get(14));
            List<String> exactRetry = host.wire.send(host.seq - 1, "CHOICE", epoch, "talk", lease, "prompt1", "yes"); status("OK", exactRetry);
            eq(accepted.subList(9, accepted.size()), exactRetry.subList(9, exactRetry.size()));
            List<String> rapidClick = host.op("CHOICE", "talk", lease, "prompt1", "yes"); status("OK", rapidClick); eq(acceptedEvent, rapidClick.get(13)); eq("true", rapidClick.get(14));
            List<String> current = guest.op("GET_STATE", "0", "talk"); status("STATE", current); eq(acceptedEvent, current.get(10));
            status("CHOICE_ALREADY_ACCEPTED", host.op("CHOICE", "talk", lease, "prompt1", "no"));
            status("OK", host.op("CHOICES", "talk", lease, "prompt2", "yes,no", "false"));
            status("STALE_CHOICE_INSTANCE", host.op("CHOICE", "talk", lease, "prompt1", "yes"));
            status("NO_VOTE", guest.op("VOTE_CAST", vote, lease, "prompt1", "no"));
            status("OK", host.op("CHOICE", "talk", lease, "prompt2", "no"));
            status("OK", host.op("CLOSE", "talk"));
            List<String> reopened = host.op("OPEN", "talk", "npc", "npcA"); status("OK", reopened); String newLease = reopened.get(11); eq(false, lease.equals(newLease));
            status("STALE_LEASE", host.op("CHOICES", "talk", lease, "prompt1", "yes,no", "false"));
            status("OK", host.op("CHOICES", "talk", newLease, "prompt1", "yes,no", "false"));
            status("STALE_LEASE", host.op("CHOICE", "talk", lease, "prompt1", "yes"));
            List<String> newAccepted = host.op("CHOICE", "talk", newLease, "prompt1", "yes"); status("OK", newAccepted);
            // Abrupt restart after durable acceptance. The active graph lease must not resume implicitly.
            server.destroyForcibly(); if (!server.waitFor(5, TimeUnit.SECONDS)) throw new AssertionError("Dialog test server did not stop");
            server = start(java, classes, state, port, "dialogue-restarted.log"); ready(host.wire, server);
            status("HELLO_REQUIRED", host.wire.send(host.seq, "CHOICE", epoch, "talk", newLease, "prompt1", "yes"));
            status("WELCOME", host.hello("host", TOKEN));
            status("NO_CONVERSATION", host.op("GET_DIALOGUE", "talk"));
            int choices = 0, firstCopies = 0; long cursor = 0;
            while (true) {
                List<String> event = host.op("GET_STATE", Long.toString(cursor), "-"); status("STATE", event);
                long latest = Long.parseLong(event.get(10));
                if (event.get(18).equals("0")) { eq(latest, cursor); break; }
                eq(Long.toString(cursor + 1), event.get(19)); cursor++;
                if (event.get(20).equals("DIALOG_CHOICE")) {
                    choices++;
                    if (event.get(23).equals(lease) && event.get(24).equals("prompt1")) firstCopies++;
                }
                eq(true, String.join("\t", event).getBytes(StandardCharsets.UTF_8).length < 8192);
            }
            eq(3, choices); eq(1, firstCopies);
        } finally { if (server.isAlive()) stop(server); }
    }
    private static final class DialogPeer implements AutoCloseable {
        final Peer wire; long seq = 1; String epoch;
        DialogPeer(int port, String name, String id) throws Exception { wire = new Peer(port, name, id); }
        List<String> hello(String role, String proof) throws Exception { return wire.send(seq++, "HELLO", role, proof, "-"); }
        List<String> op(String operation, String... args) throws Exception {
            List<String> values = new ArrayList<>(); values.add(epoch); values.addAll(Arrays.asList(args));
            return wire.send(seq++, operation, values.toArray(new String[0]));
        }
        public void close() { wire.close(); }
    }
    private static Process start(String java, String classes, Path state, int port, String log) throws IOException {
        ProcessBuilder builder = new ProcessBuilder(java, "-cp", classes, "WitcherServer", Integer.toString(port),
            "--campaign-host", "Host", "--campaign-dir", state.toAbsolutePath().toString(), "--campaign-voting", "true", "--campaign-shared-xp", "true");
        builder.environment().put("WO_CAMPAIGN_HOST_TOKEN", TOKEN);
        builder.redirectErrorStream(true).redirectOutput(state.resolve(log).toFile()); return builder.start();
    }
    private static void ready(Peer peer, Process server) throws Exception {
        for (int attempt = 0; attempt < 30; attempt++) {
            if (!server.isAlive()) throw new AssertionError("Server exited during startup");
            try { eq("ERROR\tINVALID_USERNAME", peer.raw("MOVE\t ")); return; }
            catch (SocketTimeoutException | PortUnreachableException ignored) { Thread.sleep(30); }
        }
        throw new AssertionError("Server did not become ready");
    }
    private static void stop(Process p) throws Exception {
        try { p.getOutputStream().write("stop\n".getBytes(StandardCharsets.UTF_8)); p.getOutputStream().flush(); }
        catch (IOException ignored) {}
        if (!p.waitFor(5, TimeUnit.SECONDS)) { p.destroyForcibly(); p.waitFor(); throw new AssertionError("Graceful server stop timed out"); }
        eq(0, p.exitValue());
    }
    private static final class Peer implements AutoCloseable {
        final DatagramSocket socket; final String name, id;
        Peer(int port, String name, String id) throws Exception { socket = new DatagramSocket(0, InetAddress.getLoopbackAddress()); socket.connect(InetAddress.getLoopbackAddress(), port); socket.setSoTimeout(300); this.name = name; this.id = id; }
        List<String> send(long seq, String op, String... args) throws Exception {
            String message = "COOP\t" + name + "\tsc\t1\t" + id + "\t" + seq + "\t" + op;
            for (String arg : args) message += "\t" + arg;
            rawSend(message);
            for (int n = 0; n < 10; n++) {
                String reply = receive(); List<String> fields = Arrays.asList(reply.split("\t", -1));
                if (fields.size() > 9 && fields.get(0).equals("COOP") && fields.get(2).equals("SCServer") && fields.get(7).equals(id) && fields.get(8).equals(Long.toString(seq))) return fields;
            }
            throw new AssertionError("No matching campaign response");
        }
        String raw(String message) throws Exception { rawSend(message); return receive(); }
        void rawSend(String message) throws Exception { byte[] bytes = message.getBytes(StandardCharsets.UTF_8); socket.send(new DatagramPacket(bytes, bytes.length)); }
        String receive() throws Exception { byte[] buffer = new byte[8192]; DatagramPacket packet = new DatagramPacket(buffer, buffer.length); socket.receive(packet); return new String(packet.getData(), 0, packet.getLength(), StandardCharsets.UTF_8); }
        void drain() throws Exception { try { for (int n = 0; n < 10; n++) receive(); } catch (SocketTimeoutException expected) {} }
        public void close() { socket.close(); }
    }
}
