// player_character: the second PC joins the host's session (as session_join) and keeps its own
// character across a reload of the host's save.
// 1. First time with this host: no record, so the character starts as a copy of the host's
//    Geralt. The bot then makes it its own: two levels lower (the restore must lower the host's
//    level), a new skill, gear with a rune, an enchantment and a set durability, equipped armour,
//    more crowns. It stores the character and loads the host's save again.
// 2. After the reload the host's Geralt is back; the restore must turn it into the stored
//    character: the character recorded again must match the stored one line for line, and the
//    world's quest items must be untouched.
// The host's game must never touch its own character.
function W3T_PlayerCharacter(bot : W3T_Bot, client : r_MultiplayerClient, other : r_RemotePlayer) : bool
{
    var character : r_CoopCharacter;
    var session : r_CoopSession;
    var host : bool;
    var label : string;
    var events, diff : array<string>;
    var i : int;
    host = W3T_GetEnv("W3T_ROLE") == "mover";
    label = "CHARACTER member";
    if(host) { label = "CHARACTER host"; }
    character = client.getCoopCharacter();
    session = client.getCoopSession();
    events = character.TakeEvents();
    for(i = 0; i < events.Size(); i += 1) { W3T_Log(label + " " + events[i]); }
    events = session.TakeEvents();
    for(i = 0; i < events.Size(); i += 1) { W3T_Log(label + " session " + events[i]); }
    W3T_Log(label + " phase=" + character.testPhase + " ready=" + character.IsReady() + " fresh=" + character.freshStarts + " restores=" + character.restores
        + " stores=" + character.stores + " problems=" + character.problems + " level=" + GetWitcherPlayer().GetLevel() + " crowns=" + thePlayer.GetInventory().GetMoney()
        + " inParty=" + client.getInParty() + " loads=" + session.loadsRequested);
    if(host)
    {
        return client.getCoopEnemies().GetRole() == 1 && character.restores == 0 && character.freshStarts == 0 && character.stores == 0 && bot.ElapsedS() > 60;
    }
    if(character.testPhase == 0 && character.IsReady() && character.freshStarts == 1 && client.getInParty())
    {
        W3T_CharacterInventory(character);
        character.testQuestItems = W3T_QuestItemCount();
        W3T_MakeOwnCharacter(character);
        character.testExpected = character.Capture();
        if(!character.Store())
        {
            W3T_Log(label + " FAIL could not store the character");
            character.testPhase = -1;
            return false;
        }
        W3T_Log(label + " stored its own character (level " + GetWitcherPlayer().GetLevel() + ", " + StrLen(character.testExpected) + " chars); "
            + character.testQuestItems + " quest items in the world; loading the host's save again");
        character.testPhase = 1;
        session.LoadSave(WO_SessionConfig("save"));
        return false;
    }
    if(character.testPhase == 1 && character.restores == 1 && character.IsReady())
    {
        diff = character.Differences(character.testExpected, character.Capture());
        for(i = 0; i < diff.Size() && i < 40; i += 1) { W3T_Log(label + " DIFF " + diff[i]); }
        W3T_Log(label + " after the reload: " + diff.Size() + " differences from the stored character, " + character.problems + " problems, "
            + W3T_QuestItemCount() + " quest items (before " + character.testQuestItems + ")");
        if(diff.Size() == 0 && character.problems == 0 && W3T_QuestItemCount() == character.testQuestItems) { character.testPhase = 2; }
        else { character.testPhase = -1; }
    }
    return character.testPhase == 2;
}

// What the record keeps and leaves to the world, for the log.
function W3T_CharacterInventory(character : r_CoopCharacter)
{
    var inv : CInventoryComponent;
    var ids : array<SItemUniqueId>;
    var i, kept : int;
    var line : string;
    inv = thePlayer.GetInventory();
    inv.GetAllItems(ids);
    for(i = 0; i < ids.Size(); i += 1)
    {
        if(character.Personal(inv, ids[i])) { kept += 1; continue; }
        line = NameToString(inv.GetItemName(ids[i])) + " (" + NameToString(inv.GetItemCategory(ids[i])) + ")";
        if(inv.ItemHasTag(ids[i], 'Quest')) { line += " quest"; }
        W3T_Log("CHARACTER member world item: " + line);
    }
    W3T_Log("CHARACTER member " + kept + " of " + ids.Size() + " items belong to the character");
}

function W3T_QuestItemCount() : int
{
    var inv : CInventoryComponent;
    var ids : array<SItemUniqueId>;
    var i, count : int;
    inv = thePlayer.GetInventory();
    inv.GetAllItems(ids);
    for(i = 0; i < ids.Size(); i += 1) { if(inv.ItemHasTag(ids[i], 'Quest')) { count += 1; } }
    return count;
}

// Turn the copy of the host's Geralt into a character of its own.
function W3T_MakeOwnCharacter(character : r_CoopCharacter)
{
    var w : W3PlayerWitcher;
    var inv : CInventoryComponent;
    var skills : array<SSkill>;
    var ids, runes : array<SItemUniqueId>;
    var lvl, i, learned, slot : int;
    var equipped : bool;
    w = GetWitcherPlayer();
    inv = w.GetInventory();
    lvl = Max(2, w.GetLevel() - 2);
    w.levelManager.CoopSetLevel(lvl, w.levelManager.GetTotalExpForGivenLevel(lvl) + 123);
    W3T_Log("CHARACTER member level " + lvl + " (the host's Geralt is " + (lvl + 2) + ")");
    w.AddPoints(ESkillPoint, 3, false);
    // three new skills, the first one in a skill slot
    skills = w.GetPlayerSkills();
    for(i = 0; i < skills.Size() && learned < 3; i += 1)
    {
        if(skills[i].level == 0 && !skills[i].isCoreSkill && w.CanLearnSkill(skills[i].skillType))
        {
            w.AddSkill(skills[i].skillType);
            learned += 1;
            W3T_Log("CHARACTER member learned skill " + (int)skills[i].skillType);
            for(slot = 1; slot <= 12 && learned == 1 && !equipped; slot += 1)
            {
                if(w.EquipSkill(skills[i].skillType, slot))
                {
                    equipped = true;
                    W3T_Log("CHARACTER member skill " + (int)skills[i].skillType + " in slot " + slot);
                }
            }
        }
    }
    ids = inv.AddAnItem('Long Steel Sword', 1, true, true);
    if(ids.Size() > 0)
    {
        inv.SetItemDurabilityScript(ids[0], inv.GetItemMaxDurability(ids[0]) * 0.375);
        W3T_Log("CHARACTER member worn sword durability " + inv.GetItemDurability(ids[0]) + " of " + inv.GetItemMaxDurability(ids[0]));
    }
    ids = inv.AddAnItem('Gryphon School steel sword 4', 1, true, true);
    if(ids.Size() > 0)
    {
        runes = inv.AddAnItem('Rune perun', 1, true, true);
        if(inv.GetItemEnhancementSlotsCount(ids[0]) == 0) { inv.AddSlot(ids[0]); }
        W3T_Log("CHARACTER member steel sword rune: " + (runes.Size() > 0 && inv.EnhanceItemScript(ids[0], runes[0])));
    }
    ids = inv.AddAnItem('Gryphon School silver sword 4', 1, true, true);
    if(ids.Size() > 0) { W3T_Log("CHARACTER member silver sword enchanted: " + inv.EnchantItem(ids[0], 'Runeword 1', getEnchamtmentStatName('Runeword 1'))); }
    ids = inv.AddAnItem('Starting Gloves', 1, true, true);
    if(ids.Size() > 0) { W3T_Log("CHARACTER member gloves equipped: " + w.EquipItemInGivenSlot(ids[0], EES_Gloves, false)); }
    inv.AddMoney(777);
    W3T_MakeOwnCharacterPart2(w, inv);
}

// Mutations, stash and horse gear, Gwent cards, worn gear.
function W3T_MakeOwnCharacterPart2(w : W3PlayerWitcher, inv : CInventoryComponent)
{
    var pam : W3PlayerAbilityManager;
    var horses : W3HorseManager;
    var stash : CInventoryComponent;
    var ids : array<SItemUniqueId>;
    var id, moved : SItemUniqueId;
    var i : int;
    var before : float;
    var cardGone : bool;
    pam = (W3PlayerAbilityManager)w.abilityManager;
    pam.MutationSystemEnable(true);
    pam.DEBUG_DevelopAndEquipMutation(EPMT_Mutation1);
    W3T_Log("CHARACTER member mutation equipped: " + (int)pam.GetEquippedMutationType() + ", researched " + pam.GetResearchedMutationsCount());
    horses = w.GetHorseManager();
    stash = horses.GetInventoryComponent();
    stash.AddAnItem('Long Steel Sword', 1, true, true);
    ids = inv.GetItemsByName('Horse Saddle 1');
    if(ids.Size() > 0)
    {
        moved = horses.MoveItemToHorse(ids[0], 1);
        W3T_Log("CHARACTER member saddle on the horse: " + stash.IsIdValid(horses.EquipItem(moved)));
    }
    W3T_Log("CHARACTER member stash holds " + stash.GetAllItemsQuantity() + " items");
    inv.GetAllItems(ids);
    for(i = 0; i < ids.Size() && !cardGone; i += 1)
    {
        if(inv.ItemHasTag(ids[i], 'GwintCard') && !inv.ItemHasTag(ids[i], 'Quest'))
        {
            W3T_Log("CHARACTER member gives away Gwent card " + NameToString(inv.GetItemName(ids[i])));
            inv.RemoveItem(ids[i], 1);
            cardGone = true;
        }
    }
    if(w.GetItemEquippedOnSlot(EES_SteelSword, id))
    {
        before = inv.GetItemDurability(id);
        for(i = 0; i < 20; i += 1) { inv.ReduceItemDurability(id, true); }
        W3T_Log("CHARACTER member worn steel sword " + NameToString(inv.GetItemName(id)) + ": durability " + before + " -> " + inv.GetItemDurability(id));
    }
}
