import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * Optional join password. With no password every PC may join (the original behaviour). With one,
 * a PC answers a challenge once per server run, and from then on its address may send game
 * packets and use the save share and lobby. The host's own PC (loopback) never needs it.
 *
 * UDP, before any game packet:
 *   AUTH                       -> AUTH CHALLENGE <nonce>   (AUTH OPEN without a password)
 *   AUTH <nonce> <proof>       -> AUTH OK, or ERROR WRONG_PASSWORD
 * proof = lowercase hex HMAC-SHA256(key = UTF-8 password, message = "w3lan-join:" + nonce), so the
 * password itself never crosses the network. A nonce answers once and expires after 30 seconds.
 * After 5 wrong answers within a minute an address gets ERROR TOO_MANY_ATTEMPTS instead of a nonce.
 */
final class JoinGate
{
    static final String PASSWORD_ENV = "W3LAN_JOIN_PASSWORD";
    static final long CHALLENGE_MS = 30_000;
    static final long FAILURE_WINDOW_MS = 60_000;
    static final int MAX_FAILURES = 5;
    private static final int MAX_TRACKED = 1024;
    private static final SecureRandom RANDOM = new SecureRandom();

    private record Challenge(String nonce, long expiresAt) {}

    private final byte[] key;   // null: no password
    private final Set<String> granted = new HashSet<>();
    private final Map<String, Challenge> challenges = new HashMap<>();
    private final Map<String, Deque<Long>> failures = new HashMap<>();

    JoinGate(String password)
    {
        key = password == null || password.isEmpty() ? null : password.getBytes(StandardCharsets.UTF_8);
    }

    boolean enabled()
    {
        return key != null;
    }

    synchronized boolean allows(InetAddress address)
    {
        return key == null || address.isLoopbackAddress() || granted.contains(address.getHostAddress());
    }

    /** A fresh nonce for this address (replacing an older one), or null while it is locked out. */
    synchronized String challenge(String ip, long nowMs)
    {
        if (recentFailures(ip, nowMs) >= MAX_FAILURES) return null;
        if (challenges.size() >= MAX_TRACKED) purge(nowMs);
        if (challenges.size() >= MAX_TRACKED) return null;
        byte[] raw = new byte[16];
        RANDOM.nextBytes(raw);
        String nonce = hex(raw);
        challenges.put(ip, new Challenge(nonce, nowMs + CHALLENGE_MS));
        return nonce;
    }

    /** True when proof answers this address's current nonce; the nonce is used up either way. */
    synchronized boolean answer(String ip, String nonce, String proof, long nowMs)
    {
        Challenge challenge = challenges.remove(ip);
        boolean ok = key != null && challenge != null && nowMs <= challenge.expiresAt() && challenge.nonce().equals(nonce)
                && MessageDigest.isEqual(proof(key, nonce).getBytes(StandardCharsets.US_ASCII), proof.getBytes(StandardCharsets.US_ASCII));
        if (ok)
        {
            granted.add(ip);
            failures.remove(ip);
        }
        else if (challenge != null)   // without an issued nonce there was nothing to guess
        {
            if (failures.size() >= MAX_TRACKED) purge(nowMs);
            if (failures.containsKey(ip) || failures.size() < MAX_TRACKED)
                failures.computeIfAbsent(ip, k -> new ArrayDeque<>()).addLast(nowMs);
        }
        return ok;
    }

    private int recentFailures(String ip, long nowMs)
    {
        Deque<Long> times = failures.get(ip);
        if (times == null) return 0;
        while (!times.isEmpty() && nowMs - times.peekFirst() > FAILURE_WINDOW_MS) times.removeFirst();
        if (times.isEmpty()) failures.remove(ip);
        return times.size();
    }

    private void purge(long nowMs)
    {
        challenges.values().removeIf(challenge -> nowMs > challenge.expiresAt());
        for (String ip : new HashSet<>(failures.keySet())) recentFailures(ip, nowMs);
    }

    static String proof(String password, String nonce)
    {
        return proof(password.getBytes(StandardCharsets.UTF_8), nonce);
    }

    private static String proof(byte[] key, String nonce)
    {
        try
        {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key, "HmacSHA256"));
            return hex(mac.doFinal(("w3lan-join:" + nonce).getBytes(StandardCharsets.UTF_8)));
        }
        catch (GeneralSecurityException e)
        {
            throw new IllegalStateException(e);
        }
    }

    private static String hex(byte[] bytes)
    {
        StringBuilder text = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) text.append(Character.forDigit((b >> 4) & 15, 16)).append(Character.forDigit(b & 15, 16));
        return text.toString();
    }
}
