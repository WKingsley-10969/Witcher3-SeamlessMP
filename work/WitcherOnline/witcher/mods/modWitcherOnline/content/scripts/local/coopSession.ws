// Co-op session: joining players play the host's game. The launcher (Play-LAN.ps1) downloads the
// host's newest co-op save before starting a joining player's game; here that game loads it from
// the main menu, joins the host's party, steps in beside the host, and follows the host's
// difficulty. Settings come from the launcher through WO_SessionConfig: role host|join, save (the
// host save's file name), host (the host's player name).
//
// "coop ss diff level": the host's difficulty (EDifficultyMode as a number).
import function WO_SessionConfig(key : string) : string;
import function WO_Log(text : string) : bool;

class r_CoopSession
{
    private var events : array<string>;
    private var loadRequested : bool;   // the main menu asked to load the host's save (once per game start)
    private var placed : bool;          // stepped in beside the host since the last load
    private var lastJoinAttempt : float;
    private var lastDifficultySent : int;
    private var lastCheck : float;
    private var leftByChoice : bool;    // this player left the party: no joining again until they join themselves
    private var autoJoining : bool;     // the session's own join call is running
    private var hostWorldNext : bool;   // the game being loaded is the host's (its save, or the host's new game)
    private var inHostWorld : bool;     // playing the host's world since that load; off in the main menu and after loading another save
    private var hostSave : string;      // the host's save this player last loaded
    private var hostLoadSerial : int;   // counts loads of the host's world

    public var loadsRequested : int;
    public var joinAttempts : int;
    public var placements : int;
    public var difficultyChanges : int;
    public var lastPlacedApart : float;
    public var partyLeaves : int;

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
        WO_Log("session " + text);
    }

    public function Role() : string { return WO_SessionConfig("role"); }
    public function HostName() : string { return WO_SessionConfig("host"); }
    public function IsJoining() : bool { return Role() == "join" && HostName() != ""; }

    // ------------------------------------------------------------ main menu

    // Without a lobby on the host's server (coopLobby.ws), a joining player loads the save the
    // launcher downloaded, once per game start.
    public function LoadLauncherSave()
    {
        var wanted : string;
        wanted = WO_SessionConfig("save");
        if(Role() != "join" || wanted == "" || loadRequested) { return; }
        loadRequested = true;
        if(!LoadSave(wanted))
        {
            theGame.GetGuiManager().ShowNotification(HostName() + "'s save " + wanted + " was not found: load a save yourself.");
        }
    }

    // A save of this player's co-op saves, by its exact base name (not one that only contains it:
    // AutoSave_1 must not find AutoSave_10).
    public function FindSave(wanted : string, out save : SSavegameInfo) : bool
    {
        var saves : array<SSavegameInfo>;
        var i : int;
        theGame.ListSavedGames(saves);
        for(i = 0; i < saves.Size(); i += 1)
        {
            if(CoopSaveNameIs(saves[i].filename, wanted))
            {
                save = saves[i];
                return true;
            }
        }
        return false;
    }

    // Load a co-op save by base name; false when this player does not have it.
    public function LoadSave(wanted : string) : bool
    {
        var save : SSavegameInfo;
        if(!FindSave(wanted, save))
        {
            Record("HOST_SAVE_MISSING " + wanted);
            return false;
        }
        loadsRequested += 1;
        Record("LOAD_HOST_SAVE " + save.filename + " of " + HostName());
        ExpectHostWorld(wanted);
        theGame.LoadGameInit(save, false);
        return true;
    }

    // ------------------------------------------------------------ the host's world

    // The next game started is the host's world: its save, or the new game the host started.
    public function ExpectHostWorld(saveName : string)
    {
        hostWorldNext = true;
        hostSave = saveName;
    }

    // The player loaded a save from the game's own menus. The host's save (or, after dying, a save
    // made while in the host's world) keeps the host's world; any other save is the player's own.
    public function OnMenuLoad(save : SSavegameInfo, fromDeathScreen : bool)
    {
        if(!IsJoining()) { return; }
        if((hostSave != "" && CoopSaveNameIs(save.filename, hostSave)) || (fromDeathScreen && inHostWorld))
        {
            ExpectHostWorld(hostSave);
            return;
        }
        hostWorldNext = false;
        if(inHostWorld) { Record("OWN_SAVE " + save.filename + ": not " + HostName() + "'s world, own character paused"); }
        inHostWorld = false;
    }

    // Back in the main menu: no world until the next load.
    public function OnMainMenu()
    {
        if(inHostWorld) { Record("MAIN_MENU left " + HostName() + "'s world"); }
        inHostWorld = false;
        hostWorldNext = false;
    }

    public function InHostWorld() : bool { return inHostWorld; }
    public function HostSaveName() : string { return hostSave; }   // "" for the host's new game
    public function HostLoadSerial() : int { return hostLoadSerial; }

    // A game was loaded: step in beside the host again once the party is together.
    public function OnGameStarted()
    {
        placed = false;
        lastDifficultySent = -1;
        if(hostWorldNext)
        {
            hostWorldNext = false;
            inHostWorld = true;
            hostLoadSerial += 1;
            Record("IN_HOST_WORLD " + HostName() + " (" + hostSave + ")");
        }
    }

    // Step in beside the host again (the next time the host is in this region).
    public function Replace() { placed = false; }

    // ------------------------------------------------------------ party

    // The player left the party themselves (party menu, console): the session stops joining it again.
    public function OnLeftParty()
    {
        if(!IsJoining()) { return; }
        leftByChoice = true;
        partyLeaves += 1;
        Record("LEFT_PARTY by choice: no automatic joining");
        theGame.GetGuiManager().ShowNotification("You left " + HostName() + "'s party. Interact with " + HostName() + " to join again.");
    }

    // Any join this player asks for (not the session's own) brings automatic joining back.
    public function OnJoinParty()
    {
        if(autoJoining || !leftByChoice) { return; }
        leftByChoice = false;
        Record("JOINED_PARTY by choice: automatic joining again");
    }

    public function HasLeftParty() : bool { return leftByChoice; }

    // ------------------------------------------------------------ network

    public function OnMessage()
    {
        var sender : string;
        var level : int;
        sender = WO_Str(-1);
        if(WO_Str(0) != "ss" || StringToInt(WO_Str(-3), 0) < 3 || sender == theGame.r_getMultiplayerClient().getUsername()) { return; }
        if(!IsJoining() || sender != HostName()) { return; }
        if(WO_Str(1) == "diff")
        {
            level = StringToInt(WO_Str(2), -1);
            if(level >= 0 && level != (int)theGame.GetDifficultyLevel())
            {
                difficultyChanges += 1;
                Record("DIFFICULTY " + (int)theGame.GetDifficultyLevel() + " -> " + level + " (host " + sender + ")");
                theGame.SetDifficultyLevel(level);
                theGame.OnDifficultyChanged(level);
                theGame.GetGuiManager().ShowNotification("Difficulty set to match " + sender + "'s game.");
            }
        }
    }

    // ------------------------------------------------------------ every frame

    public function Tick()
    {
        var now : float;
        now = theGame.GetEngineTimeAsSeconds();
        if(now - lastCheck < 1.0) { return; }
        lastCheck = now;
        if(Role() == "host") { ShareDifficulty(); }
        if(IsJoining()) { FollowHost(now); }
    }

    // The host tells the party its difficulty, again whenever it changes.
    private function ShareDifficulty()
    {
        var level : int;
        level = (int)theGame.GetDifficultyLevel();
        if(level == lastDifficultySent) { return; }
        lastDifficultySent = level;
        WO_Send("coop ss diff " + level);
    }

    // Join the host's party, then step in beside the host once.
    private function FollowHost(now : float)
    {
        var client : r_MultiplayerClient;
        var host : r_RemotePlayer;
        client = theGame.r_getMultiplayerClient();
        host = FindHost();
        if(!host || leftByChoice) { return; }
        if(!client.getInParty() || client.getJoinedParty() != HostName())
        {
            if(now - lastJoinAttempt >= 5.0)
            {
                lastJoinAttempt = now;
                joinAttempts += 1;
                Record("JOIN_PARTY " + HostName());
                autoJoining = true;
                client.joinParty(HostName());
                autoJoining = false;
            }
            return;
        }
        if(!placed && host.area == WO_CurrentAreaCode())
        {
            placed = true;
            StepInBeside(host.pos);
        }
    }

    private function StepInBeside(hostPos : Vector)
    {
        var spot, safe : Vector;
        var rot : EulerAngles;
        var i : int;
        var found : bool;
        // within a few metres already, but not on the host's own spot (the same save puts both there)
        if(VecDistance(thePlayer.GetWorldPosition(), hostPos) <= 4.0 && VecDistance2D(thePlayer.GetWorldPosition(), hostPos) >= 1.0)
        {
            lastPlacedApart = VecDistance(thePlayer.GetWorldPosition(), hostPos);
            Record("BESIDE_HOST already " + FloatToStringPrec(lastPlacedApart, 1) + " m away");
            return;
        }
        for(i = 0; i < 8 && !found; i += 1)
        {
            spot = hostPos + VecFromHeading(i * 45) * 1.5;
            found = theGame.GetWorld().NavigationFindSafeSpot(spot, 0.4, 1.0, safe) && VecDistance2D(safe, hostPos) >= 1.0;
        }
        if(!found) { safe = hostPos + VecFromHeading(90) * 1.5; }
        rot = thePlayer.GetWorldRotation();
        rot.Yaw = VecHeading(hostPos - safe);
        thePlayer.TeleportWithRotation(safe, rot);
        placements += 1;
        lastPlacedApart = VecDistance2D(safe, hostPos);
        Record("BESIDE_HOST stepped in " + FloatToStringPrec(lastPlacedApart, 1) + " m from " + HostName());
        theGame.GetGuiManager().ShowNotification("You joined " + HostName() + "'s game.");
    }

    private function FindHost() : r_RemotePlayer
    {
        var globals : array<r_RemotePlayer>;
        var i : int;
        globals = theGame.r_getMultiplayerClient().getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1) { if(globals[i] && globals[i].username == HostName()) { return globals[i]; } }
        return NULL;
    }
}

@wrapMethod(CR4CommonMainMenuBase)
function OnConfigUI()
{
    wrappedMethod();
    theGame.r_getMultiplayerClient().getCoopSession().OnMainMenu();
    theGame.r_getMultiplayerClient().getCoopLobby().OnMainMenu();
    return true;
}

// A save loaded from the game's menus (Load Game, the death screen).
@wrapMethod(CR4IngameMenu)
function LoadSaveRequested(saveSlotRef : SSavegameInfo)
{
    theGame.r_getMultiplayerClient().getCoopSession().OnMenuLoad(saveSlotRef, (CR4DeathScreenMenu)m_parentMenu);
    wrappedMethod(saveSlotRef);
}

// Is this save file name the save of that base name? The game lists base names; a name with a
// folder or ".sav" counts too, but not one that only contains it (AutoSave_1 in AutoSave_10).
function CoopSaveNameIs(filename : string, wanted : string) : bool
{
    var base, want, before : string;
    want = StrLower(wanted);
    base = StrLower(filename);
    if(want == "") { return false; }
    if(StrEndsWith(base, ".sav")) { base = StrLeft(base, StrLen(base) - 4); }
    if(base == want) { return true; }
    if(StrLen(base) <= StrLen(want) || !StrEndsWith(base, want)) { return false; }
    before = StrMid(base, StrLen(base) - StrLen(want) - 1, 1);
    // a folder separator before the name, not more of a name
    return StrLen(StrReplaceAll("abcdefghijklmnopqrstuvwxyz0123456789_", before, "")) == 37;
}

@wrapMethod(r_MultiplayerClient)
function leaveParty()
{
    var wasInParty : bool;
    wasInParty = getInParty();
    wrappedMethod();
    if(wasInParty && !getInParty()) { getCoopSession().OnLeftParty(); }
}

@wrapMethod(r_MultiplayerClient)
function joinParty(val : string)
{
    getCoopSession().OnJoinParty();
    wrappedMethod(val);
}
