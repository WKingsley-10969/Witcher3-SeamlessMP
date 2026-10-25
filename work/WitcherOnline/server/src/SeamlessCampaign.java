import java.io.*;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.channels.OverlappingFileLockException;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.*;
import java.util.function.LongSupplier;

/** Ordered, durable campaign intents. Engine effects are proposals, not proof of quest execution. */
public final class SeamlessCampaign implements AutoCloseable {
    public static final int SERVER_PLAYER_ID = Integer.MAX_VALUE;
    private static final int MAX_SESSIONS = 64, MAX_EVENTS = 20000, MAX_EFFECTS = 10000;
    private static final long LEASE_MS = 15000;
    private static final Set<String> EFFECT_KINDS = new HashSet<>(Arrays.asList("fact", "journal", "item", "xp"));
    private final Path directory, stateFile;
    private final String host, hostToken;
    private final LongSupplier clock;
    private final Map<String, Active> active = new HashMap<>();
    private State state;
    private long responseTick = System.currentTimeMillis() * 1000;
    private FileChannel lockChannel;
    private FileLock lock;

    public SeamlessCampaign(Path directory, String host, String hostToken, boolean voting, boolean sharedXp) throws IOException {
        this(directory, host, hostToken, voting, sharedXp, System::currentTimeMillis);
    }
    SeamlessCampaign(Path directory, String host, String hostToken, boolean voting, boolean sharedXp, LongSupplier clock) throws IOException {
        if (!validName(host) || hostToken == null || hostToken.length() < 16 || hostToken.length() > 256)
            throw new IllegalArgumentException("Campaign requires a 2-16 character host name and 16-256 character host token");
        this.directory = directory.toAbsolutePath().normalize(); this.stateFile = this.directory.resolve("campaign.bin");
        this.host = host; this.hostToken = hostToken; this.clock = clock;
        Files.createDirectories(this.directory);
        lockChannel = FileChannel.open(this.directory.resolve("campaign.lock"), StandardOpenOption.CREATE, StandardOpenOption.WRITE);
        try {
        try { lock = lockChannel.tryLock(); } catch (OverlappingFileLockException e) { throw new IOException("Campaign is already open", e); }
        if (lock == null) throw new IOException("Campaign is already open");
        if (Files.exists(stateFile)) {
            state = read(stateFile);
            if (!state.host.equalsIgnoreCase(host)) throw new IOException("Saved campaign host does not match --campaign-host");
            if (state.voting != voting || state.sharedXp != sharedXp) throw new IOException("Saved campaign policy differs from requested policy");
        } else {
            state = new State(); state.host = host; state.voting = voting; state.sharedXp = sharedXp;
            state.epoch = new SecureRandom().nextLong() & Long.MAX_VALUE;
            if (state.epoch == 0) state.epoch = 1;
            persist(state);
        }
        // Nobody owns an engine conversation across a process restart. Release is durable before accepting packets.
        if (!state.scopes.isEmpty() || !state.transactions.isEmpty()) {
            State next = new State(state);
            for (Scope scope : new ArrayList<>(next.scopes.values())) release(next, scope, "SERVER_RESTART");
            next.transactions.clear(); persist(next); state = next;
        }
        } catch (IOException | RuntimeException e) { close(); throw e; }
    }

    /** Fields: sc,1,clientSession,requestSeq,op,...args. Returned fields exclude COOP envelope. */
    public synchronized List<String> request(String username, String endpoint, List<String> fields) {
        String session = fields.size() > 2 ? fields.get(2) : "";
        String seqText = fields.size() > 3 ? fields.get(3) : "0";
        try {
            expire();
            if (fields.size() < 5 || fields.size() > 20 || !"sc".equals(fields.get(0)) || !"1".equals(fields.get(1)))
                return reply(session, seqText, "BAD_REQUEST");
            int total = 0;
            for (String f : fields) { total += f.length(); if (f.length() > 512 || hasControls(f)) return reply(session, seqText, "BAD_REQUEST"); }
            if (total > 2048 || !session.matches("[A-Za-z0-9_-]{16,64}") || !validName(username)) return reply(session, seqText, "BAD_REQUEST");
            long seq = positive(seqText);
            if (seq == 0) return reply(session, seqText, "BAD_SEQUENCE");
            String op = fields.get(4);
            List<String> args = fields.subList(5, fields.size());
            Session prior = state.sessions.get(session);
            if (prior != null && !prior.username.equalsIgnoreCase(username)) return reply(session, seqText, "SESSION_OWNED");
            if ("HELLO".equals(op)) return hello(username, endpoint, session, seq, args, prior);
            Active connection = active.get(session);
            if (prior == null || connection == null || !connection.endpoint.equals(endpoint)) return reply(session, seqText, "HELLO_REQUIRED");
            connection.seen = clock.getAsLong();
            if (seq == prior.seq) return reply(session, seqText, prior.fingerprint.equals(fingerprint(fields)) ? prior.reply : list("REQUEST_CONFLICT"));
            if (seq <= prior.seq) return reply(session, seqText, "ALREADY_APPLIED", Long.toString(prior.seq));
            if (seq != prior.seq + 1) return reply(session, seqText, "BAD_SEQUENCE", Long.toString(prior.seq + 1));
            if (args.isEmpty() || parseLong(args.get(0), -1) != state.epoch) return reply(session, seqText, "STALE_EPOCH");
            State next = new State(state);
            List<String> result = apply(next, session, op, args.subList(1, args.size()));
            Session updated = next.sessions.get(session); updated.seq = seq; updated.reply = new ArrayList<>(result); updated.fingerprint = fingerprint(fields);
            persist(next); state = next;
            return reply(session, seqText, result);
        } catch (IllegalArgumentException ex) {
            return reply(session, seqText, "BAD_REQUEST");
        } catch (IOException ex) {
            System.err.println("Campaign persistence failed: " + ex.getMessage());
            return reply(session, seqText, "STORAGE_ERROR");
        }
    }

    private List<String> hello(String username, String endpoint, String id, long seq, List<String> args, Session prior) throws IOException {
        if (args.size() != 3) return reply(id, Long.toString(seq), "BAD_REQUEST");
        String role = args.get(0);
        boolean isHost = "host".equals(role);
        if (!(isHost || "guest".equals(role))) return reply(id, Long.toString(seq), "BAD_REQUEST");
        if (isHost && (!username.equalsIgnoreCase(host) || !constantEquals(args.get(1), hostToken))) return reply(id, Long.toString(seq), "HOST_AUTH_FAILED");
        if (!isHost && username.equalsIgnoreCase(host)) return reply(id, Long.toString(seq), "HOST_AUTH_FAILED");
        Set<String> capabilities = parseCapabilities(args.get(2));
        Active existing = active.get(id);
        long now = clock.getAsLong();
        if (existing != null && !existing.endpoint.equals(endpoint) && now - existing.seen < LEASE_MS)
            return reply(id, Long.toString(seq), "SESSION_ACTIVE");
        for (Map.Entry<String, Active> e : active.entrySet()) {
            Session p = state.sessions.get(e.getKey());
            if (!e.getKey().equals(id) && p != null && p.username.equalsIgnoreCase(username) && now - e.getValue().seen < LEASE_MS)
                return reply(id, Long.toString(seq), "USERNAME_ACTIVE");
        }
        if (prior == null && (seq != 1 || state.sessions.size() >= MAX_SESSIONS)) return reply(id, Long.toString(seq), "SESSION_LIMIT_OR_SEQUENCE");
        if (prior != null && seq != prior.seq && seq != prior.seq + 1) return reply(id, Long.toString(seq), "BAD_SEQUENCE", Long.toString(prior.seq + 1));
        if (prior != null && prior.host != isHost) return reply(id, Long.toString(seq), "SESSION_OWNED");
        // A retransmitted HELLO may restore the transport after a restart, but cannot replay a different operation.
        List<String> helloFields = list("sc", "1", id, Long.toString(seq), "HELLO"); helloFields.addAll(args);
        if (prior != null && seq == prior.seq && (!"HELLO".equals(prior.lastOp) || !prior.fingerprint.equals(fingerprint(helloFields))))
            return reply(id, Long.toString(seq), "BAD_SEQUENCE", Long.toString(prior.seq + 1));
        State next = new State(state);
        Session participant = prior == null ? new Session() : next.sessions.get(id);
        participant.username = username; participant.host = isHost; participant.seq = seq; participant.lastOp = "HELLO";
        participant.fingerprint = fingerprint(helloFields);
        participant.reply = list("WELCOME", Long.toString(next.epoch), Long.toString(next.nextEvent - 1));
        next.sessions.put(id, participant);
        persist(next); state = next;
        active.put(id, new Active(endpoint, now, capabilities));
        return reply(id, Long.toString(seq), participant.reply);
    }

    private List<String> apply(State s, String id, String op, List<String> a) {
        Session participant = s.sessions.get(id); participant.lastOp = op;
        switch (op) {
            case "GET_STATE": {
                require(a.size() == 1 || a.size() == 2); long cursor = nonnegative(a.get(0));
                if (cursor >= s.nextEvent) return list("BAD_CURSOR");
                Scope scope = a.size() == 2 ? s.scopes.get(a.get(1)) : ownedScope(s, id);
                List<String> out = list("STATE", Long.toString(s.nextEvent - 1), Boolean.toString(s.sharedXp), scope == null ? "" : scope.id,
                    scope == null ? "" : ownerName(s, scope), Long.toString(scope == null ? 0 : Math.max(0, scope.leaseUntil - clock.getAsLong())),
                    scope == null ? "" : scope.voteId, scope == null ? "" : scope.voteChoices, scope == null ? "" : scope.voteResult);
                Event event = null; for (Event e : s.events) if (e.id > cursor) { event = e; break; }
                out.add(event == null ? "0" : "1");
                if (event != null) { out.add(Long.toString(event.id)); out.add(event.type); out.add(event.actor); out.addAll(event.payload); }
                return out;
            }
            case "GET_DIALOGUE": {
                require(a.size() == 1 && token(a.get(0)));
                Scope scope = s.scopes.get(a.get(0));
                if (scope == null) return list("NO_CONVERSATION");
                return list("DIALOGUE", scope.id, scope.leaseId, scope.instance, scope.choiceSet, Boolean.toString(scope.mainStory),
                    scope.acceptedChoice, Long.toString(scope.acceptedEvent), scope.voteId, scope.voteChoices, scope.voteResult,
                    Long.toString(Math.max(0, scope.leaseUntil - clock.getAsLong())), ownerName(s, scope));
            }
            case "ACK": {
                require(a.size() == 1); long cursor = nonnegative(a.get(0));
                if (cursor >= s.nextEvent || cursor < participant.ack) return list("BAD_CURSOR");
                participant.ack = cursor; return list("OK", Long.toString(cursor));
            }
            case "OPEN": {
                require((a.size() == 1 || a.size() == 3) && token(a.get(0)));
                String kind = a.size() == 3 ? a.get(1) : "npc", target = a.size() == 3 ? a.get(2) : a.get(0);
                require((kind.equals("npc") || kind.equals("quest")) && token(target));
                for (Scope current : s.scopes.values()) if (current.id.equals(a.get(0)) || (current.kind.equals(kind) && current.target.equals(target)))
                    return list("BUSY", current.id, ownerName(s, current));
                if (s.events.size() >= MAX_EVENTS - 16 || s.scopes.size() >= 16) return list("CAMPAIGN_LIMIT");
                Scope scope = new Scope(); scope.id = a.get(0); scope.kind = kind; scope.target = target; scope.owner = id;
                scope.leaseId = "lease-" + s.nextEvent;
                scope.listeners.add(id); scope.leaseUntil = clock.getAsLong() + LEASE_MS; s.scopes.put(scope.id, scope);
                event(s, "OPEN", participant.username, scope.id, kind, target); return list("OK", scope.id, scope.leaseId);
            }
            case "LISTEN": {
                require(a.size() == 1); Scope scope = s.scopes.get(a.get(0)); if (scope == null) return list("NO_CONVERSATION");
                scope.listeners.add(id); return list("OK", scope.id, ownerName(s, scope));
            }
            case "RENEW": {
                require(a.size() == 1); Scope scope = s.scopes.get(a.get(0)); if (!owns(scope, id)) return list("NOT_OWNER");
                scope.leaseUntil = clock.getAsLong() + LEASE_MS; return list("OK", Long.toString(LEASE_MS));
            }
            case "UNLISTEN": {
                require(a.size() == 1); Scope scope = s.scopes.get(a.get(0)); if (scope == null) return list("NO_CONVERSATION");
                if (owns(scope, id)) return list("OWNER_MUST_CLOSE");
                scope.listeners.remove(id);
                if (scope.voteResult.isEmpty()) { scope.voters.remove(id); scope.votes.remove(id); if (!scope.voteId.isEmpty()) resolveVote(s, scope); }
                return list("OK", scope.id);
            }
            case "CHOICES": {
                require(a.size() == 5 && token(a.get(0)) && token(a.get(1)) && token(a.get(2)));
                Scope scope = s.scopes.get(a.get(0)); if (!owns(scope, id)) return list("NOT_OWNER");
                if (!scope.leaseId.equals(a.get(1))) return list("STALE_LEASE");
                List<String> choiceSet = dialogueChoices(a.get(3));
                require("true".equals(a.get(4)) || "false".equals(a.get(4)));
                boolean mainStory = Boolean.parseBoolean(a.get(4));
                if (mainStory && choiceSet.size() < 2) return list("MAIN_CHOICE_REQUIRES_OPTIONS");
                String canonical = String.join(",", choiceSet);
                if (scope.instance.equals(a.get(2)))
                    return scope.choiceSet.equals(canonical) && scope.mainStory == mainStory ? list("OK", scope.id, scope.leaseId, scope.instance) : list("CHOICE_INSTANCE_CONFLICT");
                if (scope.usedInstances.contains(a.get(2))) return list("STALE_CHOICE_INSTANCE");
                if (!scope.instance.isEmpty() && scope.acceptedChoice.isEmpty()) return list("CHOICE_PENDING");
                if (scope.usedInstances.size() >= 256 || s.events.size() >= MAX_EVENTS - 16) return list("CAMPAIGN_LIMIT");
                scope.instance = a.get(2); scope.choiceSet = canonical; scope.mainStory = mainStory;
                scope.acceptedChoice = ""; scope.acceptedEvent = 0; scope.usedInstances.add(scope.instance);
                scope.voteId = ""; scope.voteChoices = ""; scope.voteResult = ""; scope.voters.clear(); scope.votes.clear();
                scope.leaseUntil = clock.getAsLong() + LEASE_MS;
                event(s, "CHOICES", participant.username, scope.id, scope.leaseId, scope.instance, canonical, Boolean.toString(mainStory));
                return list("OK", scope.id, scope.leaseId, scope.instance);
            }
            case "CHOICE": {
                require(a.size() == 2 || a.size() == 4); Scope scope = s.scopes.get(a.get(0)); if (!owns(scope, id)) return list("NOT_OWNER");
                if (a.size() == 4) {
                    require(token(a.get(3)));
                    List<String> invalid = currentInstance(scope, a.get(1), a.get(2)); if (invalid != null) return invalid;
                    String choice = a.get(3);
                    if (!Arrays.asList(scope.choiceSet.split(",")).contains(choice)) return list("BAD_CHOICE");
                    if (!scope.acceptedChoice.isEmpty())
                        return scope.acceptedChoice.equals(choice) ? choiceReceipt(scope, true) : list("CHOICE_ALREADY_ACCEPTED", scope.acceptedChoice, Long.toString(scope.acceptedEvent));
                    if (scope.mainStory) {
                        if (!s.voting) return list("VOTING_DISABLED");
                        if (scope.voteId.isEmpty()) return list("VOTE_REQUIRED");
                        if (scope.voteResult.isEmpty()) return list("VOTE_PENDING");
                        if (!scope.voteResult.equals(choice)) return list("VOTE_BINDING", scope.voteResult);
                    }
                    if (s.events.size() >= MAX_EVENTS - 16) return list("CAMPAIGN_LIMIT");
                    scope.acceptedChoice = choice; scope.acceptedEvent = s.nextEvent;
                    event(s, "DIALOG_CHOICE", participant.username, scope.id, scope.leaseId, scope.instance, choice);
                    scope.leaseUntil = clock.getAsLong() + LEASE_MS;
                    return choiceReceipt(scope, false);
                }
                require(token(a.get(1)));
                if (!scope.instance.isEmpty()) return list("CHOICE_INSTANCE_REQUIRED");
                if (s.voting && !scope.voteId.isEmpty() && scope.voteResult.isEmpty()) return list("VOTE_PENDING");
                if (s.voting && !scope.voteId.isEmpty() && !scope.voteResult.equals(a.get(1))) return list("VOTE_BINDING", scope.voteResult);
                if (s.events.size() >= MAX_EVENTS - 16) return list("CAMPAIGN_LIMIT");
                event(s, "CHOICE", participant.username, scope.id, a.get(1)); scope.leaseUntil = clock.getAsLong() + LEASE_MS;
                return list("OK", a.get(1));
            }
            case "VOTE_OPEN": {
                require(a.size() == 2 || a.size() == 3); Scope scope = s.scopes.get(a.get(0)); if (!owns(scope, id)) return list("NOT_OWNER");
                if (!s.voting) return list("VOTING_DISABLED");
                if (a.size() == 3) {
                    List<String> invalid = currentInstance(scope, a.get(1), a.get(2)); if (invalid != null) return invalid;
                    if (!scope.mainStory) return list("NOT_MAIN_STORY");
                    if (!scope.acceptedChoice.isEmpty()) return list("CHOICE_ALREADY_ACCEPTED", scope.acceptedChoice, Long.toString(scope.acceptedEvent));
                    // New sequence numbers retry the same logical vote instead of opening a second vote.
                    if (!scope.voteId.isEmpty()) return list("OK", scope.voteId, scope.voteChoices, scope.leaseId, scope.instance);
                    if (s.events.size() >= MAX_EVENTS - 16) return list("CAMPAIGN_LIMIT");
                    openVote(s, scope, id, scope.choiceSet, participant.username);
                    return list("OK", scope.voteId, scope.voteChoices, scope.leaseId, scope.instance);
                }
                if (!scope.instance.isEmpty()) return list("CHOICE_INSTANCE_REQUIRED");
                if (!scope.voteId.isEmpty() && scope.voteResult.isEmpty()) return list("VOTE_PENDING");
                List<String> choices = choices(a.get(1));
                if (s.events.size() >= MAX_EVENTS - 16) return list("CAMPAIGN_LIMIT");
                scope.voteId = Long.toString(s.nextEvent); scope.voteChoices = String.join(",", choices); scope.voteResult = ""; scope.votes.clear(); scope.voters.clear();
                // Freeze the listener set: late joiners do not alter an in-progress vote quorum.
                for (String listener : scope.listeners) if (active.containsKey(listener)) scope.voters.add(listener);
                scope.voters.add(id); event(s, "VOTE_OPEN", participant.username, scope.id, scope.voteId, scope.voteChoices);
                return list("OK", scope.voteId, scope.voteChoices);
            }
            case "VOTE_CAST": {
                require(a.size() == 2 || a.size() == 4); Scope scope = null; for (Scope candidate : s.scopes.values()) if (a.get(0).equals(candidate.voteId)) scope = candidate;
                if (scope == null) return list("NO_VOTE");
                if (a.size() == 4) {
                    List<String> invalid = currentInstance(scope, a.get(1), a.get(2)); if (invalid != null) return invalid;
                } else if (!scope.instance.isEmpty()) return list("CHOICE_INSTANCE_REQUIRED");
                if (!scope.voters.contains(id)) return list("NOT_VOTER");
                String choice = a.get(a.size() == 4 ? 3 : 1);
                if (!Arrays.asList(scope.voteChoices.split(",")).contains(choice)) return list("BAD_CHOICE");
                String prior = scope.votes.get(id); if (prior != null && !prior.equals(choice)) return list("VOTE_ALREADY_CAST");
                if (!scope.voteResult.isEmpty()) {
                    if (a.size() == 4 && choice.equals(prior)) return list("OK", scope.voteId, scope.voteResult, scope.leaseId, scope.instance);
                    return list("VOTE_RESOLVED", scope.voteResult);
                }
                scope.votes.put(id, choice); resolveVote(s, scope);
                return a.size() == 4 ? list("OK", scope.voteId, scope.voteResult, scope.leaseId, scope.instance) : list("OK", scope.voteId, scope.voteResult);
            }
            case "CLOSE": {
                require(a.size() == 1); Scope scope = s.scopes.get(a.get(0)); if (!owns(scope, id)) return list("NOT_OWNER");
                release(s, scope, "CLOSED"); return list("OK");
            }
            case "EFFECT": {
                require(a.size() == 5 && token(a.get(0)));
                if (s.effects.containsKey(a.get(0))) {
                    if (!id.equals(s.effectOwners.get(a.get(0)))) return list("NOT_OWNER");
                    String[] saved = s.effects.get(a.get(0)).split("\u001e", -1);
                    Member retry = new Member("single", a.get(2), a.get(3), a.get(4), "-");
                    return saved.length == 4 && saved[0].equals(a.get(1)) && saved[3].equals("single\u001f" + retry.canonical())
                        ? list("OK", a.get(0), "DUPLICATE") : list("TRANSACTION_CONFLICT");
                }
                Scope scope = s.scopes.get(a.get(1)); if (!owns(scope, id)) return list("NOT_OWNER");
                Transaction transaction = new Transaction(); transaction.id = a.get(0); transaction.scope = scope.id;
                transaction.owner = id; transaction.base = s.nextEvent - 1;
                Member member = new Member("single", a.get(2), a.get(3), a.get(4), "-");
                List<String> invalid = validateMember(s, member); if (invalid != null) return invalid;
                transaction.members.put(member.id, member); return commit(s, transaction, participant.username);
            }
            case "TX_BEGIN": {
                require(a.size() == 4 && token(a.get(0))); Scope scope = s.scopes.get(a.get(1));
                if (!owns(scope, id)) return list("NOT_OWNER");
                if (s.effects.containsKey(a.get(0))) return list(id.equals(s.effectOwners.get(a.get(0))) ? "TRANSACTION_COMMITTED" : "NOT_OWNER", a.get(0));
                if (s.transactions.size() >= 16) return list("CAMPAIGN_LIMIT");
                long base = nonnegative(a.get(2)); if (base >= s.nextEvent) return list("BAD_REVISION");
                long memberCount = nonnegative(a.get(3)); require(memberCount >= 1 && memberCount <= 4);
                Transaction prior = s.transactions.get(a.get(0));
                if (prior != null) return prior.owner.equals(id) && prior.scope.equals(scope.id) && prior.base == base && prior.expectedMembers == memberCount ? list("OK", prior.id) : list("TRANSACTION_CONFLICT");
                Transaction tx = new Transaction(); tx.id = a.get(0); tx.scope = scope.id; tx.owner = id; tx.base = base; tx.expectedMembers = (int)memberCount; s.transactions.put(tx.id, tx);
                return list("OK", tx.id);
            }
            case "TX_EFFECT": {
                require(a.size() == 6 && token(a.get(0)) && token(a.get(1)));
                Transaction tx = s.transactions.get(a.get(0)); if (tx == null) return list("NO_TRANSACTION");
                if (!tx.owner.equals(id) || !owns(s.scopes.get(tx.scope), id)) return list("NOT_OWNER");
                Member member = new Member(a.get(1), a.get(2), a.get(3), a.get(4), a.get(5));
                List<String> invalid = validateMember(s, member); if (invalid != null) return invalid;
                Member previous = tx.members.get(member.id);
                if (previous != null) return previous.canonical().equals(member.canonical()) ? list("OK", tx.id, member.id) : list("TRANSACTION_CONFLICT");
                if (tx.members.size() >= tx.expectedMembers) return list("TRANSACTION_LIMIT");
                for (Member existing : tx.members.values()) if (existing.key().equals(member.key())) return list("DUPLICATE_TARGET");
                tx.members.put(member.id, member); return list("OK", tx.id, member.id);
            }
            case "TX_COMMIT": {
                require(a.size() == 1); Transaction tx = s.transactions.get(a.get(0));
                if (tx == null) return s.effects.containsKey(a.get(0)) ? (id.equals(s.effectOwners.get(a.get(0))) ? list("OK", a.get(0), "DUPLICATE") : list("NOT_OWNER")) : list("NO_TRANSACTION");
                if (!tx.owner.equals(id) || !owns(s.scopes.get(tx.scope), id)) return list("NOT_OWNER");
                List<String> result = commit(s, tx, participant.username);
                if ("OK".equals(result.get(0))) s.transactions.remove(tx.id); return result;
            }
            default: return list("UNKNOWN_OP");
        }
    }

    private void expire() throws IOException {
        long now = clock.getAsLong();
        Set<String> disconnected = new HashSet<>();
        for (Map.Entry<String, Active> e : active.entrySet()) if (now - e.getValue().seen >= LEASE_MS) disconnected.add(e.getKey());
        State next = new State(state); boolean changed = false;
        for (Scope scope : new ArrayList<>(next.scopes.values())) {
            if (now >= scope.leaseUntil || disconnected.contains(scope.owner)) { release(next, scope, "LEASE_EXPIRED"); changed = true; }
            else if (!scope.voteId.isEmpty() && scope.voteResult.isEmpty() && !Collections.disjoint(scope.voters, disconnected)) {
                scope.voters.removeAll(disconnected); resolveVote(next, scope); changed = true;
            }
        }
        if (changed) { persist(next); state = next; }
        for (String id : disconnected) active.remove(id);
    }

    private void resolveVote(State s, Scope scope) {
        if (!scope.votes.keySet().containsAll(scope.voters) || !scope.votes.containsKey(scope.owner)) return;
        Map<String, Integer> counts = new HashMap<>();
        for (String voter : scope.voters) counts.merge(scope.votes.get(voter), 1, Integer::sum);
        int best = Collections.max(counts.values()); String ownerChoice = scope.votes.get(scope.owner);
        List<String> tied = new ArrayList<>(); for (String choice : scope.voteChoices.split(",")) if (counts.getOrDefault(choice, 0) == best) tied.add(choice);
        scope.voteResult = tied.contains(ownerChoice) ? ownerChoice : tied.get(0);
        if (scope.instance.isEmpty()) event(s, "VOTE_RESULT", ownerName(s, scope), scope.id, scope.voteId, scope.voteResult);
        else event(s, "DIALOG_VOTE_RESULT", ownerName(s, scope), scope.id, scope.leaseId, scope.instance, scope.voteId, scope.voteResult);
    }
    private void openVote(State s, Scope scope, String ownerId, String choices, String actor) {
        scope.voteId = Long.toString(s.nextEvent); scope.voteChoices = choices; scope.voteResult = "";
        scope.votes.clear(); scope.voters.clear();
        for (String listener : scope.listeners) if (active.containsKey(listener)) scope.voters.add(listener);
        scope.voters.add(ownerId);
        event(s, "DIALOG_VOTE_OPEN", actor, scope.id, scope.leaseId, scope.instance, scope.voteId, choices);
    }
    private static List<String> currentInstance(Scope scope, String lease, String instance) {
        require(token(lease) && token(instance));
        if (!scope.leaseId.equals(lease)) return list("STALE_LEASE");
        if (scope.instance.isEmpty() || !scope.instance.equals(instance)) return list("STALE_CHOICE_INSTANCE");
        return null;
    }
    private static List<String> choiceReceipt(Scope scope, boolean duplicate) {
        return list("OK", scope.acceptedChoice, scope.leaseId, scope.instance, Long.toString(scope.acceptedEvent), Boolean.toString(duplicate));
    }
    private static boolean owns(Scope scope, String id) { return scope != null && scope.owner.equals(id); }
    private static Scope ownedScope(State s, String id) { for (Scope scope : s.scopes.values()) if (scope.owner.equals(id)) return scope; return null; }
    private static String ownerName(State s, Scope scope) { Session p = s.sessions.get(scope.owner); return p == null ? "" : p.username; }
    private static void release(State s, Scope scope, String reason) {
        event(s, "CLOSE", ownerName(s, scope), scope.id, reason); s.scopes.remove(scope.id);
        s.transactions.values().removeIf(tx -> tx.scope.equals(scope.id));
    }
    private static void event(State s, String type, String actor, String... payload) { s.events.add(new Event(s.nextEvent++, type, actor, Arrays.asList(payload))); }

    private List<String> validateMember(State s, Member member) {
        require(token(member.target) && member.value.length() <= 128 && member.expected.length() <= 128);
        if (!EFFECT_KINDS.contains(member.kind)) return list("UNSUPPORTED_EFFECT");
        if (member.kind.equals("fact")) {
            if (!factValue(member.value) || (!member.expected.equals("-") && !factValue(member.expected))) return list("BAD_EFFECT_VALUE");
        }
        if (member.kind.equals("journal")) {
            long value = parseLong(member.value, -1); if (value < 0 || value > 4) return list("BAD_EFFECT_VALUE");
        }
        if (member.kind.equals("xp") && !s.sharedXp) return list("SHARED_XP_DISABLED");
        // Capability advertisement is an explicit engine-adapter gate, not a claim that arbitrary quest effects work.
        for (Active player : active.values()) if (!player.capabilities.contains(member.kind)) return list("CAPABILITY_REQUIRED", member.kind);
        return null;
    }
    // A fact value is `value` (permanent) or `value@validFor` with a positive engine duration,
    // as captured from FactsSet. Expected values compare the whole stored string.
    private static boolean factValue(String text) {
        int at = text.indexOf('@');
        try {
            Integer.parseInt(at < 0 ? text : text.substring(0, at));
            if (at < 0) return true;
            String duration = text.substring(at + 1); int validFor = Integer.parseInt(duration);
            return validFor > 0 && duration.equals(Integer.toString(validFor));
        } catch (NumberFormatException e) { return false; }
    }
    private List<String> commit(State s, Transaction tx, String actor) {
        if (tx.members.size() != tx.expectedMembers) return list("INCOMPLETE_TRANSACTION");
        Scope scope = s.scopes.get(tx.scope); if (scope == null) return list("NO_CONVERSATION");
        List<String> membership = list(tx.scope, scope.kind, scope.target);
        for (Member m : tx.members.values()) membership.add(m.id + "\u001f" + m.canonical());
        String canonical = String.join("\u001e", membership);
        String existing = s.effects.get(tx.id);
        if (existing != null) return existing.equals(canonical) ? list("OK", tx.id, "DUPLICATE") : list("TRANSACTION_CONFLICT");
        if (s.effects.size() >= MAX_EFFECTS || s.events.size() >= MAX_EVENTS - 16) return list("CAMPAIGN_LIMIT");
        for (Member m : tx.members.values()) {
            List<String> invalid = validateMember(s, m); if (invalid != null) return invalid;
            Value previous = s.values.get(m.key());
            if (previous != null && previous.revision > tx.base) return list("REVISION_CONFLICT", m.target);
            if (!m.expected.equals("-") && (previous == null || !m.expected.equals(previous.value))) return list("VALUE_CONFLICT", m.target);
        }
        // Every member validates before a single ledger event publishes any member. Engine application is separate.
        List<String> payload = list(tx.id, scope.id, scope.kind, scope.target, Integer.toString(tx.members.size()));
        for (Member m : tx.members.values()) {
            payload.add(m.id); payload.add(m.kind); payload.add(m.target); payload.add(m.value);
            s.values.put(m.key(), new Value(m.value, s.nextEvent));
        }
        s.effects.put(tx.id, canonical); s.effectOwners.put(tx.id, tx.owner); event(s, "TRANSACTION", actor, payload.toArray(new String[0]));
        scope.leaseUntil = clock.getAsLong() + LEASE_MS;
        return list("OK", tx.id);
    }

    private List<String> reply(String session, String seq, String status, String... args) { List<String> result = list(status); result.addAll(Arrays.asList(args)); return reply(session, seq, result); }
    private List<String> reply(String session, String seq, List<String> result) {
        List<String> out = list("sc", "1", Long.toString(state.epoch), Long.toString(++responseTick), session, seq);
        out.addAll(result); return out;
    }
    private static boolean constantEquals(String a, String b) { return MessageDigest.isEqual(a.getBytes(StandardCharsets.UTF_8), b.getBytes(StandardCharsets.UTF_8)); }
    private static String fingerprint(List<String> fields) {
        try { byte[] digest = MessageDigest.getInstance("SHA-256").digest(String.join("\u0000", fields).getBytes(StandardCharsets.UTF_8)); return Base64.getEncoder().encodeToString(digest); }
        catch (java.security.NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }
    private static boolean validName(String s) { return s != null && s.matches("[A-Za-z0-9_]{2,16}") && !s.equalsIgnoreCase("none") && !s.equalsIgnoreCase("SCServer"); }
    private static boolean token(String s) { return s.matches("[A-Za-z0-9_.:/%\\-]{1,96}"); }
    private static boolean hasControls(String s) { for (int i = 0; i < s.length(); i++) if (Character.isISOControl(s.charAt(i))) return true; return false; }
    private static long parseLong(String s, long fallback) { try { return Long.parseLong(s); } catch (NumberFormatException e) { return fallback; } }
    private static long positive(String s) { return s.matches("[1-9][0-9]{0,17}") ? parseLong(s, 0) : 0; }
    private static long nonnegative(String s) { long n = parseLong(s, -1); require(n >= 0); return n; }
    private static void require(boolean condition) { if (!condition) throw new IllegalArgumentException(); }
    private static List<String> list(String... strings) { return new ArrayList<>(Arrays.asList(strings)); }
    private static Set<String> parseCapabilities(String value) {
        Set<String> out = new HashSet<>(); if (value.isEmpty() || "-".equals(value)) return out;
        for (String kind : value.split(",", -1)) { require(EFFECT_KINDS.contains(kind)); out.add(kind); } return out;
    }
    private static List<String> choices(String value) {
        List<String> out = Arrays.asList(value.split(",", -1)); require(out.size() >= 2 && out.size() <= 8 && new HashSet<>(out).size() == out.size());
        for (String choice : out) require(token(choice)); return out;
    }
    private static List<String> dialogueChoices(String value) {
        List<String> out = Arrays.asList(value.split(",", -1)); require(out.size() >= 1 && out.size() <= 8 && new HashSet<>(out).size() == out.size());
        for (String choice : out) require(token(choice)); return out;
    }

    private void persist(State s) throws IOException {
        Path temporary = directory.resolve("campaign.bin.tmp");
        try (FileOutputStream file = new FileOutputStream(temporary.toFile()); DataOutputStream out = new DataOutputStream(new BufferedOutputStream(file))) {
            out.writeInt(0x53434331); out.writeInt(3); out.writeLong(s.epoch); out.writeUTF(s.host); out.writeBoolean(s.voting); out.writeBoolean(s.sharedXp); out.writeLong(s.nextEvent);
            map(out, s.effects); map(out, s.effectOwners);
            out.writeInt(s.scopes.size()); for (Scope scope : s.scopes.values()) {
                out.writeUTF(scope.id); out.writeUTF(scope.kind); out.writeUTF(scope.target); out.writeUTF(scope.owner); out.writeLong(scope.leaseUntil); strings(out, scope.listeners);
                out.writeUTF(scope.voteId); out.writeUTF(scope.voteChoices); out.writeUTF(scope.voteResult); strings(out, scope.voters); map(out, scope.votes);
                out.writeUTF(scope.leaseId); out.writeUTF(scope.instance); out.writeUTF(scope.choiceSet); out.writeBoolean(scope.mainStory);
                out.writeUTF(scope.acceptedChoice); out.writeLong(scope.acceptedEvent); strings(out, scope.usedInstances);
            }
            out.writeInt(s.values.size()); for (Map.Entry<String, Value> e : s.values.entrySet()) { out.writeUTF(e.getKey()); out.writeUTF(e.getValue().value); out.writeLong(e.getValue().revision); }
            out.writeInt(s.transactions.size()); for (Transaction tx : s.transactions.values()) {
                out.writeUTF(tx.id); out.writeUTF(tx.scope); out.writeUTF(tx.owner); out.writeLong(tx.base); out.writeInt(tx.expectedMembers); out.writeInt(tx.members.size());
                for (Member m : tx.members.values()) { out.writeUTF(m.id); out.writeUTF(m.kind); out.writeUTF(m.target); out.writeUTF(m.value); out.writeUTF(m.expected); }
            }
            out.writeInt(s.sessions.size());
            for (Map.Entry<String, Session> e : s.sessions.entrySet()) { out.writeUTF(e.getKey()); Session p = e.getValue(); out.writeUTF(p.username); out.writeBoolean(p.host); out.writeLong(p.seq); out.writeLong(p.ack); out.writeUTF(p.lastOp); out.writeUTF(p.fingerprint); strings(out, p.reply); }
            out.writeInt(s.events.size()); for (Event e : s.events) { out.writeLong(e.id); out.writeUTF(e.type); out.writeUTF(e.actor); strings(out, e.payload); }
            out.flush(); file.getFD().sync();
        }
        // Windows denies replacing a file another process (antivirus, indexer, backup) briefly holds open.
        for (int attempt = 1; ; attempt++) {
            try { Files.move(temporary, stateFile, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE); return; }
            catch (AtomicMoveNotSupportedException e) { throw new IOException("Campaign filesystem must support atomic replacement", e); }
            catch (AccessDeniedException e) {
                if (attempt >= PERSIST_ATTEMPTS) throw e;
                try { Thread.sleep(5L * attempt); }
                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); throw e; }
            }
        }
    }
    private static final int PERSIST_ATTEMPTS = 10;
    private static State read(Path file) throws IOException {
        if (Files.size(file) > 64L * 1024 * 1024) throw new IOException("Campaign state exceeds limit");
        try (DataInputStream in = new DataInputStream(new BufferedInputStream(Files.newInputStream(file)))) {
            if (in.readInt() != 0x53434331) throw new IOException("Unknown campaign format");
            int format = in.readInt(); if (format != 2 && format != 3) throw new IOException("Unknown campaign format");
            State s = new State(); s.epoch = in.readLong(); s.host = in.readUTF(); s.voting = in.readBoolean(); s.sharedXp = in.readBoolean(); s.nextEvent = in.readLong();
            s.effects.putAll(map(in, MAX_EFFECTS)); s.effectOwners.putAll(map(in, MAX_EFFECTS));
            int count = count(in, 16); for (int i = 0; i < count; i++) {
                Scope scope = new Scope(); scope.id = in.readUTF(); scope.kind = in.readUTF(); scope.target = in.readUTF(); scope.owner = in.readUTF(); scope.leaseUntil = in.readLong(); scope.listeners.addAll(strings(in, MAX_SESSIONS));
                scope.voteId = in.readUTF(); scope.voteChoices = in.readUTF(); scope.voteResult = in.readUTF(); scope.voters.addAll(strings(in, MAX_SESSIONS)); scope.votes.putAll(map(in, MAX_SESSIONS));
                if (format >= 3) {
                    scope.leaseId = in.readUTF(); scope.instance = in.readUTF(); scope.choiceSet = in.readUTF(); scope.mainStory = in.readBoolean();
                    scope.acceptedChoice = in.readUTF(); scope.acceptedEvent = in.readLong(); scope.usedInstances.addAll(strings(in, 256));
                }
                s.scopes.put(scope.id, scope);
            }
            count = count(in, MAX_EFFECTS * 4); for (int i = 0; i < count; i++) s.values.put(in.readUTF(), new Value(in.readUTF(), in.readLong()));
            count = count(in, 16); for (int i = 0; i < count; i++) {
                Transaction tx = new Transaction(); tx.id = in.readUTF(); tx.scope = in.readUTF(); tx.owner = in.readUTF(); tx.base = in.readLong(); tx.expectedMembers = in.readInt(); if (tx.expectedMembers < 1 || tx.expectedMembers > 4) throw new IOException("Invalid member count");
                int members = count(in, 4); for (int j = 0; j < members; j++) { Member m = new Member(in.readUTF(), in.readUTF(), in.readUTF(), in.readUTF(), in.readUTF()); tx.members.put(m.id, m); } s.transactions.put(tx.id, tx);
            }
            count = count(in, MAX_SESSIONS);
            for (int i = 0; i < count; i++) { String id = in.readUTF(); Session p = new Session(); p.username = in.readUTF(); p.host = in.readBoolean(); p.seq = in.readLong(); p.ack = in.readLong(); p.lastOp = in.readUTF(); p.fingerprint = in.readUTF(); p.reply = strings(in, 64); s.sessions.put(id, p); }
            count = count(in, MAX_EVENTS + 32); for (int i = 0; i < count; i++) s.events.add(new Event(in.readLong(), in.readUTF(), in.readUTF(), strings(in, 24)));
            if (in.read() != -1) throw new IOException("Trailing campaign data"); return s;
        }
    }
    private static void strings(DataOutputStream out, Collection<String> values) throws IOException { out.writeInt(values.size()); for (String s : values) out.writeUTF(s); }
    private static List<String> strings(DataInputStream in, int max) throws IOException { int n = count(in, max); List<String> out = new ArrayList<>(); for (int i = 0; i < n; i++) out.add(in.readUTF()); return out; }
    private static void map(DataOutputStream out, Map<String, String> values) throws IOException { out.writeInt(values.size()); for (Map.Entry<String, String> e : values.entrySet()) { out.writeUTF(e.getKey()); out.writeUTF(e.getValue()); } }
    private static Map<String, String> map(DataInputStream in, int max) throws IOException { int n = count(in, max); Map<String, String> out = new HashMap<>(); for (int i = 0; i < n; i++) out.put(in.readUTF(), in.readUTF()); return out; }
    private static int count(DataInputStream in, int max) throws IOException { int n = in.readInt(); if (n < 0 || n > max) throw new IOException("Invalid campaign collection size"); return n; }

    @Override public synchronized void close() throws IOException {
        if (lock != null) { lock.release(); lock = null; }
        if (lockChannel != null) { lockChannel.close(); lockChannel = null; }
    }

    private static final class Active { final String endpoint; long seen; final Set<String> capabilities; Active(String e, long n, Set<String> c) { endpoint = e; seen = n; capabilities = c; } }
    private static final class Session {
        String username = "", lastOp = "", fingerprint = ""; boolean host; long seq, ack; List<String> reply = new ArrayList<>();
        Session() {} Session(Session p) { username = p.username; lastOp = p.lastOp; fingerprint = p.fingerprint; host = p.host; seq = p.seq; ack = p.ack; reply = new ArrayList<>(p.reply); }
    }
    private static final class Event { final long id; final String type, actor; final List<String> payload; Event(long i, String t, String a, List<String> p) { id = i; type = t; actor = a; payload = new ArrayList<>(p); } }
    private static final class Scope {
        String id = "", kind = "", target = "", owner = "", voteId = "", voteChoices = "", voteResult = ""; long leaseUntil;
        String leaseId = "", instance = "", choiceSet = "", acceptedChoice = ""; boolean mainStory; long acceptedEvent;
        final Set<String> usedInstances = new LinkedHashSet<>();
        final Set<String> listeners = new LinkedHashSet<>(), voters = new LinkedHashSet<>(); final Map<String, String> votes = new LinkedHashMap<>();
        Scope() {} Scope(Scope s) { id = s.id; kind = s.kind; target = s.target; owner = s.owner; voteId = s.voteId; voteChoices = s.voteChoices; voteResult = s.voteResult; leaseUntil = s.leaseUntil; listeners.addAll(s.listeners); voters.addAll(s.voters); votes.putAll(s.votes);
            leaseId = s.leaseId; instance = s.instance; choiceSet = s.choiceSet; acceptedChoice = s.acceptedChoice; mainStory = s.mainStory; acceptedEvent = s.acceptedEvent; usedInstances.addAll(s.usedInstances);
        }
    }
    private static final class Member {
        final String id, kind, target, value, expected;
        Member(String id, String kind, String target, String value, String expected) { this.id = id; this.kind = kind; this.target = target; this.value = value; this.expected = expected; }
        String key() { return kind + ":" + target; } String canonical() { return String.join("\u001f", kind, target, value, expected); }
    }
    private static final class Value { final String value; final long revision; Value(String v, long r) { value = v; revision = r; } }
    private static final class Transaction {
        String id = "", scope = "", owner = ""; long base; int expectedMembers = 1; final Map<String, Member> members = new LinkedHashMap<>();
        Transaction() {} Transaction(Transaction t) { id = t.id; scope = t.scope; owner = t.owner; base = t.base; expectedMembers = t.expectedMembers; members.putAll(t.members); }
    }
    private static final class State {
        long epoch, nextEvent = 1; String host = ""; boolean voting, sharedXp;
        final Map<String, Session> sessions = new LinkedHashMap<>(); final List<Event> events = new ArrayList<>();
        final Map<String, String> effects = new LinkedHashMap<>(), effectOwners = new LinkedHashMap<>(); final Map<String, Scope> scopes = new LinkedHashMap<>(); final Map<String, Transaction> transactions = new LinkedHashMap<>(); final Map<String, Value> values = new LinkedHashMap<>();
        State() {} State(State s) { epoch = s.epoch; nextEvent = s.nextEvent; host = s.host; voting = s.voting; sharedXp = s.sharedXp;
            for (Map.Entry<String, Session> e : s.sessions.entrySet()) sessions.put(e.getKey(), new Session(e.getValue()));
            for (Map.Entry<String, Scope> e : s.scopes.entrySet()) scopes.put(e.getKey(), new Scope(e.getValue()));
            for (Map.Entry<String, Transaction> e : s.transactions.entrySet()) transactions.put(e.getKey(), new Transaction(e.getValue()));
            events.addAll(s.events); effects.putAll(s.effects); effectOwners.putAll(s.effectOwners); values.putAll(s.values);
        }
    }
}
