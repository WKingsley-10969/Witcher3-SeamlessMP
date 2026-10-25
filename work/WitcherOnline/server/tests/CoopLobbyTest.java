import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.attribute.FileTime;
import java.util.Collections;

// CoopLobby: waiting players check in, the host's own PC starts the session with a save or a new
// game and reopens the lobby, and nobody else can start it.
public final class CoopLobbyTest
{
    private static int assertions;

    public static void main(String[] args) throws Exception
    {
        Path root = Paths.get(args.length > 0 ? args[0] : ".", "coop-lobby");
        SaveShareTest.clear(root);   // a fresh folder: an earlier run's saves would be offered
        Path saves = Files.createDirectories(root.resolve("gamesaves"));
        Files.write(saves.resolve("ManualSave_aaa111.sav"), new byte[] {1, 2, 3});
        Files.write(saves.resolve("QuickSave_bbb222.sav"), new byte[] {4, 5, 6});
        Files.setLastModifiedTime(saves.resolve("ManualSave_aaa111.sav"), FileTime.fromMillis(1_700_000_000_000L));
        Files.setLastModifiedTime(saves.resolve("QuickSave_bbb222.sav"), FileTime.fromMillis(1_700_000_900_000L));

        SaveShare share = SaveShare.start(saves, 0, "HostWitcher");
        try
        {
            String base = "http://127.0.0.1:" + share.port();
            String lobby = get(base + "/lobby").body;
            check(lobby.contains("host=HostWitcher\n") && lobby.contains("state=open\n") && lobby.contains("seq=0\n"), "a new lobby is open: " + lobby);
            check(lobby.contains("newest=QuickSave_bbb222\n"), "it names the host's newest save");
            check(lobby.contains("players=\n"), "nobody waits yet");

            get(base + "/lobby?name=GuestWitcher");
            get(base + "/lobby?name=HostWitcher");
            get(base + "/lobby?name=bad%20name");
            lobby = get(base + "/lobby?name=SecondGuest").body;
            check(lobby.contains("players=GuestWitcher,SecondGuest\n"), "waiting players are listed, not the host or bad names: " + lobby);

            check(get(base + "/lobby/start?mode=save&save=Missing_000").status == 400, "an unknown save cannot start");
            check(get(base + "/lobby/start?mode=fly").status == 400, "an unknown mode cannot start");
            check(get(base + "/lobby/start?mode=new&options=x").status == 400, "new-game options must be a number");

            lobby = get(base + "/lobby/start?mode=save").body;
            check(lobby.contains("state=started\n") && lobby.contains("seq=1\n") && lobby.contains("mode=save\n"), "the host starts with a save: " + lobby);
            check(lobby.contains("save=QuickSave_bbb222\n"), "no save named: the newest");

            lobby = get(base + "/lobby/start?mode=save&save=ManualSave_aaa111").body;
            check(lobby.contains("seq=2\n") && lobby.contains("save=ManualSave_aaa111\n"), "the host starts with a chosen save");

            lobby = get(base + "/lobby/start?mode=new&options=12345").body;
            check(lobby.contains("seq=3\n") && lobby.contains("mode=new\n") && lobby.contains("options=12345\n") && lobby.contains("save=\n"), "the host starts a new game: " + lobby);

            lobby = get(base + "/lobby/open").body;
            check(lobby.contains("state=open\n") && lobby.contains("seq=3\n"), "the host reopens the lobby");

            InetAddress other = lanAddress();
            if (other != null)
            {
                Response remote = get("http://" + other.getHostAddress() + ":" + share.port() + "/lobby/start?mode=save");
                check(remote.status == 403, "another PC cannot start the session (" + other.getHostAddress() + ")");
                check(get("http://" + other.getHostAddress() + ":" + share.port() + "/lobby/open").status == 403, "another PC cannot reopen the lobby");
            }
            else
            {
                System.out.println("SKIP no LAN address on this PC: the another-PC refusal was not checked");
            }
        }
        finally
        {
            share.stop();
        }
        System.out.println("CoopLobbyTest passed: " + assertions + " assertions");
    }

    private static InetAddress lanAddress() throws IOException
    {
        for (NetworkInterface face : Collections.list(NetworkInterface.getNetworkInterfaces()))
        {
            if (!face.isUp() || face.isLoopback()) continue;
            for (InetAddress address : Collections.list(face.getInetAddresses()))
                if (address instanceof Inet4Address && !address.isLoopbackAddress() && !address.isLinkLocalAddress()) return address;
        }
        return null;
    }

    private static final class Response
    {
        int status;
        String body;
    }

    private static Response get(String address) throws IOException
    {
        HttpURLConnection connection = (HttpURLConnection) new URL(address).openConnection();
        Response response = new Response();
        response.status = connection.getResponseCode();
        try (InputStream in = response.status < 400 ? connection.getInputStream() : connection.getErrorStream())
        {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            if (in != null) in.transferTo(out);
            response.body = new String(out.toByteArray(), StandardCharsets.UTF_8);
        }
        return response;
    }

    private static void check(boolean condition, String what)
    {
        assertions++;
        if (!condition) throw new AssertionError("FAIL " + what);
    }
}
