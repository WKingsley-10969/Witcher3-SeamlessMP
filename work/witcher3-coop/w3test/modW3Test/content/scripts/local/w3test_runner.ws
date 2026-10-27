// quest_run: plays a quest of the save on, objective by objective, and saves the game at each new objective, so a
// boss fight's quest can be started from a save made just before it (boss_fight with W3T_SAVE_DIR). The leader
// plays alone (no party); the second PC idles.
//   W3T_RUN_QUEST  parts of the quests' titles, comma-separated: tracked, and played (see W3T_RunQuest)
//   W3T_RUN_BOSS   part of the boss's template name: the run ends when it shows (other hostiles are killed)
//   W3T_RUN_TIME   seconds the run may take (600 unless set)
// Every 3 s, when not in a scene: the first open objective of the quest that has a map pin is gone to (teleport);
// there the leader talks to a character offering talk within 12 m and examines the monster clues within 15 m
// (a character once a minute, a clue once: a trail has dozens), takes the items of plants and of containers holding
// a quest item within 50 m, follows a trail of clues within 80 m (staying off the pin while on it), and goes to a
// quest character that offers talk within 40 m (300 m after 15 s); after 30 s with nothing to do it goes to the next
// objective with a pin, and each 30 s idle steps out 80 or 160 m and comes back (a quest's area trigger fires only on
// entering: the hunter of White Orchard). In a scene it takes a choice once the choices have been up 2 s: the first
// one the game marks neither taken before nor leaving, else the next in turn each time the same menu comes back (a
// conversation that loops). Hostiles that are not the boss are killed. Logs:
//   RUN objectives | <text> ; ...      on change, then a save (ManualSave) once out of scenes and fights
//   RUN saved <n> for '<objectives>'    each save: the newest save of the run's sandbox is the one before the boss
//   RUN goes to <x,y,z> / talks to <voice> / examines <clue> / follows the trail to <clue> / steps out <m> / kills <name>
//   RUN boss <name> shows               the end
function W3T_RunTime() : float
{
    var t : int;
    t = StringToInt(W3T_GetEnv("W3T_RUN_TIME"), 600);
    if(t <= 0) { t = 600; }
    return (float)t;
}

// The quest played, tracked: of the active quests named in W3T_RUN_QUEST (comma-separated parts of titles, as one
// quest hands over to another: "Lilac and Gooseberries,The Beast of White Orchard"), the first in that order with an
// objective that has a map pin here; else the first of them active.
function W3T_RunQuest() : CJournalQuest
{
    var manager : CWitcherJournalManager;
    var quests : array<CJournalBase>;
    var names : array<string>;
    var objectives : array<CJournalQuestObjective>;
    var jq, fallback : CJournalQuest;
    var at : Vector;
    var i, j, k : int;
    manager = theGame.GetJournalManager();
    manager.GetActivatedOfType('CJournalQuest', quests);
    names = W3T_Split(W3T_GetEnv("W3T_RUN_QUEST"), ",");
    for(j = 0; j < names.Size(); j += 1)
    {
        for(i = 0; i < quests.Size(); i += 1)
        {
            jq = (CJournalQuest)quests[i];
            if(!jq || manager.GetEntryStatus(jq) != JS_Active || StrFindFirst(GetLocStringById(jq.GetTitleStringId()), names[j]) < 0) { continue; }
            if(!fallback) { fallback = jq; }
            objectives = W3T_RunObjectives(jq);
            for(k = 0; k < objectives.Size(); k += 1)
            {
                if(W3T_RunPinAt(objectives[k], at))
                {
                    if(manager.GetTrackedQuest() != jq) { manager.SetTrackedQuest(jq); }
                    return jq;
                }
            }
        }
    }
    if(fallback && manager.GetTrackedQuest() != fallback) { manager.SetTrackedQuest(fallback); }
    return fallback;
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

// Whether the leader did something to this entity less than "again" seconds ago (and notes it now if not).
function W3T_RunRecently(bot : W3T_Bot, entity : CEntity, now : float, again : float) : bool
{
    var i : int;
    i = bot.runEntities.FindFirst(entity);
    if(i >= 0 && now - bot.runTimes[i] < again) { return true; }
    if(i < 0)
    {
        bot.runEntities.PushBack(entity);
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
    var container : W3Container;
    var items : array<SItemUniqueId>;
    var range : float;
    var talk : r_CoopTalk;
    var text, key : string;
    var at, spot : Vector;
    var rot : EulerAngles;
    var i, k, pick, dist : int;
    var pinned : array<int>;
    var events : array<string>;
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
        bot.scenarioStep = 2;
        bot.scenarioTime = now;
        return false;
    }
    events = talk.TakeEvents();
    for(i = 0; i < events.Size(); i += 1)
    {
        W3T_Log("RUN talk " + events[i]);
        if(StrFindFirst(events[i], " CHOICES ") >= 0) { bot.runChoices = events[i]; }
    }
    if(now - bot.scenarioSeenAt >= 30)
    {
        bot.scenarioSeenAt = now;
        W3T_Log("RUN state inScene=" + talk.InScene() + " scene='" + talk.GetScenePath() + "' dialogOrCutscene=" + theGame.IsDialogOrCutscenePlaying()
            + " choices=" + client.hasActiveDialogChoices() + " pos=" + W3T_VecStr(thePlayer.GetWorldPosition()) + " objectives='" + bot.scenarioText + "'");
    }
    // lines and cutscenes skipped, as a player pressing skip does (the owner: no need to watch them)
    if(theGame.IsDialogOrCutscenePlaying() && !client.hasActiveDialogChoices() && now - bot.scenarioActAt >= 0.5
        && theGame.GetStorySceneSystem().IsSkippingLineAllowed())
    {
        bot.scenarioActAt = now;
        theGame.GetStorySceneSystem().SendSignal(SSST_Skip, 0);
    }
    if(talk.InScene())
    {
        // the same menu again (a conversation that loops back): the next choice this time
        if(client.hasActiveDialogChoices() && talk.ChoicesAge() > 1)
        {
            key = talk.GetScenePath() + "|" + talk.LastChoiceCount();
            k = bot.runPickKeys.FindFirst(key);
            if(k < 0)
            {
                bot.runPickKeys.PushBack(key);
                bot.runPicks.PushBack(0);
                k = bot.runPicks.Size() - 1;
            }
            // a choice not taken before and not leaving, first (two menus of a conversation may have as many choices);
            // else the next in turn
            pick = W3T_RunFreshChoice(bot.runChoices);
            if(pick < 0 || pick >= talk.LastChoiceCount()) { pick = bot.runPicks[k] % talk.LastChoiceCount(); }
            bot.runPicks[k] += 1;
            W3T_Log("RUN takes choice " + pick + " of " + talk.LastChoiceCount());
            W3T_DialogModule().OnDialogOptionSelected(pick);
            W3T_DialogModule().OnDialogOptionAccepted(pick);
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
        bot.runObjective = 0;
        bot.runIdle = 0;
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
        theGame.SaveGame(SGT_Manual, -1);
        W3T_Log("RUN saved " + bot.scenarioCount + " for '" + text + "' at " + W3T_VecStr(thePlayer.GetWorldPosition()));
    }
    if(now - bot.scenarioActAt < 3) { return false; }
    bot.scenarioActAt = now;
    // the objectives with a pin here, taken in turn: the next one after 30 s with nothing to do at one
    for(i = 0; i < objectives.Size(); i += 1)
    {
        if(W3T_RunPinAt(objectives[i], at)) { pinned.PushBack(i); }
    }
    if(pinned.Size() == 0)
    {
        if(bot.scenarioValue != 1) { W3T_Log("RUN no objective has a pin here"); }
        bot.scenarioValue = 1;
        at = thePlayer.GetWorldPosition();
    }
    else
    {
        bot.scenarioValue = 0;
        i = pinned[bot.runObjective % pinned.Size()];
        W3T_RunPinAt(objectives[i], at);
    }
    // off the pin while following a trail (last step less than 20 s ago)
    if(VecDistance(thePlayer.GetWorldPosition(), at) > 5 && now - bot.runTrailTime > 20)
    {
        spot = at;
        theGame.GetWorld().NavigationFindSafeSpot(at, 0.5, 6.0, spot);
        rot.Yaw = thePlayer.GetHeading();
        thePlayer.TeleportWithRotation(spot, rot);
        W3T_Log("RUN goes to " + W3T_VecStr(spot) + " for '" + GetLocStringById(objectives[i].GetTitleStringId()) + "'");
        return false;
    }
    actors = thePlayer.GetNPCsAndPlayersInRange(12, 16, '', FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
    for(i = 0; i < actors.Size(); i += 1)
    {
        npc = (CNewNPC)actors[i];
        if(npc && !npc.HasTag('MPEntity') && !npc.HasTag('w3coop_npc_copy') && W3T_Talkable(npc) && !W3T_RunRecently(bot, npc, now, 60))
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
        if(clue && !W3T_RunRecently(bot, clue, now, 100000))
        {
            W3T_Log("RUN examines " + clue.GetReadableName());
            clue.OnInteraction("Examine", thePlayer);
            return false;
        }
    }
    // a trail to follow with the Witcher Senses: the nearest clue not yet examined within 80 m, gone to (examined on
    // the next tick)
    FindGameplayEntitiesInSphere(entities, thePlayer.GetWorldPosition(), 80, 200);
    pick = -1;
    for(i = 0; i < entities.Size(); i += 1)
    {
        if((W3MonsterClue)entities[i] && bot.runEntities.FindFirst(entities[i]) < 0 && (pick < 0 || VecDistance(thePlayer.GetWorldPosition(),
            entities[i].GetWorldPosition()) < VecDistance(thePlayer.GetWorldPosition(), entities[pick].GetWorldPosition())))
        {
            pick = i;
        }
    }
    if(pick >= 0)
    {
        spot = entities[pick].GetWorldPosition();
        theGame.GetWorld().NavigationFindSafeSpot(entities[pick].GetWorldPosition(), 0.5, 4.0, spot);
        rot.Yaw = VecHeading(entities[pick].GetWorldPosition() - thePlayer.GetWorldPosition());
        thePlayer.TeleportWithRotation(spot, rot);
        bot.runTrailTime = now;
        W3T_Log("RUN follows the trail to " + W3T_SurveyEntityName(entities[pick]) + " at " + W3T_VecStr(spot));
        return false;
    }
    // a plant (the buckthorn to find on a riverbed is an ordinary herb) or a container holding a quest item: its items
    // taken, as gathering or looting it would
    FindGameplayEntitiesInSphere(entities, thePlayer.GetWorldPosition(), 50, 100);
    for(i = 0; i < entities.Size(); i += 1)
    {
        container = (W3Container)entities[i];
        if(container && container.GetInventory() && !container.GetInventory().IsEmpty()
            && ((W3Herb)container || container.GetInventory().HasQuestItem()) && !W3T_RunRecently(bot, container, now, 100000))
        {
            container.GetInventory().GetAllItems(items);
            text = "";
            for(k = 0; k < items.Size() && k < 4; k += 1) { text += " " + NameToString(container.GetInventory().GetItemName(items[k])); }
            W3T_Log("RUN takes" + text + " from " + W3T_SurveyEntityName(container) + " at " + W3T_VecStr(container.GetWorldPosition()));
            container.GetInventory().GiveAllItemsTo(thePlayer.inv, true, true);
            return false;
        }
    }
    // a quest's own character (its template under a quests folder) off the pin, as it walks about: within 40 m, and
    // within 300 m once nothing was found here for 15 s (the hunter is not home): gone to and talked to
    range = 40;
    if(bot.runIdle >= 5) { range = 300; }
    actors = thePlayer.GetNPCsAndPlayersInRange(range, 200, '', FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
    for(i = 0; i < actors.Size(); i += 1)
    {
        npc = (CNewNPC)actors[i];
        if(npc && !npc.HasTag('MPEntity') && !npc.HasTag('w3coop_npc_copy') && StrFindFirst(npc.GetReadableName(), "quests") >= 0
            && W3T_Talkable(npc) && !W3T_RunRecently(bot, npc, now, 60))
        {
            spot = npc.GetWorldPosition() + VecNormalize(thePlayer.GetWorldPosition() - npc.GetWorldPosition()) * 2.0;
            rot.Yaw = VecHeading(npc.GetWorldPosition() - spot);
            thePlayer.TeleportWithRotation(spot, rot);
            W3T_Log("RUN goes to and talks to " + NpcVoice(npc) + " (" + npc.GetReadableName() + ")");
            npc.OnInteraction("Talk", thePlayer);
            return false;
        }
    }
    bot.runIdle += 1;
    // the hunter is not loaded at any hour while the save starts at his pin: a quest's area trigger fires only on
    // entering, so each 30 s idle step out (80 m, then 160 m) for the next tick to come back to the pin
    if(bot.runIdle % 10 == 5)
    {
        dist = 80;
        if(bot.runIdle % 20 == 15) { dist = 160; }
        spot = thePlayer.GetWorldPosition() + VecFromHeading(thePlayer.GetHeading()) * dist;
        if(theGame.GetWorld().NavigationFindSafeSpot(spot, 0.5, 30.0, spot))
        {
            rot.Yaw = thePlayer.GetHeading();
            thePlayer.TeleportWithRotation(spot, rot);
            W3T_Log("RUN steps out " + dist + " m to " + W3T_VecStr(spot) + ", " + W3T_RunQuestCharacters() + " quest characters loaded");
            return false;
        }
        W3T_Log("RUN no safe spot " + dist + " m out");
    }
    if(bot.runIdle >= 10 && pinned.Size() > 1)
    {
        bot.runIdle = 0;
        bot.runObjective += 1;
        W3T_Log("RUN nothing to do here for 30 s: the next objective");
    }
    // nothing to do here: once per objective, who is around (and whether they offer talk) and what can be looted
    if(!bot.surveySeen.Contains("idle|" + text + "|" + bot.runObjective))
    {
        bot.surveySeen.PushBack("idle|" + text + "|" + bot.runObjective);
        actors = thePlayer.GetNPCsAndPlayersInRange(30, 32, '', FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
        for(i = 0; i < actors.Size(); i += 1)
        {
            npc = (CNewNPC)actors[i];
            if(!npc) { continue; }
            W3T_Log("RUN idle near " + NpcVoice(npc) + " (" + W3T_SurveyEntityName(npc) + ") dist=" + FloatToStringPrec(VecDistance(thePlayer.GetWorldPosition(),
                npc.GetWorldPosition()), 1) + " scene=" + npc.HasInteractionScene() + " talk=" + (npc.GetComponent('talk') && npc.GetComponent('talk').IsEnabled()));
        }
        for(i = 0; i < entities.Size(); i += 1)
        {
            container = (W3Container)entities[i];
            if(!container || !container.GetInventory()) { continue; }
            container.GetInventory().GetAllItems(items);
            text = "";
            for(k = 0; k < items.Size() && k < 3; k += 1) { text += " " + NameToString(container.GetInventory().GetItemName(items[k])); }
            W3T_Log("RUN idle near container " + W3T_SurveyEntityName(container) + " dist=" + FloatToStringPrec(VecDistance(thePlayer.GetWorldPosition(),
                container.GetWorldPosition()), 1) + " items:" + text);
        }
    }
    return false;
}

// The quest's own characters loaded anywhere (their templates under a quests folder), logged; their count
function W3T_RunQuestCharacters() : int
{
    var actors : array<CActor>;
    var npc : CNewNPC;
    var i, n : int;
    actors = thePlayer.GetNPCsAndPlayersInRange(3000, 3000, '', FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
    for(i = 0; i < actors.Size(); i += 1)
    {
        npc = (CNewNPC)actors[i];
        if(npc && StrFindFirst(npc.GetReadableName(), "quests") >= 0)
        {
            n += 1;
            W3T_Log("RUN quest character " + NpcVoice(npc) + " (" + W3T_SurveyEntityName(npc) + ") dist=" + FloatToStringPrec(VecDistance(
                thePlayer.GetWorldPosition(), npc.GetWorldPosition()), 1) + " at " + W3T_VecStr(npc.GetWorldPosition()) + " talk=" + W3T_Talkable(npc));
        }
    }
    return n;
}

// The first choice of a logged list ("<time> CHOICES <n> <text> [a<action> seen off] | ...") the game marks neither as
// taken before (seen), off, nor leaving (action 8192); -1 if none
function W3T_RunFreshChoice(list : string) : int
{
    var rest, item, flags : string;
    var i : int;
    rest = StrAfterFirst(StrAfterFirst(list, " CHOICES "), " ");
    // a choice that skips a tutorial, first of all (the prologue's sparring offers one)
    if(StrFindFirst(rest, "SKIP TUTORIAL") >= 0)
    {
        item = rest;
        for(i = 0; item != ""; i += 1)
        {
            if(!StrSplitFirst(item, " | ", flags, item)) { flags = item; item = ""; }
            if(StrFindFirst(flags, "SKIP TUTORIAL") >= 0) { return i; }
        }
    }
    for(i = 0; rest != ""; i += 1)
    {
        if(!StrSplitFirst(rest, " | ", item, rest))
        {
            item = rest;
            rest = "";
        }
        flags = StrAfterFirst(item, "[a");
        if(StrFindFirst(flags, "seen") < 0 && StrFindFirst(flags, "off") < 0 && StrFindFirst(flags, "8192") != 0) { return i; }
    }
    return -1;
}
