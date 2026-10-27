// prologue_coop: the start of the owner's first two-PC playthrough. Both bots load the owner's
// Kaer Morhen checkpoint (CheckPoint_53db8_7ea47400_54d1b72: the sparring scene with Vesemir, Ciri
// watching) as a co-op session: the second PC joins the host's party by itself. The leader takes the
// first choice in scenes and, out of them, hits the nearest hostile (Vesemir in the sparring) by 6 %
// every 3 s; the second PC follows the leader and picks nothing. Every 2 s each logs how many Ciris
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
    bot.scenarioFlag = steel || silver;
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
    host = W3T_GetEnv("W3T_ROLE") == "mover";
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
    if(host)
    {
        if(client.hasActiveDialogChoices() && talk.ChoicesAge() > 2 && now - bot.scenarioActAt >= 3)
        {
            W3T_Log("PRO leader takes choice 0 of " + talk.LastChoiceCount());
            W3T_DialogModule().OnDialogOptionSelected(0);
            W3T_DialogModule().OnDialogOptionAccepted(0);
            bot.scenarioActAt = now;
        }
        else if(!talk.InScene() && now - bot.scenarioActAt >= 3)
        {
            W3T_BossHit(W3T_BossNearest(W3T_BossHostiles()));
            bot.scenarioActAt = now;
        }
    }
    else if(leader && !talk.InScene() && leader.area == WO_CurrentAreaCode() && VecDistance(leader.pos, thePlayer.GetWorldPosition()) > 15
        && (leader.pos.X != 0 || leader.pos.Y != 0))
    {
        spot = leader.pos;
        theGame.GetWorld().NavigationFindSafeSpot(leader.pos, 0.5, 6.0, spot);
        rot.Yaw = thePlayer.GetHeading();
        thePlayer.TeleportWithRotation(spot, rot);
    }
    if(now < W3T_BossTime()) { return false; }
    W3T_Log("PRO " + side + " end duplicates=" + bot.scenarioCount + " sword=" + bot.scenarioFlag + " vesemirHostileSamples=" + bot.scenarioValue
        + " vesemirSyncedWhileHostile=" + bot.scenarioStep);
    return bot.scenarioCount == 0 && bot.scenarioFlag && bot.scenarioStep == 0;
}
