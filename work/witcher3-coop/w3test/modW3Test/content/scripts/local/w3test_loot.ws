// loot_share: shared quest rewards and looted containers. The second PC joins the host's session
// (as session_join).
// 1. The host's game gives it the contract reward mh306_final (300 XP at level 24, 267 crowns).
//    The second PC must get the reward's XP for its own level, and no crowns.
// 2. The second PC's own game then gives it the same reward (its quest ran too): crowns, but no
//    XP a second time.
// 3. The host empties the nearest container with loot. The same container on the second PC, given
//    an extra item first (its own roll), must be empty too.
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
        return false;   // xp and crowns above are from before it
    }
    if(bot.scenarioStep == 2)
    {
        W3T_Log(label + " own reward: " + (xp - bot.scenarioCount) + " XP, " + (crowns - (int)bot.scenarioValue) + " crowns");
        if(xp != bot.scenarioCount || crowns <= (int)bot.scenarioValue || loot.rewardsXpSkipped != 1) { bot.scenarioStep = -1; return false; }
        container = W3T_LootContainer();
        if(!container) { W3T_Log(label + " FAIL no container with loot within 60 m"); bot.scenarioStep = -1; return false; }
        container.GetInventory().AddAnItem('Dwarven spirit', 1);
        W3T_Log(label + " container at " + W3T_VecStr(container.GetWorldPosition()) + " has " + container.GetInventory().GetAllItemsQuantity() + " items here");
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

// corpse_loot: a shared enemy's corpse holds the same loot on both PCs, the leader's game's roll.
// 1. The leader spawns a drowner next to the second PC's ghost (the second PC mirrors it), gives it
//    3 Dwarven spirit and 25 crowns, and kills it.
// 2. The second PC's corpse of it must hold the leader's loot (its own roll emptied). It takes one
//    Dwarven spirit: the leader's corpse must then hold 2.
// 3. The leader takes everything: the second PC's corpse must be empty.
function W3T_CorpseLootLeader(bot : W3T_Bot, client : r_MultiplayerClient) : bool
{
    var loot : r_CoopLoot;
    var coop : r_CoopEnemies;
    var template : CEntityTemplate;
    var drowner : CNewNPC;
    var remains : W3ActorRemains;
    var events : array<string>;
    var i : int;
    loot = client.getCoopLoot();
    coop = client.getCoopEnemies();
    events = loot.TakeEvents();
    for(i = 0; i < events.Size(); i += 1) { W3T_Log("CORPSE host " + events[i]); }
    remains = loot.NewestCorpseRemains();
    W3T_Log("CORPSE host step=" + bot.scenarioStep + " role=" + coop.GetRole() + " corpses=" + coop.CorpseCount() + " sent=" + loot.corpsesSent
        + " lootApplied=" + loot.lootApplied + " spirits=" + W3T_CorpseHas(remains, 'Dwarven spirit') + " crowns=" + W3T_CorpseHas(remains, 'Crowns')
        + " empty=" + (remains && remains.IsEmpty()));
    if(bot.scenarioStep < 0) { return false; }
    if(bot.scenarioStep == 0 && coop.GetRole() == 1 && bot.ElapsedS() > 20)
    {
        template = (CEntityTemplate)LoadResource("characters\npc_entities\monsters\drowner_lvl1.w2ent", true);
        if(!template) { W3T_Log("CORPSE host FAIL drowner template not found"); bot.scenarioStep = -1; return false; }
        thePlayer.SetImmortalityMode(AIM_Invulnerable, AIC_Cheat, true);
        bot.scenarioEntity = theGame.CreateEntity(template, thePlayer.GetWorldPosition() + VecFromHeading(thePlayer.GetHeading()) * 6.0,
            thePlayer.GetWorldRotation(), true, false, false, PM_DontPersist);
        drowner = (CNewNPC)bot.scenarioEntity;
        if(!drowner) { W3T_Log("CORPSE host FAIL no drowner"); bot.scenarioStep = -1; return false; }
        drowner.GetInventory().AddAnItem('Dwarven spirit', 3);
        drowner.GetInventory().AddAnItem('Crowns', 25);
        W3T_Log("CORPSE host spawned a drowner carrying " + drowner.GetInventory().GetItemQuantityByName('Dwarven spirit') + " Dwarven spirit, "
            + drowner.GetInventory().GetItemQuantityByName('Crowns') + " crowns");
        bot.scenarioStep = 1;
        bot.scenarioTime = bot.ElapsedS();
        return false;
    }
    if(bot.scenarioStep == 1 && bot.ElapsedS() - bot.scenarioTime > 12)
    {
        drowner = (CNewNPC)bot.scenarioEntity;
        if(!drowner) { W3T_Log("CORPSE host FAIL the drowner is gone"); bot.scenarioStep = -1; return false; }
        W3T_Log("CORPSE host kills the drowner (netId " + coop.HostNetIdOf(drowner) + ")");
        drowner.Kill('W3T', true);
        bot.scenarioStep = 2;
        bot.scenarioTime = bot.ElapsedS();
        return false;
    }
    if(bot.scenarioStep == 2 && loot.corpsesSent >= 1 && remains)
    {
        if(W3T_CorpseHas(remains, 'Dwarven spirit') != 3 || W3T_CorpseHas(remains, 'Crowns') != 25)
        {
            W3T_Log("CORPSE host FAIL its corpse does not hold what the drowner carried");
            bot.scenarioStep = -1;
            return false;
        }
        bot.scenarioStep = 3;
    }
    if(bot.scenarioStep == 3 && loot.lootApplied >= 1)
    {
        if(W3T_CorpseHas(remains, 'Dwarven spirit') != 2) { W3T_Log("CORPSE host FAIL the second PC's take did not reach this corpse"); bot.scenarioStep = -1; return false; }
        W3T_Log("CORPSE host the second PC took a spirit here too; takes everything");
        remains.TakeAllItems();
        bot.scenarioStep = 4;
        bot.scenarioTime = bot.ElapsedS();
    }
    if(bot.scenarioStep >= 2 && bot.scenarioStep < 4 && bot.ElapsedS() - bot.scenarioTime > 90)
    {
        W3T_Log("CORPSE host FAIL step " + bot.scenarioStep + " did not finish in 90 s");
        bot.scenarioStep = -1;
    }
    return bot.scenarioStep == 4 && remains && remains.IsEmpty() && bot.ElapsedS() - bot.scenarioTime > 15;
}

function W3T_CorpseLootMember(bot : W3T_Bot, client : r_MultiplayerClient, leader : r_RemotePlayer) : bool
{
    var loot : r_CoopLoot;
    var remains : W3ActorRemains;
    var events : array<string>;
    var i : int;
    loot = client.getCoopLoot();
    events = loot.TakeEvents();
    for(i = 0; i < events.Size(); i += 1) { W3T_Log("CORPSE member " + events[i]); }
    if(!client.getInParty())
    {
        thePlayer.SetImmortalityMode(AIM_Invulnerable, AIC_Cheat, true);
        client.joinParty(leader.username);
        return false;
    }
    remains = loot.NewestCorpseRemains();
    W3T_Log("CORPSE member step=" + bot.scenarioStep + " puppets=" + client.getCoopEnemies().PuppetCount() + " filled=" + loot.corpsesFilled
        + " ownRollsEmptied=" + loot.corpsesCleared + " bags=" + loot.corpseBagsMade + " lootApplied=" + loot.lootApplied + " last=" + loot.lastCorpseFilled
        + " spirits=" + W3T_CorpseHas(remains, 'Dwarven spirit') + " crowns=" + W3T_CorpseHas(remains, 'Crowns') + " empty=" + (remains && remains.IsEmpty()));
    if(bot.scenarioStep < 0) { return false; }
    if(bot.scenarioStep == 0 && loot.corpsesFilled >= 1 && remains)
    {
        if(W3T_CorpseHas(remains, 'Dwarven spirit') != 3 || W3T_CorpseHas(remains, 'Crowns') != 25)
        {
            W3T_Log("CORPSE member FAIL this corpse does not hold the leader's loot");
            bot.scenarioStep = -1;
            return false;
        }
        W3T_Log("CORPSE member takes a Dwarven spirit");
        remains.GetInventory().RemoveItemByName('Dwarven spirit', 1);
        bot.scenarioStep = 1;
    }
    if(bot.scenarioStep == 1 && loot.lootApplied >= 1 && remains && remains.IsEmpty()) { bot.scenarioStep = 2; }
    return bot.scenarioStep == 2;
}

// How many of this item a corpse holds (-1 without one).
function W3T_CorpseHas(remains : W3ActorRemains, itemName : name) : int
{
    if(!remains || !remains.GetInventory()) { return -1; }
    return remains.GetInventory().GetItemQuantityByName(itemName);
}
