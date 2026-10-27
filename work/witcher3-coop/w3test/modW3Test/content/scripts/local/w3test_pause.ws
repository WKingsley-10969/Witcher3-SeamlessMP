// pause_menu: Esc on a PC listening to a shared conversation (the owner's playtest: the menu was
// built, then closed the next frame, and Esc seemed to do nothing). Both bots go to the Novigrad
// general store as in talk_share; the second PC presses Talk and the host listens. While its
// choices are up, the host opens the pause menu; it must still be open 2 s later. The host then
// closes it and picks the farewell, and after the conversation opens the pause menu once more.
// The second PC sets the game's pause lock (nge_pause_menu_disabled) at the start: it must never
// reach the host (the fact sync copied it, and Esc did nothing for good).
// Logs: PAUSE <side> opened ... open after 2 s: <bool> / lock here=<n>
function W3T_PauseMenu(bot : W3T_Bot, client : r_MultiplayerClient, leader : r_RemotePlayer) : bool
{
    var talk : r_CoopTalk;
    var target : CNewNPC;
    var module : CR4HudModuleDialog;
    var root : CR4Menu;
    var host, open : bool;
    var label : string;
    var now : float;
    host = W3T_GetEnv("W3T_ROLE") == "mover";
    label = "PAUSE member";
    if(host) { label = "PAUSE host"; }
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
        if(!host) { FactsAdd("nge_pause_menu_disabled", 1, -1); W3T_Log(label + " sets its pause lock"); }
        W3T_TeleportNear(W3T_TalkBoard(0));
        bot.scenarioTime = now;
        bot.scenarioStep = 1;
        return false;
    }
    if(host && FactsQuerySum("nge_pause_menu_disabled") > 0 && !bot.scenarioFlag)
    {
        bot.scenarioFlag = true;
        W3T_Log(label + " FAIL-MARK the second PC's pause lock reached this game");
    }
    if(bot.scenarioStep == 1 && now - bot.scenarioTime >= 10)
    {
        target = W3T_TalkMerchant();
        if(!target) { W3T_Log(label + " FAIL no merchant by board 0"); bot.scenarioStep = -1; return false; }
        bot.scenarioEntity = target;
        if(!host) { W3T_TeleportInFront(target); }
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
        // listening, choices up: Esc
        if(bot.scenarioStep == 2 && talk.IsListening() && client.hasActiveDialogChoices() && talk.ChoicesAge() > 2 && bot.scenarioCount == 0)
        {
            W3T_Log(label + " opens the pause menu while listening");
            theGame.RequestMenu('CommonIngameMenu');
            bot.scenarioCount = 1;
            bot.scenarioTime = now;
        }
        if(bot.scenarioCount == 1 && now - bot.scenarioTime >= 2)
        {
            open = root && root.GetMenuName() == 'CommonIngameMenu';
            W3T_Log(label + " open after 2 s while listening: " + open + " lock here=" + FactsQuerySum("nge_pause_menu_disabled"));
            if(open) { bot.pauseOpens += 1; root.CloseMenu(); }
            bot.scenarioCount = 2;
            bot.scenarioTime = now;
        }
        if(bot.scenarioCount == 2 && client.hasActiveDialogChoices() && talk.picksSent == 0 && now - bot.scenarioTime >= 2 && !root)
        {
            W3T_Log(label + " picks the last choice (farewell)");
            module.OnDialogOptionSelected(talk.LastChoiceCount() - 1);
            module.OnDialogOptionAccepted(talk.LastChoiceCount() - 1);
        }
        // after the conversation: Esc again
        if(bot.scenarioCount == 2 && talk.picksSent >= 1 && !talk.InScene() && now - bot.scenarioTime >= 4)
        {
            W3T_Log(label + " opens the pause menu after the conversation");
            theGame.RequestMenu('CommonIngameMenu');
            bot.scenarioCount = 3;
            bot.scenarioTime = now;
        }
        if(bot.scenarioCount == 3 && now - bot.scenarioTime >= 2)
        {
            open = root && root.GetMenuName() == 'CommonIngameMenu';
            W3T_Log(label + " open after 2 s after the conversation: " + open);
            if(open) { bot.pauseOpens += 1; root.CloseMenu(); }
            bot.scenarioCount = 4;
            bot.scenarioStep = 3;
        }
    }
    else
    {
        if(bot.scenarioStep == 3 && root)
        {
            W3T_Log(label + " closes a menu");
            root.CloseMenu();
        }
        if(bot.scenarioStep == 3 && talk.picksApplied >= 1 && !talk.InScene()) { bot.scenarioStep = 4; }
        if(bot.scenarioStep == 4 && now - bot.scenarioTime >= 40) { bot.scenarioStep = 5; }
    }
    if(host) { return bot.scenarioStep == 3 && bot.pauseOpens == 2 && !bot.scenarioFlag; }
    return bot.scenarioStep == 5;
}
