// Remastered (5.x) identifies world areas by name ('AN_Velen'); Witcher Online keeps the old EAreaName
// numbers on the wire so the server and its region list stay unchanged.

function WO_AreaToCode(area : name) : int
{
    switch(area)
    {
        case 'AN_NMLandNovigrad': return 1;
        case 'AN_Skellige_ArdSkellig': return 2;
        case 'AN_Kaer_Morhen': return 3;
        case 'AN_Prologue_Village': return 4;
        case 'AN_Wyzima': return 5;
        case 'AN_Island_of_Myst': return 6;
        case 'AN_Spiral': return 7;
        case 'AN_Prologue_Village_Winter': return 8;
        case 'AN_Velen': return 9;
        case 'AN_CombatTestLevel': return 10;
        case 'AN_Bob': return 11;
    }

    return 0;
}

function WO_AreaFromCode(code : int) : name
{
    return theGame.GetCommonMapManager().GetDeprecatedAreaName(code);
}

function WO_CurrentAreaCode() : int
{
    return WO_AreaToCode(theGame.GetCommonMapManager().GetCurrentArea());
}

// Same strings as 4.04's AreaTypeToName and 5.x CR4MapMenu.ConvertAreaNameToWorldName.
function WO_AreaToRegion(area : name) : string
{
    switch(area)
    {
        case 'AN_NMLandNovigrad': return "novigrad";
        case 'AN_Velen': return "no_mans_land";
        case 'AN_Skellige_ArdSkellig': return "skellige";
        case 'AN_Kaer_Morhen': return "kaer_morhen";
        case 'AN_Prologue_Village': return "prolog_village";
        case 'AN_Prologue_Village_Winter': return "prolog_village_winter";
        case 'AN_Wyzima': return "wyzima_castle";
        case 'AN_Island_of_Myst': return "island_of_mist";
        case 'AN_Spiral': return "spiral";
        case 'AN_Bob': return "bob";
    }

    return "";
}

function WO_AreaCodeToRegion(code : int) : string
{
    return WO_AreaToRegion(WO_AreaFromCode(code));
}
