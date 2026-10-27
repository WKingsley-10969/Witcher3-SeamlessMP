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
    // W3T_LOBBY_REFUSE=1: the second PC's game refuses the host's save (the LoadSave wrapper below); the
    // second PC stays in the main menu, where this does not run: run_test.py counts its refusals
    if(W3T_GetEnv("W3T_LOBBY_REFUSE") == "1") { return host && lobby.starts == 1 && lobby.loads == 1; }
    if(host) { return lobby.starts == 1 && client.getCoopEnemies().GetRole() == 1 && apart >= 0 && apart < 4.0; }
    return lobby.fetches == 1 && lobby.loads == 1 && client.getInParty() && session.placements >= 1 && apart >= 0 && apart < 4.0;
}

// W3T_LOBBY_REFUSE=1: the second PC's game answers a load of the host's save as it does when this PC
// lacks a DLC the save needs (the owner's playtest: Custom Player Characters on the host only), and
// the main menu opens again, as after that refusal. Both test PCs share one game folder, so the
// missing DLC itself cannot be set up.
@wrapMethod(r_CoopSession)
function LoadSave(wanted : string) : bool
{
    var missing : array<name>;
    if(W3T_GetEnv("W3T_LOBBY_REFUSE") != "1" || W3T_GetEnv("W3T_ROLE") == "mover") { return wrappedMethod(wanted); }
    W3T_Log("LOBBY member test: the game refuses " + wanted + " (missing dlc_newreplacers)");
    missing.PushBack('dlc_newreplacers');
    theGame.GetGuiManager().OnLoadingFailed(RESTORE_DLCRequired, missing);
    theGame.r_getMultiplayerClient().getCoopLobby().OnMainMenu();
    return true;
}

// lobby_rejoin: the second PC joins through the lobby (as lobby_save), then goes back to the main
// menu ("Quit to main menu") and must come back by itself: the lobby downloads and loads the host's
// save again, and the session joins the party and steps in beside the host, without restarting.
function W3T_LobbyRejoin(bot : W3T_Bot, client : r_MultiplayerClient, other : r_RemotePlayer) : bool
{
    var lobby : r_CoopLobby;
    var session : r_CoopSession;
    var joined : bool;
    var apart : float;
    lobby = client.getCoopLobby();
    session = client.getCoopSession();
    joined = W3T_Lobby(bot, client, other, false);
    if(W3T_GetEnv("W3T_ROLE") == "mover") { return joined; }
    if(lobby.testMenuReturns == 0)
    {
        if(!joined) { return false; }
        lobby.testMenuReturns = 1;
        W3T_Log("LOBBY member joined; going back to the main menu (placements=" + session.placements + ")");
        theGame.RequestEndGame();
        return false;
    }
    apart = VecDistance(thePlayer.GetWorldPosition(), other.pos);
    return lobby.loads >= 2 && lobby.fetches >= 2 && client.getInParty() && session.placements >= 2 && session.InHostWorld() && apart < 4.0;
}

