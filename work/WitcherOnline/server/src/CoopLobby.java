import com.sun.net.httpserver.HttpContext;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * Co-op lobby on the host's server, beside SaveShare. Joining players wait in it from the main
 * menu; the host starts the session, with a save or a new game, and every waiting game loads it.
 *
 * GET /lobby?name=NAME         a waiting player checks in (seen for LOBBY_SEEN_MS); returns the state:
 *                              host, state open|started, seq (counts starts), mode save|new, save,
 *                              options (new-game options), age (seconds since the start), newest
 *                              (the host's newest save), players (waiting players, comma separated)
 * GET /lobby/start?mode=save[&save=NAME]  or  ?mode=new&options=N
 *                              start the session (the host's own PC only); no save: the newest
 * GET /lobby/open              back to waiting (the host's own PC only: the host is in the main menu)
 */
final class CoopLobby
{
    private static final Pattern PLAYER_NAME = Pattern.compile("[A-Za-z0-9_]{2,16}");
    private static final Pattern SAVE_NAME = Pattern.compile("[A-Za-z0-9_.-]{1,120}");
    static final long LOBBY_SEEN_MS = 6000;

    private final SaveShare saves;
    private final Map<String, Long> seen = new LinkedHashMap<>();
    private boolean started;
    private int seq;
    private String mode = "";
    private String save = "";
    private int options;
    private long startedAt;

    private CoopLobby(SaveShare saves)
    {
        this.saves = saves;
    }

    static HttpContext attach(HttpServer server, SaveShare saves)
    {
        CoopLobby lobby = new CoopLobby(saves);
        return server.createContext("/lobby", lobby::handle);
    }

    private void handle(HttpExchange exchange) throws IOException
    {
        try
        {
            String path = exchange.getRequestURI().getPath();
            Map<String, String> query = query(exchange.getRequestURI().getRawQuery());
            boolean hostPc = exchange.getRemoteAddress().getAddress().isLoopbackAddress();
            int status = 200;
            String error = null;
            synchronized (this)
            {
                if (!"GET".equals(exchange.getRequestMethod())) { status = 405; error = "GET only"; }
                else if ("/lobby".equals(path)) checkIn(query.get("name"));
                else if ("/lobby/start".equals(path))
                {
                    if (!hostPc) { status = 403; error = "only the host starts the session"; }
                    else error = start(query);
                    if (error != null && status == 200) status = 400;
                }
                else if ("/lobby/open".equals(path))
                {
                    if (!hostPc) { status = 403; error = "only the host reopens the lobby"; }
                    else started = false;
                }
                else { status = 404; error = "not found"; }
                String body = error != null ? error + "\n" : describe();
                SaveShare.send(exchange, status, "text/plain; charset=utf-8", body.getBytes(StandardCharsets.UTF_8));
            }
        }
        finally
        {
            exchange.close();
        }
    }

    private void checkIn(String name)
    {
        if (name != null && PLAYER_NAME.matcher(name).matches() && !name.equals(saves.hostName()))
            seen.put(name, System.currentTimeMillis());
    }

    // null when started, otherwise why not
    private String start(Map<String, String> query) throws IOException
    {
        String wanted = query.get("mode");
        if ("save".equals(wanted))
        {
            String name = query.getOrDefault("save", "");
            if (name.isEmpty()) name = SaveShare.baseName(saves.newestSave());
            if (name.isEmpty()) return "the host has no save yet";
            if (!SAVE_NAME.matcher(name).matches() || !saves.hasSave(name)) return "no such save";
            save = name;
            options = 0;
        }
        else if ("new".equals(wanted))
        {
            try { options = Integer.parseInt(query.getOrDefault("options", "")); }
            catch (NumberFormatException e) { return "options must be a number"; }
            save = "";
        }
        else return "mode must be save or new";
        mode = wanted;
        started = true;
        seq++;
        startedAt = System.currentTimeMillis();
        return null;
    }

    private String describe() throws IOException
    {
        long now = System.currentTimeMillis();
        seen.values().removeIf(time -> now - time > LOBBY_SEEN_MS);
        StringBuilder text = new StringBuilder();
        text.append("host=").append(saves.hostName()).append('\n');
        text.append("state=").append(started ? "started" : "open").append('\n');
        text.append("seq=").append(seq).append('\n');
        text.append("mode=").append(mode).append('\n');
        text.append("save=").append(save).append('\n');
        text.append("options=").append(options).append('\n');
        text.append("age=").append(started ? (now - startedAt) / 1000 : 0).append('\n');
        text.append("newest=").append(SaveShare.baseName(saves.newestSave())).append('\n');
        text.append("players=").append(String.join(",", seen.keySet())).append('\n');
        return text.toString();
    }

    private static Map<String, String> query(String raw)
    {
        Map<String, String> values = new LinkedHashMap<>();
        if (raw == null || raw.isEmpty()) return values;
        for (String pair : raw.split("&"))
        {
            int at = pair.indexOf('=');
            if (at <= 0) continue;
            values.put(URLDecoder.decode(pair.substring(0, at), StandardCharsets.UTF_8), URLDecoder.decode(pair.substring(at + 1), StandardCharsets.UTF_8));
        }
        return values;
    }
}
