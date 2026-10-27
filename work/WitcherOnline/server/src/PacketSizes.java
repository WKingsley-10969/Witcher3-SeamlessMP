import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.function.LongSupplier;

/**
 * Sizes of the UDP datagrams the server receives and sends, against what internet paths carry in one piece.
 * A datagram larger than a path's MTU is split into IP fragments, and losing any fragment loses the whole
 * message. IPv4 and UDP headers take 28 bytes, so one piece is at most 1252 bytes over Tailscale (MTU 1280),
 * 1472 bytes over an ordinary 1500-byte internet path and 2772 bytes over ZeroTier (MTU 2800).
 *
 * Counts datagrams per direction and message type ("COOP/en" for a co-op channel) by size band, keeps the largest
 * size per type, and returns a warning, at most once per type every 30 seconds, for datagrams over 1200 bytes.
 */
final class PacketSizes
{
    /** Larger than any UDP payload (65,507 bytes), so no datagram is cut off on receipt. */
    static final int RECEIVE_BUFFER_BYTES = 65536;
    /** The game's native client receives into 8192 bytes: a larger datagram fails there, so it is not relayed. */
    static final int CLIENT_RECEIVE_BYTES = 8192;
    static final int WARN_BYTES = 1200;
    static final long WARN_INTERVAL_NANOS = 30_000_000_000L;
    /** Types tracked separately; any further ones are counted together as "other". */
    static final int MAX_TYPES = 128;

    private static final int[] BAND_LIMITS = {WARN_BYTES, 1252, 1472, 2772, CLIENT_RECEIVE_BYTES, Integer.MAX_VALUE};
    static final String[] BAND_NAMES = {"<=1200", "1201-1252", "1253-1472", "1473-2772", "2773-8192", ">8192"};

    private static final class Stats
    {
        final long[] bands = new long[BAND_NAMES.length];
        long datagrams;
        int largest;
        long refused;
        long lastWarning;
        boolean warned;
        long overSinceWarning;
        long lastRefusal;
        boolean refusalWarned;
    }

    private final Map<String, Stats> stats = new TreeMap<>();
    private final LongSupplier clock;

    PacketSizes()
    {
        this(System::nanoTime);
    }

    PacketSizes(LongSupplier clock)
    {
        this.clock = clock;
    }

    static int band(int bytes)
    {
        int band = 0;
        while (bytes > BAND_LIMITS[band]) band++;
        return band;
    }

    /** What a size means on the paths players use. */
    static String pathNote(int bytes)
    {
        if (bytes <= WARN_BYTES) return "fits every path";
        if (bytes <= 1252) return "close to the Tailscale limit of 1252";
        if (bytes <= 1472) return "IP-fragmented over Tailscale (over 1252)";
        if (bytes <= 2772) return "IP-fragmented over Tailscale and 1500-byte internet paths (over 1472)";
        if (bytes <= CLIENT_RECEIVE_BYTES) return "IP-fragmented on every path, ZeroTier too (over 2772)";
        return "over the game client's 8192-byte receive buffer";
    }

    /** The message type of a datagram's text: its opcode, or "COOP/<channel>" (the optional numeric player id skipped). */
    static String typeOf(String text)
    {
        int end = text.indexOf('\t');
        String opcode = end < 0 ? text : text.substring(0, end);
        if (!"COOP".equals(opcode) || end < 0) return clean(opcode, 16);
        String second = field(text, end + 1);
        int start = end + 1 + second.length() + 1;  // past the username, or past the player id
        if (isInteger(second.trim()))
        {
            String third = field(text, start);
            int afterThird = start + third.length() + 1;
            // "COOP id user channel ...": the server's rule for a leading number (handleMessage)
            if (afterThird <= text.length()) start = afterThird;
        }
        return "COOP/" + clean(field(text, start), 8);
    }

    /** The type of a packet the server builds from an opcode and its fields. */
    static String type(String opcode, List<String> fields)
    {
        if (!"COOP".equals(opcode)) return clean(opcode, 16);
        return "COOP/" + clean(fields.isEmpty() ? "" : fields.get(0), 8);
    }

    private static String field(String text, int start)
    {
        if (start >= text.length()) return "";
        int end = text.indexOf('\t', start);
        return end < 0 ? text.substring(start) : text.substring(start, end);
    }

    private static boolean isInteger(String value)
    {
        if (value.isEmpty() || value.length() > 10) return false;
        for (int i = 0; i < value.length(); i++)
        {
            char c = value.charAt(i);
            if (!(c >= '0' && c <= '9') && !(i == 0 && c == '-' && value.length() > 1)) return false;
        }
        return true;
    }

    // Types come from the network: keep them short and printable.
    private static String clean(String value, int maxLength)
    {
        if (value.isEmpty() || value.length() > maxLength) return "?";
        for (int i = 0; i < value.length(); i++)
        {
            char c = value.charAt(i);
            if (!(c >= 'A' && c <= 'Z') && !(c >= 'a' && c <= 'z') && !(c >= '0' && c <= '9') && c != '_') return "?";
        }
        return value;
    }

    private Stats statsFor(String direction, String type)
    {
        String key = direction + " " + type;
        Stats s = stats.get(key);
        if (s == null)
        {
            if (stats.size() >= MAX_TYPES) key = direction + " other";
            s = stats.computeIfAbsent(key, k -> new Stats());
        }
        return s;
    }

    /**
     * Counts datagrams of one type and size ("in" received, "out" sent). Returns a warning to log when one is over
     * 1200 bytes, at most once per direction and type every 30 seconds; otherwise null.
     */
    synchronized String record(String direction, String type, int bytes, int datagrams, String peer)
    {
        if (datagrams <= 0) return null;
        Stats s = statsFor(direction, type);
        s.datagrams += datagrams;
        s.bands[band(bytes)] += datagrams;
        s.largest = Math.max(s.largest, bytes);
        if (bytes <= WARN_BYTES) return null;
        s.overSinceWarning += datagrams;
        long now = clock.getAsLong();
        if (s.warned && now - s.lastWarning < WARN_INTERVAL_NANOS) return null;
        long others = s.overSinceWarning - datagrams;
        s.warned = true;
        s.lastWarning = now;
        s.overSinceWarning = 0;
        return String.format("Large datagram: %s %s %s %s, %d bytes: %s%s",
                direction, type, "in".equals(direction) ? "from" : "of", peer, bytes, pathNote(bytes),
                others > 0 ? " (" + others + " more over " + WARN_BYTES + " bytes since the last warning)" : "");
    }

    /** A datagram not relayed because it is over the client's receive buffer; returns a rate-limited warning or null. */
    synchronized String refuse(String type, int bytes, String peer)
    {
        Stats s = statsFor("out", type);
        s.refused++;
        s.largest = Math.max(s.largest, bytes);
        long now = clock.getAsLong();
        if (s.refusalWarned && now - s.lastRefusal < WARN_INTERVAL_NANOS) return null;
        s.refusalWarned = true;
        s.lastRefusal = now;
        return String.format("Not relayed: %s of %s is %d bytes, over the game client's %d-byte receive buffer (%d refused so far)",
                type, peer, bytes, CLIENT_RECEIVE_BYTES, s.refused);
    }

    /** The largest size seen for a direction and type, or 0. */
    synchronized int largest(String direction, String type)
    {
        Stats s = stats.get(direction + " " + type);
        return s == null ? 0 : s.largest;
    }

    synchronized long datagrams(String direction, String type, int band)
    {
        Stats s = stats.get(direction + " " + type);
        return s == null ? 0 : s.bands[band];
    }

    /** Datagram counts by size band and the largest size per type, for the log at shutdown. */
    synchronized String summary()
    {
        StringBuilder sb = new StringBuilder();
        sb.append("Datagram sizes in bytes (one piece over Tailscale: 1252, a 1500-byte internet path: 1472, ZeroTier: 2772):\n");
        if (stats.isEmpty()) sb.append("  none\n");
        long[] totals = new long[BAND_NAMES.length];
        for (Map.Entry<String, Stats> e : stats.entrySet())
        {
            Stats s = e.getValue();
            sb.append(String.format("  %-16s %10d datagrams, largest %6d", e.getKey(), s.datagrams, s.largest));
            for (int b = 0; b < BAND_NAMES.length; b++)
            {
                totals[b] += s.bands[b];
                if (s.bands[b] > 0 && b > 0) sb.append(", ").append(BAND_NAMES[b]).append(": ").append(s.bands[b]);
            }
            if (s.refused > 0) sb.append(", not relayed: ").append(s.refused);
            sb.append('\n');
        }
        sb.append("  all by size:");
        for (int b = 0; b < BAND_NAMES.length; b++) sb.append(b == 0 ? " " : ", ").append(BAND_NAMES[b]).append(": ").append(totals[b]);
        sb.append('\n');
        return sb.toString();
    }
}
