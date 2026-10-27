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
// and nothing outside it (or that is not a .sav/.png/.json) can be fetched.
public final class SaveShareTest
{
    private static int assertions;

    public static void main(String[] args) throws Exception
    {
        Path root = Paths.get(args.length > 0 ? args[0] : ".", "save-share");
        clear(root);   // a fresh folder: an earlier run's saves would be offered
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
            Files.write(saves.resolve("ManualSave_1a2b3c.json"), "{\"build\":\"4.04\"}".getBytes(java.nio.charset.StandardCharsets.UTF_8));
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
            Response json = get(base + "/session/save/ManualSave_1a2b3c.json");
            check(json.status == 200 && new String(json.bytes, java.nio.charset.StandardCharsets.UTF_8).contains("4.04"), "save metadata (.json) served");

            // checksum: in the listing and on every file, of the whole file
            String newerSha = sha256(newer);
            check(session.contains("sha256=" + newerSha + "\n"), "SHA-256 of the newest save in the listing");
            check(newerSha.equals(sav.header("X-Content-SHA256")), "SHA-256 header on the save");
            check(sha256(png.bytes).equals(png.header("X-Content-SHA256")), "SHA-256 header on the thumbnail");
            check("bytes".equals(sav.header("Accept-Ranges")), "ranges offered");

            // Range: a dropped download resumes where it broke off
            String url = base + "/session/save/QuickSave_9f8e.sav";
            Response tail = get(url, "bytes=100000-");
            check(tail.status == 206 && Arrays.equals(tail.bytes, Arrays.copyOfRange(newer, 100_000, 250_000)), "resume from an offset: the rest of the file");
            check("bytes 100000-249999/250000".equals(tail.header("Content-Range")), "Content-Range of a resume: " + tail.header("Content-Range"));
            check(newerSha.equals(tail.header("X-Content-SHA256")), "a part carries the whole file's SHA-256");
            Response middle = get(url, "bytes=10-19");
            check(middle.status == 206 && Arrays.equals(middle.bytes, Arrays.copyOfRange(newer, 10, 20)), "a closed range");
            Response suffix = get(url, "bytes=-500");
            check(suffix.status == 206 && Arrays.equals(suffix.bytes, Arrays.copyOfRange(newer, 249_500, 250_000)), "a suffix range");
            Response last = get(url, "bytes=249999-2000000");
            check(last.status == 206 && last.bytes.length == 1 && "bytes 249999-249999/250000".equals(last.header("Content-Range")), "a range end past the file is cut at its end");
            Response outside = get(url, "bytes=250000-");
            check(outside.status == 416 && "bytes */250000".equals(outside.header("Content-Range")), "a range starting at the end: 416");
            Response several = get(url, "bytes=0-9,20-29");
            check(several.status == 200 && Arrays.equals(several.bytes, newer), "several ranges: the whole file");
            check(get(url, "items=0-9").status == 200, "other units: the whole file");
            check(get(url, "bytes=20-10").status == 200, "a reversed range: the whole file");
            check(get(base + "/session/save/Missing_0000.sav", "bytes=0-").status == 404, "a range of a missing file");

            check(SaveShare.range(null, 10) == null, "no header");
            check(Arrays.equals(SaveShare.range("bytes=0-", 10), new long[] { 0, 9 }), "bytes=0-");
            check(Arrays.equals(SaveShare.range("bytes=-20", 10), new long[] { 0, 9 }), "a suffix longer than the file");
            check(SaveShare.range("bytes=-0", 10).length == 0, "an empty suffix");
            check(SaveShare.range("bytes=0-", 0).length == 0, "any range of an empty file");
            check(SaveShare.range("bytes=-", 10) == null, "no numbers");
            check(SaveShare.range("bytes=99999999999999999999-", 10) == null, "a number too long");

            check(get(base + "/session/save/../secret.sav").status == 404, "no path outside the directory");
            check(get(base + "/session/save/%2e%2e%2fsecret.sav").status == 404, "no encoded path outside the directory");
            check(get(base + "/session/save/notes.txt").status == 404, "only .sav, .png and .json files");
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
        java.util.Map<String, java.util.List<String>> headers;

        String header(String name)
        {
            for (java.util.Map.Entry<String, java.util.List<String>> entry : headers.entrySet())
                if (name.equalsIgnoreCase(entry.getKey())) return entry.getValue().get(0);
            return null;
        }
    }

    private static Response get(String address) throws IOException
    {
        return get(address, null);
    }

    private static Response get(String address, String range) throws IOException
    {
        HttpURLConnection connection = (HttpURLConnection) new URL(address).openConnection();
        if (range != null) connection.setRequestProperty("Range", range);
        Response response = new Response();
        response.status = connection.getResponseCode();
        response.headers = connection.getHeaderFields();
        try (InputStream in = response.status < 400 ? connection.getInputStream() : connection.getErrorStream())
        {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            if (in != null) in.transferTo(out);
            response.bytes = out.toByteArray();
        }
        response.body = new String(response.bytes, StandardCharsets.UTF_8);
        return response;
    }

    static void clear(Path folder) throws IOException
    {
        if (!Files.exists(folder)) return;
        try (java.util.stream.Stream<Path> paths = Files.walk(folder))
        {
            for (Path path : (Iterable<Path>) paths.sorted(java.util.Comparator.reverseOrder())::iterator) Files.delete(path);
        }
    }

    private static String sha256(byte[] bytes) throws Exception
    {
        return java.util.HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256").digest(bytes));
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
