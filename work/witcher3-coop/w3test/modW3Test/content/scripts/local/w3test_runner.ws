// quest_run: plays a quest of the save on, objective by objective, and saves the game at each new objective, so a
// boss fight's quest can be started from a save made just before it (boss_fight with W3T_SAVES_DIR). The leader
// plays alone (no party); the second PC idles.
//   W3T_RUN_QUEST  part of the quest's title: tracked, and played
//   W3T_RUN_BOSS   part of the boss's template name: the run ends when it shows (other hostiles are killed)
//   W3T_RUN_TIME   seconds the run may take (600 unless set)
// Every 3 s, when not in a scene: the first open objective of the quest that has a map pin is gone to (teleport);
// there the leader talks to a character offering talk within 8 m and examines the monster clues within 15 m
// (each once a minute). In a scene it takes the first choice once the choices have been up 2 s. Hostiles that are
// not the boss are killed. Logs:
//   RUN objectives | <text> ; ...      on change, then a save (ManualSave) once out of scenes and fights
//   RUN saved <n> for '<objectives>'    each save: the newest save of the run's sandbox is the one before the boss
//   RUN goes to <x,y,z> / talks to <voice> / examines <clue> / kills <name>
//   RUN boss <name> shows               the end
function W3T_RunTime() : float
{
    var t : int;
    t = StringToInt(W3T_GetEnv("W3T_RUN_TIME"), 600);
    if(t <= 0) { t = 600; }
    return (float)t;
}

// The quest of W3T_RUN_QUEST among the active ones, tracked.
function W3T_RunQuest() : CJournalQuest
{
    var manager : CWitcherJournalManager;
    var quests : array<CJournalBase>;
    var jq : CJournalQuest;
    var i : int;
    manager = theGame.GetJournalManager();
    jq = manager.GetTrackedQuest();
    if(jq && StrFindFirst(GetLocStringById(jq.GetTitleStringId()), W3T_GetEnv("W3T_RUN_QUEST")) >= 0) { return jq; }
    manager.GetActivatedOfType('CJournalQuest', quests);
    for(i = 0; i < quests.Size(); i += 1)
    {
        jq = (CJournalQuest)quests[i];
        if(jq && manager.GetEntryStatus(jq) == JS_Active && StrFindFirst(GetLocStringById(jq.GetTitleStringId()), W3T_GetEnv("W3T_RUN_QUEST")) >= 0)
        {
            manager.SetTrackedQuest(jq);
            return jq;
        }
    }
    return NULL;
}

function W3T_RunObjectives(jq : CJournalQuest) : array<CJournalQuestObjective>
{
    var manager : CWitcherJournalManager;
    var phase : CJournalQuestPhase;
    var objective : CJournalQuestObjective;
    var list : array<CJournalQuestObjective>;
    var j, k : int;
    manager = theGame.GetJournalManager();
    for(j = 0; jq && j < jq.GetNumChildren(); j += 1)
    {
        phase = (CJournalQuestPhase)jq.GetChild(j);
        if(!phase) { continue; }
        for(k = 0; k < phase.GetNumChildren(); k += 1)
        {
            objective = (CJournalQuestObjective)phase.GetChild(k);
            if(objective && manager.GetEntryStatus(objective) == JS_Active) { list.PushBack(objective); }
        }
    }
    return list;
}

// Where an objective's map pin is in this world, or false.
function W3T_RunPinAt(objective : CJournalQuestObjective, out at : Vector) : bool
{
    var pin : CJournalQuestMapPin;
    var pins : array<SCommonMapPinInstance>;
    var i, j : int;
    pins = theGame.GetCommonMapManager().GetMapPinInstances(theGame.GetWorld().GetDepotPath());
    for(i = 0; i < objective.GetNumChildren(); i += 1)
    {
        pin = (CJournalQuestMapPin)objective.GetChild(i);
        if(!pin) { continue; }
        for(j = 0; j < pins.Size(); j += 1)
        {
            if(pins[j].tag == pin.GetMapPinID())
            {
                at = pins[j].position;
                return true;
            }
        }
    }
    return false;
}

// Whether the leader did something to this entity in the last minute (and notes it now if not).
function W3T_RunRecently(bot : W3T_Bot, entity : CEntity, now : float) : bool
{
    var i : int;
    i = bot.scenarioEntities.FindFirst(entity);
    if(i >= 0 && now - bot.runTimes[i] < 60) { return true; }
    if(i < 0)
    {
        bot.scenarioEntities.PushBack(entity);
        bot.runTimes.PushBack(now);
    }
    else
    {
        bot.runTimes[i] = now;
    }
    return false;
}

function W3T_RunLeader(bot : W3T_Bot, client : r_MultiplayerClient) : bool
{
    var jq : CJournalQuest;
    var objectives : array<CJournalQuestObjective>;
    var actors : array<CActor>;
    var entities : array<CGameplayEntity>;
    var npc : CNewNPC;
    var clue : W3MonsterClue;
    var talk : r_CoopTalk;
    var text : string;
    var at, spot : Vector;
    var rot : EulerAngles;
    var i : int;
    var now : float;
    now = bot.ElapsedS();
    talk = client.getCoopTalk();
    if(now < 20) { return false; }
    if(bot.scenarioStep == 0)
    {
        thePlayer.SetImmortalityMode(AIM_Invulnerable, AIC_Cheat, true);
        bot.scenarioStep = 1;
        bot.scenarioTime = now;
    }
    if(bot.scenarioStep == 2) { return now - bot.scenarioTime > 10; }
    if(now - bot.scenarioTime > W3T_RunTime())
    {
        W3T_Log("RUN out of time");
        return true;
    }
    if(talk.InScene())
    {
        if(client.hasActiveDialogChoices() && talk.ChoicesAge() > 2)
        {
            W3T_Log("RUN takes choice 0 of " + talk.LastChoiceCount());
            W3T_DialogModule().OnDialogOptionSelected(0);
            W3T_DialogModule().OnDialogOptionAccepted(0);
        }
        return false;
    }
    jq = W3T_RunQuest();
    if(!jq)
    {
        W3T_Log("RUN no active quest '" + W3T_GetEnv("W3T_RUN_QUEST") + "' (done or not started)");
        bot.scenarioStep = 2;
        bot.scenarioTime = now;
        return false;
    }
    objectives = W3T_RunObjectives(jq);
    for(i = 0; i < objectives.Size(); i += 1) { text += GetLocStringById(objectives[i].GetTitleStringId()) + " ; "; }
    if(text != bot.scenarioText)
    {
        bot.scenarioText = text;
        bot.scenarioFlag = false;
        W3T_Log("RUN objectives | " + text);
    }
    // the hostiles around: the boss ends the run, anything else is in the way
    actors = thePlayer.GetNPCsAndPlayersInRange(30, 32, '', FLAG_Attitude_Hostile + FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
    for(i = 0; i < actors.Size(); i += 1)
    {
        npc = (CNewNPC)actors[i];
        if(!npc || npc.HasTag('MPEntity')) { continue; }
        if(W3T_GetEnv("W3T_RUN_BOSS") != "" && StrFindFirst(npc.GetReadableName(), W3T_GetEnv("W3T_RUN_BOSS")) >= 0)
        {
            W3T_Log("RUN boss " + npc.GetReadableName() + " shows at " + W3T_VecStr(npc.GetWorldPosition()) + "; the newest save is before it");
            bot.scenarioStep = 2;
            bot.scenarioTime = now;
            return false;
        }
        W3T_Log("RUN kills " + npc.GetReadableName());
        npc.Kill('W3T', true);
        return false;
    }
    // a new objective, out of scenes and fights: saved
    if(!bot.scenarioFlag && thePlayer.IsAlive() && !thePlayer.IsInCombat())
    {
        bot.scenarioFlag = true;
        bot.scenarioCount += 1;
        theGame.SaveGame(SGT_ManualSave, -1);
        W3T_Log("RUN saved " + bot.scenarioCount + " for '" + text + "' at " + W3T_VecStr(thePlayer.GetWorldPosition()));
    }
    if(now - bot.scenarioActAt < 3) { return false; }
    bot.scenarioActAt = now;
    for(i = 0; i < objectives.Size(); i += 1)
    {
        if(W3T_RunPinAt(objectives[i], at)) { break; }
    }
    if(i >= objectives.Size())
    {
        if(bot.scenarioValue != 1) { W3T_Log("RUN no objective has a pin here"); }
        bot.scenarioValue = 1;
        at = thePlayer.GetWorldPosition();
    }
    else
    {
        bot.scenarioValue = 0;
    }
    if(VecDistance(thePlayer.GetWorldPosition(), at) > 5)
    {
        spot = at;
        theGame.GetWorld().NavigationFindSafeSpot(at, 0.5, 6.0, spot);
        rot.Yaw = thePlayer.GetHeading();
        thePlayer.TeleportWithRotation(spot, rot);
        W3T_Log("RUN goes to " + W3T_VecStr(spot) + " for '" + GetLocStringById(objectives[i].GetTitleStringId()) + "'");
        return false;
    }
    actors = thePlayer.GetNPCsAndPlayersInRange(8, 16, '', FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
    for(i = 0; i < actors.Size(); i += 1)
    {
        npc = (CNewNPC)actors[i];
        if(npc && !npc.HasTag('MPEntity') && !npc.HasTag('w3coop_npc_copy') && W3T_Talkable(npc) && !W3T_RunRecently(bot, npc, now))
        {
            W3T_Log("RUN talks to " + NpcVoice(npc) + " (" + npc.GetReadableName() + ")");
            W3T_LookAt(npc.GetWorldPosition());
            npc.OnInteraction("Talk", thePlayer);
            return false;
        }
    }
    FindGameplayEntitiesInSphere(entities, thePlayer.GetWorldPosition(), 15, 32);
    for(i = 0; i < entities.Size(); i += 1)
    {
        clue = (W3MonsterClue)entities[i];
        if(clue && !W3T_RunRecently(bot, clue, now))
        {
            W3T_Log("RUN examines " + clue.GetReadableName());
            clue.OnInteraction("Examine", thePlayer);
            return false;
        }
    }
    return false;
}
