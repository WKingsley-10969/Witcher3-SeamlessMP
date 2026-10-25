// Per-player characters: a joining player keeps their own Geralt in the host's game. The host's
// save brings the world (quests, choices, places); after it loads, this player's own level, XP,
// skill points, skills and their slots, money, recipes and items replace the host's. The
// character is recorded every 20 s to "The Witcher 3\coop-characters\<host>.txt" in this
// player's co-op profile (WO_CharacterStore). The first time with a host there is no record yet:
// the character starts as a copy of the host's Geralt and is this player's own from then on.
//
// World items stay with the world: quest items, notice-board notes and the game's hidden items
// are neither recorded nor removed. Also the character's: Gwent cards (the decks stay the
// world's, the game keeps them natively), the stash and the horse's gear (one inventory, the horse
// manager's), and Blood and Wine mutations.
//
// Record, one line per entry, fields separated by ';':
//   coop-character;1
//   level;<level>;<total XP>
//   skillpoints;<free>;<used>
//   money;<crowns>
//   skill;<ESkill>;<level>;<skill slot or -1>
//   recipe;<name>      schematic;<name>
//   reward;<name>      a reward whose XP this player had (coopLoot.ws)
//   item;<name>;<quantity>;<durability or -1>;<equipment slot or -1>;<enchantment>;<runes, comma>;<rune slots>;<autogen abilities, comma>;<charges or -1>
//   stash;...          as item, in the stash / horse inventory; the slot is a horse slot
//   mutations;<system enabled 0|1>;<equipped EPlayerMutationType>
//   mutation;<EPlayerMutationType>;<red>;<blue>;<green>;<skill points>;<overall progress>
import function WO_CharacterStore(text : string) : bool;
import function WO_CharacterLoad() : string;
import function WO_ToName(text : string) : name;

class r_CoopCharacter
{
    private var events : array<string>;
    private var loadedAt : float;
    private var lastStore : float;
    private var ready : bool;       // restored (or started fresh) since the last load: recording
    private var broken : bool;      // the stored record could not be read: never overwrite it

    public var restores : int;
    public var freshStarts : int;
    public var stores : int;
    public var problems : int;      // entries a restore could not apply
    public var lastRestoreItems : int;
    public var lastRestoreSkills : int;
    public var testPhase : int;          // bot tests (w3test_character.ws)
    public var testExpected : string;
    public var testQuestItems : int;

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

    private function Session() : r_CoopSession { return theGame.r_getMultiplayerClient().getCoopSession(); }
    public function IsReady() : bool { return ready; }

    // ------------------------------------------------------------ when

    public function OnGameStarted()
    {
        ready = false;
        loadedAt = theGame.GetEngineTimeAsSeconds();
    }

    public function Tick()
    {
        var now : float;
        if(!Session().IsJoining() || !GetWitcherPlayer() || broken) { return; }
        now = theGame.GetEngineTimeAsSeconds();
        // after the game's own start-up work on the loaded character (skill refund timers, 1.5 s)
        if(!ready)
        {
            if(now - loadedAt < 5.0 || theGame.IsDialogOrCutscenePlaying() || thePlayer.IsInNonGameplayCutscene()) { return; }
            Begin();
            return;
        }
        if(now - lastStore >= 20.0 && !theGame.IsDialogOrCutscenePlaying()) { Store(); }
    }

    private function Begin()
    {
        var text : string;
        text = WO_CharacterLoad();
        if(text == "")
        {
            freshStarts += 1;
            Record("FRESH no character for " + Session().HostName() + " yet: starting from the host's Geralt");
            theGame.GetGuiManager().ShowNotification("Your co-op character starts as a copy of " + Session().HostName() + "'s Geralt.");
        }
        else if(!Restore(text))
        {
            broken = true;
            Record("BROKEN the stored character could not be read: kept, not overwritten");
            theGame.GetGuiManager().ShowNotification("Your co-op character could not be read: playing the host's Geralt this time.");
            return;
        }
        ready = true;
        Store();
    }

    public function Store() : bool
    {
        lastStore = theGame.GetEngineTimeAsSeconds();
        if(!ready || broken) { return false; }
        if(WO_CharacterStore(Capture()))
        {
            stores += 1;
            return true;
        }
        Record("STORE_FAILED");
        return false;
    }

    // ------------------------------------------------------------ what

    // Equipment slots that belong to the character (not hair, horse or unused slots).
    private function CharacterSlot(slot : int) : bool
    {
        return (slot >= (int)EES_SilverSword && slot <= (int)EES_Quickslot2) || (slot >= (int)EES_Potion1 && slot <= (int)EES_SkillMutagen4 && slot != (int)EES_Mask);
    }

    // Items of the character rather than of the world.
    public function Personal(inv : CInventoryComponent, id : SItemUniqueId) : bool
    {
        var category : name;
        if(!CoopSafeField(NameToString(inv.GetItemName(id))) || inv.GetItemName(id) == 'Crowns') { return false; }   // the money line
        if(inv.ItemHasTag(id, 'GwintCard')) { return !inv.ItemHasTag(id, 'Quest'); }   // the collection, hidden in the inventory
        if(inv.ItemHasTag(id, 'Quest') || inv.ItemHasTag(id, 'NoticeBoardNote') || inv.ItemHasTag(id, theGame.params.TAG_DONT_SHOW)
            || inv.ItemHasTag(id, 'NoDrop') || inv.ItemHasTag(id, theGame.params.TAG_DONT_SHOW_ONLY_IN_PLAYERS)) { return false; }
        category = inv.GetItemCategory(id);
        return category != 'hair' && category != 'head' && category != 'fist' && category != 'work';
    }

    public function Capture() : string
    {
        var w : W3PlayerWitcher;
        var inv : CInventoryComponent;
        var pam : W3PlayerAbilityManager;
        var skills : array<SSkill>;
        var recipes : array<name>;
        var rewards : array<string>;
        var ids, equippedIds : array<SItemUniqueId>;
        var equippedSlots : array<int>;
        var id : SItemUniqueId;
        var i, j, slot : int;
        var text : string;
        w = GetWitcherPlayer();
        inv = w.GetInventory();
        pam = (W3PlayerAbilityManager)w.abilityManager;
        text = "coop-character;1";
        text += "|level;" + w.GetLevel() + ";" + w.levelManager.GetPointsTotal(EExperiencePoint);
        text += "|skillpoints;" + w.levelManager.GetPointsFree(ESkillPoint) + ";" + w.levelManager.GetPointsUsed(ESkillPoint);
        text += "|money;" + inv.GetMoney();
        skills = w.GetPlayerSkills();
        for(i = 0; i < skills.Size(); i += 1)
        {
            if(skills[i].level <= 0 || skills[i].isCoreSkill || skills[i].isTemporary || skills[i].skillType == S_SUndefined) { continue; }
            text += "|skill;" + (int)skills[i].skillType + ";" + skills[i].level + ";" + pam.GetSkillSlotID(skills[i].skillType);
        }
        recipes = w.GetAlchemyRecipes();
        for(i = 0; i < recipes.Size(); i += 1) { if(CoopSafeField(NameToString(recipes[i]))) { text += "|recipe;" + NameToString(recipes[i]); } }
        recipes.Clear();
        rewards = theGame.r_getMultiplayerClient().getCoopLoot().RewardsHad();
        for(i = 0; i < rewards.Size(); i += 1) { if(CoopSafeField(rewards[i])) { text += "|reward;" + rewards[i]; } }
        recipes = w.GetCraftingSchematicsNames();
        for(i = 0; i < recipes.Size(); i += 1) { if(CoopSafeField(NameToString(recipes[i]))) { text += "|schematic;" + NameToString(recipes[i]); } }
        text += CaptureMutations(pam) + CaptureStash(w);
        for(slot = 0; slot <= (int)EES_SkillMutagen4; slot += 1)
        {
            if(CharacterSlot(slot) && w.GetItemEquippedOnSlot((EEquipmentSlots)slot, id))
            {
                equippedIds.PushBack(id);
                equippedSlots.PushBack(slot);
            }
        }
        inv.GetAllItems(ids);
        for(i = 0; i < ids.Size(); i += 1)
        {
            if(!Personal(inv, ids[i])) { continue; }
            slot = -1;
            for(j = 0; j < equippedIds.Size(); j += 1) { if(equippedIds[j] == ids[i]) { slot = equippedSlots[j]; } }
            text += "|" + ItemLine(inv, ids[i], slot);
        }
        return text;
    }

    private function CaptureMutations(pam : W3PlayerAbilityManager) : string
    {
        var mutations : array<SMutation>;
        var text : string;
        var i : int;
        text = "|mutations;" + CoopBit(pam.IsMutationSystemEnabled()) + ";" + (int)pam.GetEquippedMutationType();
        mutations = pam.GetMutations();
        for(i = 0; i < mutations.Size(); i += 1)
        {
            if(mutations[i].progress.overallProgress < 0 && mutations[i].progress.redUsed + mutations[i].progress.blueUsed + mutations[i].progress.greenUsed
                + mutations[i].progress.skillpointsUsed == 0) { continue; }
            text += "|mutation;" + (int)mutations[i].type + ";" + mutations[i].progress.redUsed + ";" + mutations[i].progress.blueUsed + ";"
                + mutations[i].progress.greenUsed + ";" + mutations[i].progress.skillpointsUsed + ";" + mutations[i].progress.overallProgress;
        }
        return text;
    }

    // The stash and the horse's gear: the horse manager's inventory.
    private function CaptureStash(w : W3PlayerWitcher) : string
    {
        var horses : W3HorseManager;
        var inv : CInventoryComponent;
        var ids : array<SItemUniqueId>;
        var text : string;
        var i, slot : int;
        horses = w.GetHorseManager();
        if(!horses || !horses.GetInventoryComponent()) { return ""; }
        inv = horses.GetInventoryComponent();
        inv.GetAllItems(ids);
        for(i = 0; i < ids.Size(); i += 1)
        {
            if(!Personal(inv, ids[i])) { continue; }
            slot = -1;
            if(horses.IsItemEquipped(ids[i])) { slot = (int)horses.GetHorseSlotForItem(ids[i]); }
            text += "|stash" + StrAfterFirst(ItemLine(inv, ids[i], slot), "item");
        }
        return text;
    }

    private function ItemLine(inv : CInventoryComponent, id : SItemUniqueId, slot : int) : string
    {
        var names : array<name>;
        var abilities : array<name>;
        var durability : float;
        var enchantment, runes, autogen : string;
        var i, charges : int;
        durability = -1;
        charges = -1;
        if(inv.IsItemSingletonItem(id)) { charges = inv.SingletonItemGetAmmo(id); }
        if(inv.HasItemDurability(id)) { durability = inv.GetItemDurability(id); }
        // an enchantment fills the rune slots and lists itself as their runes
        if(inv.IsItemEnchanted(id)) { enchantment = NameToString(inv.GetEnchantment(id)); }
        else { inv.GetItemEnhancementItems(id, names); }
        for(i = 0; i < names.Size(); i += 1)
        {
            if(runes != "") { runes += ","; }
            runes += NameToString(names[i]);
        }
        inv.GetItemAbilities(id, abilities);
        for(i = 0; i < abilities.Size(); i += 1)
        {
            if(!StrBeginsWith(NameToString(abilities[i]), "autogen")) { continue; }
            if(autogen != "") { autogen += ","; }
            autogen += NameToString(abilities[i]);
        }
        return "item;" + NameToString(inv.GetItemName(id)) + ";" + inv.GetItemQuantity(id) + ";" + FloatToStringPrec(durability, 2) + ";" + slot
            + ";" + enchantment + ";" + runes + ";" + inv.GetItemEnhancementSlotsCount(id) + ";" + autogen + ";" + charges;
    }

    // ------------------------------------------------------------ restore

    // Replace the loaded (host's) character with the recorded one. False when the record is unreadable.
    public function Restore(text : string) : bool
    {
        var lines, f : array<string>;
        var w : W3PlayerWitcher;
        var inv : CInventoryComponent;
        var pam : W3PlayerAbilityManager;
        var ids : array<SItemUniqueId>;
        var id : SItemUniqueId;
        var i, j, lvl, xp, spFree, spUsed, money, slot : int;
        var skillTypes, skillLevels, skillSlots : array<int>;
        var itemLines, stashLines, mutationLines, rewards : array<string>;
        var horses : W3HorseManager;
        var stash : CInventoryComponent;
        lines = CoopSplit(text, "|");
        if(lines.Size() < 4 || lines[0] != "coop-character;1") { return false; }
        lvl = -1;
        for(i = 1; i < lines.Size(); i += 1)
        {
            f = CoopSplit(lines[i], ";");
            if(f[0] == "level" && f.Size() == 3) { lvl = StringToInt(f[1], -1); xp = StringToInt(f[2], 0); }
            else if(f[0] == "skillpoints" && f.Size() == 3) { spFree = StringToInt(f[1], 0); spUsed = StringToInt(f[2], 0); }
            else if(f[0] == "money" && f.Size() == 2) { money = StringToInt(f[1], 0); }
            else if(f[0] == "skill" && f.Size() == 4)
            {
                skillTypes.PushBack(StringToInt(f[1], 0));
                skillLevels.PushBack(StringToInt(f[2], 0));
                skillSlots.PushBack(StringToInt(f[3], -1));
            }
            else if(f[0] == "item" && f.Size() == 10) { itemLines.PushBack(lines[i]); }
            else if(f[0] == "stash" && f.Size() == 10) { stashLines.PushBack(lines[i]); }
            else if((f[0] == "mutation" && f.Size() == 7) || (f[0] == "mutations" && f.Size() == 3)) { mutationLines.PushBack(lines[i]); }
            else if(f[0] == "reward" && f.Size() == 2) { rewards.PushBack(f[1]); }
        }
        if(lvl < 1 || lvl > 100 || xp < 0 || spFree < 0 || spUsed < 0 || money < 0) { return false; }
        w = GetWitcherPlayer();
        inv = w.GetInventory();
        pam = (W3PlayerAbilityManager)w.abilityManager;
        problems = 0;

        // 1. the host's things off: horse gear and stash (unequipped horse gear goes to the pack),
        //    equipped gear, personal items, money, skills
        horses = w.GetHorseManager();
        if(horses) { stash = horses.GetInventoryComponent(); }
        if(stash)
        {
            for(slot = (int)EES_HorseBlinders; slot <= (int)EES_HorseTrophy; slot += 1) { horses.UnequipItem((EEquipmentSlots)slot); }
            stash.GetAllItems(ids);
            for(i = 0; i < ids.Size(); i += 1) { if(Personal(stash, ids[i])) { stash.RemoveItem(ids[i], stash.GetItemQuantity(ids[i])); } }
        }
        for(slot = 0; slot <= (int)EES_SkillMutagen4; slot += 1)
        {
            if(CharacterSlot(slot) && w.GetItemEquippedOnSlot((EEquipmentSlots)slot, id) && Personal(inv, id)) { w.UnequipItemFromSlot((EEquipmentSlots)slot); }
        }
        inv.GetAllItems(ids);
        for(i = 0; i < ids.Size(); i += 1) { if(Personal(inv, ids[i])) { inv.RemoveItem(ids[i], inv.GetItemQuantity(ids[i])); } }
        if(inv.GetMoney() > 0) { inv.RemoveMoney(inv.GetMoney()); }
        w.ResetCharacterDev();
        // mutations before skills: they unlock skill slots
        pam.CoopSetMutations(mutationLines);

        // 2. level and XP, then skill points: all of them free, so learning spends them as the game does
        w.levelManager.CoopSetLevel(lvl, xp);
        w.levelManager.CoopSetSkillPoints(spFree + spUsed, 0);
        pam.UpdateSkillSlots();
        for(i = 0; i < skillTypes.Size(); i += 1)
        {
            for(j = 0; j < skillLevels[i] && j < 10; j += 1) { w.AddSkill((ESkill)skillTypes[i]); }
            if(w.GetSkillLevel((ESkill)skillTypes[i]) != skillLevels[i]) { problems += 1; Record("SKILL_MISMATCH " + skillTypes[i]); }
        }
        w.levelManager.CoopSetSkillPoints(spFree, spUsed);
        pam.UpdateSkillSlots();
        for(i = 0; i < skillTypes.Size(); i += 1)
        {
            if(skillSlots[i] >= 0 && !w.EquipSkill((ESkill)skillTypes[i], skillSlots[i])) { problems += 1; Record("SKILL_SLOT_FAILED " + skillTypes[i] + " -> " + skillSlots[i]); }
        }

        // 3. recipes, money, items
        w.CoopSetRecipes(lines);
        theGame.r_getMultiplayerClient().getCoopLoot().RestoreRewards(rewards);
        if(money > 0) { inv.AddMoney(money); }
        for(i = 0; i < itemLines.Size(); i += 1) { RestoreItem(w, inv, CoopSplit(itemLines[i], ";"), NULL); }
        if(stash) { for(i = 0; i < stashLines.Size(); i += 1) { RestoreItem(w, stash, CoopSplit(stashLines[i], ";"), horses); } }

        restores += 1;
        lastRestoreItems = itemLines.Size();
        lastRestoreSkills = skillTypes.Size();
        Record("RESTORED level " + lvl + ", " + skillTypes.Size() + " skills, " + itemLines.Size() + " items, " + stashLines.Size() + " in the stash, "
            + Max(0, mutationLines.Size() - 1) + " mutations, " + money + " crowns, " + problems + " problems");
        if(problems == 0) { theGame.GetGuiManager().ShowNotification("Your own co-op character is back."); }
        else { theGame.GetGuiManager().ShowNotification("Your own co-op character is back (" + problems + " details could not be restored)."); }
        return true;
    }

    // An item into the pack (horses NULL) or the stash.
    private function RestoreItem(w : W3PlayerWitcher, inv : CInventoryComponent, f : array<string>, horses : W3HorseManager)
    {
        var ids, runeIds : array<SItemUniqueId>;
        var id : SItemUniqueId;
        var abilities : array<name>;
        var parts : array<string>;
        var quantity, slot, runeSlots, charges, i : int;
        var durability : float;
        var enchantment : name;
        quantity = StringToInt(f[2], 1);
        durability = StringToFloat(f[3], -1);
        slot = StringToInt(f[4], -1);
        runeSlots = StringToInt(f[7], 0);
        charges = StringToInt(f[9], -1);
        if(quantity < 1) { quantity = 1; }
        ids = inv.CoopAddItem(WO_ToName(f[1]), quantity);
        if(ids.Size() == 0)
        {
            problems += 1;
            Record("ITEM_FAILED " + f[1]);
            return;
        }
        id = ids[0];
        // recorded as the character's: a quest finished with it, the item keeps no quest tag
        if(inv.ItemHasTag(id, 'Quest')) { inv.RemoveItemTag(id, 'Quest'); }
        if(inv.ItemHasTag(id, 'NoticeBoardNote')) { inv.RemoveItemTag(id, 'NoticeBoardNote'); }
        if(charges >= 0 && inv.IsItemSingletonItem(id)) { inv.SingletonItemSetAmmo(id, charges); }
        // the item's level: the recorded autogen abilities, not ones generated for this level
        if(f[8] != "")
        {
            inv.GetItemAbilities(id, abilities);
            for(i = 0; i < abilities.Size(); i += 1) { if(StrBeginsWith(NameToString(abilities[i]), "autogen")) { inv.RemoveItemCraftedAbility(id, abilities[i]); } }
            parts = CoopSplit(f[8], ",");
            for(i = 0; i < parts.Size(); i += 1) { inv.AddItemCraftedAbility(id, WO_ToName(parts[i]), true); }
        }
        if(durability >= 0 && inv.HasItemDurability(id)) { inv.SetItemDurabilityScript(id, durability); }
        for(i = inv.GetItemEnhancementSlotsCount(id); i < runeSlots && i < 3; i += 1) { inv.AddSlot(id); }
        if(f[6] != "")
        {
            parts = CoopSplit(f[6], ",");
            for(i = 0; i < parts.Size(); i += 1)
            {
                runeIds = inv.AddAnItem(WO_ToName(parts[i]), 1, true, true);
                if(runeIds.Size() == 0 || !inv.EnhanceItemScript(id, runeIds[0]))
                {
                    problems += 1;
                    Record("RUNE_FAILED " + parts[i] + " on " + f[1]);
                    if(runeIds.Size() > 0) { inv.RemoveItem(runeIds[0], 1); }
                }
            }
        }
        if(f[5] != "")
        {
            enchantment = WO_ToName(f[5]);
            if(!inv.EnchantItem(id, enchantment, getEnchamtmentStatName(enchantment))) { problems += 1; Record("ENCHANT_FAILED " + f[5] + " on " + f[1]); }
        }
        if(slot >= 0 && horses && !inv.IsIdValid(horses.EquipItem(id))) { problems += 1; Record("HORSE_EQUIP_FAILED " + f[1] + " -> " + slot); }
        else if(slot >= 0 && !horses && !w.EquipItemInGivenSlot(id, (EEquipmentSlots)slot, false)) { problems += 1; Record("EQUIP_FAILED " + f[1] + " -> " + slot); }
    }

    // Lines of a record that the other does not have (both directions), for tests. Stacks of an
    // item count by their total: the game may split them differently when they are added again.
    public function Differences(a : string, b : string) : array<string>
    {
        var left, right, changes : array<string>;
        var i, j : int;
        var found : bool;
        left = CoopStacksTotalled(CoopSplit(a, "|"));
        right = CoopStacksTotalled(CoopSplit(b, "|"));
        for(i = 0; i < left.Size(); i += 1)
        {
            found = false;
            for(j = 0; j < right.Size() && !found; j += 1)
            {
                if(right[j] == left[i])
                {
                    right.Erase(j);
                    found = true;
                }
            }
            if(!found) { changes.PushBack("- " + left[i]); }
        }
        for(j = 0; j < right.Size(); j += 1) { changes.PushBack("+ " + right[j]); }
        return changes;
    }
}

function CoopSplit(text : string, sep : string) : array<string>
{
    var parts : array<string>;
    var head, rest : string;
    rest = text;
    while(StrSplitFirst(rest, sep, head, rest)) { parts.PushBack(head); }
    parts.PushBack(rest);
    return parts;
}

// Item lines that differ only in quantity become one line with the total quantity.
function CoopStacksTotalled(lines : array<string>) : array<string>
{
    var keys, others, totalled : array<string>;
    var sums : array<int>;
    var f : array<string>;
    var i, k : int;
    var key : string;
    for(i = 0; i < lines.Size(); i += 1)
    {
        f = CoopSplit(lines[i], ";");
        if(f[0] != "item" || f.Size() < 3)
        {
            others.PushBack(lines[i]);
            continue;
        }
        key = StrReplace(lines[i], ";" + f[2] + ";", ";*;");
        k = keys.FindFirst(key);
        if(k < 0)
        {
            keys.PushBack(key);
            sums.PushBack(0);
            k = keys.Size() - 1;
        }
        sums[k] += StringToInt(f[2], 0);
    }
    totalled = others;
    for(i = 0; i < keys.Size(); i += 1) { totalled.PushBack(StrReplace(keys[i], ";*;", ";" + sums[i] + ";")); }
    return totalled;
}

// Names written into a record must not contain its separators.
function CoopSafeField(text : string) : bool
{
    return text != "" && StrFindFirst(text, ";") < 0 && StrFindFirst(text, "|") < 0 && StrFindFirst(text, ",") < 0;
}

// An item with exactly this quantity, also a single-use item (bomb, oil) with more than one.
@addMethod(CInventoryComponent)
public function CoopAddItem(itemName : name, quantity : int) : array<SItemUniqueId>
{
    var ids : array<SItemUniqueId>;
    if(quantity < 2) { ids.PushBack(AddSingleItem(itemName, false, false, true)); }
    else { ids = AddMultiItem(itemName, quantity, false, false, true); }
    return ids;
}

// The level without the game's level-up flow: level-up abilities follow, XP is kept.
@addMethod(W3LevelManager)
public function CoopSetLevel(newLevel : int, totalExp : int)
{
    var i : int;
    var ability : name;
    for(i = level; i > newLevel; i -= 1)
    {
        ability = owner.GetLevelupAbility(i);
        if(IsNameValid(ability)) { owner.RemoveAbility(ability); }
    }
    for(i = level + 1; i <= newLevel; i += 1)
    {
        ability = owner.GetLevelupAbility(i);
        if(IsNameValid(ability)) { owner.AddAbility(ability); }
    }
    level = newLevel;
    points[EExperiencePoint].used = GetTotalExpForCurrLevel();
    points[EExperiencePoint].free = Max(0, totalExp - points[EExperiencePoint].used);
}

@addMethod(W3LevelManager)
public function CoopSetSkillPoints(free : int, used : int)
{
    points[ESkillPoint].free = free;
    points[ESkillPoint].used = used;
}

// Alchemy recipes and crafting schematics as recorded ("recipe;..." and "schematic;..." lines).
@addMethod(W3PlayerWitcher)
public function CoopSetRecipes(lines : array<string>)
{
    var i : int;
    var f : array<string>;
    alchemyRecipes.Clear();
    craftingSchematics.Clear();
    for(i = 0; i < lines.Size(); i += 1)
    {
        f = CoopSplit(lines[i], ";");
        if(f.Size() != 2) { continue; }
        if(f[0] == "recipe") { AddAlchemyRecipe(WO_ToName(f[1]), true, true); }
        else if(f[0] == "schematic") { AddCraftingSchematic(WO_ToName(f[1]), true, true); }
    }
}

// Mutations as recorded ("mutations;..." and "mutation;..." lines): research progress, the
// system's state and the equipped mutation. Without lines (an older record) they are left alone.
@addMethod(W3PlayerAbilityManager)
public function CoopSetMutations(lines : array<string>)
{
    var f : array<string>;
    var i, k : int;
    var equipped : EPlayerMutationType;
    if(lines.Size() == 0) { return; }
    ResetMutationsDev();
    equipped = EPMT_None;
    for(i = 0; i < lines.Size(); i += 1)
    {
        f = CoopSplit(lines[i], ";");
        if(f[0] == "mutations")
        {
            MutationSystemEnable(f[1] == "1");
            equipped = (EPlayerMutationType)StringToInt(f[2], 0);
            continue;
        }
        k = GetMutationIndex((EPlayerMutationType)StringToInt(f[1], 0));
        if(k < 0) { continue; }
        mutations[k].progress.redUsed = StringToInt(f[2], 0);
        mutations[k].progress.blueUsed = StringToInt(f[3], 0);
        mutations[k].progress.greenUsed = StringToInt(f[4], 0);
        mutations[k].progress.skillpointsUsed = StringToInt(f[5], 0);
        mutations[k].progress.overallProgress = StringToInt(f[6], -1);
        if(mutations[k].progress.overallProgress >= 100) { OnMutationFullyResearched(mutations[k].type); }
    }
    if(equipped != EPMT_None) { SetEquippedMutation(equipped); }
}
