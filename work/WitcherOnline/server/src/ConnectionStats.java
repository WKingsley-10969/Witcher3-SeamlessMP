import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Connection health of each player for the host console: the "status" command, and a one-line
 * summary every statusSummarySeconds (server.properties; default 60, 0 = off) while players are
 * connected. Meant for internet play over ZeroTier or Tailscale, where packet loss and stalls show.
 *
 * Counters are kept per UDP endpoint (address:port), fed by the server's receive and send paths.
 * Loss is estimated from the movement sequence number the native game client already stamps on
 * MOVE (field 0) and UPDATE1A/UPDATE1B (field 1): one counter shared by the three opcodes, and
 * UPDATE1A and UPDATE1B carry the same number. It covers packets from a player to the host only;
 * the other direction has no acknowledgements. Ping cannot be measured: clients echo nothing the
 * server sends, so it shows "n/a".
 */
public final class ConnectionStats
{
    public static final String SUMMARY_PROPERTY = "statusSummarySeconds";
    public static final int DEFAULT_SUMMARY_SECONDS = 60;
    static final int RATE_SECONDS = 10;      // rates and loss: the last 10 complete seconds
    static final int GAP_SECONDS = 60;       // longest silence between two packets: the last 60 seconds

    private static final long SECOND = 1_000_000_000L;
    private static final int SLOTS = GAP_SECONDS + 2;
    private static final int MAX_TRACKED = 256;               // endpoints; idle unknown senders are dropped first
    private static final long FORGET_NANOS = 10 * SECOND;     // an endpoint no session uses, silent this long
    private static final int SEQ_WINDOW = 1024;               // recent sequence numbers kept to spot duplicates
    private static final long SEQ_RESTART_JUMP = 5000;        // a bigger jump is a new stream, not loss
    private static final long MIN_EXPECTED_FOR_LOSS = 10;

    private final Map<ClientEndpoint, Link> links = new ConcurrentHashMap<>();
    private volatile long summaryIntervalNanos = DEFAULT_SUMMARY_SECONDS * SECOND;
    private boolean summaryArmed;      // tick() thread only
    private long nextSummaryNanos;     // tick() thread only

    /** Reads statusSummarySeconds; a bad value keeps the default and says so on stderr. */
    public void configure(Properties properties)
    {
        String text = properties.getProperty(SUMMARY_PROPERTY);
        if (text == null)
        {
            return;
        }

        try
        {
            int seconds = Integer.parseInt(text.trim());
            if (seconds >= 0 && seconds <= 86_400)
            {
                setSummarySeconds(seconds);
                return;
            }
        }
        catch (NumberFormatException ignored)
        {
        }

        System.err.println("Invalid server.properties " + SUMMARY_PROPERTY + ": " + text
                + " (0 to 86400; keeping " + summarySeconds() + ")");
    }

    public void setSummarySeconds(int seconds)
    {
        summaryIntervalNanos = Math.max(0, seconds) * SECOND;
    }

    public int summarySeconds()
    {
        return (int) (summaryIntervalNanos / SECOND);
    }

    /** A datagram from an endpoint that passed the ban and whitelist checks. */
    public void packetIn(ClientEndpoint from, long now)
    {
        Link link = links.get(from);

        if (link == null)
        {
            if (links.size() >= MAX_TRACKED)
            {
                forget(now, FORGET_NANOS, Set.of());
                if (links.size() >= MAX_TRACKED)
                {
                    return;
                }
            }

            link = links.computeIfAbsent(from, key -> new Link(now));
        }

        link.in(now);
    }

    /** Fields after the player id and name of an accepted player packet. */
    public void sequence(ClientEndpoint from, String opcode, List<String> fields, long now)
    {
        int index = "MOVE".equals(opcode) ? 0 : ("UPDATE1A".equals(opcode) || "UPDATE1B".equals(opcode)) ? 1 : -1;
        if (index < 0 || fields == null || fields.size() <= index)
        {
            return;
        }

        long sequence = parsePositive(fields.get(index));
        Link link = links.get(from);

        if (sequence > 0 && link != null)
        {
            link.sequence(sequence, now);
        }
    }

    /** A datagram the server sent; only endpoints that have sent something are counted. */
    public void packetOut(ClientEndpoint to, long now)
    {
        Link link = links.get(to);
        if (link != null)
        {
            link.out(now);
        }
    }

    /** The "status" table, one row per connected player. */
    public List<String> statusLines(Collection<PlayerSession> sessions, long now)
    {
        List<PlayerSession> sorted = sortedSessions(sessions);
        List<String> lines = new ArrayList<>();

        lines.add(String.format(Locale.ROOT, "---- Connection status: %d player%s; rates and loss over the last %d s ----",
                sorted.size(), sorted.size() == 1 ? "" : "s", RATE_SECONDS));

        if (sorted.isEmpty())
        {
            lines.add("No players connected.");
            return lines;
        }

        lines.add(String.format(Locale.ROOT, "%4s  %-16s  %-21s  %7s  %6s  %6s  %6s  %6s  %6s  %4s",
                "id", "name", "address", "online", "last", "in/s", "out/s", "loss", "gap", "ping"));

        for (PlayerSession session : sorted)
        {
            Link link = links.get(session.endpoint);
            Snapshot s = link == null ? null : link.snapshot(now);

            lines.add(String.format(Locale.ROOT, "%4d  %-16s  %-21s  %7s  %6s  %6s  %6s  %6s  %6s  %4s",
                    session.playerId,
                    session.username,
                    session.endpoint,
                    s == null ? "?" : duration(now - s.firstIn),
                    seconds(now - (s == null ? session.lastSeen : s.lastIn)),
                    s == null ? "?" : rate(s.inPerSecond),
                    s == null ? "?" : rate(s.outPerSecond),
                    s == null ? "n/a" : percent(s.lossPercent),
                    s == null ? "?" : seconds(s.maxGapNanos),
                    "n/a"));
        }

        lines.add("online: since this address first sent; last: since its last packet; gap: longest silence in the last "
                + GAP_SECONDS + " s.");
        lines.add("loss: estimated from the sequence numbers on each game's packets to the host (that direction only).");
        lines.add("ping: n/a, the game sends nothing the host could time a round trip with.");
        return lines;
    }

    /** One line for the periodic summary; null without players. */
    public String summaryLine(Collection<PlayerSession> sessions, long now)
    {
        List<PlayerSession> sorted = sortedSessions(sessions);
        if (sorted.isEmpty())
        {
            return null;
        }

        StringBuilder out = new StringBuilder("Connections (last " + RATE_SECONDS + " s):");
        String separator = " ";

        for (PlayerSession session : sorted)
        {
            Link link = links.get(session.endpoint);
            Snapshot s = link == null ? null : link.snapshot(now);

            out.append(separator).append(session.username).append(' ').append(session.endpoint.address.getHostAddress());
            if (s == null)
            {
                out.append(" last ").append(seconds(now - session.lastSeen));
            }
            else
            {
                out.append(" in ").append(rate(s.inPerSecond)).append("/s")
                        .append(" out ").append(rate(s.outPerSecond)).append("/s")
                        .append(" loss ").append(percent(s.lossPercent))
                        .append(" last ").append(seconds(now - s.lastIn));
            }
            separator = " | ";
        }

        return out.append(" (type status for details)").toString();
    }

    /**
     * Called about once a second: forgets silent endpoints no player uses and returns the summary
     * line when one is due (the first one a full interval after players are connected), else null.
     */
    public String tick(Collection<PlayerSession> sessions, long now)
    {
        Set<ClientEndpoint> active = new HashSet<>();
        for (PlayerSession session : sessions)
        {
            active.add(session.endpoint);
        }

        forget(now, FORGET_NANOS, active);

        long interval = summaryIntervalNanos;
        if (interval <= 0 || active.isEmpty())
        {
            summaryArmed = false;
            return null;
        }

        if (!summaryArmed)
        {
            summaryArmed = true;
            nextSummaryNanos = now + interval;
            return null;
        }

        if (now - nextSummaryNanos < 0)
        {
            return null;
        }

        nextSummaryNanos = now + interval;
        return summaryLine(sessions, now);
    }

    int trackedEndpoints()
    {
        return links.size();
    }

    private void forget(long now, long idleNanos, Set<ClientEndpoint> keep)
    {
        links.entrySet().removeIf(entry -> !keep.contains(entry.getKey()) && entry.getValue().idleNanos(now) > idleNanos);
    }

    private static List<PlayerSession> sortedSessions(Collection<PlayerSession> sessions)
    {
        List<PlayerSession> sorted = new ArrayList<>();
        for (PlayerSession session : sessions)
        {
            if (session != null && session.endpoint != null)
            {
                sorted.add(session);
            }
        }
        sorted.sort(Comparator.comparingInt((PlayerSession session) -> session.playerId));
        return sorted;
    }

    private static long parsePositive(String text)
    {
        if (text == null || text.isEmpty() || text.length() > 18)
        {
            return -1;
        }

        long value = 0;
        for (int i = 0; i < text.length(); i++)
        {
            char c = text.charAt(i);
            if (c < '0' || c > '9')
            {
                return -1;
            }
            value = value * 10 + (c - '0');
        }
        return value;
    }

    static String rate(double perSecond)
    {
        return perSecond < 0 ? "-" : String.format(Locale.ROOT, perSecond >= 100 ? "%.0f" : "%.1f", perSecond);
    }

    static String percent(double value)
    {
        return value < 0 ? "n/a" : String.format(Locale.ROOT, "%.1f%%", value);
    }

    static String seconds(long nanos)
    {
        return String.format(Locale.ROOT, "%.1fs", Math.max(0L, nanos) / (double) SECOND);
    }

    static String duration(long nanos)
    {
        long total = Math.max(0L, nanos) / SECOND;
        if (total < 60)
        {
            return total + "s";
        }
        if (total < 3600)
        {
            return String.format(Locale.ROOT, "%dm%02ds", total / 60, total % 60);
        }
        return String.format(Locale.ROOT, "%dh%02dm", total / 3600, (total % 3600) / 60);
    }

    static final class Snapshot
    {
        long firstIn;
        long lastIn;
        double inPerSecond = -1;
        double outPerSecond = -1;
        double lossPercent = -1;
        long maxGapNanos;
    }

    /** Counters of one endpoint, in per-second slots of a ring. */
    private static final class Link
    {
        private final long firstIn;
        private long lastIn;
        private long packetsIn;

        private final long[] slotSecond = new long[SLOTS];
        private final long[] in = new long[SLOTS];
        private final long[] out = new long[SLOTS];
        private final long[] expected = new long[SLOTS];
        private final long[] received = new long[SLOTS];
        private final long[] maxGap = new long[SLOTS];

        private boolean sequenceStarted;
        private long highest;
        private final long[] seen = new long[SEQ_WINDOW / 64];

        Link(long now)
        {
            firstIn = now;
            lastIn = now;
            Arrays.fill(slotSecond, Long.MIN_VALUE);
        }

        synchronized void in(long now)
        {
            int slot = slot(now);
            if (packetsIn > 0 && now - lastIn > maxGap[slot])
            {
                maxGap[slot] = now - lastIn;
            }
            lastIn = now;
            packetsIn++;
            in[slot]++;
        }

        synchronized void out(long now)
        {
            out[slot(now)]++;
        }

        synchronized void sequence(long sequence, long now)
        {
            int slot = slot(now);

            if (!sequenceStarted)
            {
                restart(sequence, slot);
                return;
            }

            long delta = sequence - highest;

            if (delta > 0)
            {
                if (delta > SEQ_RESTART_JUMP)
                {
                    restart(sequence, slot);
                    return;
                }

                if (delta >= SEQ_WINDOW)
                {
                    Arrays.fill(seen, 0L);
                }
                else
                {
                    for (long s = highest + 1; s < sequence; s++)
                    {
                        clear(s);
                    }
                }

                mark(sequence);
                highest = sequence;
                expected[slot] += delta;
                received[slot]++;
                return;
            }

            if (-delta >= SEQ_WINDOW)
            {
                if (-delta > SEQ_RESTART_JUMP)
                {
                    restart(sequence, slot);
                }
                return;   // too late to tell from a duplicate
            }

            if (!isMarked(sequence))
            {
                mark(sequence);   // arrived late: it was counted as expected already
                received[slot]++;
            }
        }

        synchronized long idleNanos(long now)
        {
            return now - lastIn;
        }

        synchronized Snapshot snapshot(long now)
        {
            Snapshot s = new Snapshot();
            s.firstIn = firstIn;
            s.lastIn = lastIn;

            long current = Math.floorDiv(now, SECOND);
            long window = Math.min(RATE_SECONDS, current - Math.floorDiv(firstIn, SECOND));

            if (window > 0)
            {
                long sumIn = 0, sumOut = 0, sumExpected = 0, sumReceived = 0;
                for (long second = current - window; second < current; second++)
                {
                    int slot = (int) Math.floorMod(second, (long) SLOTS);
                    if (slotSecond[slot] == second)
                    {
                        sumIn += in[slot];
                        sumOut += out[slot];
                        sumExpected += expected[slot];
                        sumReceived += received[slot];
                    }
                }

                s.inPerSecond = sumIn / (double) window;
                s.outPerSecond = sumOut / (double) window;
                if (sumExpected >= MIN_EXPECTED_FOR_LOSS)
                {
                    s.lossPercent = 100.0 * Math.max(0L, sumExpected - sumReceived) / sumExpected;
                }
            }

            for (long second = current - GAP_SECONDS; second <= current; second++)
            {
                int slot = (int) Math.floorMod(second, (long) SLOTS);
                if (slotSecond[slot] == second)
                {
                    s.maxGapNanos = Math.max(s.maxGapNanos, maxGap[slot]);
                }
            }

            return s;
        }

        private void restart(long sequence, int slot)
        {
            sequenceStarted = true;
            highest = sequence;
            Arrays.fill(seen, 0L);
            mark(sequence);
            expected[slot]++;
            received[slot]++;
        }

        private int slot(long now)
        {
            long second = Math.floorDiv(now, SECOND);
            int slot = (int) Math.floorMod(second, (long) SLOTS);
            if (slotSecond[slot] != second)
            {
                slotSecond[slot] = second;
                in[slot] = 0;
                out[slot] = 0;
                expected[slot] = 0;
                received[slot] = 0;
                maxGap[slot] = 0;
            }
            return slot;
        }

        private void mark(long sequence)
        {
            int bit = (int) (sequence & (SEQ_WINDOW - 1));
            seen[bit >>> 6] |= 1L << (bit & 63);
        }

        private void clear(long sequence)
        {
            int bit = (int) (sequence & (SEQ_WINDOW - 1));
            seen[bit >>> 6] &= ~(1L << (bit & 63));
        }

        private boolean isMarked(long sequence)
        {
            int bit = (int) (sequence & (SEQ_WINDOW - 1));
            return (seen[bit >>> 6] & (1L << (bit & 63))) != 0;
        }
    }
}
