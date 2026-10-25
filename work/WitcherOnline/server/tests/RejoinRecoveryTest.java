import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicLong;

/** Deterministic disconnects in both directions, with a live continuing peer. */
public final class RejoinRecoveryTest {
    private static int assertions;
    private static final String TOKEN = "recovery-test-host-proof", CAPS = "fact,fact_remove";
    private static final String H = "recovery_host_00001", G = "recovery_guest_0001";
    private static void eq(Object expected, Object actual) { assertions++; if (!Objects.equals(expected, actual)) throw new AssertionError("Expected " + expected + " got " + actual); }
    private static List<String> status(String expected, List<String> r) { eq(expected, r.get(6)); return r; }
    public static void main(String[] args) throws Exception {
        Path root = Paths.get(args[0]); Files.createDirectories(root);
        for (boolean hostDrops : new boolean[] {false, true}) scenario(root, hostDrops);
        System.out.println("RejoinRecoveryTest passed: " + assertions + " assertions");
    }
    private static void scenario(Path root, boolean hostDrops) throws Exception {
        Path dir = Files.createTempDirectory(root, "rejoin-"); AtomicLong clock = new AtomicLong(100000);
        long returningSeq; String epoch;
        try (SeamlessCampaign c = new SeamlessCampaign(dir, "Host", TOKEN, true, true, clock::get)) {
            Peer host = new Peer(c, "Host", H), guest = new Peer(c, "SecondPC", G);
            host.hello(); guest.hello(); epoch = host.epoch;
            Peer away = hostDrops ? host : guest, online = hostDrops ? guest : host;
            away.endpoint = "new:2";
            status("SESSION_ACTIVE", away.resume(away.seq));
            away.endpoint = away.name + ":1";
            String lease = status("OK", away.op("OPEN", "oldTalk", "npc", "npcA")).get(8);
            status("OK", away.op("CHOICES", "oldTalk", lease, "prompt", "yes,no", "false"));
            status("OK", away.op("CHOICE", "oldTalk", lease, "prompt", "yes"));
            status("OK", online.op("OPEN", "continuing", "quest", "questA"));
            status("OK", away.op("LISTEN", "continuing"));
            List<String> committed = status("OK", away.op("EFFECT", "beforeDrop", "oldTalk", "fact", "sc_test_removed", "0"));
            long lostSeq = away.seq - 1;
            // The effect response is lost. Do not replace it with a HELLO receipt.
            long cursor = latest(online);
            for (int i = 0; i < 4; i++) {
                clock.addAndGet(4000);
                status("OK", online.op("RENEW", "continuing"));
            }
            status("OK", online.op("EFFECT", "offlineSet", "continuing", "fact", "sc_test_changed", "9"));
            status("OK", online.op("EFFECT", "offlineRemove", "continuing", "fact", "sc_test_removed", "absent"));
            away.endpoint = "new:2";
            status("HELLO_REQUIRED", away.raw(lostSeq, "EFFECT", epoch, "beforeDrop", "oldTalk", "fact", "sc_test_removed", "0"));
            status("HOST_AUTH_FAILED", host.raw(host.seq, "RESUME", epoch, "host", "wrong", CAPS));
            status("CAPABILITY_REQUIRED", away.raw(lostSeq, "RESUME", epoch, away.role(), away.proof(), "fact"));
            status("STALE_EPOCH", away.raw(lostSeq, "RESUME", "0", away.role(), away.proof(), CAPS));
            List<String> resumed = status("RESUMED", away.resume(lostSeq));
            eq(Long.toString(lostSeq), resumed.get(9));
            List<String> retried = status("OK", away.raw(lostSeq, "EFFECT", epoch, "beforeDrop", "oldTalk", "fact", "sc_test_removed", "0"));
            eq(committed.subList(6, committed.size()), retried.subList(6, retried.size()));
            // Repeating RESUME cannot eat a sequence, append events or reacquire a scene.
            long floor = Long.parseLong(resumed.get(8));
            eq(resumed.subList(6, resumed.size()), status("RESUMED", away.resume(lostSeq)).subList(6, resumed.size()));
            status("NO_CONVERSATION", away.op("GET_DIALOGUE", "oldTalk"));
            Map<String, String> facts = new HashMap<>(); int tx = 0, choices = 0;
            while (true) {
                List<String> r = status("STATE", away.op("GET_STATE", Long.toString(cursor), "-"));
                if (r.get(15).equals("0")) break;
                eq(Long.toString(cursor + 1), r.get(16)); cursor++;
                if (r.get(17).equals("DIALOG_CHOICE")) choices++;
                if (r.get(17).equals("TRANSACTION")) { tx++; facts.put(r.get(26), r.get(27)); }
                status("OK", away.op("ACK", Long.toString(cursor)));
            }
            eq(floor, cursor); eq(2, tx); eq(0, choices);
            eq("absent", facts.get("sc_test_removed")); eq("9", facts.get("sc_test_changed"));
            // Rejoin once more at the applied cursor: no event, no transaction, no conversation.
            status("RESUMED", away.resume(away.seq));
            List<String> tail = status("STATE", away.op("GET_STATE", Long.toString(cursor), "oldTalk"));
            eq("0", tail.get(15)); eq("", tail.get(9)); eq(cursor, latest(online));
            // An uncommitted request must also retain its unused sequence across RESUME.
            status("RESUMED", online.resume(online.seq));
            status("OK", online.op("EFFECT", "afterResume", "continuing", "fact", "sc_test_changed", "2"));
            String onlineLease = status("DIALOGUE", online.op("GET_DIALOGUE", "continuing")).get(8);
            status("OK", online.op("CHOICES", "continuing", onlineLease, "newPrompt", "yes,no", "true"));
            String vote = status("OK", online.op("VOTE_OPEN", "continuing", onlineLease, "newPrompt")).get(7);
            // Reconnection alone never re-enrols the expired listener in a new vote.
            eq("yes", status("OK", online.op("VOTE_CAST", vote, onlineLease, "newPrompt", "yes")).get(8));
            status("NOT_VOTER", away.op("VOTE_CAST", vote, onlineLease, "newPrompt", "no"));
            returningSeq = away.seq;
        }
        try (SeamlessCampaign c = new SeamlessCampaign(dir, "Host", TOKEN, true, true, clock::get)) {
            Peer away = hostDrops ? new Peer(c, "Host", H) : new Peer(c, "SecondPC", G);
            away.epoch = epoch; away.seq = returningSeq;
            status("RESUMED", away.resume(away.seq));
            status("OK", away.op("EFFECT", "beforeDrop", "oldTalk", "fact", "sc_test_removed", "0"));
            int oldTransactions = 0, oldChoices = 0; long cursor = 0;
            while (true) {
                List<String> r = status("STATE", away.op("GET_STATE", Long.toString(cursor), "-"));
                if (r.get(15).equals("0")) break;
                cursor = Long.parseLong(r.get(16));
                if (r.get(17).equals("TRANSACTION") && r.get(19).equals("beforeDrop")) oldTransactions++;
                if (r.get(17).equals("DIALOG_CHOICE")) oldChoices++;
            }
            eq(1, oldTransactions); eq(1, oldChoices);
        }
    }
    private static long latest(Peer p) { return Long.parseLong(status("STATE", p.op("GET_STATE", "0", "-")).get(7)); }
    private static final class Peer {
        final SeamlessCampaign c; final String name, id; String endpoint, epoch; long seq = 1;
        Peer(SeamlessCampaign c, String name, String id) { this.c = c; this.name = name; this.id = id; endpoint = name + ":1"; }
        String role() { return name.equals("Host") ? "host" : "guest"; }
        String proof() { return name.equals("Host") ? TOKEN : "-"; }
        void hello() { epoch = status("WELCOME", raw(seq++, "HELLO", role(), proof(), CAPS)).get(2); }
        List<String> resume(long n) { return raw(n, "RESUME", epoch, role(), proof(), CAPS); }
        List<String> op(String op, String... args) { List<String> a = new ArrayList<>(); a.add(epoch); a.addAll(Arrays.asList(args)); return raw(seq++, op, a.toArray(new String[0])); }
        List<String> raw(long n, String op, String... args) {
            List<String> f = new ArrayList<>(Arrays.asList("sc", "1", id, Long.toString(n), op)); f.addAll(Arrays.asList(args));
            return c.request(name, endpoint, f);
        }
    }
}
