// Stand-ins for the parts of Chill Out that Witcher Online calls, so the Remastered (5.x) port runs
// without that mod: tavern seats are not available. Do not install this next to the real Chill Out
// (it declares the same classes). The Custom Player Characters stand-ins are in
// modWitcherOnlineCompatCPC, left out when the real mod is installed.

// Chill Out: no seats; the classes exist only so Witcher Online's hooks compile.
enum EChillSpotType
{
    CST_Chair,
    CST_Table,
    CST_Bench
}

struct SChillSpot
{
    var position : Vector;
    var rotation : EulerAngles;
    var type : EChillSpotType;
}

function ChillSpot(position : Vector, rotation : EulerAngles, type : EChillSpotType) : SChillSpot
{
    var spot : SChillSpot;

    spot.position = position;
    spot.rotation = rotation;
    spot.type = type;
    return spot;
}

class CO_SpotEntGroup
{
    var tag : name;

    function Add(spot : SChillSpot) {}
}

statemachine class ChillOut
{
    var m_groups : array<CO_SpotEntGroup>;

    function InitGroups() {}
    function State() : CScriptableState { return GetCurrentState(); }
}

state CO_Action in ChillOut
{
    function GetAnimation() : name { return ''; }
}

function Chill() : ChillOut { return NULL; }
function CO_CurrentArea() : EAreaName { return AN_Undefined; }
