// Pending real-client verification. Distinguishes existing zero -> absent -> existing zero.
// Host receipts make each transition observable before the guest proceeds.
function W3T_SeamlessRemovals(bot : W3T_Bot) : bool
{
    var campaign : r_SeamlessCampaign;
    var host : bool;
    var scope : string;
    campaign = theGame.r_getMultiplayerClient().getSeamlessCampaign();
    host = W3T_GetEnv("W3T_ROLE") == "mover";
    W3T_Log("REMOVAL stage=" + bot.scenarioStep + " status=" + campaign.GetStatus()
        + " exists=" + FactsDoesExist("sc_test_removed") + " value=" + FactsQuerySum("sc_test_removed")
        + " receipt=" + FactsQuerySum("sc_test_remove_receipt") + " commits=" + campaign.GetCaptureCommits()
        + " applied=" + campaign.GetAppliedCount() + " tx=" + campaign.GetTransactionCount()
        + " cursor=" + campaign.GetCursor() + "/" + campaign.GetLatest());
    if(!campaign.IsReady() || bot.scenarioStep < 0) { return false; }
    if(bot.scenarioStep == 0)
    {
        scope = "sc_test_remove_guest";
        if(host) { scope = "sc_test_remove_host"; }
        if(campaign.OpenConversation(scope, "quest", scope)) { bot.scenarioStep = 1; }
    }
    else if(bot.scenarioStep == 1 && campaign.OwnsConversation())
    {
        if(campaign.RequestFactRemoval("sc_test_forbidden", "mh306_job_taken")) { bot.scenarioStep = -1; return false; }
        if(!campaign.WatchSnapshotFact("sc_test_removed")) { bot.scenarioStep = -1; return false; }
        if(!host) { FactsSet("sc_test_removed", 0); }
        bot.scenarioStep = 2;
    }
    else if(host)
    {
        if(bot.scenarioStep == 2 && FactsDoesExist("sc_test_removed") && FactsQuerySum("sc_test_removed") == 0
            && campaign.GetAppliedCount() >= 1)
        {
            if(campaign.RequestFactSet("sc_test_remove_zero_seen", "sc_test_remove_receipt", 1)) { bot.scenarioStep = 3; }
        }
        else if(bot.scenarioStep == 3 && !FactsDoesExist("sc_test_removed") && campaign.GetAppliedCount() >= 3)
        {
            if(campaign.RequestFactSet("sc_test_remove_absent_seen", "sc_test_remove_receipt", 2)) { bot.scenarioStep = 4; }
        }
        else if(bot.scenarioStep == 4 && FactsDoesExist("sc_test_removed") && FactsQuerySum("sc_test_removed") == 0
            && campaign.GetAppliedCount() == 5 && campaign.GetCaptureCommits() == 0
            && campaign.GetTransactionCount() == 5 && campaign.GetCursor() == campaign.GetLatest())
        {
            return WO_SCReadFactChange() == "";
        }
    }
    else
    {
        if(bot.scenarioStep == 2 && FactsQuerySum("sc_test_remove_receipt") == 1 && campaign.GetCaptureCommits() == 1)
        {
            FactsRemove("sc_test_removed"); bot.scenarioStep = 3;
        }
        else if(bot.scenarioStep == 3 && FactsQuerySum("sc_test_remove_receipt") == 2 && campaign.GetCaptureCommits() == 2)
        {
            FactsSet("sc_test_removed", 0); bot.scenarioStep = 4;
        }
        else if(bot.scenarioStep == 4 && campaign.GetCaptureCommits() == 3 && campaign.GetAppliedCount() == 2
            && campaign.GetTransactionCount() == 5 && campaign.GetCursor() == campaign.GetLatest())
        {
            return FactsDoesExist("sc_test_removed") && FactsQuerySum("sc_test_removed") == 0 && WO_SCReadFactChange() == "";
        }
    }
    return false;
}
