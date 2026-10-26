// boss_fight: a quest fight from the owner's save (copied into the run's sandbox), played by both bots and logged on
// both PCs, so boss_report.py can list what the second PC got wrong. Measures, does not pass/fail on it.
//   W3T_BOSS_AT     x,y,z where the fight is (an objective pin of the save's quest, from scene_probe)
//   W3T_BOSS_QUEST  part of the quest's title: its open objectives are logged on both PCs as they change
//   W3T_BOSS_NEAR   or the voice tag of a character to go to and talk to (VESEMIR) when the objective has no pin
//   W3T_BOSS_TIME   seconds the fight is watched once there (200 unless set)
// Both players are invulnerable. The leader goes to W3T_BOSS_AT, the second PC follows it. From 25 s on, every 3 s
// the leader hurts the nearest hostile by 6 % of its health (closing in on it) and the second PC hurts the nearest
// copy the same way, through its own hits (they reach the leader). Each logs every 2 s:
//   BOSS <side> enemies <n> | <name> <hp %> <immortality mode> <gameplay visibility> <stance> [fly] [x] ; ...
//       leader: its real hostiles (x: not shared with the second PC); copy: the second PC's copies (dead: dead)
//   BOSS copy own <n> | <name> ; ...      hostiles of the second PC's own game that show there (not copies)
//   BOSS <side> objectives | <text> ; ...  on change: the quest's open objectives
//   BOSS <side> scene <path or none>       on change
//   BOSS <side> counters ...               the co-op hit and hurt counters
// In a scene the leader takes the first choice once the choices have been up 2 s (the second PC only suggests).

function W3T_BossTime() : float
{
    var t : int;
    t = StringToInt(W3T_GetEnv("W3T_BOSS_TIME"), 200);
    if(t <= 0) { t = 200; }
    return (float)t;
}

function W3T_BossPos() : Vector
{
    var parts : array<string>;
    parts = W3T_Split(W3T_GetEnv("W3T_BOSS_AT"), ",");
    if(parts.Size() < 3) { return Vector(0, 0, 0); }
    return Vector(StringToFloat(parts[0], 0), StringToFloat(parts[1], 0), StringToFloat(parts[2], 0));
}

// <name> <hp %> <immortality mode> <gameplay visibility> <stance> [fly]
function W3T_BossEnemy(npc : CNewNPC) : string
{
    var s : string;
    s = W3T_SurveyEntityName(npc) + " " + (int)(npc.GetHealthPercents() * 100) + " " + (int)npc.GetImmortalityMode() + " "
        + npc.GetGameplayVisibility() + " " + (int)npc.GetCurrentStance();
    if(npc.IsFlying()) { s = s + " fly"; }
    return s;
}

// The leader's real hostiles near it (players' ghosts left out).
function W3T_BossHostiles() : array<CNewNPC>
{
    var actors : array<CActor>;
    var list : array<CNewNPC>;
    var npc : CNewNPC;
    var i : int;
    actors = thePlayer.GetNPCsAndPlayersInRange(50, 64, '', FLAG_Attitude_Hostile + FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
    for(i = 0; i < actors.Size(); i += 1)
    {
        npc = (CNewNPC)actors[i];
        if(npc && !npc.HasTag('MPEntity') && !npc.IsHorse()) { list.PushBack(npc); }
    }
    return list;
}

// The character of W3T_BOSS_NEAR (a voice tag) within 300 m nearest to "around" (there may be two: White Orchard's
// Vesemir at the inn and the quest's one at the field of W3T_BOSS_AT), or NULL.
function W3T_BossCharacter(around : Vector) : CNewNPC
{
    var actors : array<CActor>;
    var npc, found : CNewNPC;
    var i : int;
    actors = thePlayer.GetNPCsAndPlayersInRange(300, 500, '', FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
    for(i = 0; i < actors.Size(); i += 1)
    {
        npc = (CNewNPC)actors[i];
        if(npc && !npc.HasTag('MPEntity') && !npc.HasTag('w3coop_npc_copy') && NpcVoice(npc) == W3T_GetEnv("W3T_BOSS_NEAR")
            && (!found || VecDistance(npc.GetWorldPosition(), around) < VecDistance(found.GetWorldPosition(), around)))
        {
            found = npc;
        }
    }
    return found;
}

function W3T_BossNearest(list : array<CNewNPC>) : CNewNPC
{
    var best : CNewNPC;
    var d, bestD : float;
    var i : int;
    bestD = 1000;
    for(i = 0; i < list.Size(); i += 1)
    {
        if(!list[i] || !list[i].IsAlive()) { continue; }
        d = VecDistance(thePlayer.GetWorldPosition(), list[i].GetWorldPosition());
        if(d < bestD) { best = list[i]; bestD = d; }
    }
    return best;
}

// Hurts npc by 6 % of its health as this player would; within 50 m, first steps up to 2.5 m from it.
function W3T_BossHit(npc : CNewNPC)
{
    var action : W3DamageAction;
    var spot : Vector;
    var rot : EulerAngles;
    if(!npc) { return; }
    if(VecDistance(thePlayer.GetWorldPosition(), npc.GetWorldPosition()) > 6)
    {
        spot = npc.GetWorldPosition() + VecNormalize(thePlayer.GetWorldPosition() - npc.GetWorldPosition()) * 2.5;
        rot.Yaw = VecHeading(npc.GetWorldPosition() - spot);
        thePlayer.TeleportWithRotation(spot, rot);
    }
    W3T_LookAt(npc.GetWorldPosition());
    thePlayer.GoToCombatIfNeeded(npc);
    action = new W3DamageAction in theGame.damageMgr;
    action.Initialize(thePlayer, npc, thePlayer, "W3TestHit", EHRT_Light, CPS_AttackPower, false, false, true, false);
    action.AddDamage(theGame.params.DAMAGE_NAME_DIRECT, 0.06 * npc.GetMaxHealth());
    theGame.damageMgr.ProcessAction(action);
    delete action;
}

// The quest's open objectives and the scene, logged when they change.
function W3T_BossQuestAndScene(bot : W3T_Bot, client : r_MultiplayerClient, side : string)
{
    var manager : CWitcherJournalManager;
    var quests : array<CJournalBase>;
    var jq : CJournalQuest;
    var phase : CJournalQuestPhase;
    var objective : CJournalQuestObjective;
    var filter, text, scene : string;
    var i, j, k : int;
    filter = W3T_GetEnv("W3T_BOSS_QUEST");
    manager = theGame.GetJournalManager();
    manager.GetActivatedOfType('CJournalQuest', quests);
    for(i = 0; i < quests.Size(); i += 1)
    {
        jq = (CJournalQuest)quests[i];
        if(!jq || manager.GetEntryStatus(jq) != JS_Active) { continue; }
        if(filter != "" && StrFindFirst(GetLocStringById(jq.GetTitleStringId()), filter) < 0) { continue; }
        for(j = 0; j < jq.GetNumChildren(); j += 1)
        {
            phase = (CJournalQuestPhase)jq.GetChild(j);
            if(!phase) { continue; }
            for(k = 0; k < phase.GetNumChildren(); k += 1)
            {
                objective = (CJournalQuestObjective)phase.GetChild(k);
                if(objective && manager.GetEntryStatus(objective) == JS_Active)
                {
                    text = text + GetLocStringById(objective.GetTitleStringId()) + " ; ";
                }
            }
        }
    }
    if(text != bot.scenarioText)
    {
        bot.scenarioText = text;
        W3T_Log("BOSS " + side + " objectives | " + text);
    }
    scene = "none";
    if(client.getCoopTalk().InScene()) { scene = client.getCoopTalk().GetScenePath(); }
    if(scene != bot.bossScene)
    {
        bot.bossScene = scene;
        W3T_Log("BOSS " + side + " scene " + scene);
    }
}

function W3T_BossCounters(side : string, coop : r_CoopEnemies)
{
    W3T_Log("BOSS " + side + " counters hitsSent=" + coop.hitsSent + " hitsApplied=" + coop.hitsApplied + " hurtsCaptured=" + coop.hurtsCaptured
        + " hurtsApplied=" + coop.hurtsApplied + " shared=" + coop.HostEnemyCount() + " copies=" + coop.PuppetCount() + " suppressed="
        + coop.SuppressedCount() + " pos=" + W3T_VecStr(thePlayer.GetWorldPosition()));
}

function W3T_BossLeader(bot : W3T_Bot, client : r_MultiplayerClient) : bool
{
    var coop : r_CoopEnemies;
    var hostiles : array<CNewNPC>;
    var character : CNewNPC;
    var line : string;
    var spot, at : Vector;
    var rot : EulerAngles;
    var i : int;
    var now : float;
    coop = client.getCoopEnemies();
    now = bot.ElapsedS();
    if(bot.scenarioStep == 0)
    {
        if(coop.GetRole() != 1) { return false; }
        thePlayer.SetImmortalityMode(AIM_Invulnerable, AIC_Cheat, true);
        at = W3T_BossPos();
        // with W3T_BOSS_AT the character is looked for there, once it is loaded (below)
        if(at.X == 0 && at.Y == 0) { character = W3T_BossCharacter(thePlayer.GetWorldPosition()); }
        if(character)
        {
            at = character.GetWorldPosition() + VecFromHeading(character.GetHeading()) * 2.0;
            bot.scenarioEntity = character;
        }
        else if(W3T_GetEnv("W3T_BOSS_NEAR") != "")
        {
            W3T_Log("BOSS leader finds no " + W3T_GetEnv("W3T_BOSS_NEAR") + " within 300 m");
        }
        if(at.X != 0 || at.Y != 0)
        {
            spot = at;
            theGame.GetWorld().NavigationFindSafeSpot(at, 0.5, 6.0, spot);
            rot.Yaw = thePlayer.GetHeading();
            thePlayer.TeleportWithRotation(spot, rot);
        }
        W3T_Log("BOSS leader goes to " + W3T_VecStr(spot) + " for '" + W3T_GetEnv("W3T_BOSS_QUEST") + "'");
        bot.scenarioStep = 1;
        bot.scenarioTime = now;
        bot.scenarioActAt = now;
        bot.scenarioSeenAt = 0;
        return false;
    }
    W3T_BossQuestAndScene(bot, client, "leader");
    // at W3T_BOSS_AT, 5 s after arriving (the field's Vesemir is only loaded near it): its W3T_BOSS_NEAR character
    if(!bot.scenarioEntity && W3T_GetEnv("W3T_BOSS_NEAR") != "" && now - bot.scenarioTime > 5 && bot.scenarioCount == 0)
    {
        character = W3T_BossCharacter(thePlayer.GetWorldPosition());
        if(character)
        {
            bot.scenarioEntity = character;
            spot = character.GetWorldPosition() + VecFromHeading(character.GetHeading()) * 2.0;
            theGame.GetWorld().NavigationFindSafeSpot(spot, 0.5, 4.0, spot);
            rot.Yaw = VecHeading(character.GetWorldPosition() - spot);
            thePlayer.TeleportWithRotation(spot, rot);
            W3T_Log("BOSS leader goes to " + W3T_GetEnv("W3T_BOSS_NEAR") + " at " + W3T_VecStr(character.GetWorldPosition()));
            bot.scenarioTime = now - 3;
        }
    }
    hostiles = W3T_BossHostiles();
    // the character starts the quest's scene when talked to: again 10 s after each scene while no enemy has come
    // (White Orchard's trap takes two talks to Vesemir), at most three times
    character = (CNewNPC)bot.scenarioEntity;
    if(client.getCoopTalk().InScene()) { bot.bossTalkAt = now; }
    if(character && bot.scenarioCount < 3 && hostiles.Size() == 0 && !client.getCoopTalk().InScene() && now - bot.scenarioTime > 3
        && now - bot.bossTalkAt > 10)
    {
        W3T_Log("BOSS leader talks to " + W3T_GetEnv("W3T_BOSS_NEAR") + " (try " + (bot.scenarioCount + 1) + ")");
        W3T_LookAt(character.GetWorldPosition());
        character.OnInteraction("Talk", thePlayer);
        bot.scenarioCount += 1;
        bot.bossTalkAt = now;
    }
    if(client.hasActiveDialogChoices() && client.getCoopTalk().ChoicesAge() > 2)
    {
        W3T_Log("BOSS leader takes choice 0 of " + client.getCoopTalk().LastChoiceCount());
        W3T_DialogModule().OnDialogOptionSelected(0);
        W3T_DialogModule().OnDialogOptionAccepted(0);
    }
    // the fight's first seconds are left to the quest (its scene, its enemies coming) and the second PC joining
    if(now - bot.scenarioTime > 25 && now - bot.scenarioActAt >= 3 && !client.getCoopTalk().InScene())
    {
        W3T_BossHit(W3T_BossNearest(hostiles));
        bot.scenarioActAt = now;
    }
    if(now - bot.scenarioSeenAt >= 2)
    {
        bot.scenarioSeenAt = now;
        line = "BOSS leader enemies " + hostiles.Size() + " |";
        for(i = 0; i < hostiles.Size(); i += 1)
        {
            line = line + " " + W3T_BossEnemy(hostiles[i]);
            if(coop.HostNetIdOf(hostiles[i]) == 0) { line = line + " x"; }
            line = line + " ;";
        }
        W3T_Log(line);
        W3T_BossCounters("leader", coop);
    }
    return now - bot.scenarioTime > W3T_BossTime();
}

function W3T_BossMember(bot : W3T_Bot, client : r_MultiplayerClient, leader : r_RemotePlayer) : bool
{
    var coop : r_CoopEnemies;
    var actors : array<CActor>;
    var copies : array<CNewNPC>;
    var npc : CNewNPC;
    var line, own : string;
    var spot : Vector;
    var rot : EulerAngles;
    var i, owned : int;
    var now : float;
    coop = client.getCoopEnemies();
    now = bot.ElapsedS();
    if(!client.getInParty())
    {
        thePlayer.SetImmortalityMode(AIM_Invulnerable, AIC_Cheat, true);
        client.joinParty(leader.username);
        return false;
    }
    W3T_BossQuestAndScene(bot, client, "copy");
    // stays with the leader (it hurts the copies from close by, as the leader does), by the position the leader sends:
    // its ghost only exists nearby, and far ground has no navigation data loaded yet (then straight to it)
    if(leader.pos.X == 0 && leader.pos.Y == 0) { return false; }
    if(VecDistance(thePlayer.GetWorldPosition(), leader.pos) > 20)
    {
        spot = leader.pos - VecFromHeading(leader.heading) * 3.0;
        theGame.GetWorld().NavigationFindSafeSpot(spot, 0.5, 4.0, spot);
        rot.Yaw = leader.heading;
        thePlayer.TeleportWithRotation(spot, rot);
        return false;
    }
    if(bot.scenarioStep == 0)
    {
        W3T_Log("BOSS copy is with the leader at " + W3T_VecStr(thePlayer.GetWorldPosition()));
        bot.scenarioStep = 1;
        bot.scenarioTime = now;
        bot.scenarioActAt = now;
        bot.scenarioSeenAt = 0;
    }
    for(i = 0; i < coop.PuppetCount(); i += 1)
    {
        if(coop.PuppetAt(i)) { copies.PushBack(coop.PuppetAt(i)); }
    }
    if(now - bot.scenarioTime > 10 && now - bot.scenarioActAt >= 3 && !client.getCoopTalk().InScene())
    {
        W3T_BossHit(W3T_BossNearest(copies));
        bot.scenarioActAt = now;
    }
    if(now - bot.scenarioSeenAt >= 2)
    {
        bot.scenarioSeenAt = now;
        line = "BOSS copy enemies " + copies.Size() + " |";
        for(i = 0; i < copies.Size(); i += 1)
        {
            line = line + " " + W3T_BossEnemy(copies[i]);
            if(!copies[i].IsAlive()) { line = line + " dead"; }
            line = line + " ;";
        }
        W3T_Log(line);
        // what this PC's own game shows of its quest's enemies: hostiles that are neither copies nor hidden here
        actors = thePlayer.GetNPCsAndPlayersInRange(50, 64, '', FLAG_Attitude_Hostile + FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
        for(i = 0; i < actors.Size(); i += 1)
        {
            npc = (CNewNPC)actors[i];
            if(!npc || npc.HasTag('MPEntity') || npc.IsHorse() || coop.IsPuppet(npc) || !npc.GetGameplayVisibility()) { continue; }
            own = own + " " + W3T_SurveyEntityName(npc) + " ;";
            owned += 1;
        }
        W3T_Log("BOSS copy own " + owned + " |" + own);
        W3T_BossCounters("copy", coop);
    }
    return bot.scenarioStep == 1 && now - bot.scenarioTime > W3T_BossTime();
}
