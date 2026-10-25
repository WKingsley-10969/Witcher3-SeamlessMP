// lobby_save: both games wait in the main menu's co-op lobby; the second PC starts without the
// save. Once it waits in the lobby, the host starts with its newest save: the host loads it, and the
// second PC downloads it from the host and loads it, then joins the host's party beside it.
// lobby_new: the same, but the host starts a new game and the second PC starts the same new game.
function W3T_Lobby(bot : W3T_Bot, client : r_MultiplayerClient, other : r_RemotePlayer, newGame : bool) : bool
{
    var lobby : r_CoopLobby;
    var session : r_CoopSession;
    var host : bool;
    var label : string;
    var apart : float;
    var events : array<string>;
    var i : int;
    host = W3T_GetEnv("W3T_ROLE") == "mover";
    label = "LOBBY member";
    if(host) { label = "LOBBY host"; }
    lobby = client.getCoopLobby();
    session = client.getCoopSession();
    events = lobby.TakeEvents();
    for(i = 0; i < events.Size(); i += 1) { W3T_Log(label + " " + events[i]); }
    events = session.TakeEvents();
    for(i = 0; i < events.Size(); i += 1) { W3T_Log(label + " session " + events[i]); }
    apart = -1;
    if(other) { apart = VecDistance(thePlayer.GetWorldPosition(), other.pos); }
    W3T_Log(label + " polls=" + lobby.polls + " answers=" + lobby.answers + " state=" + lobby.lobbyState + " seq=" + lobby.seq + " mode=" + lobby.mode
        + " save=" + lobby.save + " starts=" + lobby.starts + " fetches=" + lobby.fetches + " loads=" + lobby.loads + " newGames=" + lobby.newGames
        + " inParty=" + client.getInParty() + " role=" + client.getCoopEnemies().GetRole() + " placements=" + session.placements + " apart=" + FloatToStringPrec(apart, 1));
    if(newGame)
    {
        if(host) { return lobby.starts == 1 && lobby.mode == "new"; }
        return lobby.newGames == 1;
    }
    if(host) { return lobby.starts == 1 && client.getCoopEnemies().GetRole() == 1 && apart >= 0 && apart < 4.0; }
    return lobby.fetches == 1 && lobby.loads == 1 && client.getInParty() && session.placements >= 1 && apart >= 0 && apart < 4.0;
}
