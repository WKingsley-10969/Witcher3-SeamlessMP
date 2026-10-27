import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.URL;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

// JoinGate: no password lets every PC in; with one, only a PC that answered a challenge with the
// right password (and the host's own PC) gets in, and the save share and lobby follow the same rule.
public final class JoinGateTest
{
    private static int assertions;

    public static void main(String[] args) throws Exception
    {
        InetAddress second = InetAddress.getByName("10.147.17.20");   // a second PC (virtual LAN)
        InetAddress third = InetAddress.getByName("10.147.17.30");
        InetAddress host = InetAddress.getLoopbackAddress();
        String ip = second.getHostAddress(), otherIp = third.getHostAddress();
        long now = 1_000_000;

        JoinGate open = new JoinGate("");
        check(!open.enabled() && open.allows(second) && open.allows(host), "no password: anyone joins");
        check(!new JoinGate(null).enabled(), "no password variable: anyone joins");

        JoinGate gate = new JoinGate("silver sword");
        check(gate.enabled(), "a password is required");
        check(gate.allows(host), "the host's own PC needs no password");
        check(!gate.allows(second), "a second PC is refused before it answers");

        String nonce = gate.challenge(ip, now);
        check(nonce != null && nonce.matches("[0-9a-f]{32}"), "a 128-bit hex nonce: " + nonce);
        check(!gate.answer(ip, nonce, JoinGate.proof("steel sword", nonce), now), "a wrong password is refused");
        check(!gate.allows(second), "still refused after a wrong password");
        check(!gate.answer(ip, nonce, JoinGate.proof("silver sword", nonce), now), "a nonce answers once, even after a wrong answer");

        nonce = gate.challenge(ip, now);
        check(!gate.answer(ip, nonce, "", now), "a missing password is refused");
        nonce = gate.challenge(ip, now);
        check(!gate.answer(otherIp, nonce, JoinGate.proof("silver sword", nonce), now), "another PC cannot answer this PC's nonce");
        check(!gate.allows(third), "so it is not let in");
        check(!gate.answer(ip, nonce, JoinGate.proof("silver sword", nonce), now + JoinGate.CHALLENGE_MS + 1), "an expired nonce is refused");

        nonce = gate.challenge(ip, now);
        check(gate.answer(ip, nonce, JoinGate.proof("silver sword", nonce), now), "the right password joins");
        check(gate.allows(second), "the second PC is let in from then on");
        check(!gate.allows(third), "other PCs still are not");
        check(!gate.answer(ip, nonce, JoinGate.proof("silver sword", nonce), now), "a used nonce cannot be replayed");

        JoinGate locked = new JoinGate("silver sword");
        for (int i = 0; i < JoinGate.MAX_FAILURES; i++)
        {
            String guess = locked.challenge(otherIp, now);
            check(guess != null && !locked.answer(otherIp, guess, JoinGate.proof("guess" + i, guess), now), "wrong guess " + i);
        }
        check(locked.challenge(otherIp, now) == null, "too many wrong guesses lock the PC out");
        check(locked.challenge(ip, now) != null, "only that PC");
        String later = locked.challenge(otherIp, now + JoinGate.FAILURE_WINDOW_MS + 1);
        check(later != null, "the lock-out ends after a minute");
        check(locked.answer(otherIp, later, JoinGate.proof("silver sword", later), now + JoinGate.FAILURE_WINDOW_MS + 1), "and the right password then joins");

        // Save share and lobby: a refused PC gets 403 on both; this test's requests come from loopback.
        Path saves = Files.createDirectories(Paths.get(args.length > 0 ? args[0] : ".", "join-gate", "gamesaves"));
        SaveShare refused = SaveShare.start(saves, 0, "HostWitcher", address -> false);
        try
        {
            String base = "http://127.0.0.1:" + refused.port();
            check(status(base + "/session") == 403, "a refused PC cannot read the session");
            check(status(base + "/session/save/QuickSave_1.sav") == 403, "or download a save");
            check(status(base + "/lobby?name=Guest") == 403, "or wait in the lobby");
        }
        finally
        {
            refused.stop();
        }
        SaveShare allowed = SaveShare.start(saves, 0, "HostWitcher", address -> true);
        try
        {
            String base = "http://127.0.0.1:" + allowed.port();
            check(status(base + "/session") == 200 && status(base + "/lobby?name=Guest") == 200, "a PC that joined uses both");
        }
        finally
        {
            allowed.stop();
        }
        System.out.println("JoinGateTest passed: " + assertions + " assertions");
    }

    private static int status(String address) throws IOException
    {
        HttpURLConnection connection = (HttpURLConnection) new URL(address).openConnection();
        try { return connection.getResponseCode(); }
        finally { connection.disconnect(); }
    }

    private static void check(boolean condition, String what)
    {
        assertions++;
        if (!condition) throw new AssertionError("FAIL " + what);
    }
}
