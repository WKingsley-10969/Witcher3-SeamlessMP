import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.attribute.FileTime;
import java.util.Arrays;

// SaveShare: the newest save is described, files of the save directory are served byte for byte,
// and nothing outside it (or that is not a .sav/.png) can be fetched.
public final class SaveShareTest
{
    private static int assertions;

    public static void main(String[] args) throws Exception
    {
        Path root = Files.createDirectories(Paths.get(args.length > 0 ? args[0] : ".", "save-share"));
        Path saves = Files.createDirectories(root.resolve("gamesaves"));
        Files.write(root.resolve("secret.sav"), "outside".getBytes(StandardCharsets.UTF_8));
        Files.write(saves.resolve("notes.txt"), "not a save".getBytes(StandardCharsets.UTF_8));

        SaveShare share = SaveShare.start(saves, 0, "HostWitcher");
        try
        {
            String base = "http://127.0.0.1:" + share.port();
            check(get(base + "/session").body.equals("host=HostWitcher\nsave=\n"), "no save yet: empty save=");

            byte[] older = bytes(70_000, 1);
            byte[] newer = bytes(250_000, 7);
            Files.write(saves.resolve("ManualSave_1a2b3c.sav"), older);
            Files.write(saves.resolve("ManualSave_1a2b3c.png"), bytes(900, 3));
            Files.write(saves.resolve("QuickSave_9f8e.sav"), newer);
            Files.setLastModifiedTime(saves.resolve("ManualSave_1a2b3c.sav"), FileTime.fromMillis(1_700_000_000_000L));
            Files.setLastModifiedTime(saves.resolve("QuickSave_9f8e.sav"), FileTime.fromMillis(1_700_000_500_000L));

            String session = get(base + "/session").body;
            check(session.contains("host=HostWitcher\n"), "host name");
            check(session.contains("save=QuickSave_9f8e\n"), "newest save by modification time: " + session);
            check(session.contains("size=250000\n"), "size of the newest save");
            check(session.contains("modified=1700000500000\n"), "modification time");

            Response sav = get(base + "/session/save/QuickSave_9f8e.sav");
            check(sav.status == 200 && Arrays.equals(sav.bytes, newer), "save served byte for byte");
            Response png = get(base + "/session/save/ManualSave_1a2b3c.png");
            check(png.status == 200 && png.bytes.length == 900, "thumbnail served");

            check(get(base + "/session/save/../secret.sav").status == 404, "no path outside the directory");
            check(get(base + "/session/save/%2e%2e%2fsecret.sav").status == 404, "no encoded path outside the directory");
            check(get(base + "/session/save/notes.txt").status == 404, "only .sav and .png files");
            check(get(base + "/session/save/Missing_0000.sav").status == 404, "missing file");
            check(get(base + "/other").status == 404, "nothing else is served");
        }
        finally
        {
            share.stop();
        }
        System.out.println("SaveShareTest passed: " + assertions + " assertions");
    }

    private static final class Response
    {
        int status;
        byte[] bytes;
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
            response.bytes = out.toByteArray();
        }
        response.body = new String(response.bytes, StandardCharsets.UTF_8);
        return response;
    }

    private static byte[] bytes(int size, int seed)
    {
        byte[] data = new byte[size];
        for (int i = 0; i < size; i++) data[i] = (byte) (i * seed + seed);
        return data;
    }

    private static void check(boolean condition, String what)
    {
        assertions++;
        if (!condition) throw new AssertionError("FAIL " + what);
    }
}
