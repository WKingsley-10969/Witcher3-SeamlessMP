// Per-player characters: a joining player keeps their own Geralt in the host's game. The host's
// save brings the world (quests, choices, places); after it loads, this player's own level, XP,
// skill points, skills and their slots, money, recipes and items replace the host's. The
// character is recorded every 20 s (and when the pause menu opens) to
// "The Witcher 3\coop-characters\<host>.txt" in this player's co-op profile (WO_CharacterStore).
// The first time with a host there is no record yet: the character starts as a copy of the host's
// Geralt and is this player's own from then on.
//
// Only in the host's world (r_CoopSession.InHostWorld: after loading the host's save or starting
// the host's new game), never in a game of this player's own, nor in the prologue's Kaer Morhen
// dream. The record is restored once per load of the host's world, not after every loading screen.
// Before a restore replaces the character the record is backed up (coop-characters\backups), and a
// record without any equipped weapon or armour is not applied over an armed character.
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
//   cpc;<ENR_PlayerType>;<head>                with Custom Player Characters (nikich340) installed:
//   cpcslot;<ENR_AppearanceSlots>;<template>   the character type and look; switched to before the
//   cpcitem;<index>;<template>                 rest is restored. The first time, its creator opens.
//   cpcspeech;<0 auto, 1 female, 2 never>      its "Use female speech" setting (nr_speech_manual_control)
import function WO_CharacterStore(text : string) : bool;
import function WO_CharacterLoad() : string;
import function WO_ToName(text : string) : name;
import function WO_CharacterBackup() : bool;

class r_CoopCharacter
{
    private var events : array<string>;
    private var loadedAt : float;
    private var lastStore : float;
    private var ready : bool;       // restored (or started fresh) since the last load: recording
    private var broken : bool;      // the stored record could not be read: never overwrite it
    private var prologueSerial : int;   // the load of the host's world checked for being in the prologue
    private var prologueLoad : bool;    // that load was a save from the prologue's dream: a new playthrough
    private var restoredSerial : int;   // the load of the host's world (r_CoopSession.HostLoadSerial) restored for
    private var cpcPending : string;    // a record waiting for Custom Player Characters to switch the character type
    private var cpcPendingSince : float;
    private var creatorDue : bool;      // a new character with Custom Player Characters: open its creator once in the world

    public var restores : int;
    public var freshStarts : int;
    public var skippedRecords : int;  // records not applied: no weapon or armour while this character has some
    public var cpcSwitches : int;     // character type switches before a restore (Custom Player Characters)
    public var cpcLooks : int;        // looks applied from the record
    public var creatorsOpened : int;
    public var testNoCreator : bool;  // bot tests: the creator scene would wait for a player
    public var backups : int;
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
        WO_Log("character " + text);
    }

    private function Session() : r_CoopSession { return theGame.r_getMultiplayerClient().getCoopSession(); }
    public function IsReady() : bool { return ready; }

    // ------------------------------------------------------------ when

    public function OnGameStarted()
    {
        loadedAt = theGame.GetEngineTimeAsSeconds();
        // a host's save from the prologue's dream (as the owner's playtest started): a new playthrough,
        // like the lobby's new game. The dream's end sets q001_nightmare_ended, and before, the fact
        // could arrive from the other PC: then the stored character replaced the prologue's Geralt
        // as White Orchard loaded, right at the first fight, without a sword.
        if(Session().HostLoadSerial() != prologueSerial)
        {
            prologueSerial = Session().HostLoadSerial();
            prologueLoad = Session().InHostWorld() && FactsQuerySum("q001_nightmare_ended") <= 0;
            if(prologueLoad) { Record("PROLOGUE the host's save is in the prologue: this playthrough's character starts fresh"); }
        }
    }

    // Recording and restoring happen only here: in the host's world, as the witcher (not Ciri),
    // after the prologue's Kaer Morhen dream (its own gear; the game hands out the real gear after).
    private function Active() : bool
    {
        return Session().IsJoining() && Session().InHostWorld() && GetWitcherPlayer() && !broken && FactsQuerySum("q001_nightmare_ended") > 0;
    }

    public function Tick()
    {
        var now : float;
        var text : string;
        if(!Active()) { return; }
        now = theGame.GetEngineTimeAsSeconds();
        // a new load of the host's world: restore once, after the game's own start-up work on the
        // loaded character (skill refund timers, 1.5 s). Other loading screens keep the character.
        if(restoredSerial != Session().HostLoadSerial()) { ready = false; cpcPending = ""; }
        if(now - loadedAt < 5.0) { return; }
        if(cpcPending != "")
        {
            // Custom Player Characters builds the new character over a few frames
            if((NR_GetPlayerManager().IsReady() && (int)NR_GetPlayerManager().GetCurrentPlayerType() == CpcType(cpcPending)) || now - cpcPendingSince > 30.0)
            {
                text = cpcPending;
                cpcPending = "";
                RestoreRecord(text);
            }
            return;
        }
        if(ready && creatorDue && !thePlayer.IsInCombat() && !theGame.IsDialogOrCutscenePlaying() && Session().placements > 0) { OpenCreator(); }
        if(!ready)
        {
            if(theGame.IsDialogOrCutscenePlaying() || thePlayer.IsInNonGameplayCutscene()) { return; }
            restoredSerial = Session().HostLoadSerial();
            Begin();
            return;
        }
        if(now - lastStore >= 20.0 && !theGame.IsDialogOrCutscenePlaying()) { Store(); }
    }

    // The pause menu opened (also on the way to quitting): record what this player has now.
    public function OnPauseMenu()
    {
        // the record every 20 s covers the rest: each one builds the whole inventory and writes it
        // out, a stall the owner felt on Esc
        if(Active() && ready && theGame.GetEngineTimeAsSeconds() - loadedAt >= 5.0 && theGame.GetEngineTimeAsSeconds() - lastStore >= 10.0) { Store(); }
    }

    private function Begin()
    {
        var text : string;
        text = WO_CharacterLoad();
        if(text != "" && (Session().HostSaveName() == "" || prologueLoad))
        {
            // the host's new game: a new playthrough, so a new character (the old one is backed up)
            if(WO_CharacterBackup()) { backups += 1; }
            freshStarts += 1;
            Record("FRESH new game (or the prologue) with " + Session().HostName() + ": a new character (the previous record is backed up)");
            theGame.GetGuiManager().ShowNotification("New game with " + Session().HostName() + ": your co-op character starts fresh.");
            ready = true;
            Store();
            return;
        }
        if(text != "" && !RecordArmed(text) && Armed())
        {
            // a record without any weapon or armour (made in the wrong world): never strip this character for it
            if(WO_CharacterBackup()) { backups += 1; }
            skippedRecords += 1;
            Record("SKIPPED the record has no sword equipped: keeping the current character (record backed up)");
            theGame.GetGuiManager().ShowNotification("Your stored co-op character had no sword: kept your current gear instead.");
            ready = true;
            Store();
            return;
        }
        if(text != "" && WO_CharacterBackup()) { backups += 1; }
        if(text == "")
        {
            freshStarts += 1;
            Record("FRESH no character for " + Session().HostName() + " yet: starting from the host's Geralt");
            theGame.GetGuiManager().ShowNotification("Your co-op character starts as a copy of " + Session().HostName() + "'s Geralt.");
            creatorDue = CpcInstalled();
            // not the host's "Use female speech" (it is in the host's save): Auto, for the copy of its Geralt
            if(CpcInstalled()) { ApplyCpcSpeech(""); }
            ready = true;
            Store();
            return;
        }
        // the record's character type first (Custom Player Characters rebuilds the player), then the rest
        if(CpcInstalled() && CpcType(text) > 0 && CpcType(text) != (int)NR_GetPlayerManager().GetCurrentPlayerType())
        {
            cpcSwitches += 1;
            cpcPending = text;
            cpcPendingSince = theGame.GetEngineTimeAsSeconds();
            Record("CPC_SWITCH to character type " + CpcType(text) + " before the restore");
            NR_ChangePlayer((ENR_PlayerType)CpcType(text));
            return;
        }
        RestoreRecord(text);
    }

    private function RestoreRecord(text : string)
    {
        if(!Restore(text))
        {
            broken = true;
            Record("BROKEN the stored character could not be read: kept, not overwritten");
            theGame.GetGuiManager().ShowNotification("Your co-op character could not be read: playing the host's Geralt this time.");
            return;
        }
        if(CpcInstalled()) { ApplyCpcLook(text); ApplyCpcSpeech(text); }
        ready = true;
        Store();
    }

    // ------------------------------------------------------------ Custom Player Characters

    private function CpcInstalled() : bool { return WO_SessionConfig("cpc") == "1"; }

    // The record's character type (ENR_PlayerType), 0 without a "cpc" line.
    private function CpcType(text : string) : int
    {
        var lines, f : array<string>;
        var i : int;
        lines = CoopSplit(text, "|");
        for(i = 0; i < lines.Size(); i += 1)
        {
            f = CoopSplit(lines[i], ";");
            if(f.Size() == 3 && f[0] == "cpc") { return StringToInt(f[1], 0); }
        }
        return 0;
    }

    private function CaptureCpc() : string
    {
        var pm : NR_PlayerManager;
        var heads : array<name>;
        var type, slot, i : int;
        var text, head : string;
        if(!CpcInstalled()) { return ""; }
        pm = NR_GetPlayerManager();
        type = (int)pm.GetCurrentPlayerType();
        heads = pm.mpghosts_GetHeads();
        head = "";
        if(type < heads.Size()) { head = NameToString(heads[type]); }
        if(!CoopSafeField(head)) { head = ""; }
        text = "|cpc;" + type + ";" + head + "|cpcspeech;" + FactsQuerySum("nr_speech_manual_control");
        if(type >= pm.m_appearanceTemplates.Size()) { return text; }
        for(slot = (int)ENR_RSlotHair; slot <= (int)ENR_RSlotMisc && slot < pm.m_appearanceTemplates[type].Size(); slot += 1)
        {
            if(pm.m_appearanceTemplates[type][slot] != "" && CoopSafeField(pm.m_appearanceTemplates[type][slot])) { text += "|cpcslot;" + slot + ";" + pm.m_appearanceTemplates[type][slot]; }
        }
        for(i = 0; i < pm.m_appearanceItems[type].Size(); i += 1)
        {
            if(pm.m_appearanceItems[type][i] != "" && CoopSafeField(pm.m_appearanceItems[type][i])) { text += "|cpcitem;" + i + ";" + pm.m_appearanceItems[type][i]; }
        }
        return text;
    }

    // The record's "Use female speech" setting (Auto for a record without one), and the voice it gives the
    // current character: the host's save carries the host's setting and voice, which are not synced (the
    // owner's playtest: the host's "always female" muted the second PC's Geralt, who spoke female lines).
    private function ApplyCpcSpeech(text : string)
    {
        var lines, f : array<string>;
        var speech, i : int;
        speech = 0;
        lines = CoopSplit(text, "|");
        for(i = 0; i < lines.Size(); i += 1)
        {
            f = CoopSplit(lines[i], ";");
            if(f.Size() == 2 && f[0] == "cpcspeech") { speech = StringToInt(f[1], 0); }
        }
        FactsRemove("nr_speech_manual_control");
        if(speech > 0) { FactsAdd("nr_speech_manual_control", speech); }
        NR_GetPlayerManager().UpdateSpeechSwitchFacts();
        Record("CPC_SPEECH setting " + speech + ": female lines " + FactsQuerySum("nr_speech_switch"));
    }

    // The record's look on the current character (its type switched to already).
    private function ApplyCpcLook(text : string)
    {
        var pm : NR_PlayerManager;
        var lines, f : array<string>;
        var slots, items : array<string>;
        var i, slot, type : int;
        var head : string;
        type = CpcType(text);
        pm = NR_GetPlayerManager();
        if(type <= 0 || type != (int)pm.GetCurrentPlayerType()) { return; }
        slots.Resize((int)ENR_RSlotMisc + 1);
        head = "";
        lines = CoopSplit(text, "|");
        for(i = 0; i < lines.Size(); i += 1)
        {
            f = CoopSplit(lines[i], ";");
            if(f.Size() == 3 && f[0] == "cpc") { head = f[2]; }
            else if(f.Size() == 3 && f[0] == "cpcslot")
            {
                slot = StringToInt(f[1], -1);
                if(slot >= (int)ENR_RSlotHair && slot <= (int)ENR_RSlotMisc) { slots[slot] = f[2]; }
            }
            else if(f.Size() == 3 && f[0] == "cpcitem") { items.PushBack(f[2]); }
        }
        if(head != "") { pm.UpdateHead(WO_ToName(head)); }
        // every slot as recorded: one the record leaves empty is emptied
        for(slot = (int)ENR_RSlotHair; slot <= (int)ENR_RSlotMisc; slot += 1) { pm.UpdateAppearanceTemplate(slots[slot], (ENR_AppearanceSlots)slot); }
        for(i = 0; i < items.Size(); i += 1) { pm.UpdateAppearanceItem(items[i], i); }
        for(i = items.Size(); i < pm.m_appearanceItems[type].Size(); i += 1) { pm.UpdateAppearanceItem("", i); }
        cpcLooks += 1;
        Record("CPC_LOOK character type " + type + ", head " + head + ", " + items.Size() + " items");
    }

    // A new character: Custom Player Characters' creator (its Chameleon potion: the same fact).
    private function OpenCreator()
    {
        creatorDue = false;
        if(testNoCreator)
        {
            Record("CREATOR would open now (bot test: skipped)");
            return;
        }
        creatorsOpened += 1;
        Record("CREATOR opened for the new character");
        theGame.GetGuiManager().ShowNotification("Create your co-op character. (Later: hold E and press P.)");
        FactsAdd("item_use_nr_chameleon_potion", 1);
    }

    // A sword equipped in the record ("item" lines with a sword slot)? Armour alone is not enough: a
    // record without a sword stripped the player's swords (the owner's playtest).
    private function RecordArmed(text : string) : bool
    {
        var lines, f : array<string>;
        var i, slot : int;
        lines = CoopSplit(text, "|");
        for(i = 0; i < lines.Size(); i += 1)
        {
            f = CoopSplit(lines[i], ";");
            if(f.Size() != 10 || f[0] != "item") { continue; }
            slot = StringToInt(f[4], -1);
            if(slot == (int)EES_SteelSword || slot == (int)EES_SilverSword) { return true; }
        }
        return false;
    }

    private function Armed() : bool
    {
        var id : SItemUniqueId;
        var w : W3PlayerWitcher;
        w = GetWitcherPlayer();
        return w.GetItemEquippedOnSlot(EES_SteelSword, id) || w.GetItemEquippedOnSlot(EES_SilverSword, id) || w.GetItemEquippedOnSlot(EES_Armor, id);
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
        text += CaptureMutations(pam) + CaptureStash(w) + CaptureCpc();
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
        // the horse's EquipItem returns the item it replaced, not the one equipped
        if(slot >= 0 && horses) { horses.EquipItem(id); }
        if(slot >= 0 && horses && !horses.IsItemEquipped(id)) { problems += 1; Record("HORSE_EQUIP_FAILED " + f[1] + " -> " + slot); }
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

// The pause menu (not the main menu) opened: the character is recorded, so quitting loses nothing.
@wrapMethod(CR4IngameMenu)
function OnConfigUI()
{
    wrappedMethod();
    if(!isMainMenu) { theGame.r_getMultiplayerClient().getCoopCharacter().OnPauseMenu(); }
    return true;
}
