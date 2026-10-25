// Stand-ins for the parts of Custom Player Characters (nikich340) that Witcher Online and the co-op
// scripts call, so the game runs without that mod: players are Geralt (or Ciri in her sections),
// sorceress magic and appearance presets are not available. The installer and the test stager leave
// this mod out when the real Custom Player Characters is installed (it declares the same classes).
// Names, enum values and signatures follow CPC 3.1.2 (with its Remaster compatibility fix).

enum ENR_PlayerType
{
    ENR_PlayerUnknown,
    ENR_PlayerGeralt,
    ENR_PlayerCiri,
    ENR_PlayerWitcher,
    ENR_PlayerWitcheress,
    ENR_PlayerSorceress
}

// G: Geralt slots, R: replacer slots (as CPC numbers them)
enum ENR_AppearanceSlots
{
    ENR_GSlotUnknown,
    ENR_GSlotHair,
    ENR_GSlotHead,
    ENR_GSlotArmor,
    ENR_GSlotGloves,
    ENR_GSlotPants,
    ENR_GSlotBoots,
    ENR_RSlotHair,
    ENR_RSlotBody,
    ENR_RSlotTorso,
    ENR_RSlotArms,
    ENR_RSlotGloves,
    ENR_RSlotDress,
    ENR_RSlotLegs,
    ENR_RSlotShoes,
    ENR_RSlotMisc
}

enum ENR_MagicAction
{
    ENR_HandFx,
    ENR_Teleport,
    ENR_CounterPush,
    ENR_SpecialLumos,
    ENR_SpecialWeatherChange,
    ENR_LightAbstract,
    ENR_Slash,
    ENR_ThrowAbstract,
    ENR_Lightning,
    ENR_ProjectileWithPrepare,
    ENR_BombExplosion,
    ENR_Rock,
    ENR_RipApart,
    ENR_HeavyAbstract,
    ENR_FastTravelTeleport,
    ENR_SpecialShield,
    ENR_SpecialTornado,
    ENR_SpecialControl,
    ENR_SpecialMeteor,
    ENR_SpecialServant,
    ENR_SpecialLightningFall,
    ENR_SpecialField,
    ENR_SpecialMeteorFall,
    ENR_SpecialPolymorphism,
    ENR_WaterTrap
}

class NR_Map
{
    function getI(key : string) : int { return 0; }
    function getN(key : string) : name { return ''; }
}

class NR_PlayerManager
{
    // [player type][appearance slot], all empty: Witcher Online then sends "none" for every slot
    var m_appearanceTemplates : array< array<string> >;
    var m_appearanceItems : array< array<string> >;
    var m_headNames : array< name >;

    function Init()
    {
        var empty : array<string>;
        var type : int;

        empty.Resize(EnumGetMax('ENR_AppearanceSlots') + 1);
        for(type = 0; type <= (int)ENR_PlayerSorceress; type += 1)
        {
            m_appearanceTemplates.PushBack(empty);
            m_appearanceItems.PushBack(empty);
            m_headNames.PushBack('');
        }
    }

    function GetCurrentPlayerType() : ENR_PlayerType
    {
        if(thePlayer && thePlayer.IsCiri())
        {
            return ENR_PlayerCiri;
        }
        return ENR_PlayerGeralt;
    }

    function IsPlayerTypeChangeLocked() : bool { return false; }
    function IsRealEquipmentModeEnabled() : bool { return false; }
    function IsReady() : bool { return true; }
    function IsReplacerActive() : bool { return false; }

    function UpdateHead(newHeadName : name) { m_headNames[GetCurrentPlayerType()] = newHeadName; }
    function UpdateAppearanceTemplate(templateName : string, slot : ENR_AppearanceSlots) { m_appearanceTemplates[GetCurrentPlayerType()][slot] = templateName; }
    function UpdateAppearanceItem(templateName : string, itemIndex : int)
    {
        if(itemIndex < 0 || itemIndex >= m_appearanceItems[GetCurrentPlayerType()].Size()) { m_appearanceItems[GetCurrentPlayerType()].PushBack(templateName); }
        else { m_appearanceItems[GetCurrentPlayerType()][itemIndex] = templateName; }
    }
}

class NR_MagicAction
{
    var drainStaminaOnPerform : bool;

    function RestoreFromSave() {}
    function OnInit() : bool { return true; }
    function OnPrepare() : bool { return true; }
    function OnPerform() : bool { return true; }
}

class NR_MagicSpecialPolymorphism extends NR_MagicAction
{
    var animalType : name;
    var appearanceName : name;
}

class NR_MagicManager
{
    var m_map : NR_Map;

    function GetMap(key : name) : NR_Map
    {
        if(!m_map)
        {
            m_map = new NR_Map in this;
        }
        return m_map;
    }

    function SetActionSkillLevel(action : ENR_MagicAction, level : int) {}
    function AddActionScripted(action : NR_MagicAction) {}
}

class NR_RandomGenerator
{
    function next(max : int) : int { return RandRange(max); }
}

@addField(CR4Game)
var wo_compatPlayerManager : NR_PlayerManager;

@addField(CR4Game)
var wo_compatMagicManager : NR_MagicManager;

@addField(CR4Game)
var wo_compatRandom : NR_RandomGenerator;

@addMethod(CR4Game)
function WO_CompatPlayerManager() : NR_PlayerManager
{
    if(!wo_compatPlayerManager)
    {
        wo_compatPlayerManager = new NR_PlayerManager in this;
        wo_compatPlayerManager.Init();
    }
    return wo_compatPlayerManager;
}

@addMethod(CR4Game)
function WO_CompatMagicManager() : NR_MagicManager
{
    if(!wo_compatMagicManager)
    {
        wo_compatMagicManager = new NR_MagicManager in this;
    }
    return wo_compatMagicManager;
}

@addMethod(CR4Game)
function WO_CompatRandom() : NR_RandomGenerator
{
    if(!wo_compatRandom)
    {
        wo_compatRandom = new NR_RandomGenerator in this;
    }
    return wo_compatRandom;
}

function NR_GetPlayerManager() : NR_PlayerManager { return theGame.WO_CompatPlayerManager(); }
function NR_GetMagicManager() : NR_MagicManager { return theGame.WO_CompatMagicManager(); }
function NR_GetRandomGenerator() : NR_RandomGenerator { return theGame.WO_CompatRandom(); }
function NR_IsSceneInPreviewState() : bool { return false; }
function NR_ChangePlayer(newPlayerType : ENR_PlayerType, optional nakedCiriTemplate : bool) {}
