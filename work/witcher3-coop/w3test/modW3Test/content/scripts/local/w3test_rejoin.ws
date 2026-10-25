// Pending game verification. Campaign-only outage injection lives in the test mod:
// production scripts contain no test disconnect switch. Ordinary party traffic
// continues. The real UDP suite separately closes/replaces the client's socket.
@addField(CR4Game)
var w3t_rejoinOfflineUntil : int;

@addMethod(CR4Game)
function W3T_RejoinGoOffline()
{
    w3t_rejoinOfflineUntil = W3T_TimeMs() + 24000;
}

function W3T_RejoinOffline() : bool
{
    return W3T_GetEnv("W3T_SCENARIO") == "seamless_rejoin" && W3T_GetEnv("W3T_ROLE") != "mover"
        && W3T_TimeMs() < theGame.w3t_rejoinOfflineUntil;
}

@wrapMethod(r_SeamlessCampaign)
public function Tick()
{
    if(W3T_RejoinOffline()) { return; }
    wrappedMethod();
}

@wrapMethod(r_SeamlessCampaign)
public function OnMessage()
{
    if(W3T_RejoinOffline()) { return; }
    wrappedMethod();
}

@addField(W3T_Bot)
var rejoinApplied : int;
@addField(W3T_Bot)
var rejoinTransactions : int;
@addField(W3T_Bot)
var rejoinRecoveries : int;

function W3T_SeamlessRejoin(bot : W3T_Bot) : bool
{
    var c : r_SeamlessCampaign;
    var host : bool;
    c = theGame.r_getMultiplayerClient().getSeamlessCampaign();
    host = W3T_GetEnv("W3T_ROLE") == "mover";
    W3T_Log("REJOIN stage=" + bot.scenarioStep + " status=" + c.GetStatus()
        + " offline=" + W3T_RejoinOffline() + " recoveries=" + c.GetRecoveryCount()
        + " removed=" + FactsDoesExist("sc_test_rejoin_removed")
        + " changed=" + FactsQuerySum("sc_test_rejoin_changed")
        + " receipt=" + FactsQuerySum("sc_test_rejoin_receipt")
        + " applied=" + c.GetAppliedCount() + " tx=" + c.GetTransactionCount()
        + " choices=" + c.GetEngineChoiceCount() + " cursor=" + c.GetCursor() + "/" + c.GetLatest());
    if(W3T_RejoinOffline() || !c.IsReady() || bot.scenarioStep < 0) { return false; }
    if(host)
    {
        if(bot.scenarioStep == 0 && c.OpenConversation("sc_test_rejoin_online", "quest", "sc_test_rejoin_online")) { bot.scenarioStep = 1; }
        else if(bot.scenarioStep == 1 && c.OwnsConversation()
            && c.RequestFactSet("sc_test_rejoin_initial", "sc_test_rejoin_removed", 0)) { bot.scenarioStep = 2; }
        else if(bot.scenarioStep == 2 && !c.HasPendingRequest() && FactsDoesExist("sc_test_rejoin_removed")
            && c.RequestFactSet("sc_test_rejoin_changed_initial", "sc_test_rejoin_changed", 1)) { bot.scenarioStep = 3; }
        else if(bot.scenarioStep == 3 && !c.HasPendingRequest() && FactsQuerySum("sc_test_rejoin_receipt") == 1)
        {
            bot.scenarioTime = bot.ElapsedS(); bot.scenarioStep = 4;
        }
        else if(bot.scenarioStep == 4 && bot.ElapsedS() - bot.scenarioTime > 6
            && c.RequestFactSet("sc_test_rejoin_offline_change", "sc_test_rejoin_changed", 9)) { bot.scenarioStep = 5; }
        else if(bot.scenarioStep == 5 && !c.HasPendingRequest() && FactsQuerySum("sc_test_rejoin_changed") == 9
            && c.RequestFactRemoval("sc_test_rejoin_offline_remove", "sc_test_rejoin_removed")) { bot.scenarioStep = 6; }
        else if(bot.scenarioStep == 6 && FactsQuerySum("sc_test_rejoin_receipt") == 3 && !c.HasPendingRequest())
        {
            return !FactsDoesExist("sc_test_rejoin_removed") && FactsQuerySum("sc_test_rejoin_changed") == 9;
        }
        return false;
    }
    if(bot.scenarioStep == 0 && FactsDoesExist("sc_test_rejoin_removed") && FactsQuerySum("sc_test_rejoin_changed") == 1
        && c.OpenConversation("sc_test_rejoin_guest_1", "quest", "sc_test_rejoin_guest")) { bot.scenarioStep = 1; }
    else if(bot.scenarioStep == 1 && c.OwnsConversation()
        && c.RequestFactSet("sc_test_rejoin_leaving_1", "sc_test_rejoin_receipt", 1)) { bot.scenarioStep = 2; }
    else if(bot.scenarioStep == 2 && !c.HasPendingRequest() && FactsQuerySum("sc_test_rejoin_receipt") == 1
        && c.GetCursor() == c.GetLatest())
    {
        bot.rejoinRecoveries = c.GetRecoveryCount();
        theGame.W3T_RejoinGoOffline(); bot.scenarioStep = 3;
    }
    else if(bot.scenarioStep == 3 && c.GetRecoveryCount() > bot.rejoinRecoveries && c.GetCursor() == c.GetLatest())
    {
        if(FactsDoesExist("sc_test_rejoin_removed") || FactsQuerySum("sc_test_rejoin_changed") != 9
            || c.GetEngineChoiceCount() != 0 || c.GetConversation() != "") { bot.scenarioStep = -1; return false; }
        if(c.OpenConversation("sc_test_rejoin_guest_2", "quest", "sc_test_rejoin_guest")) { bot.scenarioStep = 4; }
    }
    else if(bot.scenarioStep == 4 && c.OwnsConversation()
        && c.RequestFactSet("sc_test_rejoin_leaving_2", "sc_test_rejoin_receipt", 2)) { bot.scenarioStep = 5; }
    else if(bot.scenarioStep == 5 && !c.HasPendingRequest() && FactsQuerySum("sc_test_rejoin_receipt") == 2
        && c.GetCursor() == c.GetLatest())
    {
        bot.rejoinApplied = c.GetAppliedCount(); bot.rejoinTransactions = c.GetTransactionCount();
        bot.rejoinRecoveries = c.GetRecoveryCount();
        theGame.W3T_RejoinGoOffline(); bot.scenarioStep = 6;
    }
    else if(bot.scenarioStep == 6 && c.GetRecoveryCount() > bot.rejoinRecoveries && c.GetCursor() == c.GetLatest())
    {
        if(c.GetAppliedCount() != bot.rejoinApplied || c.GetTransactionCount() != bot.rejoinTransactions
            || c.GetEngineChoiceCount() != 0 || FactsDoesExist("sc_test_rejoin_removed")
            || FactsQuerySum("sc_test_rejoin_changed") != 9) { bot.scenarioStep = -1; return false; }
        if(c.OpenConversation("sc_test_rejoin_guest_done", "quest", "sc_test_rejoin_guest")) { bot.scenarioStep = 7; }
    }
    else if(bot.scenarioStep == 7 && c.OwnsConversation()
        && c.RequestFactSet("sc_test_rejoin_finished", "sc_test_rejoin_receipt", 3)) { bot.scenarioStep = 8; }
    else if(bot.scenarioStep == 8 && !c.HasPendingRequest() && c.GetCursor() == c.GetLatest())
    {
        return FactsQuerySum("sc_test_rejoin_receipt") == 3 && !FactsDoesExist("sc_test_rejoin_removed")
            && FactsQuerySum("sc_test_rejoin_changed") == 9 && c.GetEngineChoiceCount() == 0;
    }
    return false;
}
