// Mechanism proof only: two clients write independent leased test targets.
// No vanilla quest graph or real quest reward is exercised here.
function W3T_SeamlessEffects(bot : W3T_Bot) : bool
{
    var campaign : r_SeamlessCampaign;
    var stem, ownFact, otherFact : string;
    var initial, decreased : int;
    campaign = theGame.r_getMultiplayerClient().getSeamlessCampaign();
    W3T_Log("SEAMLESS stage=" + bot.scenarioStep + " status=" + campaign.GetStatus()
        + " cursor=" + campaign.GetCursor() + " applied=" + campaign.GetAppliedCount());
    if(!campaign.IsReady()) { return false; }
    stem = "A";
    ownFact = "sc_test_host_progress";
    otherFact = "sc_test_guest_progress";
    initial = 9;
    decreased = 2;
    if(W3T_GetEnv("W3T_ROLE") != "mover")
    {
        stem = "B";
        ownFact = "sc_test_guest_progress";
        otherFact = "sc_test_host_progress";
        initial = 7;
        decreased = 3;
    }
    if(bot.scenarioStep == 0)
    {
        if(campaign.OpenConversation("sc_test_conversation_" + stem, "quest", "sc_test_scope_" + stem))
        { bot.scenarioStep = 1; }
    }
    else if(bot.scenarioStep == 1 && campaign.OwnsConversation())
    {
        if(campaign.RequestFactSet("sc_test_initial_" + stem, ownFact, initial)) { bot.scenarioStep = 2; }
    }
    else if(bot.scenarioStep == 2 && FactsQuerySum(ownFact) == initial && FactsQuerySum(otherFact) > 0
        && campaign.GetAppliedCount() >= 2)
    {
        if(campaign.RequestFactSet("sc_test_decrease_" + stem, ownFact, decreased)) { bot.scenarioStep = 3; }
    }
    else if(bot.scenarioStep == 3 && FactsQuerySum(ownFact) == decreased && campaign.GetAppliedCount() >= 4)
    {
        if(campaign.RequestFactSet("sc_test_zero_" + stem, ownFact, 0)) { bot.scenarioStep = 4; }
    }
    else if(bot.scenarioStep == 4 && FactsDoesExist(ownFact) && FactsDoesExist(otherFact)
        && FactsQuerySum(ownFact) == 0 && FactsQuerySum(otherFact) == 0 && campaign.GetAppliedCount() >= 6)
    {
        if(SC_ApplyFactAbsolute("not_an_allowed_quest_fact", 17)) { return false; }
        if(SC_ApplyJournalAbsolute("sc_test_missing_journal", (int)JS_Success)) { return false; }
        W3T_Log("SEAMLESS fact mechanism verified bidirectional decreases and existing zero; natural quests NOT tested");
        return true;
    }
    return false;
}

// This exercises the real script/native/UDP path with a guest controller and
// host voter. It does not play a cinematic or execute any vanilla quest graph.
function W3T_SeamlessDialogue(bot : W3T_Bot) : bool
{
    var campaign : r_SeamlessCampaign;
    campaign = theGame.r_getMultiplayerClient().getSeamlessCampaign();
    W3T_Log("DIALOGUE stage=" + bot.scenarioStep + " status=" + campaign.GetStatus() + " prompt=" + campaign.GetPromptInstance()
        + " owner=" + campaign.GetOwner() + " joined=" + campaign.GetConversation()
        + " observed=" + campaign.GetObservedConversation() + " result=" + campaign.GetVoteResult() + " accepted=" + campaign.GetAcceptedChoice()
        + " receipt=" + campaign.GetAcceptedChoiceEvent() + " engine=" + campaign.GetEngineChoiceCount()
        + " voteStatus=" + campaign.GetLastVoteStatus() + " done=" + FactsQuerySum("sc_test_dialogue_done")
        + " cursor=" + campaign.GetCursor() + "/" + campaign.GetLatest() + " applied=" + campaign.GetAppliedCount());
    if(!campaign.IsReady()) { return false; }
    if(W3T_GetEnv("W3T_ROLE") == "mover")
    {
        if(campaign.GetConversation() == "") { campaign.ListenConversation("sc_test_guest_dialogue"); return false; }
        if(campaign.OwnsConversation() || campaign.RequestChoice("A")) { return false; }
        if(campaign.GetVoteId() != "" && bot.scenarioStep == 0)
        {
            if(campaign.CastVote("A")) { bot.scenarioStep = 1; }
        }
        return bot.scenarioStep == 1 && campaign.GetLastVoteStatus() == "OK" && campaign.GetAcceptedChoice() == "A"
            && campaign.GetEngineChoiceCount() == 0 && FactsQuerySum("sc_test_dialogue_done") == 2
            && campaign.GetCursor() == campaign.GetLatest();
    }
    if(bot.scenarioStep == 0)
    {
        if(campaign.OpenConversation("sc_test_guest_dialogue", "npc", "sc_test_guest_npc")) { bot.scenarioStep = 1; }
    }
    else if(bot.scenarioStep == 1 && campaign.OwnsConversation() && campaign.GetLease() != "")
    {
        if(bot.scFirstInstance == "") { bot.scFirstInstance = WO_SCInstance(); }
        if(campaign.PublishChoices(bot.scFirstInstance, "A,B", true)) { bot.scenarioStep = 2; bot.scenarioTime = bot.ElapsedS(); }
    }
    else if(bot.scenarioStep == 2 && campaign.GetPromptInstance() == bot.scFirstInstance && bot.ElapsedS() - bot.scenarioTime > 8)
    {
        if(campaign.RequestVote("A,B")) { bot.scenarioStep = 3; }
    }
    else if(bot.scenarioStep == 3 && campaign.GetVoteId() != "")
    {
        if(campaign.CastVote("B")) { bot.scenarioStep = 4; }
    }
    else if(bot.scenarioStep == 4 && campaign.GetVoteResult() == "B")
    {
        if(campaign.RequestChoice("B")) { bot.scenarioStep = 5; }
    }
    else if(bot.scenarioStep == 5 && campaign.GetAcceptedChoice() == "B" && campaign.GetAcceptedChoiceEvent() > 0)
    {
        bot.scFirstReceipt = campaign.GetAcceptedChoiceEvent();
        if(bot.scSecondInstance == "") { bot.scSecondInstance = WO_SCInstance(); }
        if(campaign.PublishChoices(bot.scSecondInstance, "A,B", false)) { bot.scenarioStep = 6; }
    }
    else if(bot.scenarioStep == 6 && campaign.GetPromptInstance() == bot.scSecondInstance && campaign.GetAcceptedChoice() == "")
    {
        if(campaign.RequestChoice("A")) { bot.scenarioStep = 7; }
    }
    else if(bot.scenarioStep == 7 && campaign.GetAcceptedChoice() == "A" && campaign.GetAcceptedChoiceEvent() > bot.scFirstReceipt)
    {
        if(campaign.RequestFactSet("sc_test_dialogue_receipt", "sc_test_dialogue_done", 2)) { bot.scenarioStep = 8; }
    }
    return bot.scenarioStep == 8 && campaign.GetLastVoteStatus() == "OK" && campaign.GetEngineChoiceCount() == 0
        && FactsQuerySum("sc_test_dialogue_done") == 2 && campaign.GetCursor() == campaign.GetLatest();
}

// Exact scripted-helper observation only. No remote quest execution is claimed.
function W3T_SeamlessCapture(bot : W3T_Bot) : bool
{
    var generation, i, expectedValue, expectedDuration : int;
    var wire : string;
    var parts : array<string>;
    if(bot.scenarioStep == 1) { return true; }
    if(bot.scenarioStep < 0) { return false; }
    generation = WNB_FactOpsReset();
    if(!WNB_FactOpsBegin("sc_test_capture") || !WNB_FactOpsWatch("sc_test_transient")
        || WNB_FactOpsWatch("real_quest_fact")) { bot.scenarioStep = -1; return false; }
    // All transitions occur before any snapshot/poll. A sum observer would see
    // only the final zero; this helper observer must retain the six operations.
    FactsSet("sc_test_transient", 7, 120);
    FactsSet("sc_test_transient", 3, 45);
    FactsSet("sc_test_transient", 0, -1);
    if(!FactsDoesExist("sc_test_transient") || FactsQuerySum("sc_test_transient") != 0) { bot.scenarioStep = -1; return false; }
    for(i = 0; i < 6; i += 1)
    {
        wire = WNB_FactOpsPeek();
        parts = W3T_Split(wire, " ");
        W3T_Log("CAPTURE operation=" + wire);
        if(parts.Size() != 9 || StringToInt(parts[0], -1) != generation || StringToInt(parts[1], -1) != i + 1
            || parts[2] != "sc_test_capture" || parts[4] != "sc_test_transient" || parts[7] != "0")
        { bot.scenarioStep = -1; return false; }
        expectedValue = 0;
        expectedDuration = 0;
        if(i == 1) { expectedValue = 7; expectedDuration = 120; }
        if(i == 3) { expectedValue = 3; expectedDuration = 45; }
        if(i == 5) { expectedDuration = -1; }
        if((i % 2 == 0 && parts[3] != "remove") || (i % 2 == 1 && parts[3] != "add")
            || StringToInt(parts[5], -1) != expectedValue || StringToInt(parts[6], -999) != expectedDuration)
        { bot.scenarioStep = -1; return false; }
        if(WNB_FactOpsAck(generation, i + 2) || WNB_FactOpsPeek() != wire || !WNB_FactOpsAck(generation, i + 1))
        { bot.scenarioStep = -1; return false; }
    }
    if(WNB_FactOpsPeek() != "") { bot.scenarioStep = -1; return false; }
    FactsSet("sc_test_transient", 4, -1);
    if(!WNB_FactOpsBeginRemote()) { bot.scenarioStep = -1; return false; }
    FactsSet("sc_test_transient", 11, -1);
    if(!WNB_FactOpsEndRemote() || FactsQuerySum("sc_test_transient") != 11) { bot.scenarioStep = -1; return false; }
    for(i = 7; i <= 8; i += 1)
    {
        parts = W3T_Split(WNB_FactOpsPeek(), " ");
        if(parts.Size() != 9 || StringToInt(parts[1], -1) != i || (i == 8 && parts[5] != "4")
            || !WNB_FactOpsAck(generation, i)) { bot.scenarioStep = -1; return false; }
    }
    // Direct native FactsRemove is intentionally outside this narrow observer.
    FactsRemove("sc_test_transient");
    if(WNB_FactOpsPeek() != "" || FactsDoesExist("sc_test_transient") || !WNB_FactOpsEnd())
    { bot.scenarioStep = -1; return false; }
    bot.scenarioStep = 1;
    W3T_Log("CAPTURE verified transient helper operations, duration, ordered ACK, remote suppression; direct natives/quests NOT captured");
    return true;
}

// Guest-captured FactsSet calls replicated through the campaign ledger to the host.
// The host watches the same targets so a recaptured remote write would show up in
// its queue. Test facts only; no quest graph or native quest-node write is involved.
function W3T_SeamlessReplicate(bot : W3T_Bot) : bool
{
    var campaign : r_SeamlessCampaign;
    campaign = theGame.r_getMultiplayerClient().getSeamlessCampaign();
    W3T_Log("REPLICATE stage=" + bot.scenarioStep + " status=" + campaign.GetStatus() + " commits=" + campaign.GetCaptureCommits()
        + " queue=" + WNB_FactOpsPeek() + " capture=" + WNB_FactOpsStatus()
        + " a=" + FactsDoesExist("sc_test_rep_a") + "/" + FactsQuerySum("sc_test_rep_a")
        + " b=" + FactsDoesExist("sc_test_rep_b") + "/" + FactsQuerySum("sc_test_rep_b")
        + " c=" + FactsDoesExist("sc_test_rep_c") + "/" + FactsQuerySum("sc_test_rep_c")
        + " applied=" + campaign.GetAppliedCount() + " tx=" + campaign.GetTransactionCount()
        + " cursor=" + campaign.GetCursor() + "/" + campaign.GetLatest());
    if(bot.scenarioStep < 0 || !campaign.IsReady()) { return false; }
    if(W3T_GetEnv("W3T_ROLE") == "mover")
    {
        if(bot.scenarioStep == 0)
        {
            if(!WNB_FactOpsBegin("sc_test_rep_host") || !WNB_FactOpsWatch("sc_test_rep_a")
                || !WNB_FactOpsWatch("sc_test_rep_b") || !WNB_FactOpsWatch("sc_test_rep_c")) { bot.scenarioStep = -1; return false; }
            bot.scenarioStep = 1;
        }
        return FactsDoesExist("sc_test_rep_a") && FactsQuerySum("sc_test_rep_a") == 3
            && FactsDoesExist("sc_test_rep_b") && FactsQuerySum("sc_test_rep_b") == 0
            && FactsQuerySum("sc_test_rep_c") == 5 && campaign.GetAppliedCount() == 4
            && campaign.GetCaptureCommits() == 0 && WNB_FactOpsPeek() == "" && campaign.GetCursor() == campaign.GetLatest();
    }
    if(bot.scenarioStep == 0)
    {
        if(campaign.OpenConversation("sc_test_replicate", "quest", "sc_test_rep_quest")) { bot.scenarioStep = 1; }
    }
    else if(bot.scenarioStep == 1 && campaign.OwnsConversation() && campaign.GetLease() != "")
    {
        if(!WNB_FactOpsBegin("sc_test_replicate") || !WNB_FactOpsWatch("sc_test_rep_a")
            || !WNB_FactOpsWatch("sc_test_rep_b") || !WNB_FactOpsWatch("sc_test_rep_c")) { bot.scenarioStep = -1; return false; }
        FactsSet("sc_test_rep_a", 7, 120);
        FactsSet("sc_test_rep_a", 3);
        FactsSet("sc_test_rep_b", 0);
        FactsSet("sc_test_rep_c", 5, 3600);
        bot.scenarioStep = 2;
    }
    // applied == 0: the guest's own echoes are not re-applied (or recaptured) here.
    return bot.scenarioStep == 2 && campaign.GetCaptureCommits() == 4 && WNB_FactOpsPeek() == ""
        && campaign.GetTransactionCount() == 4 && campaign.GetAppliedCount() == 0
        && FactsQuerySum("sc_test_rep_a") == 3 && FactsQuerySum("sc_test_rep_c") == 5
        && campaign.GetCursor() == campaign.GetLatest();
}

// Research probe for one real side quest start: the guest takes a notice-board note
// exactly as NoticeBoardMenu.OnTakeQuest does (AcceptNewQuest), and the whole facts DB
// is diffed before/after, with a quiet control window first to expose background noise.
// It also lists which targets went through scripted FactsSet in the quest window, which
// shows whether the quest's writes bypass the helper capture. The host only records its
// own diff over the same period. No replication is attempted here.
function W3T_ActiveQuestTags() : array<string>
{
    var manager : CWitcherJournalManager;
    var quests : array<CJournalBase>;
    var tags : array<string>;
    var i : int;
    manager = theGame.GetJournalManager();
    manager.GetActivatedOfType('CJournalQuest', quests);
    for(i = 0; i < quests.Size(); i += 1)
    {
        if(manager.GetEntryStatus(quests[i]) == JS_Active) { tags.PushBack(NameToString(quests[i].GetUniqueScriptTag())); }
    }
    return tags;
}

function W3T_DumpFactDiff(label : string)
{
    var parts : array<string>;
    var page : string;
    var pages, p, i, n : int;
    page = WO_FactsPage(40);
    if(page == "") { W3T_Log(label + " FACTS_UNAVAILABLE"); return; }
    parts = W3T_Split(page, " ");
    pages = StringToInt(parts[1], 1);
    for(p = 0; p < pages && p < 50; p += 1)
    {
        if(p > 0) { parts = W3T_Split(WO_FactsPage(40), " "); }
        n = StringToInt(parts[2], 0);
        for(i = 0; i < n; i += 1) { W3T_Log(label + " FACT " + parts[3 + i * 2] + "=" + parts[4 + i * 2]); }
    }
    W3T_Log(label + " FACT_PAGES=" + pages);
}

function W3T_ProbeNoteUsable(note : ErrandDetailsList) : bool
{
    return note.errandPosition > 0 && !note.displayAsFluff && note.newQuestFact != "" && note.newQuestFact != "flaw"
        && !FactsDoesExist(note.newQuestFact)
        && (note.forbiddenFact == "" || !FactsDoesExist(note.forbiddenFact))
        && (note.requiredFact == "" || FactsDoesExist(note.requiredFact));
}

function W3T_QuestProbe(bot : W3T_Bot) : bool
{
    var entities : array<CGameplayEntity>;
    var board : W3NoticeBoard;
    var before, after, viaFactsSet : array<string>;
    var campaign : r_SeamlessCampaign;
    var i, j : int;
    var now : float;
    campaign = theGame.r_getMultiplayerClient().getSeamlessCampaign();
    now = bot.ElapsedS();
    if(bot.scenarioStep < 0) { return false; }
    if(W3T_GetEnv("W3T_ROLE") == "mover")
    {
        if(bot.scenarioStep == 0)
        {
            W3T_Log("PROBE host baseline=" + WO_FactsBaseline() + " world=" + theGame.GetWorld().GetDepotPath()
                + " area=" + NameToString(theGame.GetCommonMapManager().GetCurrentArea()) + " pos=" + W3T_VecStr(thePlayer.GetWorldPosition()));
            bot.scenarioTime = now;
            bot.scenarioStep = 1;
            return false;
        }
        if(bot.scenarioStep == 1 && now - bot.scenarioTime > 40)
        {
            W3T_DumpFactDiff("HOST");
            bot.scenarioStep = 2;
        }
        return bot.scenarioStep == 2;
    }
    if(bot.scenarioStep == 0)
    {
        W3T_Log("PROBE world=" + theGame.GetWorld().GetDepotPath() + " area=" + NameToString(theGame.GetCommonMapManager().GetCurrentArea())
            + " pos=" + W3T_VecStr(thePlayer.GetWorldPosition()));
        FindGameplayEntitiesInRange(entities, thePlayer, 3000, 64, , , , 'W3NoticeBoard');
        for(i = 0; i < entities.Size(); i += 1)
        {
            board = (W3NoticeBoard)entities[i];
            if(!board) { continue; }
            W3T_Log("BOARD " + i + " name=" + board.GetReadableName() + " pos=" + W3T_VecStr(board.GetWorldPosition())
                + " dist=" + VecDistance(board.GetWorldPosition(), thePlayer.GetWorldPosition()) + " notes=" + board.addedNotes.Size());
            for(j = 0; j < board.addedNotes.Size(); j += 1)
            {
                W3T_Log("NOTE board=" + i + " key=" + board.addedNotes[j].errandStringKey + " fact=" + board.addedNotes[j].newQuestFact
                    + " required=" + board.addedNotes[j].requiredFact + " forbidden=" + board.addedNotes[j].forbiddenFact
                    + " item=" + NameToString(board.addedNotes[j].addedItemName) + " position=" + board.addedNotes[j].errandPosition
                    + " fluff=" + board.addedNotes[j].displayAsFluff + " usable=" + W3T_ProbeNoteUsable(board.addedNotes[j]));
                if(bot.qpNote == "" && W3T_ProbeNoteUsable(board.addedNotes[j]))
                {
                    bot.scenarioEntity = board;
                    bot.qpNote = board.addedNotes[j].errandStringKey;
                    bot.qpQuestFact = board.addedNotes[j].newQuestFact;
                }
            }
        }
        if(bot.qpNote == "") { W3T_Log("PROBE NO_USABLE_NOTE boards=" + entities.Size()); bot.scenarioStep = -1; return false; }
        W3T_Log("PROBE chosen note=" + bot.qpNote + " questFact=" + bot.qpQuestFact + " controlBaseline=" + WO_FactsBaseline());
        bot.scenarioTime = now;
        bot.scenarioStep = 1;
    }
    else if(bot.scenarioStep == 1 && now - bot.scenarioTime > 10)
    {
        W3T_DumpFactDiff("CONTROL");
        bot.qpQuests = W3T_ActiveQuestTags();
        W3T_Log("PROBE questBaseline=" + WO_FactsBaseline() + " activeQuests=" + bot.qpQuests.Size());
        campaign.BeginFactsSetProbe();
        board = (W3NoticeBoard)bot.scenarioEntity;
        W3T_Log("PROBE accept=" + board.AcceptNewQuest(bot.qpNote) + " questFactExists=" + FactsDoesExist(bot.qpQuestFact));
        bot.scenarioTime = now;
        bot.scenarioStep = 2;
    }
    else if(bot.scenarioStep == 2 && now - bot.scenarioTime > 15)
    {
        W3T_DumpFactDiff("QUEST");
        viaFactsSet = campaign.EndFactsSetProbe();
        for(i = 0; i < viaFactsSet.Size(); i += 1) { W3T_Log("QUEST VIA_FACTSSET " + viaFactsSet[i]); }
        after = W3T_ActiveQuestTags();
        for(i = 0; i < after.Size(); i += 1)
        {
            if(!bot.qpQuests.Contains(after[i])) { W3T_Log("QUEST JOURNAL_ACTIVATED " + after[i]); }
        }
        W3T_Log("PROBE done viaFactsSet=" + viaFactsSet.Size() + " activeQuests=" + after.Size());
        bot.scenarioStep = 3;
    }
    return bot.scenarioStep == 3;
}

// First real side quest replicated second PC -> host: "Novigrad Hunt: Da'o" (mh306).
// The guest owns quest scope quest_mh306, watches mh306_job_taken through the whole-DB
// snapshot tracker and takes the real notice exactly as the board menu does. The host
// has moved ~590 m away first. Pass on the host requires the fact AND the journal entry
// its own quest graph activates from it; the host never touches a notice board.
function W3T_QuestIsActive(guid : string) : bool
{
    var tags : array<string>;
    var i : int;
    tags = W3T_ActiveQuestTags();
    for(i = 0; i < tags.Size(); i += 1)
    {
        if(StrFindFirst(tags[i], guid) >= 0) { return true; }
    }
    return false;
}

function W3T_FindNotice(key : string) : W3NoticeBoard
{
    var entities : array<CGameplayEntity>;
    var board : W3NoticeBoard;
    var i, j : int;
    FindGameplayEntitiesInRange(entities, thePlayer, 3000, 64, , , , 'W3NoticeBoard');
    for(i = 0; i < entities.Size(); i += 1)
    {
        board = (W3NoticeBoard)entities[i];
        if(!board) { continue; }
        for(j = 0; j < board.addedNotes.Size(); j += 1)
        {
            if(board.addedNotes[j].errandStringKey == key && W3T_ProbeNoteUsable(board.addedNotes[j])) { return board; }
        }
    }
    return NULL;
}

function W3T_QuestMh306(bot : W3T_Bot) : bool
{
    var campaign : r_SeamlessCampaign;
    var board : W3NoticeBoard;
    var guid : string;
    campaign = theGame.r_getMultiplayerClient().getSeamlessCampaign();
    guid = "AF164E2C-41CC196D-1AB4BFB6-1DAA9A91";
    W3T_Log("MH306 stage=" + bot.scenarioStep + " status=" + campaign.GetStatus() + " fact=" + FactsDoesExist("mh306_job_taken")
        + "/" + FactsQuerySum("mh306_job_taken") + " journal=" + W3T_QuestIsActive(guid) + " commits=" + campaign.GetCaptureCommits()
        + " applied=" + campaign.GetAppliedCount() + " tx=" + campaign.GetTransactionCount() + " cursor=" + campaign.GetCursor() + "/" + campaign.GetLatest()
        + " pos=" + W3T_VecStr(thePlayer.GetWorldPosition()));
    if(bot.scenarioStep < 0 || !campaign.IsReady()) { return false; }
    if(W3T_GetEnv("W3T_ROLE") == "mover")
    {
        if(bot.scenarioStep == 0)
        {
            // Preconditions: the quest has not started here. Then move away from the guest.
            if(FactsDoesExist("mh306_job_taken") || W3T_QuestIsActive(guid)) { W3T_Log("MH306 host precondition failed"); bot.scenarioStep = -1; return false; }
            W3T_Log("MH306 host baseline=" + WO_FactsBaseline());
            thePlayer.Teleport(Vector(1123.5, 2378.8, 4.5));
            bot.scenarioStep = 1;
            return false;
        }
        if(bot.scenarioStep == 1 && FactsQuerySum("mh306_job_taken") == 1 && W3T_QuestIsActive(guid))
        {
            W3T_Log("MH306 host distance=" + VecDistance(thePlayer.GetWorldPosition(), Vector(582.98, 2140.82, 33.56)));
            W3T_DumpFactDiff("HOST");
            bot.scenarioStep = 2;
        }
        return bot.scenarioStep == 2 && campaign.GetAppliedCount() == 1 && campaign.GetCursor() == campaign.GetLatest();
    }
    if(bot.scenarioStep == 0)
    {
        if(FactsDoesExist("mh306_job_taken") || W3T_QuestIsActive(guid)) { W3T_Log("MH306 guest precondition failed"); bot.scenarioStep = -1; return false; }
        if(campaign.OpenConversation("quest_mh306", "quest", "mh306")) { bot.scenarioStep = 1; }
    }
    else if(bot.scenarioStep == 1 && campaign.OwnsConversation() && campaign.GetLease() != "")
    {
        board = W3T_FindNotice("item_name_mh306_contract");
        if(!board || !campaign.WatchSnapshotFact("mh306_job_taken")) { W3T_Log("MH306 guest setup failed: no usable mh306 notice or watch refused"); bot.scenarioStep = -1; return false; }
        W3T_Log("MH306 guest takes notice accept=" + board.AcceptNewQuest("item_name_mh306_contract"));
        bot.scenarioStep = 2;
    }
    // applied == 0: the guest's own snapshot echo is skipped, not re-applied.
    return bot.scenarioStep == 2 && campaign.GetCaptureCommits() == 1 && FactsQuerySum("mh306_job_taken") == 1
        && W3T_QuestIsActive(guid) && campaign.GetAppliedCount() == 0 && campaign.GetCursor() == campaign.GetLatest();
}

// Shared progress survives a host load. The second PC starts "Novigrad Hunt: Da'o" as in
// seamless_quest_mh306; once the host has it, the host loads the run's save again, which
// predates the quest. The adapter must replay the ledger onto the loaded world: the fact
// returns, the host's quest graph re-activates the journal entry, and applied == 2 (the
// live apply plus the replay) shows it came from the ledger rather than the save.
function W3T_LoadRunSave() : bool
{
    var saves : array<SSavegameInfo>;
    var wanted : string;
    var i : int;
    wanted = W3T_GetEnv("W3T_SAVE");
    theGame.ListSavedGames(saves);
    for(i = 0; i < saves.Size(); i += 1)
    {
        if(wanted != "" && StrFindFirst(saves[i].filename, wanted) >= 0)
        {
            W3T_Log("RELOAD loading " + saves[i].filename);
            theGame.LoadGameInit(saves[i], false);
            return true;
        }
    }
    return false;
}

function W3T_ReloadMh306(bot : W3T_Bot) : bool
{
    var campaign : r_SeamlessCampaign;
    var guid : string;
    if(W3T_GetEnv("W3T_ROLE") != "mover") { return W3T_QuestMh306(bot); }
    campaign = theGame.r_getMultiplayerClient().getSeamlessCampaign();
    guid = "AF164E2C-41CC196D-1AB4BFB6-1DAA9A91";
    W3T_Log("RELOAD stage=" + bot.scenarioStep + " status=" + campaign.GetStatus() + " loads=" + campaign.GetLoadCount()
        + " fact=" + FactsDoesExist("mh306_job_taken") + "/" + FactsQuerySum("mh306_job_taken") + " journal=" + W3T_QuestIsActive(guid)
        + " applied=" + campaign.GetAppliedCount() + " cursor=" + campaign.GetCursor() + "/" + campaign.GetLatest());
    if(bot.scenarioStep < 0) { return false; }
    if(bot.scenarioStep == 0)
    {
        if(!campaign.IsReady()) { return false; }
        if(FactsDoesExist("mh306_job_taken") || W3T_QuestIsActive(guid)) { W3T_Log("RELOAD host precondition failed"); bot.scenarioStep = -1; return false; }
        bot.scenarioStep = 1;
    }
    else if(bot.scenarioStep == 1 && FactsQuerySum("mh306_job_taken") == 1 && W3T_QuestIsActive(guid) && campaign.GetAppliedCount() == 1)
    {
        W3T_Log("RELOAD quest replicated before the load; loading the older save now");
        bot.scenarioStep = 2;
        if(!W3T_LoadRunSave()) { W3T_Log("RELOAD no save matches W3T_SAVE"); bot.scenarioStep = -1; }
    }
    return bot.scenarioStep == 2 && campaign.IsReady() && campaign.GetLoadCount() == 1 && campaign.GetAppliedCount() == 2
        && FactsQuerySum("mh306_job_taken") == 1 && W3T_QuestIsActive(guid) && campaign.GetCursor() == campaign.GetLatest();
}

// Research probe for nearby NPC sync. Both games list every living NPC within 60 m every
// 5 s; tools/npc_probe_report.py pairs the two logs by wall-clock time and measures how many
// NPCs exist in both worlds, whether they can be matched (voicetag, template, appearance),
// and how far apart and how differently they behave. Nothing is synced.
function W3T_NpcTags(npc : CNewNPC) : string
{
    var tags : array<name>;
    var text : string;
    var i : int;
    tags = npc.GetTags();
    for(i = 0; i < tags.Size(); i += 1)
    {
        if(i > 0) { text += "|"; }
        text += NameToString(tags[i]);
    }
    if(text == "") { text = "-"; }
    return text;
}

function W3T_NpcProbe(bot : W3T_Bot) : bool
{
    var actors : array<CActor>;
    var npc : CNewNPC;
    var now : float;
    var i, n : int;
    now = bot.ElapsedS();
    if(bot.scenarioStep == 0) { bot.scenarioTime = now; bot.scenarioStep = 1; return false; }
    if(bot.scenarioStep >= 1 && bot.scenarioStep <= 9 && now - bot.scenarioTime >= 5 * bot.scenarioStep)
    {
        actors = thePlayer.GetNPCsAndPlayersInRange(60, 300, '', FLAG_ExcludePlayer + FLAG_OnlyAliveActors);
        n = 0;
        for(i = 0; i < actors.Size(); i += 1)
        {
            npc = (CNewNPC)actors[i];
            if(!npc || npc.HasTag('MPEntity')) { continue; }
            n += 1;
            W3T_Log("NPC sample=" + bot.scenarioStep + " voice=" + NameToString(npc.GetVoicetag()) + " tpl=" + npc.GetReadableName()
                + " app=" + NameToString(npc.GetAppearance()) + " tags=" + W3T_NpcTags(npc)
                + " pos=" + W3T_VecStr(npc.GetWorldPosition()) + " yaw=" + FloatToStringPrec(npc.GetHeading(), 1)
                + " action=" + (int)npc.GetCurrentActionType() + " work=" + npc.IsAtWork() + " sit=" + npc.IsSittingAtWork()
                + " combat=" + npc.IsInCombat() + " horse=" + npc.IsHorse());
        }
        W3T_Log("NPCSAMPLE sample=" + bot.scenarioStep + " count=" + n + " player=" + W3T_VecStr(thePlayer.GetWorldPosition()));
        bot.scenarioStep += 1;
    }
    return bot.scenarioStep == 10;
}

// Nearby NPC sync prototype: the member joins the leader's party; the leader's game owns the
// non-hostile NPCs around both and the member's copies follow them. Logs everything needed to
// judge it (matches, NPCs without a copy, puppet offsets, lost work state); passes on a
// sustained, converged sync, and the logs say how good it actually looked.
// Where this world's Ciri stands and faces, for comparing both screens over time.
function W3T_CiriState() : string
{
    var actors : array<CActor>;
    var npc : CNewNPC;
    var i : int;
    actors = thePlayer.GetNPCsAndPlayersInRange(60, 64, '', FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
    for(i = 0; i < actors.Size(); i += 1)
    {
        npc = (CNewNPC)actors[i];
        if(npc && !npc.HasTag('w3coop_npc_copy') && NpcVoice(npc) == "CIRILLA")
        {
            return W3T_VecStr(npc.GetWorldPosition()) + " yaw=" + FloatToStringPrec(npc.GetHeading(), 0);
        }
    }
    return "none";
}

function W3T_NpcSyncLeader(bot : W3T_Bot, client : r_MultiplayerClient) : bool
{
    var npcs : r_CoopNpcs;
    npcs = client.getCoopNpcs();
    W3T_Log("CIRI host local=" + W3T_CiriState());
    W3T_Log("NPCSYNC host role=" + client.getCoopEnemies().GetRole() + " hosted=" + npcs.HostedCount() + " sent=" + npcs.snapshotsSent);
    return client.getCoopEnemies().GetRole() == 1 && npcs.HostedCount() > 0 && npcs.snapshotsSent >= 150;
}

function W3T_NpcSyncMember(bot : W3T_Bot, client : r_MultiplayerClient, leader : r_RemotePlayer) : bool
{
    var npcs : r_CoopNpcs;
    var lines : array<string>;
    var mean, worst : float;
    var i : int;
    if(!client.getInParty())
    {
        W3T_Log("PARTY join " + leader.username);
        client.joinParty(leader.username);
        return false;
    }
    npcs = client.getCoopNpcs();
    npcs.PuppetError(mean, worst);
    W3T_Log("CIRI member " + npcs.DescribeVoice("CIRILLA") + " local=" + W3T_CiriState());
    W3T_Log("NPCSYNC member applied=" + npcs.snapshotsApplied + " leaderList=" + npcs.lastSnapshotCount + " puppets=" + npcs.PuppetCount()
        + " byVoice=" + npcs.matchedByVoice + " byTemplate=" + npcs.matchedByTemplate + " standIns=" + npcs.SpawnedCount()
        + " displays=" + npcs.DisplayCount() + " owned=" + npcs.OwnedCount() + " hidden=" + npcs.HiddenCount() + " overCap=" + npcs.overCap
        + " takeovers=" + npcs.takeovers + " handbacks=" + npcs.handbacks + " worstSnapBack=" + FloatToStringPrec(npcs.worstSnapBack, 2) + " noCopyHere=" + npcs.UnmatchedCount()
        + " offMean=" + FloatToStringPrec(mean, 2) + " offWorst=" + FloatToStringPrec(worst, 2));
    if(npcs.snapshotsApplied >= 150 && bot.scenarioStep == 0)
    {
        lines = npcs.Describe();
        for(i = 0; i < lines.Size(); i += 1) { W3T_Log("NPCPUPPET " + lines[i]); }
        bot.scenarioStep = 1;
    }
    return bot.scenarioStep == 1 && npcs.PuppetCount() >= 8 && mean < 1.0 && worst < 4.0;
}

// Per-NPC ownership: the leader steps back from Ciri, the member walks up to her (as shown on
// its screen), stays, then walks off. While the member is near, its world should own her: its
// own Ciri shown, reacting on her own AI, and the leader showing a stand-in that mirrors her.
// Logs both worlds' Ciri (shown and real, animation speed vs actual movement, to catch running
// in place) for npc_own_report.py.
function W3T_CiriLine(npcs : r_CoopNpcs) : string
{
    var shown : CNewNPC;
    var text : string;
    shown = npcs.ShownByVoice("CIRILLA");
    text = npcs.DescribeVoice("CIRILLA") + " visible=" + npcs.VisibleCount("CIRILLA") + " real=" + W3T_CiriState() + " player=" + W3T_VecStr(thePlayer.GetWorldPosition());
    if(shown)
    {
        text += " shownAt=" + W3T_VecStr(shown.GetWorldPosition()) + " anim=" + FloatToStringPrec(shown.GetMovingAgentComponent().GetRelativeMoveSpeed(), 2)
            + " dist=" + FloatToStringPrec(VecDistance(shown.GetWorldPosition(), thePlayer.GetWorldPosition()), 1)
            + " standIn=" + shown.HasTag('w3coop_npc_copy');
    }
    return text;
}

// A spot `range` metres from `from`, away from `center` (or behind `from` when they coincide).
function W3T_AwayFrom(center : Vector, from : Vector, range : float) : Vector
{
    var dir : Vector;
    dir = from - center;
    dir.Z = 0;
    if(VecLength(dir) < 0.5) { dir = VecFromHeading(thePlayer.GetHeading() + 180); }
    return center + VecNormalize(dir) * range;
}

// A reachable spot about `range` metres from `from` that is at least 0.7 * range from `center`:
// straight away from it first, then fanning out. Falls back to the straight line.
function W3T_ReachableAway(center : Vector, from : Vector, range : float) : Vector
{
    var spot, safe : Vector;
    var heading : float;
    var i : int;
    heading = VecHeading(from - center);
    for(i = 0; i < 16; i += 1)
    {
        spot = from + VecFromHeading(heading + ((i + 1) / 2) * 22.5 * (1 - 2 * (i % 2))) * range;
        if(theGame.GetWorld().NavigationFindSafeSpot(spot, 0.5, 3.0, safe) && theGame.GetWorld().NavigationLineTest(from, safe, 0.5)
            && VecDistance(safe, center) >= 0.7 * range)
        {
            return safe;
        }
    }
    return W3T_AwayFrom(center, from, range);
}

function W3T_GlideLine(npcs : r_CoopNpcs) : string
{
    var ref : string;
    if(npcs.refFrames > 0)
    {
        ref = " refFrames=" + npcs.refFrames + " refStallPct=" + FloatToStringPrec(100.0 * npcs.refStalls / npcs.refFrames, 1)
            + " refJerk=" + FloatToStringPrec(npcs.refJerk / npcs.refFrames, 3);
    }
    if(npcs.glideFrames == 0) { return " glideFrames=0" + ref; }
    return ref + " glideFrames=" + npcs.glideFrames + " stallPct=" + FloatToStringPrec(100.0 * npcs.glideStalls / npcs.glideFrames, 1)
        + " jerk=" + FloatToStringPrec(npcs.glideJerk / npcs.glideFrames, 3) + " jumps=" + npcs.glideJumps;
}

function W3T_NpcOwnLeader(bot : W3T_Bot, client : r_MultiplayerClient) : bool
{
    var npcs : r_CoopNpcs;
    var lines : array<string>;
    var i : int;
    var ciri : CNewNPC;
    var now : float;
    npcs = client.getCoopNpcs();
    now = bot.ElapsedS();
    ciri = npcs.ShownByVoice("CIRILLA");
    if(bot.scenarioStep == 0 && ciri && client.getCoopEnemies().GetRole() == 1)
    {
        thePlayer.ActionMoveToAsync(W3T_AwayFrom(ciri.GetWorldPosition(), thePlayer.GetWorldPosition(), 14), MT_Run);
        W3T_Log("OWN host stepping back from Ciri");
        bot.scenarioStep = 1;
    }
    if(bot.scenarioStep == 1 && npcs.ownershipTaken >= 1 && npcs.MemberOwnedCount() == 0)
    {
        bot.scenarioStep = 2;
        bot.scenarioTime = now;
    }
    W3T_Log("CIRI host " + W3T_CiriLine(npcs));
    W3T_Log("NPCSYNC host role=" + client.getCoopEnemies().GetRole() + " hosted=" + npcs.HostedCount() + " sent=" + npcs.snapshotsSent
        + " streams=" + npcs.streamsApplied + " given=" + npcs.ownershipGiven + " taken=" + npcs.ownershipTaken
        + " memberOwned=" + npcs.MemberOwnedCount() + " displays=" + npcs.DisplayCount() + " overCap=" + npcs.overCap + W3T_GlideLine(npcs));
    if(bot.scenarioStep == 2 && now - bot.scenarioTime >= 12)
    {
        lines = npcs.DescribeHosted();
        for(i = 0; i < lines.Size(); i += 1) { W3T_Log("NPCHOSTED " + lines[i]); }
        bot.scenarioStep = 3;
    }
    return bot.scenarioStep == 3 && npcs.ownershipGiven >= 1;
}

function W3T_NpcOwnMember(bot : W3T_Bot, client : r_MultiplayerClient, leader : r_RemotePlayer) : bool
{
    var npcs : r_CoopNpcs;
    var lines : array<string>;
    var i : int;
    var ciri : CNewNPC;
    var spot : Vector;
    var now : float;
    if(!client.getInParty())
    {
        W3T_Log("PARTY join " + leader.username);
        client.joinParty(leader.username);
        return false;
    }
    npcs = client.getCoopNpcs();
    now = bot.ElapsedS();
    ciri = npcs.ShownByVoice("CIRILLA");
    if(bot.scenarioStep == 0)
    {
        bot.scenarioStep = 1;
        bot.scenarioTime = now;
    }
    if(bot.scenarioStep == 1 && now - bot.scenarioTime >= 15 && ciri)
    {
        W3T_Log("OWN member walking up to Ciri");
        bot.scenarioStep = 2;
        bot.scenarioTime = now;
        bot.scenarioVec = Vector(0, 0, 0);
    }
    if(bot.scenarioStep == 2 && ciri)
    {
        if(VecDistance(ciri.GetWorldPosition(), thePlayer.GetWorldPosition()) > 2.5 && VecDistance(ciri.GetWorldPosition(), bot.scenarioVec) > 1.0)
        {
            spot = W3T_AwayFrom(ciri.GetWorldPosition(), thePlayer.GetWorldPosition(), 1.5);
            thePlayer.ActionMoveToAsync(spot, MT_Walk);
            bot.scenarioVec = ciri.GetWorldPosition();
        }
        if(now - bot.scenarioTime >= 25)
        {
            W3T_Log("OWN member walking away from Ciri");
            thePlayer.ActionMoveToAsync(W3T_ReachableAway(ciri.GetWorldPosition(), thePlayer.GetWorldPosition(), 14), MT_Run);
            bot.scenarioStep = 3;
            bot.scenarioTime = now;
            bot.scenarioVec = thePlayer.GetWorldPosition();
        }
    }
    if(bot.scenarioStep == 3 && ciri && VecDistance(ciri.GetWorldPosition(), thePlayer.GetWorldPosition()) < 8
        && VecDistance(thePlayer.GetWorldPosition(), bot.scenarioVec) < 0.5 && now - bot.scenarioTime >= 4 && now - bot.scenarioTime < 20)
    {
        // Blocked (or she followed): try another way out.
        W3T_Log("OWN member still near Ciri, trying another way");
        thePlayer.ActionMoveToAsync(W3T_ReachableAway(ciri.GetWorldPosition(), thePlayer.GetWorldPosition(), 14), MT_Run);
    }
    if(bot.scenarioStep == 3) { bot.scenarioVec = thePlayer.GetWorldPosition(); }
    W3T_Log("CIRI member " + W3T_CiriLine(npcs));
    W3T_Log("NPCSYNC member applied=" + npcs.snapshotsApplied + " leaderList=" + npcs.lastSnapshotCount + " puppets=" + npcs.PuppetCount()
        + " byVoice=" + npcs.matchedByVoice + " byTemplate=" + npcs.matchedByTemplate + " standIns=" + npcs.SpawnedCount()
        + " displays=" + npcs.DisplayCount() + " owned=" + npcs.OwnedCount() + " gained=" + npcs.ownedGained + " lost=" + npcs.ownedLost
        + " streamsSent=" + npcs.streamsSent + " takeovers=" + npcs.takeovers + " handbacks=" + npcs.handbacks
        + " worstSnapBack=" + FloatToStringPrec(npcs.worstSnapBack, 2) + " worstSwapPop=" + FloatToStringPrec(npcs.worstSwapPop, 2) + " overCap=" + npcs.overCap + W3T_GlideLine(npcs));
    if(bot.scenarioStep == 3 && now - bot.scenarioTime >= 20)
    {
        lines = npcs.Describe();
        for(i = 0; i < lines.Size(); i += 1) { W3T_Log("NPCPUPPET " + lines[i]); }
        bot.scenarioStep = 4;
    }
    return bot.scenarioStep == 4 && npcs.ownedGained >= 1 && npcs.ownedLost >= 1;
}

// Shared quest progress in a party, second PC -> host (quest_share). The second PC takes three
// real notice-board contracts (each a native FactsAdd its quest graph waits on), activates an
// objective of an active quest; once its quests settle it reports how many it gained in
// w3t_share_member (10 + count). The host never touches a board: its own quest graphs must
// activate the same number of quests from the replicated facts (not every notice starts one:
// card-game notices only mark a player as discovered), and the objective must arrive through
// the journal list. Then the host sets a fact the other way.
// Both sides finally check the applied counters stay put (no fact or journal ping-pong).
// Both bots pick the same notices: the first three usable ones by key.
function W3T_ShareNotes(bot : W3T_Bot)
{
    var entities : array<CGameplayEntity>;
    var board : W3NoticeBoard;
    var keys, facts : array<string>;
    var best, i, j : int;
    FindGameplayEntitiesInRange(entities, thePlayer, 3000, 64, , , , 'W3NoticeBoard');
    for(i = 0; i < entities.Size(); i += 1)
    {
        board = (W3NoticeBoard)entities[i];
        if(!board) { continue; }
        for(j = 0; j < board.addedNotes.Size(); j += 1)
        {
            if(W3T_ProbeNoteUsable(board.addedNotes[j]) && !facts.Contains(board.addedNotes[j].newQuestFact))
            {
                keys.PushBack(board.addedNotes[j].errandStringKey);
                facts.PushBack(board.addedNotes[j].newQuestFact);
            }
        }
    }
    bot.qpKeys.Clear();
    bot.qpFacts.Clear();
    while(bot.qpKeys.Size() < 3 && keys.Size() > 0)
    {
        best = 0;
        for(i = 1; i < keys.Size(); i += 1) { if(StrCmp(keys[i], keys[best]) < 0) { best = i; } }
        bot.qpKeys.PushBack(keys[best]);
        bot.qpFacts.PushBack(facts[best]);
        keys.Erase(best);
        facts.Erase(best);
    }
}

function W3T_ShareFactsLine(bot : W3T_Bot) : string
{
    var text : string;
    var i : int;
    for(i = 0; i < bot.qpFacts.Size(); i += 1) { text += " " + bot.qpFacts[i] + "=" + FactsQuerySum(bot.qpFacts[i]); }
    return text;
}

function W3T_NewActiveQuests(bot : W3T_Bot) : int
{
    var now : array<string>;
    var i, n : int;
    now = W3T_ActiveQuestTags();
    for(i = 0; i < now.Size(); i += 1) { if(!bot.qpQuests.Contains(now[i])) { n += 1; } }
    return n;
}

function W3T_LogNewQuests(bot : W3T_Bot, label : string)
{
    var now : array<string>;
    var i : int;
    now = W3T_ActiveQuestTags();
    for(i = 0; i < now.Size(); i += 1) { if(!bot.qpQuests.Contains(now[i])) { W3T_Log(label + " new quest " + now[i]); } }
}

function W3T_QuestShareLeader(bot : W3T_Bot, coop : r_CoopEnemies) : bool
{
    var now : float;
    var i, done : int;
    now = bot.ElapsedS();
    if(bot.scenarioStep < 0) { return false; }
    if(bot.scenarioStep == 0)
    {
        if(!coop.FactsReady() || coop.GetRole() != 1) { return false; }
        bot.qpQuests = W3T_ActiveQuestTags();
        W3T_ShareNotes(bot);
        for(i = 0; i < bot.qpKeys.Size(); i += 1) { W3T_Log("SHARE host expects note=" + bot.qpKeys[i] + " fact=" + bot.qpFacts[i]); }
        if(bot.qpKeys.Size() < 3) { W3T_Log("SHARE host precondition failed: " + bot.qpKeys.Size() + " usable notes"); bot.scenarioStep = -1; return false; }
        bot.scenarioStep = 1;
    }
    W3T_Log("SHARE host step=" + bot.scenarioStep + W3T_ShareFactsLine(bot) + " member=" + FactsQuerySum("w3t_share_member")
        + " newQuests=" + W3T_NewActiveQuests(bot) + " journalApplied=" + coop.journalApplied + " last=" + NameToString(coop.lastJournalApplied)
        + " status=" + coop.JournalStatusOf(coop.lastJournalApplied) + " factsApplied=" + coop.factsApplied + " lists=" + coop.journalMessages);
    if(bot.scenarioStep == 1)
    {
        for(i = 0; i < bot.qpFacts.Size(); i += 1) { if(FactsQuerySum(bot.qpFacts[i]) == 1) { done += 1; } }
        if(done == 3 && FactsQuerySum("w3t_share_member") >= 10 && W3T_NewActiveQuests(bot) == FactsQuerySum("w3t_share_member") - 10
            && coop.journalApplied >= 1
            && coop.JournalStatusOf(coop.lastJournalApplied) == coop.lastJournalAppliedStatus)
        {
            W3T_LogNewQuests(bot, "SHARE host");
            W3T_Log("SHARE host has the second PC's progress; setting w3t_share_host the other way");
            W3T_DumpFactDiff("HOSTDIFF");
            FactsAdd("w3t_share_host", 7);
            bot.scenarioTime = now;
            bot.scenarioStep = 2;
        }
    }
    else if(bot.scenarioStep == 2 && now - bot.scenarioTime >= 10)
    {
        bot.qpApplied = coop.factsApplied + coop.journalApplied;
        bot.scenarioTime = now;
        bot.scenarioStep = 3;
    }
    else if(bot.scenarioStep == 3 && now - bot.scenarioTime >= 8)
    {
        if(coop.factsApplied + coop.journalApplied != bot.qpApplied) { W3T_Log("SHARE host FAIL applies kept going (echo loop)"); bot.scenarioStep = -1; return false; }
        bot.scenarioStep = 4;
    }
    return bot.scenarioStep == 4;
}

// The first inactive objective of an active quest, activated as a quest graph would.
function W3T_ActivateSomeObjective() : name
{
    var manager : CWitcherJournalManager;
    var quests, phases, objectives : array<CJournalBase>;
    var none : name;
    var i, j, k : int;
    manager = theGame.GetJournalManager();
    manager.GetActivatedOfType('CJournalQuest', quests);
    for(i = 0; i < quests.Size(); i += 1)
    {
        if(manager.GetEntryStatus(quests[i]) != JS_Active) { continue; }
        phases.Clear();
        manager.GetAllChildren(quests[i], phases);
        for(j = 0; j < phases.Size(); j += 1)
        {
            objectives.Clear();
            manager.GetAllChildren(phases[j], objectives);
            for(k = 0; k < objectives.Size(); k += 1)
            {
                if((CJournalQuestObjective)objectives[k] && manager.GetEntryStatus(objectives[k]) == JS_Inactive && IsNameValid(objectives[k].GetUniqueScriptTag()))
                {
                    manager.ActivateEntry(objectives[k], JS_Active, true, true);
                    return objectives[k].GetUniqueScriptTag();
                }
            }
        }
    }
    return none;
}

function W3T_QuestShareMember(bot : W3T_Bot, client : r_MultiplayerClient, coop : r_CoopEnemies, leader : r_RemotePlayer) : bool
{
    var board : W3NoticeBoard;
    var objective : name;
    var now : float;
    var i : int;
    if(!client.getInParty())
    {
        W3T_Log("PARTY join " + leader.username);
        client.joinParty(leader.username);
        return false;
    }
    now = bot.ElapsedS();
    if(bot.scenarioStep < 0) { return false; }
    if(bot.scenarioStep == 0)
    {
        if(!coop.FactsReady() || coop.GetRole() != 2) { return false; }
        bot.qpQuests = W3T_ActiveQuestTags();
        W3T_ShareNotes(bot);
        if(bot.qpKeys.Size() < 3) { W3T_Log("SHARE member precondition failed: " + bot.qpKeys.Size() + " usable notes"); bot.scenarioStep = -1; return false; }
        bot.scenarioTime = now;
        bot.scenarioStep = 1;
    }
    else if(bot.scenarioStep == 1 && now - bot.scenarioTime >= 8)
    {
        for(i = 0; i < bot.qpKeys.Size(); i += 1)
        {
            board = W3T_FindNotice(bot.qpKeys[i]);
            if(!board) { W3T_Log("SHARE member FAIL notice gone " + bot.qpKeys[i]); bot.scenarioStep = -1; return false; }
            W3T_Log("SHARE member takes note=" + bot.qpKeys[i] + " fact=" + bot.qpFacts[i] + " accept=" + board.AcceptNewQuest(bot.qpKeys[i]));
        }
        objective = W3T_ActivateSomeObjective();
        W3T_Log("SHARE member activated objective " + NameToString(objective));
        bot.scenarioTime = now;
        bot.scenarioStep = 2;
    }
    else if(bot.scenarioStep == 2 && now - bot.scenarioTime >= 6 && FactsQuerySum("w3t_share_member") == 0)
    {
        W3T_LogNewQuests(bot, "SHARE member");
        FactsAdd("w3t_share_member", 10 + W3T_NewActiveQuests(bot));
    }
    W3T_Log("SHARE member step=" + bot.scenarioStep + W3T_ShareFactsLine(bot) + " host=" + FactsQuerySum("w3t_share_host")
        + " newQuests=" + W3T_NewActiveQuests(bot) + " factsApplied=" + coop.factsApplied + " journalApplied=" + coop.journalApplied);
    if(bot.scenarioStep == 2 && FactsQuerySum("w3t_share_host") == 7 && FactsQuerySum("w3t_share_member") >= 10)
    {
        bot.scenarioTime = now;
        bot.scenarioStep = 3;
    }
    else if(bot.scenarioStep == 3 && now - bot.scenarioTime >= 5)
    {
        bot.qpApplied = coop.factsApplied + coop.journalApplied;
        bot.scenarioTime = now;
        bot.scenarioStep = 4;
    }
    else if(bot.scenarioStep == 4 && now - bot.scenarioTime >= 8)
    {
        if(coop.factsApplied + coop.journalApplied != bot.qpApplied) { W3T_Log("SHARE member FAIL applies kept going (echo loop)"); bot.scenarioStep = -1; return false; }
        W3T_DumpFactDiff("MEMBERDIFF");
        bot.scenarioStep = 5;
    }
    return bot.scenarioStep == 5;
}

// Conversation probe (talk_probe). Can one game start the conversation an NPC offers the way
// the Talk button does (CNewNPC.PlayDialog), and does the other game get the same scene when it
// does the same with its own copy, also from farther away? Both bots list the talkable NPCs
// near them and pick the same one (unique voicetag, first by name). The second PC starts the
// conversation; the host starts its own 4 s later. Each logs its scene, lines and choices, and
// takes the first choice 3 s after it appears.
function W3T_HasTalk(npc : CNewNPC) : bool
{
    if(npc.GetComponent('talk')) { return true; }
    return false;
}

// Talk offered: an interaction scene, or an enabled talk component (community and quest NPCs).
function W3T_Talkable(npc : CNewNPC) : bool
{
    return npc.HasInteractionScene() || (npc.GetComponent('talk') && npc.GetComponent('talk').IsEnabled());
}

function W3T_TalkTarget() : CNewNPC
{
    var actors : array<CActor>;
    var npc, best : CNewNPC;
    var voices : array<string>;
    var i : int;
    actors = thePlayer.GetNPCsAndPlayersInRange(100, 200, '', FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
    for(i = 0; i < actors.Size(); i += 1)
    {
        npc = (CNewNPC)actors[i];
        if(npc && !npc.HasTag('w3coop_npc_copy') && NpcVoice(npc) != "") { voices.PushBack(NpcVoice(npc)); }
    }
    for(i = 0; i < actors.Size(); i += 1)
    {
        npc = (CNewNPC)actors[i];
        if(!npc || npc.HasTag('w3coop_npc_copy') || npc.HasTag('MPEntity') || NpcVoice(npc) == "" || CoopCount(voices, NpcVoice(npc)) != 1) { continue; }
        if(!W3T_Talkable(npc)) { continue; }
        if(!best || StrCmp(NpcVoice(npc), NpcVoice(best)) < 0) { best = npc; }
    }
    return best;
}

function W3T_TalkMerchant() : CNewNPC
{
    var entities : array<CGameplayEntity>;
    var npc, best : CNewNPC;
    var i : int;
    FindGameplayEntitiesInRange(entities, thePlayer, 3000, 200, , , , 'W3MerchantNPC');
    for(i = 0; i < entities.Size(); i += 1)
    {
        npc = (CNewNPC)entities[i];
        if(!npc || !npc.IsAlive() || npc.HasTag('w3coop_npc_copy')) { continue; }
        W3T_Log("TALK merchant candidate voice=" + NpcVoice(npc) + " at " + W3T_VecStr(npc.GetWorldPosition())
            + " dist=" + FloatToStringPrec(VecDistance(npc.GetWorldPosition(), thePlayer.GetWorldPosition()), 1));
        if(!best || VecDistance(npc.GetWorldPosition(), thePlayer.GetWorldPosition()) < VecDistance(best.GetWorldPosition(), thePlayer.GetWorldPosition())) { best = npc; }
    }
    return best;
}

function W3T_TalkBoard(i : int) : Vector
{
    if(i == 0) { return Vector(688.66, 2015.03, 32.70); }
    if(i == 1) { return Vector(670.10, 1902.73, 10.75); }
    return Vector(557.37, 1845.18, 4.68);
}

function W3T_TeleportNear(pos : Vector)
{
    var safe : Vector;
    var rot : EulerAngles;
    if(!theGame.GetWorld().NavigationFindSafeSpot(pos + Vector(2, 0, 0), 0.5, 6.0, safe)) { safe = pos + Vector(2, 0, 1); }
    thePlayer.TeleportWithRotation(safe, rot);
}

function W3T_TeleportInFront(npc : CNewNPC)
{
    var spot : Vector;
    var rot : EulerAngles;
    spot = npc.GetWorldPosition() + VecFromHeading(npc.GetHeading()) * 1.8;
    rot.Yaw = npc.GetHeading() + 180;
    thePlayer.TeleportWithRotation(spot, rot);
}

function W3T_TalkLogEvents(talk : r_CoopTalk, label : string)
{
    var events : array<string>;
    var i : int;
    events = talk.TakeEvents();
    for(i = 0; i < events.Size(); i += 1) { W3T_Log(label + " " + events[i]); }
}

function W3T_TalkProbe(bot : W3T_Bot, client : r_MultiplayerClient, leader : r_RemotePlayer) : bool
{
    var talk : r_CoopTalk;
    var target : CNewNPC;
    var actors : array<CActor>;
    var npc : CNewNPC;
    var module : CR4HudModuleDialog;
    var host : bool;
    var label : string;
    var now : float;
    var i : int;
    host = W3T_GetEnv("W3T_ROLE") == "mover";
    label = "TALK member";
    if(host) { label = "TALK host"; }
    if(!host && !client.getInParty())
    {
        W3T_Log("PARTY join " + leader.username);
        client.joinParty(leader.username);
        return false;
    }
    talk = client.getCoopTalk();
    W3T_TalkLogEvents(talk, label);
    now = bot.ElapsedS();
    if(bot.scenarioStep == 0)
    {
        bot.scenarioTime = now;
        bot.scenarioStep = 1;
        return false;
    }
    if(bot.scenarioStep == 1 && now - bot.scenarioTime >= 10)
    {
        actors = thePlayer.GetNPCsAndPlayersInRange(100, 200, '', FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
        for(i = 0; i < actors.Size(); i += 1)
        {
            npc = (CNewNPC)actors[i];
            if(!npc || npc.HasTag('MPEntity')) { continue; }
            W3T_Log(label + " npc voice=" + NpcVoice(npc) + " tpl=" + npc.GetReadableName() + " scene=" + npc.HasInteractionScene() + " canTalk=" + npc.CanTalk()
                + " talkComp=" + W3T_HasTalk(npc) + " talkOn=" + W3T_Talkable(npc)
                + " copy=" + npc.HasTag('w3coop_npc_copy') + " dist=" + FloatToStringPrec(VecDistance(npc.GetWorldPosition(), thePlayer.GetWorldPosition()), 1));
        }
        // A merchant always has a conversation with choices (trade, goodbye). None is loaded where the
        // bots start, so try the market squares by the Novigrad notice boards in turn (both bots
        // visit the same ones in the same order) and take the nearest merchant there.
        target = W3T_TalkMerchant();
        if(!target)
        {
            if(bot.scenarioCount >= 3) { W3T_Log(label + " no merchant near the first three boards"); bot.scenarioStep = -1; return false; }
            W3T_Log(label + " no merchant here; trying board " + bot.scenarioCount);
            W3T_TeleportNear(W3T_TalkBoard(bot.scenarioCount));
            bot.scenarioCount += 1;
            bot.scenarioTime = now;
            return false;
        }
        bot.scenarioCount = 0;
        bot.scenarioEntity = target;
        W3T_Log(label + " target merchant voice=" + NpcVoice(target) + " tpl=" + target.GetReadableName() + " at " + W3T_VecStr(target.GetWorldPosition())
            + " dist=" + FloatToStringPrec(VecDistance(target.GetWorldPosition(), thePlayer.GetWorldPosition()), 1));
        W3T_TeleportInFront(target);
        bot.scenarioTime = now;
        bot.scenarioStep = 2;
    }
    else if(bot.scenarioStep == 2 && ((!host && now - bot.scenarioTime >= 10) || (host && now - bot.scenarioTime >= 14)))
    {
        // as the Talk button does
        target = (CNewNPC)bot.scenarioEntity;
        W3T_Log(label + " talks from " + FloatToStringPrec(VecDistance(target.GetWorldPosition(), thePlayer.GetWorldPosition()), 1) + " m");
        target.OnInteraction("Talk", thePlayer);
        bot.scenarioTime = now;
        bot.scenarioStep = 3;
    }
    else if(bot.scenarioStep == 3)
    {
        if(client.hasActiveDialogChoices() && bot.scenarioCount == 0)
        {
            bot.scenarioCount = 1;
            bot.scenarioVec = Vector(now, 0, 0);
        }
        if(bot.scenarioCount == 1 && now - bot.scenarioVec.X >= 3)
        {
            module = W3T_DialogModule();
            if(module && client.hasActiveDialogChoices()) { module.OnDialogOptionAccepted(0); W3T_Log(label + " took choice 0"); }
            bot.scenarioCount = 0;
        }
        W3T_Log(label + " state inScene=" + talk.InScene() + " scene=" + talk.GetScenePath() + " lines=" + talk.linesSeen + " choiceSets=" + talk.choiceSets
            + " pos=" + W3T_VecStr(thePlayer.GetWorldPosition()));
        if(now - bot.scenarioTime >= 90 || (now - bot.scenarioTime >= 10 && !talk.InScene()))
        {
            bot.scenarioStep = 4;
        }
    }
    return bot.scenarioStep == 4;
}

// Shared conversation (talk_share). Both bots go to the Novigrad general store (merchant by
// board 0). The second PC walks up and presses Talk; the host, 10-15 m away, must be brought
// into the same conversation by its own game. At the first choice list the host clicks
// "Care to play cards?", which must only reach the second PC as a suggestion. The second PC
// then picks the first choice (its lines end in the shop opening): the host must follow, and
// the shop opened by the conversation in the host's game must be closed. The second PC closes
// its own shop and picks the last choice (Farewell); both conversations must end.
function W3T_TalkShare(bot : W3T_Bot, client : r_MultiplayerClient, leader : r_RemotePlayer) : bool
{
    var talk : r_CoopTalk;
    var target : CNewNPC;
    var module : CR4HudModuleDialog;
    var root : CR4Menu;
    var host : bool;
    var label : string;
    var now : float;
    host = W3T_GetEnv("W3T_ROLE") == "mover";
    label = "SHARETALK member";
    if(host) { label = "SHARETALK host"; }
    if(!host && !client.getInParty())
    {
        W3T_Log("PARTY join " + leader.username);
        client.joinParty(leader.username);
        return false;
    }
    if(host && client.getCoopEnemies().GetRole() != 1) { return false; }
    talk = client.getCoopTalk();
    W3T_TalkLogEvents(talk, label);
    now = bot.ElapsedS();
    if(bot.scenarioStep < 0) { return false; }
    if(bot.scenarioStep == 0)
    {
        W3T_TeleportNear(W3T_TalkBoard(0));
        bot.scenarioTime = now;
        bot.scenarioStep = 1;
        return false;
    }
    if(bot.scenarioStep == 1 && now - bot.scenarioTime >= 10)
    {
        target = W3T_TalkMerchant();
        if(!target) { W3T_Log(label + " FAIL no merchant by board 0"); bot.scenarioStep = -1; return false; }
        bot.scenarioEntity = target;
        if(!host) { W3T_TeleportInFront(target); }
        W3T_Log(label + " merchant " + NpcVoice(target) + " dist=" + FloatToStringPrec(VecDistance(target.GetWorldPosition(), thePlayer.GetWorldPosition()), 1));
        bot.scenarioTime = now;
        bot.scenarioStep = 2;
        return false;
    }
    if(!host && bot.scenarioStep == 2 && now - bot.scenarioTime >= 6)
    {
        target = (CNewNPC)bot.scenarioEntity;
        W3T_Log(label + " presses Talk");
        target.OnInteraction("Talk", thePlayer);
        bot.scenarioTime = now;
        bot.scenarioStep = 3;
    }
    module = W3T_DialogModule();
    root = theGame.GetGuiManager().GetRootMenu();
    if(host)
    {
        // the listener: once its choices are up, click one; it must stay a suggestion
        if(bot.scenarioStep == 2 && talk.IsListening() && client.hasActiveDialogChoices() && talk.votesSent == 0)
        {
            W3T_Log(label + " clicks choice 1 (a suggestion)");
            module.OnDialogOptionSelected(1);
            module.OnDialogOptionAccepted(1);
        }
        if(bot.scenarioStep == 2 && talk.joins >= 1 && talk.picksApplied >= 2 && !talk.InScene())
        {
            bot.scenarioStep = 3;
        }
    }
    else
    {
        if(bot.scenarioStep == 3 && client.hasActiveDialogChoices() && bot.scenarioCount == 0)
        {
            bot.scenarioCount = 1;
            bot.scenarioTime = now;  // the choices are up: give the host 10 s to suggest
        }
        if(bot.scenarioStep == 3 && client.hasActiveDialogChoices() && talk.picksSent == 0 && (talk.votesReceived >= 1 || now - bot.scenarioTime >= 10))
        {
            W3T_Log(label + " picks choice 0 after " + talk.votesReceived + " suggestion(s): " + talk.lastVote);
            module.OnDialogOptionSelected(0);
            module.OnDialogOptionAccepted(0);
            bot.scenarioTime = now;
        }
        if(bot.scenarioStep == 3 && root && talk.picksSent >= 1)
        {
            W3T_Log(label + " closes its shop");
            root.CloseMenu();
        }
        if(bot.scenarioStep == 3 && client.hasActiveDialogChoices() && talk.picksSent == 1 && talk.ChoicesAge() >= 3 && !root)
        {
            W3T_Log(label + " picks the last choice (farewell)");
            module.OnDialogOptionSelected(talk.LastChoiceCount() - 1);
            module.OnDialogOptionAccepted(talk.LastChoiceCount() - 1);
            bot.scenarioTime = now;
        }
        if(bot.scenarioStep == 3 && talk.picksSent >= 2 && !talk.InScene())
        {
            bot.scenarioStep = 4;
        }
    }
    W3T_Log(label + " step=" + bot.scenarioStep + " inScene=" + talk.InScene() + " listening=" + talk.IsListening() + " listeners=" + talk.ListenerCount()
        + " joins=" + talk.joins + " joinFailures=" + talk.joinFailures + " mismatches=" + talk.sceneMismatches + " picksSent=" + talk.picksSent
        + " picksApplied=" + talk.picksApplied + " votesSent=" + talk.votesSent + " votesReceived=" + talk.votesReceived + " menusClosed=" + talk.menusClosed
        + " lines=" + talk.linesSeen + " scene=" + talk.GetScenePath());
    if(host) { return bot.scenarioStep == 3 && talk.sceneMismatches == 0 && talk.votesSent >= 1 && talk.menusClosed >= 1; }
    return bot.scenarioStep == 4 && talk.votesReceived >= 1;
}

// scene_probe: lists the save's active quests, the tracked one and its open objectives, so a
// quest scene reachable from the test save can be chosen. Logs scene starts for a minute.
function W3T_SceneProbe(bot : W3T_Bot, client : r_MultiplayerClient) : bool
{
    var manager : CWitcherJournalManager;
    var quests : array<CJournalBase>;
    var jq : CJournalQuest;
    var phase : CJournalQuestPhase;
    var objective : CJournalQuestObjective;
    var label : string;
    var i, j, k : int;
    label = "SCENEPROBE";
    W3T_TalkLogEvents(client.getCoopTalk(), label);
    if(bot.scenarioStep == 0)
    {
        manager = theGame.GetJournalManager();
        manager.GetActivatedOfType('CJournalQuest', quests);
        for(i = 0; i < quests.Size(); i += 1)
        {
            jq = (CJournalQuest)quests[i];
            if(!jq || manager.GetEntryStatus(jq) != JS_Active) { continue; }
            W3T_Log(label + " QUEST " + NameToString(jq.GetUniqueScriptTag()) + " '" + GetLocStringById(jq.GetTitleStringId()) + "' type=" + (int)jq.GetType()
                + " tracked=" + (jq == manager.GetTrackedQuest()));
            for(j = 0; j < jq.GetNumChildren(); j += 1)
            {
                phase = (CJournalQuestPhase)jq.GetChild(j);
                if(!phase) { continue; }
                for(k = 0; k < phase.GetNumChildren(); k += 1)
                {
                    objective = (CJournalQuestObjective)phase.GetChild(k);
                    if(objective && manager.GetEntryStatus(objective) == JS_Active)
                    {
                        W3T_Log(label + "   OBJ '" + GetLocStringById(objective.GetTitleStringId()) + "'");
                        W3T_LogObjectivePins(label, objective);
                    }
                }
            }
        }
        W3T_Log(label + " player=" + W3T_VecStr(thePlayer.GetWorldPosition()) + " area=" + WO_CurrentAreaCode() + " hour=" + GameTimeHours(theGame.GetGameTime()));
        bot.scenarioTime = bot.ElapsedS();
        bot.scenarioStep = 1;
    }
    return bot.scenarioStep == 1 && bot.ElapsedS() - bot.scenarioTime > 20;
}

function W3T_FindCiri() : CNewNPC
{
    var actors : array<CActor>;
    var npc : CNewNPC;
    var i : int;
    actors = thePlayer.GetNPCsAndPlayersInRange(80, 64, '', FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
    for(i = 0; i < actors.Size(); i += 1)
    {
        npc = (CNewNPC)actors[i];
        if(npc && !npc.HasTag('w3coop_npc_copy') && NpcVoice(npc) == "CIRILLA") { return npc; }
    }
    return NULL;
}

// ciri_follow (probe): the mover keeps 2.5 m behind Ciri on "Go with Ciri to see Whoreson
// Junior" and logs where she goes and every scene its quest starts; the other bot stands still
// (no party), showing whether its own quest starts anything without its Geralt there.
function W3T_CiriFollow(bot : W3T_Bot, client : r_MultiplayerClient) : bool
{
    var ciri : CNewNPC;
    var talk : r_CoopTalk;
    var spot : Vector;
    var rot : EulerAngles;
    var label, objectives : string;
    var dist : float;
    label = "CIRIFOLLOW";
    talk = client.getCoopTalk();
    W3T_TalkLogEvents(talk, label);
    if(W3T_GetEnv("W3T_ROLE") != "mover") { return bot.ElapsedS() > 440; }
    if(client.hasActiveDialogChoices() && talk.ChoicesAge() > 2)
    {
        W3T_Log(label + " takes choice 0");
        W3T_DialogModule().OnDialogOptionSelected(0);
        W3T_DialogModule().OnDialogOptionAccepted(0);
    }
    objectives = W3T_TrackedObjectives();
    if(objectives != bot.scenarioText)
    {
        W3T_Log(label + " OBJECTIVES " + objectives);
        bot.scenarioText = objectives;
    }
    ciri = W3T_FindCiri();
    if(!ciri)
    {
        if(bot.scenarioStep % 5 == 0) { W3T_Log(label + " no Ciri within 80 m, player=" + W3T_VecStr(thePlayer.GetWorldPosition())); }
        bot.scenarioStep += 1;
        return false;
    }
    dist = VecDistance(ciri.GetWorldPosition(), thePlayer.GetWorldPosition());
    if(bot.scenarioCount == 0 && bot.scenarioStep >= 10)
    {
        // "Wait for daylight": move the clock to the next morning, as meditating would
        theGame.SetGameTime(GameTimeCreate(GameTimeDays(theGame.GetGameTime()) + 1, 8, 0, 0), true);
        bot.scenarioCount = 1;
        W3T_Log(label + " clock set to 08:00, hour now " + GameTimeHours(theGame.GetGameTime()));
    }
    if(!talk.InScene() && dist > 4.0)
    {
        spot = ciri.GetWorldPosition() - VecFromHeading(ciri.GetHeading()) * 2.5;
        rot.Yaw = ciri.GetHeading();
        thePlayer.TeleportWithRotation(spot, rot);
    }
    if(bot.scenarioStep % 5 == 0)
    {
        W3T_Log(label + " ciri=" + W3T_VecStr(ciri.GetWorldPosition()) + " speed=" + FloatToStringPrec(ciri.GetMovingAgentComponent().GetRelativeMoveSpeed(), 2)
            + " dist=" + FloatToStringPrec(dist, 1) + " inScene=" + talk.InScene() + " scene=" + talk.GetScenePath());
    }
    bot.scenarioStep += 1;
    return bot.ElapsedS() > 440;
}

// The map pins of a quest objective and where this world's map puts them.
function W3T_LogObjectivePins(label : string, objective : CJournalQuestObjective)
{
    var pin : CJournalQuestMapPin;
    var pins : array<SCommonMapPinInstance>;
    var i, j : int;
    pins = theGame.GetCommonMapManager().GetMapPinInstances(theGame.GetWorld().GetDepotPath());
    for(i = 0; i < objective.GetNumChildren(); i += 1)
    {
        pin = (CJournalQuestMapPin)objective.GetChild(i);
        if(!pin) { continue; }
        W3T_Log(label + "     PIN " + NameToString(pin.GetMapPinID()) + " radius=" + FloatToStringPrec(pin.GetRadius(), 1));
        for(j = 0; j < pins.Size(); j += 1)
        {
            if(pins[j].tag == pin.GetMapPinID())
            {
                W3T_Log(label + "       AT " + W3T_VecStr(pins[j].position) + " type=" + NameToString(pins[j].type) + " dist="
                    + FloatToStringPrec(VecDistance(pins[j].position, thePlayer.GetWorldPosition()), 0));
            }
        }
    }
}

// The tracked quest and its active objectives, as one line.
function W3T_TrackedObjectives() : string
{
    var manager : CWitcherJournalManager;
    var jq : CJournalQuest;
    var phase : CJournalQuestPhase;
    var objective : CJournalQuestObjective;
    var text : string;
    var j, k : int;
    manager = theGame.GetJournalManager();
    jq = manager.GetTrackedQuest();
    if(!jq) { return "none"; }
    text = GetLocStringById(jq.GetTitleStringId()) + ":";
    for(j = 0; j < jq.GetNumChildren(); j += 1)
    {
        phase = (CJournalQuestPhase)jq.GetChild(j);
        if(!phase) { continue; }
        for(k = 0; k < phase.GetNumChildren(); k += 1)
        {
            objective = (CJournalQuestObjective)phase.GetChild(k);
            if(objective && manager.GetEntryStatus(objective) == JS_Active) { text += " [" + GetLocStringById(objective.GetTitleStringId()) + "]"; }
        }
    }
    return text;
}

// scene_share: a scene the quest starts by itself, shared. Stand-in for a quest's area trigger:
// each bot starts the general-store trader's scene (PlayDialog, as Talk would, without Talk) once its
// Geralt is within 6 m of him. The host stands in front of him and the second PC 20 m away, so
// only the host's trigger fires. The second PC must be brought over, where its own trigger
// starts the same scene; it suggests a choice; the host picks the artefacts topic (its lines open
// the shop, closed on the second PC), closes its own shop and says farewell; both scenes end.
// Then the second PC walks off again with its trigger spent (its "quest" is past that step) and
// the host starts the scene once more: the second PC is brought over, no scene starts there,
// and it must be put back where it was. During its scene the trader must be itself, not a stand-in.
function W3T_SceneShare(bot : W3T_Bot, client : r_MultiplayerClient, leader : r_RemotePlayer) : bool
{
    var talk : r_CoopTalk;
    var trader, shown : CNewNPC;
    var module : CR4HudModuleDialog;
    var root : CR4Menu;
    var host : bool;
    var label : string;
    var now, dist : float;
    host = W3T_GetEnv("W3T_ROLE") == "mover";
    label = "SCENESHARE member";
    if(host) { label = "SCENESHARE host"; }
    if(!host && !client.getInParty())
    {
        W3T_Log("PARTY join " + leader.username);
        client.joinParty(leader.username);
        return false;
    }
    if(host && client.getCoopEnemies().GetRole() != 1) { return false; }
    talk = client.getCoopTalk();
    W3T_TalkLogEvents(talk, label);
    now = bot.ElapsedS();
    if(bot.scenarioStep < 0) { return false; }
    if(bot.scenarioStep == 0)
    {
        W3T_TeleportNear(W3T_TalkBoard(0));
        bot.scenarioTime = now;
        bot.scenarioStep = 1;
        return false;
    }
    if(bot.scenarioStep == 1 && now - bot.scenarioTime >= 10)
    {
        trader = W3T_TalkMerchant();
        if(!trader) { W3T_Log(label + " FAIL no merchant by board 0"); bot.scenarioStep = -1; return false; }
        bot.scenarioEntity = trader;
        if(host) { W3T_TeleportInFront(trader); }
        else { W3T_SceneShareWalkOff(bot, trader); }
        bot.scenarioTime = now;
        bot.scenarioStep = 2;
        return false;
    }
    trader = (CNewNPC)bot.scenarioEntity;
    if(!trader) { return false; }
    dist = VecDistance(trader.GetWorldPosition(), thePlayer.GetWorldPosition());

    // the stand-in quest trigger (scenarioCount: times it fired here)
    if(!talk.InScene() && dist < 6.0 && ((host && bot.scenarioStep == 2 && now - bot.scenarioTime >= 8 && bot.scenarioCount == 0)
        || (host && bot.scenarioStep == 5 && now - bot.scenarioTime >= 8 && bot.scenarioCount == 1)
        || (!host && bot.scenarioCount == 0)))
    {
        bot.scenarioCount += 1;
        W3T_Log(label + " TRIGGER starts the trader scene (no Talk), dist=" + FloatToStringPrec(dist, 1) + " started=" + trader.PlayDialog());
    }

    module = W3T_DialogModule();
    root = theGame.GetGuiManager().GetRootMenu();
    if(host)
    {
        if(talk.ListenerCount() >= 1) { bot.scenarioFlag = true; }
        if(bot.scenarioStep == 2 && client.hasActiveDialogChoices() && talk.picksSent == 0 && talk.ChoicesAge() > 2 && (talk.votesReceived >= 1 || talk.ChoicesAge() > 20))
        {
            W3T_Log(label + " picks choice 0 after " + talk.votesReceived + " suggestion(s): " + talk.lastVote);
            module.OnDialogOptionSelected(0);
            module.OnDialogOptionAccepted(0);
        }
        if(root && talk.InScene())
        {
            W3T_Log(label + " closes its shop");
            root.CloseMenu();
        }
        if(client.hasActiveDialogChoices() && talk.picksSent >= 1 && talk.ChoicesAge() >= 3 && !root
            && ((bot.scenarioStep == 2 && talk.picksSent == 1) || bot.scenarioStep == 5))
        {
            W3T_Log(label + " picks the last choice (farewell)");
            module.OnDialogOptionSelected(talk.LastChoiceCount() - 1);
            module.OnDialogOptionAccepted(talk.LastChoiceCount() - 1);
        }
        if(bot.scenarioStep == 2 && talk.picksSent >= 2 && !talk.InScene())
        {
            bot.scenarioStep = 3;
            bot.scenarioTime = now;
        }
        // let the second PC walk off before the second scene
        if(bot.scenarioStep == 3 && now - bot.scenarioTime >= 12)
        {
            bot.scenarioStep = 5;
            bot.scenarioTime = now;
        }
        if(bot.scenarioStep == 5 && bot.scenarioCount == 2 && !talk.InScene() && talk.autoOpens >= 2)
        {
            bot.scenarioStep = 6;
        }
    }
    else
    {
        if(talk.IsListening() && client.hasActiveDialogChoices() && talk.votesSent == 0 && talk.ChoicesAge() > 1)
        {
            W3T_Log(label + " clicks choice 1 (a suggestion)");
            module.OnDialogOptionSelected(1);
            module.OnDialogOptionAccepted(1);
        }
        if(talk.InScene())
        {
            shown = client.getCoopNpcs().ShownByVoice(NpcVoice(trader));
            if(shown && shown.HasTag('w3coop_npc_copy'))
            {
                if(!bot.scenarioFlag) { W3T_Log(label + " FAIL-MARK the trader is a stand-in during the scene"); }
                bot.scenarioFlag = true;
            }
        }
        if(bot.scenarioStep == 2 && talk.autoJoins >= 1 && talk.picksApplied >= 2 && !talk.InScene())
        {
            W3T_SceneShareWalkOff(bot, trader);
            bot.scenarioStep = 3;
        }
        if(bot.scenarioStep == 3 && talk.autoMissed >= 1 && !talk.IsListening())
        {
            W3T_Log(label + " back after the missed scene: " + FloatToStringPrec(VecDistance(thePlayer.GetWorldPosition(), bot.scenarioVec), 1) + " m from where it stood");
            bot.scenarioStep = 4;
        }
    }
    W3T_Log(label + " step=" + bot.scenarioStep + " triggers=" + bot.scenarioCount + " dist=" + FloatToStringPrec(dist, 1) + " inScene=" + talk.InScene()
        + " listening=" + talk.IsListening() + " listeners=" + talk.ListenerCount() + " autoOpens=" + talk.autoOpens + " autoJoins=" + talk.autoJoins
        + " autoMissed=" + talk.autoMissed + " handovers=" + talk.handovers + " mismatches=" + talk.sceneMismatches + " picksSent=" + talk.picksSent
        + " picksApplied=" + talk.picksApplied + " votesSent=" + talk.votesSent + " votesReceived=" + talk.votesReceived + " menusClosed=" + talk.menusClosed
        + " flag=" + bot.scenarioFlag);
    if(host) { return bot.scenarioStep == 6 && bot.scenarioFlag && talk.votesReceived >= 1 && talk.handovers == 0; }
    // put back where it stood when the scene was offered: the host's scene starting can nudge it a
    // few metres first (run 20261025-110932: 2.7 m before the offer arrived), hence 5 m
    return bot.scenarioStep == 4 && !bot.scenarioFlag && talk.sceneMismatches == 0 && talk.menusClosed >= 1 && talk.votesSent >= 1
        && VecDistance(thePlayer.GetWorldPosition(), bot.scenarioVec) < 5.0;
}

// The second PC stands 20 m from the trader, out of the stand-in trigger's reach.
function W3T_SceneShareWalkOff(bot : W3T_Bot, trader : CNewNPC)
{
    var spot, safe : Vector;
    var rot : EulerAngles;
    spot = trader.GetWorldPosition() + VecFromHeading(trader.GetHeading()) * 20.0;
    if(!theGame.GetWorld().NavigationFindSafeSpot(spot, 0.5, 6.0, safe)) { safe = spot; }
    rot.Yaw = VecHeading(trader.GetWorldPosition() - safe);
    thePlayer.TeleportWithRotation(safe, rot);
    bot.scenarioVec = safe;
    W3T_Log("SCENESHARE member walks off to " + W3T_VecStr(safe) + ", " + FloatToStringPrec(VecDistance(safe, trader.GetWorldPosition()), 1) + " m from the trader");
}

// watch_skip: the Watch / Skip prompt. The second PC talks to the general-store trader twice.
// The host answers Skip to the first prompt (the bot's dialog hook): it must not be brought over
// or join. It leaves the second prompt unanswered: when that conversation ends the prompt must
// close by itself (and the host must keep running while it is up).
function W3T_WatchSkip(bot : W3T_Bot, client : r_MultiplayerClient, leader : r_RemotePlayer) : bool
{
    var talk : r_CoopTalk;
    var target : CNewNPC;
    var module : CR4HudModuleDialog;
    var host : bool;
    var label : string;
    var now, moved : float;
    host = W3T_GetEnv("W3T_ROLE") == "mover";
    label = "WATCHSKIP member";
    if(host) { label = "WATCHSKIP host"; }
    if(!host && !client.getInParty())
    {
        W3T_Log("PARTY join " + leader.username);
        client.joinParty(leader.username);
        return false;
    }
    if(host && client.getCoopEnemies().GetRole() != 1) { return false; }
    talk = client.getCoopTalk();
    W3T_TalkLogEvents(talk, label);
    now = bot.ElapsedS();
    if(bot.scenarioStep < 0) { return false; }
    if(bot.scenarioStep == 0)
    {
        W3T_TeleportNear(W3T_TalkBoard(0));
        bot.scenarioTime = now;
        bot.scenarioStep = 1;
        return false;
    }
    if(bot.scenarioStep == 1 && now - bot.scenarioTime >= 10)
    {
        target = W3T_TalkMerchant();
        if(!target) { W3T_Log(label + " FAIL no merchant by board 0"); bot.scenarioStep = -1; return false; }
        bot.scenarioEntity = target;
        if(!host) { W3T_TeleportInFront(target); }
        bot.scenarioVec = thePlayer.GetWorldPosition();
        bot.scenarioTime = now;
        bot.scenarioStep = 2;
        return false;
    }
    if(bot.scenarioStep < 2) { return false; }
    target = (CNewNPC)bot.scenarioEntity;
    module = W3T_DialogModule();
    moved = VecDistance(thePlayer.GetWorldPosition(), bot.scenarioVec);
    if(!host)
    {
        // scenarioCount: conversations started; each ends with Farewell
        if(!talk.InScene() && bot.scenarioCount < 2 && now - bot.scenarioTime >= 6)
        {
            W3T_Log(label + " presses Talk (" + (bot.scenarioCount + 1) + ")");
            target.OnInteraction("Talk", thePlayer);
            bot.scenarioCount += 1;
            bot.scenarioTime = now;
        }
        if(talk.InScene() && client.hasActiveDialogChoices() && talk.ChoicesAge() > 3)
        {
            W3T_Log(label + " says farewell");
            module.OnDialogOptionSelected(talk.LastChoiceCount() - 1);
            module.OnDialogOptionAccepted(talk.LastChoiceCount() - 1);
            bot.scenarioTime = now;
        }
        if(bot.scenarioCount == 2 && !talk.InScene() && now - bot.scenarioTime >= 8) { bot.scenarioStep = 3; }
    }
    else if(talk.offersGone >= 1 && talk.offersSkipped >= 1)
    {
        bot.scenarioStep = 3;
    }
    W3T_Log(label + " step=" + bot.scenarioStep + " talks=" + bot.scenarioCount + " inScene=" + talk.InScene() + " listening=" + talk.IsListening()
        + " joins=" + talk.joins + " offersShown=" + talk.offersShown + " skipped=" + talk.offersSkipped + " gone=" + talk.offersGone
        + " listeners=" + talk.ListenerCount() + " moved=" + FloatToStringPrec(moved, 1) + " mode=" + COOP_WATCH_MODE());
    if(host) { return bot.scenarioStep == 3 && talk.offersShown == 2 && talk.joins == 0 && !talk.InScene() && moved < 1.0; }
    return bot.scenarioStep == 3 && talk.ListenerCount() == 0;
}

// travel_together: both players stand together; the host fast-travels to a discovered signpost
// at least 300 m away (the calls the map menu makes). The second PC must travel along and end up
// near the host. Then the second PC walks 150 m off and the host fast-travels again: this time
// the second PC was not with the host and must stay where it is.
function W3T_TravelTogether(bot : W3T_Bot, client : r_MultiplayerClient, other : r_RemotePlayer) : bool
{
    var travel : r_CoopTravel;
    var host : bool;
    var label : string;
    var now, apart : float;
    var pin : name;
    var spot, safe : Vector;
    var rot : EulerAngles;
    var events : array<string>;
    var i : int;
    host = W3T_GetEnv("W3T_ROLE") == "mover";
    label = "TRAVEL member";
    if(host) { label = "TRAVEL host"; }
    if(!host && !client.getInParty())
    {
        W3T_Log("PARTY join " + other.username);
        client.joinParty(other.username);
        return false;
    }
    if(host && client.getCoopEnemies().GetRole() != 1) { return false; }
    travel = client.getCoopTravel();
    events = travel.TakeEvents();
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
        // travel once the second PC stands with the host
        if(bot.scenarioStep == 1 && now - bot.scenarioTime >= 12 && apart < 20)
        {
            if(!W3T_TravelPin(thePlayer.GetWorldPosition(), 300, pin)) { W3T_Log(label + " FAIL no discovered signpost 300 m away"); bot.scenarioStep = -1; return false; }
            W3T_Log(label + " fast-travels to " + NameToString(pin) + " (second PC " + FloatToStringPrec(apart, 1) + " m away)");
            W3T_FastTravel(pin);
            bot.scenarioTime = now;
            bot.scenarioStep = 2;
        }
        // the second PC arrived, then walks off; travel again without it
        if(bot.scenarioStep == 2 && now - bot.scenarioTime >= 10 && apart < 40)
        {
            W3T_Log(label + " second PC arrived " + FloatToStringPrec(apart, 1) + " m away");
            bot.scenarioTime = now;
            bot.scenarioStep = 3;
        }
        if(bot.scenarioStep == 3 && now - bot.scenarioTime >= 10 && apart > 100)
        {
            if(!W3T_TravelPin(thePlayer.GetWorldPosition(), 300, pin)) { W3T_Log(label + " FAIL no second signpost"); bot.scenarioStep = -1; return false; }
            W3T_Log(label + " fast-travels alone to " + NameToString(pin) + " (second PC " + FloatToStringPrec(apart, 1) + " m away)");
            W3T_FastTravel(pin);
            bot.scenarioTime = now;
            bot.scenarioStep = 4;
        }
        if(bot.scenarioStep == 4 && now - bot.scenarioTime >= 20) { bot.scenarioStep = 5; }
    }
    else
    {
        if(bot.scenarioStep == 1 && travel.travelsFollowed >= 1)
        {
            bot.scenarioTime = now;
            bot.scenarioStep = 2;
        }
        // arrived next to the host: walk 150 m off
        if(bot.scenarioStep == 2 && now - bot.scenarioTime >= 15 && apart < 40)
        {
            W3T_Log(label + " arrived " + FloatToStringPrec(apart, 1) + " m from the host; walks off");
            spot = thePlayer.GetWorldPosition() + VecFromHeading(thePlayer.GetHeading()) * 150.0;
            if(!theGame.GetWorld().NavigationFindSafeSpot(spot, 1.0, 30.0, safe)) { safe = spot; }
            rot.Yaw = thePlayer.GetHeading();
            thePlayer.TeleportWithRotation(safe, rot);
            bot.scenarioVec = safe;
            bot.scenarioTime = now;
            bot.scenarioStep = 3;
        }
        if(bot.scenarioStep == 3 && travel.travelsIgnored >= 1 && now - bot.scenarioTime >= 30) { bot.scenarioStep = 4; }
    }
    W3T_Log(label + " step=" + bot.scenarioStep + " apart=" + FloatToStringPrec(apart, 1) + " sent=" + travel.travelsSent + " followed=" + travel.travelsFollowed
        + " ignored=" + travel.travelsIgnored + " regionFollows=" + travel.regionFollows + " pos=" + W3T_VecStr(thePlayer.GetWorldPosition()));
    if(host) { return bot.scenarioStep == 5 && travel.travelsSent == 2 && travel.travelsFollowed == 0; }
    return bot.scenarioStep == 4 && travel.travelsFollowed == 1 && travel.regionFollows == 0
        && VecDistance(thePlayer.GetWorldPosition(), bot.scenarioVec) < 5.0;
}

// A discovered land signpost in this world at least minDist from pos (the nearest such).
function W3T_TravelPin(pos : Vector, minDist : float, out pin : name) : bool
{
    var pins : array<SCommonMapPinInstance>;
    var best, d : float;
    var i : int;
    var found : bool;
    pins = theGame.GetCommonMapManager().GetMapPinInstances(theGame.GetWorld().GetDepotPath());
    for(i = 0; i < pins.Size(); i += 1)
    {
        if(pins[i].type != 'RoadSign' || !pins[i].isDiscovered || pins[i].isDisabled) { continue; }
        d = VecDistance(pins[i].position, pos);
        if(d < minDist) { continue; }
        if(!found || d < best)
        {
            found = true;
            best = d;
            pin = pins[i].tag;
        }
    }
    return found;
}

// What the map menu does for a fast travel within this region.
function W3T_FastTravel(pin : name)
{
    var manager : CCommonMapManager;
    manager = theGame.GetCommonMapManager();
    manager.UseMapPin(pin, true);
    manager.PerformLocalFastTravelTeleport(pin);
}

// travel_region: both stand together in Novigrad; the host fast-travels to a discovered signpost
// on Ard Skellig (another world: a full load). The second PC must travel along and arrive in the
// same region near the host.
function W3T_TravelRegion(bot : W3T_Bot, client : r_MultiplayerClient, other : r_RemotePlayer) : bool
{
    var travel : r_CoopTravel;
    var manager : CCommonMapManager;
    var host : bool;
    var label, worldPath : string;
    var now, apart : float;
    var pin : name;
    var events : array<string>;
    var i : int;
    host = W3T_GetEnv("W3T_ROLE") == "mover";
    label = "REGION member";
    if(host) { label = "REGION host"; }
    if(!host && !client.getInParty())
    {
        W3T_Log("PARTY join " + other.username);
        client.joinParty(other.username);
        return false;
    }
    if(host && client.getCoopEnemies().GetRole() != 1) { return false; }
    travel = client.getCoopTravel();
    events = travel.TakeEvents();
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
    if(host && bot.scenarioStep == 1 && now - bot.scenarioTime >= 12 && apart < 20)
    {
        manager = theGame.GetCommonMapManager();
        worldPath = manager.GetWorldPathFromAreaType('AN_Skellige_ArdSkellig');
        if(!W3T_TravelPinIn(worldPath, pin)) { W3T_Log(label + " FAIL no discovered signpost in " + worldPath); bot.scenarioStep = -1; return false; }
        W3T_Log(label + " fast-travels to Skellige: " + NameToString(pin) + " (" + worldPath + ")");
        manager.UseMapPin(pin, true);
        manager.PerformGlobalFastTravelTeleport('AN_Skellige_ArdSkellig', pin);
        bot.scenarioTime = now;
        bot.scenarioStep = 2;
    }
    if(!host && bot.scenarioStep == 1 && travel.travelsFollowed >= 1) { bot.scenarioStep = 2; }
    if(bot.scenarioStep == 2 && WO_CurrentAreaCode() == WO_AreaToCode('AN_Skellige_ArdSkellig') && other.area == WO_CurrentAreaCode() && apart < 40)
    {
        W3T_Log(label + " both on Ard Skellig, " + FloatToStringPrec(apart, 1) + " m apart");
        bot.scenarioStep = 3;
    }
    W3T_Log(label + " step=" + bot.scenarioStep + " area=" + WO_CurrentAreaCode() + " otherArea=" + other.area + " apart=" + FloatToStringPrec(apart, 1)
        + " sent=" + travel.travelsSent + " followed=" + travel.travelsFollowed + " ignored=" + travel.travelsIgnored + " regionFollows=" + travel.regionFollows
        + " pos=" + W3T_VecStr(thePlayer.GetWorldPosition()));
    if(host) { return bot.scenarioStep == 3 && travel.travelsSent == 1; }
    return bot.scenarioStep == 3 && travel.travelsFollowed == 1 && travel.regionFollows == 0;
}

// A discovered land signpost in another world (the first one listed).
function W3T_TravelPinIn(worldPath : string, out pin : name) : bool
{
    var pins : array<SCommonMapPinInstance>;
    var i : int;
    pins = theGame.GetCommonMapManager().GetMapPinInstances(worldPath);
    W3T_Log("REGION " + pins.Size() + " map pins listed for " + worldPath);
    for(i = 0; i < pins.Size(); i += 1)
    {
        if(pins[i].type == 'RoadSign' && pins[i].isDiscovered && !pins[i].isDisabled)
        {
            pin = pins[i].tag;
            return true;
        }
    }
    return false;
}
