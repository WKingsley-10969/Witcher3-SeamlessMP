// party_revive: both stand together in a party. The host takes a lethal blow and must be knocked
// down instead of dying; the second PC walks up and holds Interact until the host is revived.
// Then the second PC walks 40 m off and the host takes another lethal blow: nobody comes, so after
// the wait the host must get up beside the second PC.
function W3T_PartyRevive(bot : W3T_Bot, client : r_MultiplayerClient, other : r_RemotePlayer) : bool
{
    var revive : r_CoopRevive;
    var host : bool;
    var label : string;
    var now, apart : float;
    var spot, safe : Vector;
    var events : array<string>;
    var i : int;
    host = W3T_GetEnv("W3T_ROLE") == "mover";
    label = "REVIVE member";
    if(host) { label = "REVIVE host"; }
    if(!host && !client.getInParty())
    {
        W3T_Log("PARTY join " + other.username);
        client.joinParty(other.username);
        return false;
    }
    if(host && client.getCoopEnemies().GetRole() != 1) { return false; }
    revive = client.getCoopRevive();
    events = revive.TakeEvents();
    for(i = 0; i < events.Size(); i += 1) { W3T_Log(label + " " + events[i]); }
    now = bot.ElapsedS();
    apart = VecDistance(thePlayer.GetWorldPosition(), other.pos);
    if(bot.scenarioStep < 0) { return false; }
    if(bot.scenarioStep == 0)
    {
        W3T_TeleportNear(W3T_TalkBoard(0));
        bot.scenarioTime = now;
        bot.scenarioStep = 1;
        return false;
    }
    if(host)
    {
        // 1: knocked down beside the second PC, which revives
        if(bot.scenarioStep == 1 && now - bot.scenarioTime >= 12 && apart < 20 && other.isAlive)
        {
            W3T_Log(label + " takes a lethal blow (health " + FloatToStringPrec(thePlayer.GetStat(BCS_Vitality), 0) + ", why not down: '" + revive.WhyNotDown() + "')");
            W3T_LethalHit();
            events = revive.TakeEvents();
            for(i = 0; i < events.Size(); i += 1) { W3T_Log(label + " " + events[i]); }
            if(!thePlayer.IsAlive() || revive.downs != 1) { W3T_Log(label + " FAIL not knocked down: alive=" + thePlayer.IsAlive() + " downs=" + revive.downs); bot.scenarioStep = -1; return false; }
            bot.scenarioTime = now;
            bot.scenarioStep = 2;
        }
        if(bot.scenarioStep == 2 && revive.revivesReceived == 1 && !revive.IsDowned())
        {
            W3T_Log(label + " revived and standing: health " + FloatToStringPrec(thePlayer.GetHealthPercents() * 100, 0) + "% state=" + thePlayer.GetCurrentStateName());
            bot.scenarioTime = now;
            bot.scenarioStep = 3;
        }
        // 3: knocked down again with the second PC 40 m off: nobody revives
        if(bot.scenarioStep == 3 && now - bot.scenarioTime >= 5 && apart > 25 && other.isAlive)
        {
            W3T_Log(label + " takes another lethal blow, " + FloatToStringPrec(apart, 1) + " m from the second PC");
            W3T_LethalHit();
            if(!thePlayer.IsAlive() || revive.downs != 2) { W3T_Log(label + " FAIL not knocked down again"); bot.scenarioStep = -1; return false; }
            bot.scenarioTime = now;
            bot.scenarioStep = 4;
        }
        if(bot.scenarioStep == 4 && revive.respawns == 1 && !revive.IsDowned())
        {
            W3T_Log(label + " got up after " + FloatToStringPrec(now - bot.scenarioTime, 1) + " s, " + FloatToStringPrec(apart, 1) + " m from the second PC, health "
                + FloatToStringPrec(thePlayer.GetHealthPercents() * 100, 0) + "%");
            bot.scenarioStep = 5;
        }
    }
    else
    {
        // 1: the host goes down: walk up to it and hold Interact
        if(bot.scenarioStep == 1 && revive.peerDowns == 1)
        {
            spot = other.pos + VecFromHeading(thePlayer.GetHeading()) * 1.0;
            if(!theGame.GetWorld().NavigationFindSafeSpot(spot, 0.5, 2.0, safe)) { safe = spot; }
            thePlayer.Teleport(safe);
            revive.testHold = true;
            W3T_Log(label + " beside the downed host (" + FloatToStringPrec(VecDistance(safe, other.pos), 1) + " m), holding Interact");
            bot.scenarioStep = 2;
        }
        if(bot.scenarioStep == 2 && revive.revivesGiven == 1)
        {
            revive.testHold = false;
            bot.scenarioTime = now;
            bot.scenarioStep = 3;
        }
        // 3: once the host stands, walk 40 m off
        if(bot.scenarioStep == 3 && other.isAlive && now - bot.scenarioTime >= 4)
        {
            spot = thePlayer.GetWorldPosition() + VecFromHeading(thePlayer.GetHeading() + 180) * 40;
            if(!theGame.GetWorld().NavigationFindSafeSpot(spot, 0.5, 8.0, safe)) { safe = spot; }
            thePlayer.Teleport(safe);
            W3T_Log(label + " walks 40 m off to " + W3T_VecStr(safe));
            bot.scenarioStep = 4;
        }
        if(bot.scenarioStep == 4 && revive.peerDowns == 2) { bot.scenarioStep = 5; }
        if(bot.scenarioStep == 5 && other.isAlive && apart >= 1.0 && apart < 8)
        {
            W3T_Log(label + " the host got up beside this player, " + FloatToStringPrec(apart, 1) + " m away");
            bot.scenarioStep = 6;
        }
    }
    W3T_Log(label + " step=" + bot.scenarioStep + " apart=" + FloatToStringPrec(apart, 1) + " alive=" + thePlayer.IsAlive() + " otherAlive=" + other.isAlive
        + " downed=" + revive.IsDowned() + " state=" + thePlayer.GetCurrentStateName() + " health=" + FloatToStringPrec(thePlayer.GetStat(BCS_Vitality), 0)
        + " downs=" + revive.downs + " peerDowns=" + revive.peerDowns + " given=" + revive.revivesGiven + " received=" + revive.revivesReceived
        + " respawns=" + revive.respawns + " realDeaths=" + revive.realDeaths + " kneeling=" + revive.IsKneeling() + " examining=" + (thePlayer.GetPlayerAction() == PEA_ExamineGround));
    if(!host && revive.IsKneeling()) { bot.scenarioVec.W = 1; }   // the reviver knelt at some point
    if(host) { return bot.scenarioStep == 5 && apart >= 1.0 && apart < 8 && revive.realDeaths == 0 && thePlayer.IsAlive(); }
    return bot.scenarioStep == 6 && revive.revivesGiven == 1 && revive.realDeaths == 0 && bot.scenarioVec.W == 1;
}

// A blow worth twice this player's full health, through the game's damage pipeline.
function W3T_LethalHit()
{
    var action : W3DamageAction;
    action = new W3DamageAction in theGame.damageMgr;
    action.Initialize(NULL, thePlayer, theGame, 'w3test_lethal', EHRT_None, CPS_Undefined, false, false, false, true);
    action.AddDamage(theGame.params.DAMAGE_NAME_DIRECT, thePlayer.GetStatMax(BCS_Vitality) * 2);
    theGame.damageMgr.ProcessAction(action);
    delete action;
}
