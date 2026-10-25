import java.io.IOException;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicLong;

public final class SeamlessCampaignTest {
    private static int assertions;
    private static final String TOKEN = "test-host-proof-very-long";
    private static final String H = "host_session_000001", G = "guest_session_00001";
    private static List<String> call(SeamlessCampaign c, String name, String endpoint, String id, long seq, String op, String... args) {
        List<String> fields = new ArrayList<>(Arrays.asList("sc", "1", id, Long.toString(seq), op)); fields.addAll(Arrays.asList(args));
        return c.request(name, endpoint, fields);
    }
    private static void eq(Object expected, Object actual) { assertions++; if (!Objects.equals(expected, actual)) throw new AssertionError("Expected " + expected + " but got " + actual); }
    private static void status(String expected, List<String> reply) { eq(expected, reply.get(6)); }
    public static void main(String[] args) throws Exception {
        Path root = Paths.get(args[0]); Files.createDirectories(root);
        AtomicLong now = new AtomicLong(100000);
        Path state = Files.createTempDirectory(root, "pure-");
        String epoch;
        try (SeamlessCampaign c = new SeamlessCampaign(state, "Host", TOKEN, true, true, now::get)) {
            status("BAD_REQUEST", call(c, "SCServer", "evil:1", H, 1, "HELLO", "guest", "-", "-"));
            status("HOST_AUTH_FAILED", call(c, "Host", "evil:1", H, 1, "HELLO", "host", "wrong", "fact"));
            status("HOST_AUTH_FAILED", call(c, "Host", "evil:1", H, 1, "HELLO", "guest", "", "fact"));
            List<String> welcome = call(c, "Host", "h:1", H, 1, "HELLO", "host", TOKEN, "fact,journal,item,xp"); status("WELCOME", welcome); epoch = welcome.get(2);
            status("WELCOME", call(c, "SecondPC", "g:1", G, 1, "HELLO", "guest", "", "fact,journal,item,xp"));
            status("HELLO_REQUIRED", call(c, "Host", "evil:1", H, 2, "OPEN", epoch, "quest/talk"));
            status("SESSION_OWNED", call(c, "SecondPC", "g:1", H, 2, "OPEN", epoch, "quest/talk"));
            status("BAD_SEQUENCE", call(c, "Host", "h:1", H, 3, "OPEN", epoch, "quest/talk"));
            status("STALE_EPOCH", call(c, "Host", "h:1", H, 2, "OPEN", "1", "quest/talk"));
            List<String> opened = call(c, "Host", "h:1", H, 2, "OPEN", epoch, "quest/talk"); status("OK", opened);
            List<String> duplicate = call(c, "Host", "h:1", H, 2, "OPEN", epoch, "quest/talk"); status("OK", duplicate);
            eq(opened.subList(6, opened.size()), duplicate.subList(6, duplicate.size()));
            eq(false, opened.get(3).equals(duplicate.get(3)));
            status("REQUEST_CONFLICT", call(c, "Host", "h:1", H, 2, "CLOSE", epoch, "quest/talk"));
            status("BUSY", call(c, "SecondPC", "g:1", G, 2, "OPEN", epoch, "quest/talk"));
            status("NOT_OWNER", call(c, "SecondPC", "g:1", G, 3, "CHOICE", epoch, "quest/talk", "yes"));
            status("OK", call(c, "SecondPC", "g:1", G, 4, "LISTEN", epoch, "quest/talk"));
            List<String> vote = call(c, "Host", "h:1", H, 3, "VOTE_OPEN", epoch, "quest/talk", "yes,no"); status("OK", vote); String voteId = vote.get(7);
            status("VOTE_PENDING", call(c, "Host", "h:1", H, 4, "CHOICE", epoch, "quest/talk", "yes"));
            status("OK", call(c, "SecondPC", "g:1", G, 5, "VOTE_CAST", epoch, voteId, "no"));
            List<String> tie = call(c, "Host", "h:1", H, 5, "VOTE_CAST", epoch, voteId, "yes"); status("OK", tie); eq("yes", tie.get(8));
            status("VOTE_BINDING", call(c, "Host", "h:1", H, 6, "CHOICE", epoch, "quest/talk", "no"));
            status("OK", call(c, "Host", "h:1", H, 7, "CHOICE", epoch, "quest/talk", "yes"));
            status("NOT_OWNER", call(c, "SecondPC", "g:1", G, 6, "EFFECT", epoch, "tx-evil", "quest/talk", "fact", "quest_fact", "1"));
            status("UNSUPPORTED_EFFECT", call(c, "Host", "h:1", H, 8, "EFFECT", epoch, "tx-code", "quest/talk", "exec", "arbitrary", "code"));
            status("OK", call(c, "Host", "h:1", H, 9, "EFFECT", epoch, "tx-1", "quest/talk", "fact", "quest_fact", "1"));
            status("TRANSACTION_CONFLICT", call(c, "Host", "h:1", H, 10, "EFFECT", epoch, "tx-1", "quest/talk", "fact", "quest_fact", "2"));
            List<String> snapshot = call(c, "SecondPC", "g:1", G, 7, "GET_STATE", epoch, "0"); status("STATE", snapshot);
            eq("5", snapshot.get(7)); eq("true", snapshot.get(8)); eq("1", snapshot.get(16)); eq("OPEN", snapshot.get(17));
            status("OK", call(c, "SecondPC", "g:1", G, 8, "ACK", epoch, "1"));
            status("BAD_CURSOR", call(c, "SecondPC", "g:1", G, 9, "ACK", epoch, "0"));
            try { new SeamlessCampaign(state, "Host", TOKEN, true, true, now::get); throw new AssertionError("Second writer was allowed"); } catch (IOException expected) { assertions++; }
        }
        try (SeamlessCampaign c = new SeamlessCampaign(state, "Host", TOKEN, true, true, now::get)) {
            status("HELLO_REQUIRED", call(c, "Host", "h:2", H, 11, "GET_STATE", epoch, "0"));
            status("WELCOME", call(c, "Host", "h:2", H, 11, "HELLO", "host", TOKEN, "fact,journal,item,xp"));
            List<String> duplicateTx = call(c, "Host", "h:2", H, 12, "EFFECT", epoch, "tx-1", "quest/talk", "fact", "quest_fact", "1"); status("OK", duplicateTx); eq("DUPLICATE", duplicateTx.get(8));
            List<String> replay = call(c, "Host", "h:2", H, 13, "GET_STATE", epoch, "4"); status("STATE", replay); eq("6", replay.get(7)); eq("", replay.get(9)); eq("TRANSACTION", replay.get(17));
            status("ALREADY_APPLIED", call(c, "Host", "h:2", H, 12, "EFFECT", epoch, "tx-1", "quest/talk", "fact", "quest_fact", "1"));
            status("OK", call(c, "Host", "h:2", H, 14, "OPEN", epoch, "new/talk"));
            now.addAndGet(16000);
            status("WELCOME", call(c, "SecondPC", "g:2", G, 10, "HELLO", "guest", "", ""));
            List<String> expired = call(c, "SecondPC", "g:2", G, 11, "GET_STATE", epoch, "7"); status("STATE", expired); eq("", expired.get(9)); eq("CLOSE", expired.get(17));
            status("WELCOME", call(c, "Host", "h:2", H, 15, "HELLO", "host", TOKEN, "fact"));
            status("OK", call(c, "Host", "h:2", H, 16, "OPEN", epoch, "host/talk"));
            status("CAPABILITY_REQUIRED", call(c, "Host", "h:2", H, 17, "EFFECT", epoch, "tx-2", "host/talk", "fact", "quest_fact", "1"));
            status("BAD_REQUEST", call(c, "Host", "h:2", H, 18, "OPEN", epoch, "bad\tvalue"));
            status("OK", call(c, "SecondPC", "g:2", G, 12, "OPEN", epoch, "second/talk"));
            status("NOT_OWNER", call(c, "Host", "h:2", H, 18, "CLOSE", epoch, "second/talk"));
        }
        // Refuse damaged disk state rather than silently creating a fresh campaign.
        Path bad = Files.createTempDirectory(root, "corrupt-"); Files.write(bad.resolve("campaign.bin"), new byte[]{1,2,3});
        try { new SeamlessCampaign(bad, "Host", TOKEN, true, true); throw new AssertionError("Corrupt state accepted"); } catch (IOException expected) { assertions++; }
        transactions(root, now);
        listenersAndLargeReplay(root, now);
        choiceInstances(root, now);
        guestOwnerAndDisconnect(root);
        formatTwoMigration(root, now);
        transientStateFileLock(root, now);
        System.out.println("SeamlessCampaignTest passed: " + assertions + " assertions");
    }

    private static void transactions(Path root, AtomicLong now) throws Exception {
        Path dir = Files.createTempDirectory(root, "transactions-"); String epoch;
        try (SeamlessCampaign c = new SeamlessCampaign(dir, "Host", TOKEN, true, true, now::get)) {
            Peer host = new Peer(c, "Host", "h:1", H), guest = new Peer(c, "SecondPC", "g:1", G);
            epoch = host.hello("host", TOKEN).get(2); guest.hello("guest", "-"); host.epoch = guest.epoch = epoch;
            status("OK", host.op("OPEN", "hostQuest", "quest", "questA"));
            status("OK", guest.op("OPEN", "guestQuest", "quest", "questB"));
            status("BUSY", guest.op("OPEN", "otherConv", "quest", "questA"));
            status("STATE", guest.op("GET_STATE", "0", "guestQuest"));
            status("OK", host.op("TX_BEGIN", "tx-host", "hostQuest", "2", "2"));
            status("OK", host.op("TX_EFFECT", "tx-host", "m1", "fact", "common_fact", "4", "-"));
            status("INCOMPLETE_TRANSACTION", host.op("TX_COMMIT", "tx-host"));
            status("UNSUPPORTED_EFFECT", host.op("TX_EFFECT", "tx-host", "bad", "exec", "target", "1", "-"));
            status("INCOMPLETE_TRANSACTION", host.op("TX_COMMIT", "tx-host"));
            status("OK", host.op("TX_EFFECT", "tx-host", "m2", "journal", "journal_tag", "2", "-"));
            status("TRANSACTION_CONFLICT", host.op("TX_EFFECT", "tx-host", "m2", "journal", "journal_tag", "3", "-"));
            status("OK", guest.op("TX_BEGIN", "tx-guest", "guestQuest", "2", "1"));
            status("NOT_OWNER", guest.op("TX_EFFECT", "tx-host", "evil", "fact", "common_fact", "900", "-"));
            status("OK", guest.op("TX_EFFECT", "tx-guest", "g1", "fact", "common_fact", "5", "-"));
            status("OK", host.op("TX_COMMIT", "tx-host"));
            status("REVISION_CONFLICT", guest.op("TX_COMMIT", "tx-guest"));
            List<String> event = guest.op("GET_STATE", "2", "guestQuest"); status("STATE", event);
            eq("3", event.get(7)); eq("guestQuest", event.get(9)); eq("TRANSACTION", event.get(17)); eq("2", event.get(23));
            status("NOT_OWNER", guest.op("TX_COMMIT", "tx-host"));
            status("OK", host.op("TX_COMMIT", "tx-host"));
            status("OK", guest.op("TX_BEGIN", "tx-independent", "guestQuest", "3", "1"));
            status("OK", guest.op("TX_EFFECT", "tx-independent", "g1", "fact", "second_fact", "-2", "-"));
            status("OK", guest.op("TX_COMMIT", "tx-independent"));
            status("OK", host.op("TX_BEGIN", "tx-value", "hostQuest", "4", "1"));
            status("OK", host.op("TX_EFFECT", "tx-value", "v1", "fact", "common_fact", "8", "3"));
            status("VALUE_CONFLICT", host.op("TX_COMMIT", "tx-value"));
            // Unrelated scopes remain alive and independently owned after the failed write.
            status("OK", guest.op("CHOICE", "guestQuest", "continue"));
            status("NOT_OWNER", guest.op("CLOSE", "hostQuest"));
            status("BAD_REQUEST", host.op("EFFECT", "oversize", "hostQuest", "fact", "a".repeat(97), "1")); host.seq--;
            status("BAD_EFFECT_VALUE", host.op("EFFECT", "overflow", "hostQuest", "fact", "counter", "2147483648"));
            // Captured FactsSet durations travel as value@validFor; only a canonical positive duration is valid.
            status("OK", host.op("EFFECT", "timed", "hostQuest", "fact", "timed_fact", "7@120"));
            eq("DUPLICATE", host.op("EFFECT", "timed", "hostQuest", "fact", "timed_fact", "7@120").get(8));
            status("TRANSACTION_CONFLICT", host.op("EFFECT", "timed", "hostQuest", "fact", "timed_fact", "7@121"));
            for (String bad : new String[] {"7@0", "7@-1", "7@", "@7", "7@+5", "7@05", "7@2147483648", "7@1@2", "x@5"})
                status("BAD_EFFECT_VALUE", host.op("EFFECT", "bad-timed", "hostQuest", "fact", "timed_fact", bad));
            status("OK", host.op("TX_BEGIN", "tx-timed", "hostQuest", Long.toString(latest(host, "hostQuest")), "1"));
            status("OK", host.op("TX_EFFECT", "tx-timed", "t1", "fact", "timed_fact", "3", "7@120"));
            status("OK", host.op("TX_COMMIT", "tx-timed"));
        }
        try (SeamlessCampaign c = new SeamlessCampaign(dir, "Host", TOKEN, true, true, now::get)) {
            List<String> wrong = call(c, "Host", "h:2", H, 1, "HELLO", "host", TOKEN, "fact,journal,item,xp"); status("BAD_SEQUENCE", wrong);
            long expected = Long.parseLong(wrong.get(7));
            status("WELCOME", call(c, "Host", "h:2", H, expected, "HELLO", "host", TOKEN, "fact,journal,item,xp"));
            List<String> receipt = call(c, "Host", "h:2", H, expected + 1, "TX_COMMIT", epoch, "tx-host"); status("OK", receipt); eq("DUPLICATE", receipt.get(8));
            List<String> event = call(c, "Host", "h:2", H, expected + 2, "GET_STATE", epoch, "2", "-"); status("STATE", event); eq("TRANSACTION", event.get(17)); eq("2", event.get(23));
        }
    }
    private static final class Peer {
        final SeamlessCampaign c; final String name, endpoint, id; long seq = 1; String epoch;
        Peer(SeamlessCampaign c, String n, String e, String id) { this.c = c; name = n; endpoint = e; this.id = id; }
        List<String> hello(String role, String proof) { return call(c, name, endpoint, id, seq++, "HELLO", role, proof, "fact,journal,item,xp"); }
        List<String> op(String op, String... args) { List<String> values = new ArrayList<>(); values.add(epoch); values.addAll(Arrays.asList(args)); return call(c, name, endpoint, id, seq++, op, values.toArray(new String[0])); }
    }
    private static void listenersAndLargeReplay(Path root, AtomicLong now) throws Exception {
        Path dir = Files.createTempDirectory(root, "listeners-"); long hostNext;
        String epoch;
        try (SeamlessCampaign c = new SeamlessCampaign(dir, "Host", TOKEN, true, true, now::get)) {
            Peer host = new Peer(c, "Host", "h:1", H), guest = new Peer(c, "SecondPC", "g:1", G);
            epoch = host.hello("host", TOKEN).get(2); guest.hello("guest", "-"); host.epoch = guest.epoch = epoch;
            status("OK", host.op("OPEN", "shared", "npc", "npc/main"));
            status("OK", guest.op("LISTEN", "shared"));
            String vote = host.op("VOTE_OPEN", "shared", "a,b").get(7);
            status("OK", host.op("VOTE_CAST", vote, "a"));
            status("OK", guest.op("UNLISTEN", "shared"));
            List<String> state = host.op("GET_STATE", "0", "shared"); eq("a", state.get(14));
            status("OWNER_MUST_CLOSE", host.op("UNLISTEN", "shared"));
            status("OK", host.op("TX_BEGIN", "four", "shared", state.get(7), "4"));
            for (int i = 0; i < 4; i++) status("OK", host.op("TX_EFFECT", "four", "m" + i, "fact", "target" + i, "1", "-"));
            status("OK", host.op("TX_COMMIT", "four"));
            List<String> replay = host.op("GET_STATE", "3", "shared"); status("STATE", replay); eq("TRANSACTION", replay.get(17)); eq(40, replay.size());
            // A 4-member cached STATE reply must survive restart without violating the disk parser bounds.
            hostNext = host.seq;
        }
        try (SeamlessCampaign c = new SeamlessCampaign(dir, "Host", TOKEN, true, true, now::get)) {
            status("WELCOME", call(c, "Host", "h:2", H, hostNext, "HELLO", "host", TOKEN, "fact,journal,item,xp"));
            List<String> replay = call(c, "Host", "h:2", H, hostNext + 1, "GET_STATE", epoch, "3", "-"); eq("TRANSACTION", replay.get(17)); eq(40, replay.size());
        }
    }

    private static long latest(Peer peer, String conversation) {
        List<String> snapshot = peer.op("GET_STATE", "0", conversation); status("STATE", snapshot);
        return Long.parseLong(snapshot.get(7));
    }
    private static void choiceInstances(Path root, AtomicLong now) throws Exception {
        Path dir = Files.createTempDirectory(root, "choice-instances-"); String epoch; long hostNext;
        long acceptedEvent; String firstLease;
        try (SeamlessCampaign c = new SeamlessCampaign(dir, "Host", TOKEN, true, true, now::get)) {
            Peer host = new Peer(c, "Host", "h:1", H), guest = new Peer(c, "SecondPC", "g:1", G);
            epoch = host.hello("host", TOKEN).get(2); guest.hello("guest", "-"); host.epoch = guest.epoch = epoch;
            List<String> opened = host.op("OPEN", "side", "npc", "npcA"); status("OK", opened); firstLease = opened.get(8);
            status("OK", guest.op("OPEN", "independent", "quest", "questB"));
            status("OK", guest.op("LISTEN", "side"));
            status("NOT_OWNER", guest.op("CHOICES", "side", firstLease, "one", "a,b", "false"));
            status("STALE_LEASE", host.op("CHOICES", "side", "old-lease", "one", "a,b", "false"));
            status("OK", host.op("CHOICES", "side", firstLease, "one", "a,b", "false"));
            long before = latest(host, "side"); eq(3L, before);
            List<String> dialogue = guest.op("GET_DIALOGUE", "side"); status("DIALOGUE", dialogue);
            eq(19, dialogue.size()); eq("side", dialogue.get(7)); eq(firstLease, dialogue.get(8)); eq("one", dialogue.get(9));
            eq("a,b", dialogue.get(10)); eq("false", dialogue.get(11)); eq("", dialogue.get(12)); eq("0", dialogue.get(13)); eq("Host", dialogue.get(18));
            status("OK", host.op("CHOICES", "side", firstLease, "one", "a,b", "false"));
            eq(before, latest(host, "side"));
            status("CHOICE_INSTANCE_CONFLICT", host.op("CHOICES", "side", firstLease, "one", "b,a", "false"));
            status("CHOICE_INSTANCE_CONFLICT", host.op("CHOICES", "side", firstLease, "one", "a,b", "true"));
            status("CHOICE_PENDING", host.op("CHOICES", "side", firstLease, "two", "a,b", "false"));
            status("CHOICE_INSTANCE_REQUIRED", host.op("CHOICE", "side", "a"));
            status("STALE_LEASE", host.op("CHOICE", "side", "old-lease", "one", "a"));
            status("STALE_CHOICE_INSTANCE", host.op("CHOICE", "side", firstLease, "missing", "a"));
            status("BAD_CHOICE", host.op("CHOICE", "side", firstLease, "one", "c"));
            status("NOT_OWNER", guest.op("CHOICE", "side", firstLease, "one", "a"));
            List<String> accepted = host.op("CHOICE", "side", firstLease, "one", "a"); status("OK", accepted);
            acceptedEvent = Long.parseLong(accepted.get(10)); eq(before + 1, acceptedEvent); eq("false", accepted.get(11));
            List<String> exactRetry = call(c, "Host", "h:1", H, host.seq - 1, "CHOICE", epoch, "side", firstLease, "one", "a");
            status("OK", exactRetry); eq(accepted.subList(6, accepted.size()), exactRetry.subList(6, exactRetry.size()));
            List<String> rapidSecondClick = host.op("CHOICE", "side", firstLease, "one", "a"); status("OK", rapidSecondClick);
            eq(Long.toString(acceptedEvent), rapidSecondClick.get(10)); eq("true", rapidSecondClick.get(11));
            status("CHOICE_ALREADY_ACCEPTED", host.op("CHOICE", "side", firstLease, "one", "b"));
            eq(acceptedEvent, latest(host, "side"));
            status("OK", host.op("CHOICES", "side", firstLease, "two", "a,b", "false"));
            status("STALE_CHOICE_INSTANCE", host.op("CHOICE", "side", firstLease, "one", "a"));
            status("STALE_CHOICE_INSTANCE", host.op("CHOICES", "side", firstLease, "one", "a,b", "false"));
            status("OK", host.op("CHOICE", "side", firstLease, "two", "b"));
            status("OK", host.op("CHOICES", "side", firstLease, "main", "a,b", "true"));
            status("VOTE_REQUIRED", host.op("CHOICE", "side", firstLease, "main", "a"));
            status("CHOICE_INSTANCE_REQUIRED", host.op("VOTE_OPEN", "side", "a,b"));
            List<String> vote = host.op("VOTE_OPEN", "side", firstLease, "main"); status("OK", vote); String voteId = vote.get(7);
            long voteEvent = latest(host, "side");
            List<String> repeatedOpen = host.op("VOTE_OPEN", "side", firstLease, "main"); status("OK", repeatedOpen); eq(voteId, repeatedOpen.get(7));
            eq(voteEvent, latest(host, "side"));
            status("VOTE_PENDING", host.op("CHOICE", "side", firstLease, "main", "a"));
            status("CHOICE_INSTANCE_REQUIRED", guest.op("VOTE_CAST", voteId, "b"));
            status("STALE_CHOICE_INSTANCE", guest.op("VOTE_CAST", voteId, firstLease, "two", "b"));
            status("OK", host.op("VOTE_CAST", voteId, firstLease, "main", "a"));
            List<String> tie = guest.op("VOTE_CAST", voteId, firstLease, "main", "b"); status("OK", tie); eq("a", tie.get(8));
            long resolvedEvent = latest(host, "side");
            status("OK", guest.op("VOTE_CAST", voteId, firstLease, "main", "b")); eq(resolvedEvent, latest(host, "side"));
            status("VOTE_ALREADY_CAST", guest.op("VOTE_CAST", voteId, firstLease, "main", "a"));
            status("VOTE_BINDING", host.op("CHOICE", "side", firstLease, "main", "b"));
            List<String> mainChoice = host.op("CHOICE", "side", firstLease, "main", "a"); status("OK", mainChoice);
            long mainEvent = Long.parseLong(mainChoice.get(10));
            List<String> mainSnapshot = guest.op("GET_DIALOGUE", "side"); status("DIALOGUE", mainSnapshot);
            eq("main", mainSnapshot.get(9)); eq("true", mainSnapshot.get(11)); eq("a", mainSnapshot.get(12)); eq(Long.toString(mainEvent), mainSnapshot.get(13));
            List<String> event = guest.op("GET_STATE", Long.toString(mainEvent - 1), "side"); status("STATE", event);
            eq("DIALOG_CHOICE", event.get(17)); eq(Arrays.asList("side", firstLease, "main", "a"), event.subList(19, 23));
            status("OK", host.op("CHOICES", "side", firstLease, "next-main", "a,b", "true"));
            status("NO_VOTE", guest.op("VOTE_CAST", voteId, firstLease, "main", "b"));
            status("VOTE_REQUIRED", host.op("CHOICE", "side", firstLease, "next-main", "a"));
            status("OK", host.op("CLOSE", "side"));
            List<String> reopened = host.op("OPEN", "side", "npc", "npcA"); status("OK", reopened); String secondLease = reopened.get(8);
            eq(false, firstLease.equals(secondLease));
            status("STALE_LEASE", host.op("CHOICES", "side", firstLease, "one", "a,b", "false"));
            status("OK", host.op("CHOICES", "side", secondLease, "one", "a,b", "false"));
            status("STALE_LEASE", host.op("CHOICE", "side", firstLease, "one", "a"));
            status("OK", host.op("CHOICE", "side", secondLease, "one", "a"));
            status("DIALOGUE", host.op("GET_DIALOGUE", "side"));
            hostNext = host.seq;
        }
        try (SeamlessCampaign c = new SeamlessCampaign(dir, "Host", TOKEN, true, true, now::get)) {
            status("WELCOME", call(c, "Host", "h:2", H, hostNext, "HELLO", "host", TOKEN, "fact,journal,item,xp"));
            status("NO_CONVERSATION", call(c, "Host", "h:2", H, hostNext + 1, "GET_DIALOGUE", epoch, "side"));
            List<String> oldChoice = call(c, "Host", "h:2", H, hostNext + 2, "GET_STATE", epoch, Long.toString(acceptedEvent - 1), "-");
            status("STATE", oldChoice); eq("DIALOG_CHOICE", oldChoice.get(17)); eq(firstLease, oldChoice.get(20)); eq("one", oldChoice.get(21));
            // Old epoch/session history remains intact; restart releases rather than silently reopening a graph.
            eq(epoch, oldChoice.get(2));
        }
    }

    private static void formatTwoMigration(Path root, AtomicLong now) throws Exception {
        Path dir = Files.createTempDirectory(root, "format-two-");
        try (java.io.DataOutputStream out = new java.io.DataOutputStream(Files.newOutputStream(dir.resolve("campaign.bin")))) {
            out.writeInt(0x53434331); out.writeInt(2); out.writeLong(87654321L); out.writeUTF("Host"); out.writeBoolean(true); out.writeBoolean(true); out.writeLong(2);
            out.writeInt(0); out.writeInt(0); // effect receipts and owners
            out.writeInt(1); out.writeUTF("old"); out.writeUTF("npc"); out.writeUTF("npcOld"); out.writeUTF(H); out.writeLong(now.get() + 15000);
            out.writeInt(1); out.writeUTF(H); // listeners
            out.writeUTF(""); out.writeUTF(""); out.writeUTF(""); out.writeInt(0); out.writeInt(0); // vote state
            out.writeInt(0); out.writeInt(0); // values and transactions
            out.writeInt(1); out.writeUTF(H); out.writeUTF("Host"); out.writeBoolean(true); out.writeLong(1); out.writeLong(0); out.writeUTF("HELLO"); out.writeUTF("old-fingerprint");
            out.writeInt(3); out.writeUTF("WELCOME"); out.writeUTF("87654321"); out.writeUTF("1");
            out.writeInt(1); out.writeLong(1); out.writeUTF("OPEN"); out.writeUTF("Host"); out.writeInt(3); out.writeUTF("old"); out.writeUTF("npc"); out.writeUTF("npcOld");
        }
        try (SeamlessCampaign c = new SeamlessCampaign(dir, "Host", TOKEN, true, true, now::get)) {
            List<String> welcome = call(c, "Host", "h:new", H, 2, "HELLO", "host", TOKEN, "-"); status("WELCOME", welcome); eq("87654321", welcome.get(2)); eq("2", welcome.get(8));
            List<String> old = call(c, "Host", "h:new", H, 3, "GET_STATE", "87654321", "0", "-"); status("STATE", old); eq("OPEN", old.get(17));
            List<String> released = call(c, "Host", "h:new", H, 4, "GET_STATE", "87654321", "1", "-"); status("STATE", released); eq("CLOSE", released.get(17)); eq("SERVER_RESTART", released.get(20));
        }
        try (java.io.DataInputStream in = new java.io.DataInputStream(Files.newInputStream(dir.resolve("campaign.bin")))) { eq(0x53434331, in.readInt()); eq(3, in.readInt()); }
    }
    // Run 20261024-193822 halted with STORAGE_ERROR when Windows refused to replace a briefly opened
    // campaign.bin. A classic FileInputStream opens without delete sharing, like a scanner does.
    private static void transientStateFileLock(Path root, AtomicLong now) throws Exception {
        if (!System.getProperty("os.name", "").toLowerCase(Locale.ROOT).startsWith("windows")) return;
        Path dir = Files.createTempDirectory(root, "transient-lock-");
        try (SeamlessCampaign c = new SeamlessCampaign(dir, "Host", TOKEN, true, true, now::get)) {
            Peer host = new Peer(c, "Host", "h:1", H);
            host.epoch = host.hello("host", TOKEN).get(2);
            java.io.FileInputStream briefly = new java.io.FileInputStream(dir.resolve("campaign.bin").toFile());
            Thread release = new Thread(() -> { try { Thread.sleep(20); briefly.close(); } catch (Exception ignored) { } });
            release.start();
            status("OK", host.op("OPEN", "locked", "npc", "npc/locked"));
            release.join();
            long seq = host.seq;
            try (java.io.FileInputStream held = new java.io.FileInputStream(dir.resolve("campaign.bin").toFile())) {
                status("STORAGE_ERROR", call(c, "Host", "h:1", H, seq, "GET_STATE", host.epoch, "0", "locked"));
            }
            // A refused write commits nothing, so the identical request succeeds once the file is free.
            status("STATE", call(c, "Host", "h:1", H, seq, "GET_STATE", host.epoch, "0", "locked"));
        }
    }

    private static void guestOwnerAndDisconnect(Path root) throws Exception {
        Path dir = Files.createTempDirectory(root, "guest-dialogue-owner-"); AtomicLong clock = new AtomicLong(100000);
        try (SeamlessCampaign c = new SeamlessCampaign(dir, "Host", TOKEN, true, true, clock::get)) {
            Peer host = new Peer(c, "Host", "h:1", H), guest = new Peer(c, "SecondPC", "g:1", G);
            String epoch = host.hello("host", TOKEN).get(2); guest.hello("guest", "-"); host.epoch = guest.epoch = epoch;
            List<String> opened = guest.op("OPEN", "guestStory", "npc", "storyNPC"); status("OK", opened); String lease = opened.get(8);
            status("OK", host.op("LISTEN", "guestStory"));
            status("NOT_OWNER", host.op("CHOICES", "guestStory", lease, "p1", "a,b", "true"));
            status("OK", guest.op("CHOICES", "guestStory", lease, "p1", "a,b", "true"));
            List<String> vote = guest.op("VOTE_OPEN", "guestStory", lease, "p1"); status("OK", vote); String id = vote.get(7);
            status("OK", host.op("VOTE_CAST", id, lease, "p1", "a"));
            List<String> tied = guest.op("VOTE_CAST", id, lease, "p1", "b"); status("OK", tied); eq("b", tied.get(8));
            status("NOT_OWNER", host.op("CHOICE", "guestStory", lease, "p1", "b"));
            status("VOTE_BINDING", guest.op("CHOICE", "guestStory", lease, "p1", "a"));
            status("OK", guest.op("CHOICE", "guestStory", lease, "p1", "b"));
            status("OK", guest.op("CHOICES", "guestStory", lease, "p2", "a,b", "true"));
            String nextVote = guest.op("VOTE_OPEN", "guestStory", lease, "p2").get(7);
            status("OK", guest.op("VOTE_CAST", nextVote, lease, "p2", "b"));
            clock.addAndGet(14000); status("OK", guest.op("RENEW", "guestStory"));
            clock.addAndGet(2000);
            List<String> snapshot = guest.op("GET_DIALOGUE", "guestStory"); status("DIALOGUE", snapshot);
            eq("b", snapshot.get(16)); eq("SecondPC", snapshot.get(18));
            status("OK", guest.op("CHOICE", "guestStory", lease, "p2", "b"));
            status("HELLO_REQUIRED", host.op("VOTE_CAST", nextVote, lease, "p2", "a"));
        }
    }
}
