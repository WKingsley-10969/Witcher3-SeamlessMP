@addField(CR4Game)
var w3t_partyAnswers : int;

@addMethod(CR4Game)
function W3T_AnswerPartyPrompt(id : int)
{
    var action : EUserMessageAction;
    var client : r_MultiplayerClient;
    client = theGame.r_getMultiplayerClient();
    w3t_partyAnswers += 1;
    action = UMA_No;
    if(w3t_partyAnswers == 2 || w3t_partyAnswers == 4) { action = UMA_Yes; }
    if(w3t_partyAnswers == 2)
    {
        GetGuiManager().UserDialogCallback(id - 1, UMA_Yes);
        if(client.getInParty() || client.GetPartyPrompt().GetActiveId() != id) { W3T_Log("FAIL stale callback changed new prompt"); W3T_Quit(2); }
    }
    GetGuiManager().UserDialogCallback(id, action);
    GetGuiManager().HideUserDialog(id);
    if(w3t_partyAnswers == 2) { GetGuiManager().UserDialogCallback(id, action); }
    W3T_Log("PARTY_MENU answered=" + w3t_partyAnswers + " action=" + action + " party=" + client.getInParty());
}

function W3T_PartyMenu(bot : W3T_Bot, client : r_MultiplayerClient, peer : r_RemotePlayer) : bool
{
    if(W3T_GetEnv("W3T_ROLE") == "mover") { return client.getCoopEnemies().GetRole() == 1; }
    if(bot.ElapsedS() < 25) { return false; }
    if(bot.scenarioStep == 0)
    {
        client.createMenu(peer.ghost);
        if(client.getInParty()) { W3T_Log("FAIL cancel joined party"); W3T_Quit(2); }
        bot.scenarioStep = 1;
    }
    else if(bot.scenarioStep == 1)
    {
        client.createMenu(peer.ghost);
        if(!client.getInParty() || client.getJoinedParty() != peer.username || client.GetPartyPrompt().GetActiveId() != 0) { W3T_Log("FAIL join confirmation"); W3T_Quit(2); }
        W3T_Log("PARTY_MENU joined via confirmation");
        bot.scenarioStep = 2; bot.scenarioTime = bot.ElapsedS();
    }
    else if(bot.scenarioStep == 2 && bot.ElapsedS() - bot.scenarioTime > 4 && client.getCoopEnemies().GetRole() == 2)
    {
        client.createMenu(peer.ghost);
        if(!client.getInParty()) { W3T_Log("FAIL cancel left party"); W3T_Quit(2); }
        bot.scenarioStep = 3;
    }
    else if(bot.scenarioStep == 3)
    {
        client.createMenu(peer.ghost);
        W3T_Log("PARTY_MENU left via confirmation");
        return !client.getInParty() && client.GetPartyPrompt().GetActiveId() == 0;
    }
    return false;
}