// loot_share: shared quest rewards and looted containers. The second PC joins the host's session
// (as session_join).
// 1. The host's game gives it the contract reward mh306_final (300 XP at level 24, 267 crowns).
//    The second PC must get the reward's XP for its own level, and no crowns.
// 2. The second PC's own game then gives it the same reward (its quest ran too): crowns, but no
//    XP a second time.
// 3. The host empties the nearest container with loot. The same container on the second PC must
//    be empty too.
function W3T_LootShare(bot : W3T_Bot, client : r_MultiplayerClient, other : r_RemotePlayer) : bool
{
    var loot : r_CoopLoot;
    var host : bool;
    var label : string;
    var events : array<string>;
    var i, xp, crowns : int;
    var container : W3Container;
    host = W3T_GetEnv("W3T_ROLE") == "mover";
    label = "LOOT member";
    if(host) { label = "LOOT host"; }
    loot = client.getCoopLoot();
    events = loot.TakeEvents();
    for(i = 0; i < events.Size(); i += 1) { W3T_Log(label + " " + events[i]); }
    xp = GetWitcherPlayer().levelManager.GetPointsTotal(EExperiencePoint);
    crowns = thePlayer.GetInventory().GetMoney();
    W3T_Log(label + " step=" + bot.scenarioStep + " xp=" + xp + " crowns=" + crowns + " shared=" + loot.rewardsShared + " received=" + loot.rewardsReceived
        + " xpSkipped=" + loot.rewardsXpSkipped + " lootSent=" + loot.lootSent + " lootApplied=" + loot.lootApplied + " last=" + loot.lastLootApplied
        + " emptied=" + loot.lastLootEmptied + " inParty=" + client.getInParty());
    if(bot.scenarioStep < 0) { return false; }
    if(host)
    {
        if(bot.scenarioStep == 0 && client.getCoopEnemies().GetRole() == 1 && bot.ElapsedS() > 25)
        {
            bot.scenarioCount = xp;
            W3T_Log(label + " gets the reward mh306_final (" + xp + " XP, " + crowns + " crowns)");
            theGame.GiveReward('mh306_final', thePlayer);
            bot.scenarioStep = 1;
            bot.scenarioTime = bot.ElapsedS();
        }
        if(bot.scenarioStep == 1 && bot.ElapsedS() - bot.scenarioTime >= 20)
        {
            container = W3T_LootContainer();
            if(!container)
            {
                W3T_Log(label + " FAIL no container with loot within 60 m");
                bot.scenarioStep = -1;
                return false;
            }
            W3T_Log(label + " empties the container at " + W3T_VecStr(container.GetWorldPosition()) + " (" + container.GetInventory().GetAllItemsQuantity() + " items)");
            container.TakeAllItems();
            W3T_Log(label + " container empty here: " + container.IsEmpty());
            bot.scenarioStep = 2;
        }
        return bot.scenarioStep == 2 && loot.rewardsShared >= 1 && loot.lootSent >= 1 && bot.ElapsedS() > 90;
    }
    if(bot.scenarioStep == 0 && client.getInParty())
    {
        bot.scenarioCount = xp;
        bot.scenarioValue = crowns;
        bot.scenarioStep = 1;
    }
    if(bot.scenarioStep == 1 && loot.rewardsReceived >= 1)
    {
        W3T_Log(label + " got " + (xp - bot.scenarioCount) + " XP from the host's reward, crowns " + (crowns - (int)bot.scenarioValue));
        if(xp <= bot.scenarioCount || crowns != (int)bot.scenarioValue) { bot.scenarioStep = -1; return false; }
        // its own quest gives the reward too: crowns, no XP again
        bot.scenarioCount = xp;
        bot.scenarioValue = crowns;
        theGame.GiveReward('mh306_final', thePlayer);
        bot.scenarioStep = 2;
    }
    if(bot.scenarioStep == 2)
    {
        W3T_Log(label + " own reward: " + (xp - bot.scenarioCount) + " XP, " + (crowns - (int)bot.scenarioValue) + " crowns");
        if(xp != bot.scenarioCount || crowns <= (int)bot.scenarioValue || loot.rewardsXpSkipped != 1) { bot.scenarioStep = -1; return false; }
        bot.scenarioStep = 3;
    }
    if(bot.scenarioStep == 3 && loot.lootApplied >= 1 && loot.lastLootEmptied) { bot.scenarioStep = 4; }
    return bot.scenarioStep == 4;
}

// The nearest container with something to take (not a corpse, a house decoration or a quest container).
function W3T_LootContainer() : W3Container
{
    var entities : array<CGameplayEntity>;
    var container, best : W3Container;
    var i : int;
    var d, bestDist : float;
    FindGameplayEntitiesInRange(entities, thePlayer, 60, 200);
    bestDist = 1000;
    for(i = 0; i < entities.Size(); i += 1)
    {
        container = (W3Container)entities[i];
        if(!container || (W3ActorRemains)container || (W3HouseDecorationBase)container || !container.GetInventory() || container.IsEmpty() || container.HasQuestItem()) { continue; }
        d = VecDistance(container.GetWorldPosition(), thePlayer.GetWorldPosition());
        if(d < bestDist)
        {
            bestDist = d;
            best = container;
        }
    }
    return best;
}
