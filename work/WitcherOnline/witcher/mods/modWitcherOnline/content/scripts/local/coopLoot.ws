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
// Corpses of shared enemies (coopEnemies.ws) lie in a different spot on each PC, so they are matched by
// the enemy instead, "<leader epoch>.<netId>" (x "c", y that key, z 0 in a loot event). Their loot is the
// party leader's game's roll: the leader sends what its corpse holds once its loot dropped, and a member's
// game puts exactly that in its own corpse (its own roll is emptied: one corpse, one loot). From then on a
// take on either PC is taken on the other, as for containers.
//   "coop lc count (key items (name quantity)...)..."   the leader's last corpses' loot
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
    private var corpsesSentKeys : array<string>; // leader: corpses whose loot was sent
    private var corpseMessages : array<string>;  // leader: "key items (name quantity)...", the newest last
    private var corpseFilled : array<string>;    // member: corpses holding the leader's loot here
    private var corpseBags : array<W3ActorRemains>; // member: the remains holding it, by corpseFilled
    private var corpseWaiting : array<string>;   // member: leader loot whose corpse is not ready here
    private var corpseWaitingSince : array<float>;
    private var lastCorpseScan : float;

    public var rewardsShared : int;      // rewards announced
    public var rewardsReceived : int;    // XP given for a party member's reward
    public var rewardsXpSkipped : int;   // the game gave a reward whose XP this player already had
    public var lootSent : int;
    public var lootApplied : int;
    public var lootMissed : int;         // given up after 10 minutes
    public var lastLootApplied : string;
    public var lastLootEmptied : bool;   // the last applied event's container is empty here now
    public var corpsesSent : int;        // leader: corpse loot sent
    public var corpsesFilled : int;      // member: corpses given the leader's loot
    public var corpsesCleared : int;     // member: own rolls emptied
    public var corpseBagsMade : int;     // member: no remains here, a loot bag made for the leader's loot
    public var corpsesMissed : int;
    public var lastCorpseFilled : string;

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

    public function OnContainerTaken(container : W3Container, itemName : name, quantity : int, questItem : bool, emptied : bool)
    {
        var text, itemText, where, key : string;
        var pos : Vector;
        var i : int;
        if(applyingRemote || !container || quantity <= 0 || questItem || !InParty()) { return; }
        itemText = NameToString(itemName);
        if(!CoopSafeField(itemText)) { return; }
        key = CorpseKey(container);
        if(key != "")
        {
            // the leader's corpse loot not sent yet: what it sends will not have this item. A member's
            // corpse without the leader's loot yet holds nothing to share (its own roll is emptied).
            if(!corpsesSentKeys.Contains(key) && !corpseFilled.Contains(key)) { return; }
            where = "c " + key + " 0";
        }
        else
        {
            pos = container.GetWorldPosition();
            where = FloatToStringPrec(pos.X, 2) + " " + FloatToStringPrec(pos.Y, 2) + " " + FloatToStringPrec(pos.Z, 2);
        }
        if(epoch == "") { epoch = IntToString(theGame.GetLocalTimeAsMilliseconds() % 1000000); }
        lootCounter += 1;
        lootEvents.PushBack(epoch + "-" + lootCounter + " " + where + " " + quantity + " " + CoopEncode(itemText) + " " + CoopBit(emptied));
        if(lootEvents.Size() > 6) { lootEvents.Erase(0); }
        text = "coop lt " + lootEvents.Size();
        for(i = 0; i < lootEvents.Size(); i += 1) { text += " " + lootEvents[i]; }
        lootSent += 1;
        Record("LOOT_SENT " + quantity + " " + itemText + " at " + where);
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
            // the native side has turned the name's '*' back into spaces: encode it again for the event
            lootEvent = WO_Str(k) + " " + WO_Str(k + 1) + " " + WO_Str(k + 2) + " " + WO_Str(k + 3) + " " + WO_Str(k + 4) + " " + CoopEncode(WO_Str(k + 5)) + " " + WO_Str(k + 6);
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
        if(f.Size() != 7) { Record("LOOT_BAD_EVENT " + lootEvent); return true; }
        quantity = StringToInt(f[4], 0);
        itemName = WO_ToName(CoopDecode(f[5]));
        if(f[1] == "c")
        {
            // a member applies takes on a corpse only once it holds the leader's loot
            if(Coop().GetRole() == 2 && !corpseFilled.Contains(f[2])) { return false; }
            container = CorpseRemains(f[2]);
        }
        else
        {
            pos = Vector(StringToFloat(f[1], 0), StringToFloat(f[2], 0), StringToFloat(f[3], 0));
            FindGameplayEntitiesInSphere(entities, pos, 0.75, 8);
            for(i = 0; i < entities.Size() && !container; i += 1)
            {
                container = (W3Container)entities[i];
                if(container && VecDistance(container.GetWorldPosition(), pos) > 0.05) { container = NULL; }
            }
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
        var container : W3Container;
        var i : int;
        var d, best : float;
        f = CoopSplit(lootEvent, " ");
        if(f.Size() != 7) { return "bad event"; }
        if(f[1] == "c")
        {
            if(!Coop().CorpseOfKey(f[2])) { return "no corpse " + f[2] + " here"; }
            if(Coop().GetRole() == 2 && !corpseFilled.Contains(f[2])) { return "corpse " + f[2] + " without the leader's loot yet"; }
            return "corpse " + f[2] + " has no remains here";
        }
        pos = Vector(StringToFloat(f[1], 0), StringToFloat(f[2], 0), StringToFloat(f[3], 0));
        FindGameplayEntitiesInSphere(entities, pos, 30, 50);
        best = -1;
        for(i = 0; i < entities.Size(); i += 1)
        {
            container = (W3Container)entities[i];
            if(!container) { continue; }
            d = VecDistance(container.GetWorldPosition(), pos);
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

    // ------------------------------------------------------------ corpses

    private function Coop() : r_CoopEnemies { return theGame.r_getMultiplayerClient().getCoopEnemies(); }

    // The key of a shared enemy's corpse this container holds the loot of, "" for any other container.
    private function CorpseKey(container : W3Container) : string
    {
        var remains : W3ActorRemains;
        remains = (W3ActorRemains)container;
        if(!remains || !remains.GetOwner()) { return ""; }
        return Coop().CorpseKeyOf(remains.GetOwner());
    }

    // Every remains in this world holding the loot of this dead NPC.
    private function RemainsOf(npc : CNewNPC) : array<W3ActorRemains>
    {
        var entities : array<CGameplayEntity>;
        var found : array<W3ActorRemains>;
        var remains : W3ActorRemains;
        var i : int;
        if(!npc) { return found; }
        FindGameplayEntitiesInSphere(entities, npc.GetWorldPosition(), 6.0, 32);
        for(i = 0; i < entities.Size(); i += 1)
        {
            remains = (W3ActorRemains)entities[i];
            if(remains && remains.GetOwner() == (CActor)npc) { found.PushBack(remains); }
        }
        return found;
    }

    // The corpse's loot here: on a member the remains given the leader's loot, on the leader its own.
    private function CorpseRemains(key : string) : W3ActorRemains
    {
        var found : array<W3ActorRemains>;
        var i : int;
        i = corpseFilled.FindFirst(key);
        if(i >= 0 && corpseBags[i]) { return corpseBags[i]; }
        found = RemainsOf(Coop().CorpseOfKey(key));
        if(found.Size() == 0) { return NULL; }
        return found[0];
    }

    // What a corpse holds for a player to take: "count (name quantity)...", names encoded.
    private function LootOf(remains : W3ActorRemains) : string
    {
        var inv : CInventoryComponent;
        var ids : array<SItemUniqueId>;
        var names : array<string>;
        var quantities : array<int>;
        var itemText, text : string;
        var i, k : int;
        if(remains) { inv = remains.GetInventory(); }
        if(inv) { inv.GetAllItems(ids); }
        for(i = 0; i < ids.Size(); i += 1)
        {
            if(!Shareable(inv, ids[i])) { continue; }
            itemText = NameToString(inv.GetItemName(ids[i]));
            if(!CoopSafeField(itemText)) { continue; }
            k = names.FindFirst(itemText);
            if(k < 0)
            {
                if(names.Size() >= 16) { continue; }
                names.PushBack(itemText);
                quantities.PushBack(0);
                k = names.Size() - 1;
            }
            quantities[k] += inv.GetItemQuantity(ids[i]);
        }
        text = IntToString(names.Size());
        for(i = 0; i < names.Size(); i += 1) { text += " " + CoopEncode(names[i]) + " " + quantities[i]; }
        return text;
    }

    // Loot a player can take and that is the same everywhere (quest items are each game's own).
    private function Shareable(inv : CInventoryComponent, id : SItemUniqueId) : bool
    {
        return !inv.ItemHasTag(id, 'Quest') && !inv.ItemHasTag(id, 'NoDrop') && !inv.ItemHasTag(id, theGame.params.TAG_DONT_SHOW);
    }

    // Leader: every corpse's loot once it has dropped (or after 10 s without any: nothing to loot).
    private function SendCorpses(now : float)
    {
        var coop : r_CoopEnemies;
        var found : array<W3ActorRemains>;
        var remains : W3ActorRemains;
        var key, text : string;
        var i, sent : int;
        coop = Coop();
        for(i = 0; i < coop.CorpseCount(); i += 1)
        {
            key = coop.CorpseKeyAt(i);
            if(corpsesSentKeys.Contains(key) || now - coop.CorpseDiedAt(i) > 120) { continue; }
            found = RemainsOf(coop.CorpseNpcAt(i));
            remains = NULL;
            if(found.Size() > 0) { remains = found[0]; }
            if(!remains && now - coop.CorpseDiedAt(i) < 10) { continue; }
            corpsesSentKeys.PushBack(key);
            if(corpsesSentKeys.Size() > 64) { corpsesSentKeys.Erase(0); }
            corpseMessages.PushBack(key + " " + LootOf(remains));
            if(corpseMessages.Size() > 4) { corpseMessages.Erase(0); }
            corpsesSent += 1;
            sent += 1;
            Record("CORPSE_SENT " + key + " " + LootOf(remains));
        }
        if(sent == 0) { return; }
        text = "coop lc " + corpseMessages.Size();
        for(i = 0; i < corpseMessages.Size(); i += 1) { text += " " + corpseMessages[i]; }
        WO_Send(text);
    }

    private function OnCorpses(sender : string, count : int)
    {
        var n, i, k, items, j : int;
        var entry, key : string;
        if(Coop().GetRole() != 2 || sender != theGame.r_getMultiplayerClient().getJoinedParty()) { return; }
        n = StringToInt(WO_Str(1), 0);
        k = 2;
        for(i = 0; i < n && k + 1 < count; i += 1)
        {
            key = WO_Str(k);
            items = StringToInt(WO_Str(k + 1), 0);
            if(k + 2 + items * 2 > count) { return; }
            // the native side has turned the names' '*' back into spaces: encode them again
            entry = key + " " + items;
            for(j = 0; j < items; j += 1) { entry += " " + CoopEncode(WO_Str(k + 2 + j * 2)) + " " + WO_Str(k + 3 + j * 2); }
            k += 2 + items * 2;
            if(corpseFilled.Contains(key) || corpseWaiting.Contains(entry)) { continue; }
            if(!FillCorpse(entry))
            {
                corpseWaiting.PushBack(entry);
                corpseWaitingSince.PushBack(theGame.GetEngineTimeAsSeconds());
            }
        }
    }

    // Member: the leader's loot into this game's corpse of the same enemy, instead of its own roll. False
    // while that corpse is not here yet (the leader's game saw the death first) or has no remains yet.
    private function FillCorpse(entry : string) : bool
    {
        var f : array<string>;
        var npc : CNewNPC;
        var found : array<W3ActorRemains>;
        var remains : W3ActorRemains;
        var inv : CInventoryComponent;
        var template : CEntityTemplate;
        var tags : array<name>;
        var i, items : int;
        var died : float;
        f = CoopSplit(entry, " ");
        if(f.Size() < 2) { return true; }
        items = StringToInt(f[1], 0);
        npc = Coop().CorpseOfKey(f[0]);
        if(!npc) { return false; }
        died = -1;
        for(i = 0; i < Coop().CorpseCount(); i += 1) { if(Coop().CorpseKeyAt(i) == f[0]) { died = Coop().CorpseDiedAt(i); } }
        found = RemainsOf(npc);
        if(found.Size() > 0) { remains = found[0]; }
        if(!remains)
        {
            // its own death dropped nothing (yet): give it 5 s, then bring a bag for the leader's loot
            if(items == 0) { corpseFilled.PushBack(f[0]); corpseBags.PushBack(NULL); return true; }
            if(theGame.GetEngineTimeAsSeconds() - died < 5.0) { return false; }
            template = (CEntityTemplate)LoadResource("lootbag");
            tags.PushBack('lootbag');
            if(template) { remains = (W3ActorRemains)theGame.CreateEntity(template, npc.GetWorldPosition(), npc.GetWorldRotation(), true, false, false, PM_DontPersist, tags); }
            if(!remains) { Record("CORPSE_NO_BAG " + f[0]); return false; }
            remains.LootDropped(npc);
            corpseBagsMade += 1;
        }
        inv = remains.GetInventory();
        if(!inv) { return false; }
        applyingRemote = true;
        ClearLoot(remains);
        for(i = 0; i < items && 3 + i * 2 < f.Size(); i += 1) { inv.AddAnItem(WO_ToName(CoopDecode(f[2 + i * 2])), StringToInt(f[3 + i * 2], 1)); }
        applyingRemote = false;
        remains.RequestUpdateContainer();
        corpseFilled.PushBack(f[0]);
        corpseBags.PushBack(remains);
        if(corpseFilled.Size() > 64) { corpseFilled.Erase(0); corpseBags.Erase(0); }
        corpsesFilled += 1;
        lastCorpseFilled = f[0] + " " + LootOf(remains);
        Record("CORPSE_FILLED " + lastCorpseFilled);
        return true;
    }

    private function ClearLoot(remains : W3ActorRemains)
    {
        var inv : CInventoryComponent;
        var ids : array<SItemUniqueId>;
        var i : int;
        inv = remains.GetInventory();
        if(!inv) { return; }
        inv.GetAllItems(ids);
        for(i = 0; i < ids.Size(); i += 1)
        {
            if(Shareable(inv, ids[i])) { inv.RemoveItem(ids[i], inv.GetItemQuantity(ids[i])); }
        }
    }

    // Member: a shared enemy's corpse drops this game's own roll; it holds only the leader's loot, so
    // every other remains of it here is emptied (before the leader's loot arrives as well as after).
    private function ClearOwnRolls(now : float)
    {
        var coop : r_CoopEnemies;
        var found : array<W3ActorRemains>;
        var key : string;
        var i, j, k : int;
        coop = Coop();
        for(i = 0; i < coop.CorpseCount(); i += 1)
        {
            if(now - coop.CorpseDiedAt(i) > 60) { continue; }
            key = coop.CorpseKeyAt(i);
            k = corpseFilled.FindFirst(key);
            found = RemainsOf(coop.CorpseNpcAt(i));
            for(j = 0; j < found.Size(); j += 1)
            {
                if((k >= 0 && found[j] == corpseBags[k]) || found[j].IsEmpty()) { continue; }
                applyingRemote = true;
                ClearLoot(found[j]);
                applyingRemote = false;
                found[j].RequestUpdateContainer();
                corpsesCleared += 1;
                Record("CORPSE_OWN_ROLL_EMPTIED " + key);
            }
        }
    }

    // Tests: the newest shared corpse's loot here (a member's given the leader's loot, the leader's sent).
    public function NewestCorpseRemains() : W3ActorRemains
    {
        if(corpseFilled.Size() > 0) { return CorpseRemains(corpseFilled[corpseFilled.Size() - 1]); }
        if(corpsesSentKeys.Size() > 0) { return CorpseRemains(corpsesSentKeys[corpsesSentKeys.Size() - 1]); }
        return NULL;
    }

    private function CorpseTick(now : float)
    {
        var i, role : int;
        if(now - lastCorpseScan < 0.5) { return; }
        lastCorpseScan = now;
        role = Coop().GetRole();
        if(role == 1) { SendCorpses(now); }
        if(role != 2) { return; }
        ClearOwnRolls(now);
        for(i = corpseWaiting.Size() - 1; i >= 0; i -= 1)
        {
            if(FillCorpse(corpseWaiting[i])) { }
            else if(now - corpseWaitingSince[i] < 120 && now >= corpseWaitingSince[i]) { continue; }
            else
            {
                corpsesMissed += 1;
                Record("CORPSE_MISSED " + corpseWaiting[i]);
            }
            corpseWaiting.Erase(i);
            corpseWaitingSince.Erase(i);
        }
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
        else if(WO_Str(0) == "lc") { OnCorpses(sender, count); }
    }

    public function Tick()
    {
        var now : float;
        var i : int;
        var parts : array<string>;
        now = theGame.GetEngineTimeAsSeconds();
        CorpseTick(now);
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
    var questItem, emptied : bool;
    var ids : array<SItemUniqueId>;
    var i : int;
    // called while the item is still in the container: empty is what remains after this take,
    // as IsEmpty counts it (no-drop and hidden items do not count)
    if(inv)
    {
        itemName = inv.GetItemName(itemId);
        questItem = inv.ItemHasTag(itemId, 'Quest');
        emptied = true;
        inv.GetAllItems(ids);
        for(i = 0; i < ids.Size() && emptied; i += 1)
        {
            if(ids[i] == itemId) { emptied = quantity >= inv.GetItemQuantity(itemId); }
            else { emptied = inv.ItemHasTag(ids[i], 'NoDrop') || inv.ItemHasTag(ids[i], theGame.params.TAG_DONT_SHOW); }
        }
    }
    wrappedMethod(itemId, quantity);
    if(IsNameValid(itemName)) { theGame.r_getMultiplayerClient().getCoopLoot().OnContainerTaken(this, itemName, quantity, questItem, emptied); }
    return true;
}

function CoopBit(value : bool) : string
{
    if(value) { return "1"; }
    return "0";
}
