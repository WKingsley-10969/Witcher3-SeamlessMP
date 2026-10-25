// Shared quest rewards and looted containers, in a party.
//
// Rewards: a reward the game gives this player (quest and contract rewards, location
// discoveries) is announced to the party. A party member who has not had it gets its XP, worked
// out by the game for that member's own level; money and items stay with whoever's game gave the
// reward. Each player has each reward's XP once: a fact "coop_rw_<player>_<reward>" marks it (kept
// in the host's save for the host, in the character record for a joining player), and a reward
// the game gives later, after the shared XP arrived, gives its money and items but no XP again.
//   "coop rw count name..."   this player's last rewards (the newest last), names encoded
//
// Containers: an item this player takes from a container (chest, corpse, barrel) is announced; a
// party member's game takes the same item out of the container at that spot, so it cannot be
// looted twice. Loot is rolled by each game, so the other container may hold other items: once
// this player has emptied a container, the other game empties it too. Quest items are left alone.
// An event whose container is not loaded on the other PC is retried for 10 minutes.
//   "coop lt count (id x y z quantity name emptied)..."   this player's last loot events
//
// Channel messages are state (only the newest one per channel arrives), so each carries the last
// few events and receivers skip what they applied before.

class r_CoopLoot
{
    private var events : array<string>;
    private var sentRewards : array<string>;     // the newest last
    private var lootEvents : array<string>;      // "id x y z quantity name emptied", the newest last
    private var lootCounter : int;
    private var epoch : string;
    private var appliedLoot : array<string>;     // ids of other players' loot events applied
    private var pendingLoot : array<string>;     // "sender|event" not applied yet: container not loaded
    private var pendingSince : array<float>;
    private var lastRetry : float;
    private var applyingRemote : bool;           // this game is removing a party member's loot
    private var rewardsHad : array<string>;      // a joining player's rewards, for the character record

    public var rewardsShared : int;      // rewards announced
    public var rewardsReceived : int;    // XP given for a party member's reward
    public var rewardsXpSkipped : int;   // the game gave a reward whose XP this player already had
    public var lootSent : int;
    public var lootApplied : int;
    public var lootMissed : int;         // given up after 10 minutes
    public var lastLootApplied : string;
    public var lastLootEmptied : bool;   // the last applied event's container is empty here now

    public function TakeEvents() : array<string>
    {
        var taken : array<string>;
        taken = events;
        events.Clear();
        return taken;
    }

    private function Record(text : string)
    {
        events.PushBack(FloatToStringPrec(theGame.GetEngineTimeAsSeconds(), 2) + " " + text);
        if(events.Size() > 100) { events.Erase(0); }
    }

    private function Me() : string { return theGame.r_getMultiplayerClient().getUsername(); }

    private function InParty() : bool { return theGame.r_getMultiplayerClient().getInParty() || theGame.r_getMultiplayerClient().getCoopEnemies().GetRole() == 1; }

    // ------------------------------------------------------------ rewards

    private function RewardFact(rewardName : string) : string { return "coop_rw_" + Me() + "_" + rewardName; }

    public function HadReward(rewardName : string) : bool { return FactsQuerySum(RewardFact(rewardName)) > 0; }

    private function MarkReward(rewardName : string)
    {
        if(HadReward(rewardName)) { return; }
        FactsAdd(RewardFact(rewardName), 1);
        rewardsHad.PushBack(rewardName);
    }

    // The game gives this player a reward. False: give it without its XP (already had it).
    public function OnLocalReward(rewardName : name, rewrd : SReward) : bool
    {
        var rewardText : string;
        rewardText = NameToString(rewardName);
        if(applyingRemote || rewrd.experience <= 0 || !CoopSafeField(rewardText)) { return true; }
        if(HadReward(rewardText))
        {
            rewardsXpSkipped += 1;
            Record("REWARD_XP_ALREADY " + rewardText + ": money and items only");
            return false;
        }
        MarkReward(rewardText);
        if(InParty()) { ShareReward(rewardText); }
        return true;
    }

    private function ShareReward(rewardText : string)
    {
        var text : string;
        var i : int;
        sentRewards.PushBack(rewardText);
        if(sentRewards.Size() > 6) { sentRewards.Erase(0); }
        text = "coop rw " + sentRewards.Size();
        for(i = 0; i < sentRewards.Size(); i += 1) { text += " " + sentRewards[i]; }
        rewardsShared += 1;
        Record("REWARD_SHARED " + rewardText);
        WO_Send(text);
    }

    private function OnRewards(sender : string, count : int)
    {
        var n, i : int;
        var rewardText : string;
        var rewrd : SReward;
        n = StringToInt(WO_Str(1), 0);
        for(i = 0; i < n && 2 + i < count; i += 1)
        {
            rewardText = WO_Str(2 + i);
            if(!CoopSafeField(rewardText) || HadReward(rewardText)) { continue; }
            if(!theGame.GetReward(WO_ToName(rewardText), rewrd) || rewrd.experience <= 0) { continue; }
            MarkReward(rewardText);
            // the game's own XP for this player's level; nothing else of the reward
            rewrd.gold = 0;
            rewrd.items.Clear();
            rewrd.achievement = 0;
            applyingRemote = true;
            theGame.CoopGiveRewardXp(WO_ToName(rewardText), rewrd);
            applyingRemote = false;
            rewardsReceived += 1;
            Record("REWARD_RECEIVED " + rewardText + " from " + sender);
            theGame.GetGuiManager().ShowNotification("Party reward: experience from " + sender + "'s quest.");
        }
    }

    // A joining player's rewards for the character record (coopCharacter.ws), and back after a load.
    public function RewardsHad() : array<string> { return rewardsHad; }

    public function RestoreRewards(names : array<string>)
    {
        var i : int;
        rewardsHad.Clear();
        for(i = 0; i < names.Size(); i += 1)
        {
            if(!HadReward(names[i])) { FactsAdd(RewardFact(names[i]), 1); }
            rewardsHad.PushBack(names[i]);
        }
    }

    // ------------------------------------------------------------ containers

    public function OnContainerTaken(container : W3Container, itemName : name, quantity : int, questItem : bool)
    {
        var text, itemText : string;
        var pos : Vector;
        var i : int;
        if(applyingRemote || !container || quantity <= 0 || questItem || !InParty()) { return; }
        itemText = NameToString(itemName);
        if(!CoopSafeField(itemText)) { return; }
        if(epoch == "") { epoch = IntToString(theGame.GetLocalTimeAsMilliseconds() % 1000000); }
        lootCounter += 1;
        pos = container.GetWorldPosition();
        lootEvents.PushBack(epoch + "-" + lootCounter + " " + FloatToStringPrec(pos.X, 2) + " " + FloatToStringPrec(pos.Y, 2) + " " + FloatToStringPrec(pos.Z, 2)
            + " " + quantity + " " + CoopEncode(itemText) + " " + (int)container.IsEmpty());
        if(lootEvents.Size() > 6) { lootEvents.Erase(0); }
        text = "coop lt " + lootEvents.Size();
        for(i = 0; i < lootEvents.Size(); i += 1) { text += " " + lootEvents[i]; }
        lootSent += 1;
        Record("LOOT_SENT " + quantity + " " + itemText + " at " + FloatToStringPrec(pos.X, 1) + "," + FloatToStringPrec(pos.Y, 1));
        WO_Send(text);
    }

    private function OnLoot(sender : string, count : int)
    {
        var n, i, k : int;
        var lootEvent : string;
        n = StringToInt(WO_Str(1), 0);
        for(i = 0; i < n && 2 + i * 7 + 6 < count; i += 1)
        {
            k = 2 + i * 7;
            lootEvent = WO_Str(k) + " " + WO_Str(k + 1) + " " + WO_Str(k + 2) + " " + WO_Str(k + 3) + " " + WO_Str(k + 4) + " " + WO_Str(k + 5) + " " + WO_Str(k + 6);
            if(appliedLoot.Contains(sender + ":" + WO_Str(k)) || pendingLoot.Contains(sender + "|" + lootEvent)) { continue; }
            if(!ApplyLoot(sender, lootEvent))
            {
                Record("LOOT_WAITING " + lootEvent + " from " + sender + ": " + NearestContainer(lootEvent));
                pendingLoot.PushBack(sender + "|" + lootEvent);
                pendingSince.PushBack(theGame.GetEngineTimeAsSeconds());
            }
        }
    }

    // Take the item out of the container at that spot. False when no such container is loaded here.
    private function ApplyLoot(sender : string, lootEvent : string) : bool
    {
        var f : array<string>;
        var entities : array<CGameplayEntity>;
        var container : W3Container;
        var inv : CInventoryComponent;
        var pos : Vector;
        var itemName : name;
        var ids : array<SItemUniqueId>;
        var i, quantity, have : int;
        f = CoopSplit(lootEvent, " ");
        if(f.Size() != 7) { return true; }
        pos = Vector(StringToFloat(f[1], 0), StringToFloat(f[2], 0), StringToFloat(f[3], 0));
        quantity = StringToInt(f[4], 0);
        itemName = WO_ToName(CoopDecode(f[5]));
        FindGameplayEntitiesInSphere(entities, pos, 0.75, 8);
        for(i = 0; i < entities.Size() && !container; i += 1)
        {
            container = (W3Container)entities[i];
            if(container && VecDistance(container.GetWorldPosition(), pos) > 0.05) { container = NULL; }
        }
        if(!container) { return false; }
        Remember(sender + ":" + f[0]);
        inv = container.GetInventory();
        if(!inv) { return true; }
        have = inv.GetItemQuantityByName(itemName);
        applyingRemote = true;
        if(have > 0) { inv.RemoveItemByName(itemName, Min(quantity, have)); }
        // the looter emptied it: so does this game, whatever its own roll put in it
        if(f[6] == "1")
        {
            inv.GetAllItems(ids);
            for(i = 0; i < ids.Size(); i += 1)
            {
                if(!inv.ItemHasTag(ids[i], 'Quest') && !inv.ItemHasTag(ids[i], 'NoDrop')) { inv.RemoveItem(ids[i], inv.GetItemQuantity(ids[i])); }
            }
        }
        applyingRemote = false;
        container.RequestUpdateContainer();
        lootApplied += 1;
        lastLootEmptied = container.IsEmpty();
        lastLootApplied = CoopDecode(f[5]) + " x" + Min(quantity, have) + " at " + f[1] + "," + f[2] + "," + f[3];
        Record("LOOT_APPLIED " + sender + " took " + quantity + " " + CoopDecode(f[5]) + " (" + have + " here), emptied=" + f[6] + ", empty here now=" + lastLootEmptied);
        return true;
    }

    // For the log: how far the nearest container is from where the looter's was.
    private function NearestContainer(lootEvent : string) : string
    {
        var f : array<string>;
        var entities : array<CGameplayEntity>;
        var pos : Vector;
        var i : int;
        var d, best : float;
        f = CoopSplit(lootEvent, " ");
        if(f.Size() != 7) { return "bad event"; }
        pos = Vector(StringToFloat(f[1], 0), StringToFloat(f[2], 0), StringToFloat(f[3], 0));
        FindGameplayEntitiesInSphere(entities, pos, 30, 50);
        best = -1;
        for(i = 0; i < entities.Size(); i += 1)
        {
            if(!(W3Container)entities[i]) { continue; }
            d = VecDistance(entities[i].GetWorldPosition(), pos);
            if(best < 0 || d < best) { best = d; }
        }
        if(best < 0) { return "no container within 30 m of " + VecToString(pos); }
        return "nearest container " + FloatToStringPrec(best, 3) + " m from " + VecToString(pos);
    }

    private function Remember(id : string)
    {
        appliedLoot.PushBack(id);
        if(appliedLoot.Size() > 200) { appliedLoot.Erase(0); }
    }

    // ------------------------------------------------------------ network and clock

    public function OnMessage()
    {
        var sender : string;
        var count : int;
        sender = WO_Str(-1);
        count = StringToInt(WO_Str(-3), 0);
        if(count < 2 || sender == Me() || !CoopSameParty(sender)) { return; }
        if(WO_Str(0) == "rw") { OnRewards(sender, count); }
        else if(WO_Str(0) == "lt") { OnLoot(sender, count); }
    }

    public function Tick()
    {
        var now : float;
        var i : int;
        var parts : array<string>;
        now = theGame.GetEngineTimeAsSeconds();
        if(pendingLoot.Size() == 0 || now - lastRetry < 5.0) { return; }
        lastRetry = now;
        for(i = pendingLoot.Size() - 1; i >= 0; i -= 1)
        {
            parts = CoopSplit(pendingLoot[i], "|");
            if(parts.Size() == 2 && ApplyLoot(parts[0], parts[1])) { }
            else if(now - pendingSince[i] < 600 && now >= pendingSince[i]) { continue; }
            else
            {
                lootMissed += 1;
                Record("LOOT_MISSED " + parts[1]);
            }
            pendingLoot.Erase(i);
            pendingSince.Erase(i);
        }
    }
}

// Is this player in the same party as user (either one leading it)?
function CoopSameParty(user : string) : bool
{
    var client : r_MultiplayerClient;
    var globals : array<r_RemotePlayer>;
    var me, mine : string;
    var i : int;
    client = theGame.r_getMultiplayerClient();
    me = client.getUsername();
    mine = "";
    if(client.getInParty()) { mine = client.getJoinedParty(); }
    if(mine != "" && user == mine) { return true; }
    globals = client.getGlobalPlayers();
    for(i = 0; i < globals.Size(); i += 1)
    {
        if(!globals[i] || globals[i].username != user || !globals[i].inParty) { continue; }
        return globals[i].joinedParty == me || (mine != "" && globals[i].joinedParty == mine);
    }
    return false;
}

// The reward handler's XP, for a reward of a party member's quest.
@addMethod(CR4Game)
public function CoopGiveRewardXp(rewardName : name, rewrd : SReward)
{
    OnGiveReward(thePlayer, rewardName, rewrd);
}

@wrapMethod(CR4Game)
function OnGiveReward(target : CEntity, rewardName : name, rewrd : SReward)
{
    var client : r_MultiplayerClient;
    client = r_getMultiplayerClient();
    if(target && target == thePlayer && client && !client.getCoopLoot().OnLocalReward(rewardName, rewrd))
    {
        rewrd.experience = 0;
    }
    wrappedMethod(target, rewardName, rewrd);
    return true;
}

@wrapMethod(W3Container)
function OnItemTaken(itemId : SItemUniqueId, quantity : int)
{
    var itemName : name;
    var questItem : bool;
    if(inv)
    {
        itemName = inv.GetItemName(itemId);
        questItem = inv.ItemHasTag(itemId, 'Quest');
    }
    wrappedMethod(itemId, quantity);
    if(IsNameValid(itemName)) { theGame.r_getMultiplayerClient().getCoopLoot().OnContainerTaken(this, itemName, quantity, questItem); }
    return true;
}
