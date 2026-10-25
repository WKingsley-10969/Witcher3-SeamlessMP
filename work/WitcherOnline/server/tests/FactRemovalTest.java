import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicLong;

/** Absent is a durable fact state, never an alias for an existing zero. */
public final class FactRemovalTest {
    private static int assertions;
    private static final String TOKEN = "fact-removal-host-proof", H = "remove_host_0000001", G = "remove_guest_000001";
    private static void eq(Object expected, Object actual) {
        assertions++;
        if (!Objects.equals(expected, actual)) throw new AssertionError("Expected " + expected + " got " + actual);
    }
    private static void status(String expected, List<String> reply) { eq(expected, reply.get(6)); }
    public static void main(String[] args) throws Exception {
        Path root = Paths.get(args[0]); Files.createDirectories(root);
        Path dir = Files.createTempDirectory(root, "fact-removal-");
        AtomicLong now = new AtomicLong(100000); String epoch; long next;
        try (SeamlessCampaign c = new SeamlessCampaign(dir, "Host", TOKEN, true, true, now::get)) {
            Peer host = new Peer(c, "Host", H), guest = new Peer(c, "SecondPC", G);
            epoch = host.hello("host", TOKEN, "fact,journal,fact_remove").get(2);
            status("WELCOME", guest.hello("guest", "-", "fact,journal")); host.epoch = guest.epoch = epoch;
            status("OK", host.op("OPEN", "scope", "quest", "questA"));
            status("OK", guest.op("OPEN", "other", "quest", "questB"));
            status("OK", host.op("EFFECT", "zero", "scope", "fact", "sc_test_removed", "0"));
            long base = host.latest();
            status("CAPABILITY_REQUIRED", host.op("EFFECT", "remove", "scope", "fact", "sc_test_removed", "absent"));
            eq(base, host.latest());
            status("WELCOME", guest.hello("guest", "-", "fact,fact_remove"));
            status("NOT_OWNER", guest.op("EFFECT", "stolen", "scope", "fact", "sc_test_removed", "absent"));
            status("BAD_EFFECT_VALUE", host.op("EFFECT", "bad", "scope", "fact", "sc_test_removed", "absent@10"));
            status("UNSUPPORTED_EFFECT", host.op("EFFECT", "bad-kind", "scope", "fact_remove", "sc_test_removed", "0"));
            status("OK", guest.op("TX_BEGIN", "stale", "other", Long.toString(base), "1"));
            status("OK", guest.op("TX_EFFECT", "stale", "m", "fact", "sc_test_removed", "8", "0"));
            // Prepared while everyone supports removal; recheck capability at commit.
            status("OK", host.op("TX_BEGIN", "pending", "scope", Long.toString(base), "1"));
            status("OK", host.op("TX_EFFECT", "pending", "m", "fact", "sc_test_removed", "absent", "0"));
            status("WELCOME", guest.hello("guest", "-", "fact"));
            status("CAPABILITY_REQUIRED", host.op("TX_COMMIT", "pending"));
            eq(base, host.latest());
            status("WELCOME", guest.hello("guest", "-", "fact,fact_remove"));
            status("OK", host.op("EFFECT", "remove", "scope", "fact", "sc_test_removed", "absent"));
            List<String> duplicate = host.op("EFFECT", "remove", "scope", "fact", "sc_test_removed", "absent");
            status("OK", duplicate); eq("DUPLICATE", duplicate.get(8));
            status("TRANSACTION_CONFLICT", host.op("EFFECT", "remove", "scope", "fact", "sc_test_removed", "0"));
            status("REVISION_CONFLICT", guest.op("TX_COMMIT", "stale"));
            List<String> event = guest.op("GET_STATE", Long.toString(base), "other");
            status("STATE", event); eq("TRANSACTION", event.get(17)); eq("fact", event.get(25)); eq("absent", event.get(27));
            long afterRemoval = host.latest(); eq(base + 1, afterRemoval);
            status("OK", host.op("TX_BEGIN", "wrong", "scope", Long.toString(afterRemoval), "1"));
            status("OK", host.op("TX_EFFECT", "wrong", "m", "fact", "sc_test_removed", "5", "0"));
            status("VALUE_CONFLICT", host.op("TX_COMMIT", "wrong"));
            // SET and REMOVE occupy the same target slot within a transaction.
            status("OK", host.op("TX_BEGIN", "dup-target", "scope", Long.toString(afterRemoval), "2"));
            status("OK", host.op("TX_EFFECT", "dup-target", "m", "fact", "sc_test_removed", "0", "absent"));
            status("DUPLICATE_TARGET", host.op("TX_EFFECT", "dup-target", "other", "fact", "sc_test_removed", "absent", "-"));
            status("OK", host.op("TX_BEGIN", "restore", "scope", Long.toString(afterRemoval), "1"));
            status("OK", host.op("TX_EFFECT", "restore", "m", "fact", "sc_test_removed", "0", "absent"));
            status("OK", host.op("TX_COMMIT", "restore"));
            next = host.seq;
        }
        try (SeamlessCampaign c = new SeamlessCampaign(dir, "Host", TOKEN, true, true, now::get)) {
            Peer host = new Peer(c, "Host", H); host.seq = next; host.epoch = epoch;
            // Older adapters are refused even though the latest state is zero again.
            status("CAPABILITY_REQUIRED", host.hello("host", TOKEN, "fact,journal"));
            host.seq--; // refused HELLO never commits the request sequence
            status("WELCOME", host.hello("host", TOKEN, "fact,journal,fact_remove"));
            status("OK", host.op("EFFECT", "remove", "scope", "fact", "sc_test_removed", "absent"));
            long cursor = 0; int removals = 0, zeros = 0;
            while (true) {
                List<String> event = host.op("GET_STATE", Long.toString(cursor), "-"); status("STATE", event);
                if (event.get(15).equals("0")) break;
                cursor = Long.parseLong(event.get(16));
                if (!event.get(17).equals("TRANSACTION")) continue;
                if (event.get(27).equals("absent")) removals++;
                if (event.get(27).equals("0")) zeros++;
            }
            eq(1, removals); eq(2, zeros);
        }
        System.out.println("FactRemovalTest passed: " + assertions + " assertions");
    }
    private static final class Peer {
        final SeamlessCampaign campaign; final String name, id; long seq = 1; String epoch;
        Peer(SeamlessCampaign c, String n, String id) { campaign = c; name = n; this.id = id; }
        List<String> hello(String role, String proof, String caps) { return send("HELLO", role, proof, caps); }
        List<String> op(String op, String... args) {
            List<String> values = new ArrayList<>(); values.add(epoch); values.addAll(Arrays.asList(args));
            return send(op, values.toArray(new String[0]));
        }
        List<String> send(String op, String... args) {
            List<String> fields = new ArrayList<>(Arrays.asList("sc", "1", id, Long.toString(seq++), op));
            fields.addAll(Arrays.asList(args)); return campaign.request(name, name + ":1", fields);
        }
        long latest() { List<String> r = op("GET_STATE", "0", "-"); status("STATE", r); return Long.parseLong(r.get(7)); }
    }
}
