// prologue_coop: the start of the owner's first two-PC playthrough. Both bots load the owner's
// Kaer Morhen checkpoint (CheckPoint_53db8_7ea47400_54d1b72: the sparring scene with Vesemir, Ciri
// watching) as a co-op session: the second PC joins the host's party by itself. Both vote the first
// choice in scenes (shared choices wait for both votes), except that both take [SKIP TUTORIAL] when it
// is offered, so Vesemir spars at once; out of scenes both draw the steel sword when asked to, the
// leader hits the nearest hostile (Vesemir in the sparring) by 6 % every 3 s and the second PC follows
// the leader while it is more than 15 m off. Every 2 s each logs how many Ciris
// and Vesemirs it shows (real ones visible, stand-ins and enemy copies), its role, scene and swords.
// Pass: no sample with two of either character on screen, and the second PC still has a sword (the
// playtest: a second Vesemir, Ciri gone, no sword). While Vesemir spars (hostile), each PC's must be
// its own, on his own AI: never an enemy-sync copy (the owner's playtest: the second PC's stood in his
// plain pose). scenarioStep counts samples breaking that, scenarioValue the samples he was hostile in.
// Logs: PRO <side> ciri=<n> vesemir=<n> role=<r> party=<p> scene=<path> steel=<b> silver=<b> objectives | ...
// Visible NPCs within 60 m whose template names the character (stand-ins and copies keep the template).
function W3T_PrologueShown(part : string) : int
{
    var entities : array<CGameplayEntity>;
    var npc : CNewNPC;
    var i, n : int;
    FindGameplayEntitiesInSphere(entities, thePlayer.GetWorldPosition(), 60, 256, '', FLAG_OnlyAliveActors);
    for(i = 0; i < entities.Size(); i += 1)
    {
        npc = (CNewNPC)entities[i];
        if(!npc || !npc.GetVisibility() || npc.HasTag('MPEntity')) { continue; }
        if(StrFindFirst(StrLower(npc.GetReadableName()), part) >= 0) { n += 1; }
    }
    return n;
}

// The open objectives of all active quests, as text.
function W3T_PrologueObjectives() : string
{
    var manager : CWitcherJournalManager;
    var quests : array<CJournalBase>;
    var jq : CJournalQuest;
    var phase : CJournalQuestPhase;
    var objective : CJournalQuestObjective;
    var text : string;
    var i, j, k : int;
    manager = theGame.GetJournalManager();
    manager.GetActivatedOfType('CJournalQuest', quests);
    for(i = 0; i < quests.Size(); i += 1)
    {
        jq = (CJournalQuest)quests[i];
        if(!jq || manager.GetEntryStatus(jq) != JS_Active) { continue; }
        for(j = 0; j < jq.GetNumChildren(); j += 1)
        {
            phase = (CJournalQuestPhase)jq.GetChild(j);
            if(!phase) { continue; }
            for(k = 0; k < phase.GetNumChildren(); k += 1)
            {
                objective = (CJournalQuestObjective)phase.GetChild(k);
                if(objective && manager.GetEntryStatus(objective) == JS_Active) { text += GetLocStringById(objective.GetTitleStringId()) + " ; "; }
            }
        }
    }
    return text;
}

// The visible Vesemir of this world: hostile, in combat, his stance, and whether enemy sync runs him.
function W3T_PrologueVesemir(bot : W3T_Bot, client : r_MultiplayerClient) : string
{
    var entities : array<CGameplayEntity>;
    var npc : CNewNPC;
    var hostile, puppet : bool;
    var i : int;
    FindGameplayEntitiesInSphere(entities, thePlayer.GetWorldPosition(), 60, 256, '', FLAG_OnlyAliveActors);
    for(i = 0; i < entities.Size(); i += 1)
    {
        npc = (CNewNPC)entities[i];
        if(!npc || !npc.GetVisibility() || npc.HasTag('MPEntity') || npc.HasTag('w3coop_npc_copy') || NpcVoice(npc) == "") { continue; }
        if(StrFindFirst(StrLower(npc.GetReadableName()), "vesemir") < 0) { continue; }
        hostile = npc.GetAttitude(thePlayer) == AIA_Hostile;
        puppet = client.getCoopEnemies().IsPuppet(npc);
        if(hostile) { bot.scenarioValue += 1; }
        if(hostile && puppet) { bot.scenarioStep += 1; }
        return "hostile=" + hostile + " combat=" + npc.IsInCombat() + " stance=" + (int)npc.GetCurrentStance() + " synced=" + puppet;
    }
    return "none";
}

function W3T_PrologueSample(bot : W3T_Bot, client : r_MultiplayerClient, side : string)
{
    var id : SItemUniqueId;
    var ciri, vesemir : int;
    var steel, silver : bool;
    ciri = W3T_PrologueShown("ciri");
    vesemir = W3T_PrologueShown("vesemir");
    steel = GetWitcherPlayer().GetItemEquippedOnSlot(EES_SteelSword, id);
    silver = GetWitcherPlayer().GetItemEquippedOnSlot(EES_SilverSword, id);
    if(ciri >= 2 || vesemir >= 2) { bot.scenarioCount += 1; }
    // the swords are checked in Kaer Morhen: after the wake-up White Orchard has its own gear story
    if(WO_CurrentAreaCode() == 3) { bot.scenarioFlag = steel || silver; }
    W3T_Log("PRO " + side + " ciri=" + ciri + " vesemir=" + vesemir + " role=" + client.getCoopEnemies().GetRole() + " party=" + client.getJoinedParty()
        + " area=" + WO_CurrentAreaCode() + " scene=" + client.getCoopTalk().GetScenePath() + " steel=" + steel + " silver=" + silver
        + " vesemirState=" + W3T_PrologueVesemir(bot, client)
        + " objectives | " + W3T_PrologueObjectives());
}

function W3T_PrologueCoop(bot : W3T_Bot, client : r_MultiplayerClient, leader : r_RemotePlayer) : bool
{
    var talk : r_CoopTalk;
    var host : bool;
    var side : string;
    var now : float;
    var spot : Vector;
    var rot : EulerAngles;
    var pick : int;
    var tutorial, done : bool;
    host = W3T_GetEnv("W3T_ROLE") == "mover";
    tutorial = W3T_GetEnv("W3T_PROLOGUE_TUTORIAL") == "1";
    side = "copy";
    if(host) { side = "leader"; }
    now = bot.ElapsedS();
    talk = client.getCoopTalk();
    W3T_TalkLogEvents(talk, "PRO " + side + " talk");
    if(now < 10) { return false; }
    if(now - bot.scenarioSeenAt >= 2)
    {
        bot.scenarioSeenAt = now;
        W3T_PrologueSample(bot, client, side);
    }
    // lines are skipped (the owner: the runs were too slow): both bots press skip every second, through the
    // dialogue box as the space bar does, so a line goes once both pressed (scenarioFarSince: the last press)
    if(talk.InScene() && !client.hasActiveDialogChoices() && now - bot.scenarioFarSince >= 1.0 && theGame.GetStorySceneSystem().IsSkippingLineAllowed())
    {
        bot.scenarioFarSince = now;
        W3T_DialogModule().OnDialogSkipped(0);
    }
    if(client.hasActiveDialogChoices() && talk.ChoicesAge() > 2 && talk.MyVote() == "" && now - bot.scenarioActAt >= 3)
    {
        pick = -1;
        // W3T_PROLOGUE_TUTORIAL=1: the combat tutorial (Vesemir spars); else free training (straight to the nightmare)
        if(!tutorial) { pick = talk.ChoiceContaining("SKIP TUTORIAL"); }
        if(pick < 0) { pick = 0; }
        W3T_Log("PRO " + side + " votes choice " + pick + " of " + talk.LastChoiceCount());
        W3T_DialogModule().OnDialogOptionSelected(pick);
        W3T_DialogModule().OnDialogOptionAccepted(pick);
        bot.scenarioActAt = now;
    }
    else if(!talk.InScene() && !thePlayer.HasWeaponDrawn(false) && StrFindFirst(W3T_PrologueObjectives(), "Draw your sword") >= 0
        && now - bot.scenarioActAt >= 5)
    {
        W3T_Log("PRO " + side + " draws the steel sword");
        thePlayer.OnEquipMeleeWeapon(PW_Steel, true);
        bot.scenarioActAt = now;
    }
    else if(host)
    {
        if(!talk.InScene() && now - bot.scenarioActAt >= 3)
        {
            W3T_BossHit(W3T_BossNearest(W3T_BossHostiles()));
            bot.scenarioActAt = now;
        }
    }
    // following the leader: never while this game joins a scene (a move then broke its own quest's start
    // of the nightmare)
    else if(leader && !talk.InScene() && !talk.IsSyncing() && leader.area == WO_CurrentAreaCode() && VecDistance(leader.pos, thePlayer.GetWorldPosition()) > 15
        && (leader.pos.X != 0 || leader.pos.Y != 0))
    {
        spot = leader.pos;
        theGame.GetWorld().NavigationFindSafeSpot(leader.pos, 0.5, 6.0, spot);
        rot.Yaw = thePlayer.GetHeading();
        thePlayer.TeleportWithRotation(spot, rot);
    }
    // done early (the owner: runs too slow): free training once the wake-up scene is over here, the
    // tutorial after 10 samples (20 s) of Vesemir sparring; at the latest at the scenario's time
    if(tutorial) { done = bot.scenarioValue >= 10; }
    else { done = !talk.InScene() && StrFindFirst(talk.GetScenePath(), "q001_5_wake_up") >= 0; }
    if(!done && now < W3T_BossTime()) { return false; }
    W3T_Log("PRO " + side + " end duplicates=" + bot.scenarioCount + " sword=" + bot.scenarioFlag + " vesemirHostileSamples=" + bot.scenarioValue
        + " vesemirSyncedWhileHostile=" + bot.scenarioStep + " holds=" + talk.holds + " holdTimeouts=" + talk.holdTimeouts
        + " votes=" + talk.votesSent + " decisions=" + talk.picksSent + " applied=" + talk.picksApplied + " ties=" + talk.ties);
    // the swords only on the tutorial path: free training and the nightmare take them (a dream), the wake-up gives them back later
    return bot.scenarioCount == 0 && (bot.scenarioFlag || !tutorial) && bot.scenarioStep == 0 && talk.holdTimeouts == 0 && done;
}
