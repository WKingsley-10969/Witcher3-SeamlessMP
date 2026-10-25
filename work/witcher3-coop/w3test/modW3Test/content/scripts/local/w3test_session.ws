// session_join: the harness starts the second PC as a joining player of the host's co-op session
// (W3LAN_SESSION_ROLE join, W3LAN_SESSION_SAVE the run's save, W3LAN_SESSION_HOST BotA). Its game
// must load that save from the main menu and join the host's party by itself (this bot never asks
// to join). Then it walks 60 m off and must step in beside the host again; the host changes its
// difficulty and the second PC's game must follow.
function W3T_SessionJoin(bot : W3T_Bot, client : r_MultiplayerClient, other : r_RemotePlayer) : bool
{
    var session : r_CoopSession;
    var host : bool;
    var label : string;
    var now, apart : float;
    var spot, safe : Vector;
    var events : array<string>;
    var i, level : int;
    host = W3T_GetEnv("W3T_ROLE") == "mover";
    label = "SESSION member";
    if(host) { label = "SESSION host"; }
    session = client.getCoopSession();
    events = session.TakeEvents();
    for(i = 0; i < events.Size(); i += 1) { W3T_Log(label + " " + events[i]); }
    now = bot.ElapsedS();
    apart = VecDistance(thePlayer.GetWorldPosition(), other.pos);
    if(bot.scenarioStep < 0) { return false; }
    if(host)
    {
        if(bot.scenarioStep == 0 && session.Role() == "host" && client.getCoopEnemies().GetRole() == 1)
        {
            W3T_Log(label + " the second PC joined this party by itself");
            bot.scenarioTime = now;
            bot.scenarioStep = 1;
        }
        // once the second PC stands beside this player again (after walking off), change difficulty
        if(bot.scenarioStep == 1 && bot.scenarioFlag && apart < 4.0 && now - bot.scenarioTime >= 5)
        {
            level = (int)theGame.GetDifficultyLevel();
            if(level < 4) { level += 1; } else { level = 3; }
            W3T_Log(label + " changes difficulty " + (int)theGame.GetDifficultyLevel() + " -> " + level);
            theGame.SetDifficultyLevel(level);
            theGame.OnDifficultyChanged(level);
            bot.scenarioTime = now;
            bot.scenarioStep = 2;
        }
        if(apart > 30) { bot.scenarioFlag = true; }   // the second PC walked off
        if(bot.scenarioStep == 2 && now - bot.scenarioTime >= 8) { bot.scenarioStep = 3; }
    }
    else
    {
        // 0: loaded the host's save through the session and joined the host's party by itself
        if(bot.scenarioStep == 0 && session.loadsRequested == 1 && client.getInParty() && client.getJoinedParty() == session.HostName())
        {
            W3T_Log(label + " loaded " + session.HostName() + "'s save and joined their party (" + session.joinAttempts + " attempts), " + FloatToStringPrec(apart, 1) + " m away");
            bot.scenarioTime = now;
            bot.scenarioStep = 1;
        }
        // not left standing on the host's own spot after loading the same save
        if(bot.scenarioStep == 1 && session.placements == 0 && now - bot.scenarioTime >= 4)
        {
            W3T_Log(label + " FAIL still " + FloatToStringPrec(apart, 2) + " m from the host after loading");
            bot.scenarioStep = -1;
        }
        // 1: walk 60 m off, then the session must step in beside the host again
        if(bot.scenarioStep == 1 && now - bot.scenarioTime >= 5)
        {
            spot = thePlayer.GetWorldPosition() + VecFromHeading(thePlayer.GetHeading() + 180) * 60;
            if(!theGame.GetWorld().NavigationFindSafeSpot(spot, 0.5, 8.0, safe)) { safe = spot; }
            thePlayer.Teleport(safe);
            W3T_Log(label + " walks 60 m off to " + W3T_VecStr(safe));
            bot.scenarioTime = now;
            bot.scenarioStep = 2;
        }
        if(bot.scenarioStep == 2 && now - bot.scenarioTime >= 3)
        {
            session.Replace();
            bot.scenarioStep = 3;
        }
        if(bot.scenarioStep == 3 && session.placements >= 2 && apart < 4.0)
        {
            W3T_Log(label + " stepped in beside the host: " + FloatToStringPrec(apart, 1) + " m");
            bot.scenarioStep = 4;
        }
        if(bot.scenarioStep == 4 && session.difficultyChanges >= 1) { bot.scenarioStep = 5; }
    }
    W3T_Log(label + " step=" + bot.scenarioStep + " role=" + session.Role() + " hostName=" + session.HostName() + " apart=" + FloatToStringPrec(apart, 1)
        + " inParty=" + client.getInParty() + " party=" + client.getJoinedParty() + " loads=" + session.loadsRequested + " joins=" + session.joinAttempts
        + " placements=" + session.placements + " difficulty=" + (int)theGame.GetDifficultyLevel() + " changes=" + session.difficultyChanges);
    if(host) { return bot.scenarioStep == 3; }
    return bot.scenarioStep == 5;
}

// party_leave: the second PC joins the host's party through the session, then leaves it itself.
// The session must not join it again (before, it rejoined within 5 s); once the player joins
// themselves, the session's automatic joining is back.
function W3T_PartyLeave(bot : W3T_Bot, client : r_MultiplayerClient, other : r_RemotePlayer) : bool
{
    var session : r_CoopSession;
    var label : string;
    var now : float;
    var events : array<string>;
    var i : int;
    session = client.getCoopSession();
    label = "LEAVE member";
    if(W3T_GetEnv("W3T_ROLE") == "mover") { return client.getCoopEnemies().GetRole() == 1 && bot.ElapsedS() > 60; }
    events = session.TakeEvents();
    for(i = 0; i < events.Size(); i += 1) { W3T_Log(label + " " + events[i]); }
    now = bot.ElapsedS();
    if(bot.scenarioStep == 0 && client.getInParty() && client.getJoinedParty() == session.HostName())
    {
        W3T_Log(label + " in " + session.HostName() + "'s party; leaving it");
        client.leaveParty();
        bot.scenarioCount = session.joinAttempts;
        bot.scenarioTime = now;
        bot.scenarioStep = 1;
    }
    if(bot.scenarioStep == 1)
    {
        if(client.getInParty() || session.joinAttempts != bot.scenarioCount)
        {
            W3T_Log(label + " FAIL joined again " + FloatToStringPrec(now - bot.scenarioTime, 1) + " s after leaving (" + session.joinAttempts + " join attempts)");
            bot.scenarioStep = -1;
        }
        else if(now - bot.scenarioTime >= 15)
        {
            W3T_Log(label + " stayed out of the party for 15 s; joining it myself");
            client.joinParty(session.HostName());
            bot.scenarioTime = now;
            bot.scenarioStep = 2;
        }
    }
    if(bot.scenarioStep == 2 && client.getInParty() && !session.HasLeftParty() && now - bot.scenarioTime >= 2)
    {
        W3T_Log(label + " back in " + client.getJoinedParty() + "'s party; automatic joining is on again");
        bot.scenarioStep = 3;
    }
    W3T_Log(label + " step=" + bot.scenarioStep + " inParty=" + client.getInParty() + " left=" + session.HasLeftParty() + " leaves=" + session.partyLeaves + " joins=" + session.joinAttempts);
    return bot.scenarioStep == 3;
}
