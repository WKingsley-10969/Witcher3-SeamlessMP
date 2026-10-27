// Co-op lobby in the main menu (step 2 of the co-op session, coopSession.ws). The host's server
// keeps the lobby (CoopLobby.java, HTTP on the game port + 1). Joining players wait in it from the
// main menu. The host starts the session from the "Co-op lobby" entry (OK: its newest save) or by
// starting a New Game as usual; every waiting game then loads that save (downloading it first when
// this player lacks it) or starts the same new game. A player who joins after the start loads the
// host's newest save. Without a lobby (an older host), a joining player loads the save the
// launcher downloaded (coopSession.ws).
import function WO_LobbyRequest(path : string) : bool;
import function WO_LobbyResult() : string;
import function WO_LobbyFetchSave(saveName : string) : bool;
import function WO_LobbyFetchState() : string;

statemachine class r_CoopLobby
{
    private var events : array<string>;
    private var active : bool;            // in the main menu: polling the lobby
    private var waiting : bool;           // a joining player waits for the host's start
    private var menuSince : float;
    private var seenSeq : int;            // the host's start this game acted on (-1: none)
    private var startRequested : bool;    // the host asked to start with its save: load it once confirmed
    private var fetchName : string;       // downloading this save, then loading it
    private var fetchedName : string;     // downloaded: loading it once the game lists it
    private var fetchedAt : float;
    private var listRefreshedAt : float;
    private var listUpdates : int;      // the game's "save list updated" events since the download
    private var listCheckedAt : float;
    private var newGameOptions : int;     // the host's new-game choice, sent when it really starts
    private var dialogShown : bool;
    private var dialogText : string;
    private var lastPoll : float;

    // the lobby as the host's server last described it
    public var reachable : bool;
    public var host : string;
    public var lobbyState : string;
    public var mode : string;
    public var save : string;
    public var newest : string;
    public var players : string;
    public var seq : int;
    public var options : int;
    public var age : int;

    public var polls : int;
    public var answers : int;
    public var starts : int;
    public var loads : int;
    public var fetches : int;
    public var testMenuReturns : int;   // bot tests (lobby_rejoin): times the bot went back to the main menu
    public var newGames : int;
    public var autoStartWhenJoined : bool;   // bot tests: the host starts with its save once someone waits
    public var autoNewGameOptions : int;     // bot tests: the host starts this new game once someone waits (0: no)

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
        WO_Log("lobby " + text);
    }

    private function Session() : r_CoopSession { return theGame.r_getMultiplayerClient().getCoopSession(); }
    public function IsWaiting() : bool { return waiting; }
    public function IsActive() : bool { return active; }

    // ------------------------------------------------------------ main menu

    public function OnMainMenu()
    {
        if(Session().Role() == "") { return; }
        active = true;
        menuSince = Clock();
        seenSeq = -1;
        fetchName = "";
        startRequested = false;
        reachable = false;
        Record("MENU role=" + Session().Role());
        if(Session().Role() == "host") { WO_LobbyRequest("/lobby/open"); }   // back in the main menu: waiting again
        if(Session().Role() == "join") { waiting = true; }
        // the popup opens by itself for both (the host closes it to use New Game or Load)
        ShowDialog();
        if(GetCurrentStateName() != 'CoopLobbyPolling') { GotoState('CoopLobbyPolling'); }
    }

    // The "Co-op lobby" entry of the main menu.
    public function OnEntryActivated()
    {
        if(Session().Role() == "join") { waiting = true; }
        ShowDialog();
    }

    // A game was loaded or started: leave the lobby. A host who started the game some other way
    // (Continue, Load) starts the session with its newest save, so waiting players follow.
    public function OnGameStarted()
    {
        if(!active) { return; }
        active = false;
        waiting = false;
        HideDialog();
        if(Session().Role() == "host" && lobbyState != "started")
        {
            Record("HOST_IN_GAME announces its newest save");
            WO_LobbyRequest("/lobby/start?mode=save");
        }
    }

    // The host is about to start a new game (the menu's New Game, after any confirmation).
    public function OnHostNewGame(newOptions : int)
    {
        if(Session().Role() != "host") { return; }
        starts += 1;
        Record("HOST_NEW_GAME options=" + newOptions);
        WO_LobbyRequest("/lobby/start?mode=new&options=" + newOptions);
    }

    public function OnHostNewGameChosen(newOptions : int) { newGameOptions = newOptions; }
    public function HostNewGameOptions() : int { return newGameOptions; }

    // Bot tests: the host starts with its save, or this new game, once someone waits.
    public function SetTestAutoStart() { autoStartWhenJoined = true; ShowDialog(); }
    public function SetTestAutoNewGame(newOptions : int) { autoNewGameOptions = newOptions; ShowDialog(); }
    public function IsDialogShown() : bool { return dialogShown; }

    // This player's name: the client learns it only once in game, the launcher sets it before.
    private function PlayerName() : string
    {
        var player : string;
        player = WO_SessionConfig("player");
        if(player == "") { player = theGame.r_getMultiplayerClient().getUsername(); }
        return player;
    }

    // Real time in seconds: engine time stands still while the main menu pauses the game.
    private function Clock() : float { return theGame.GetLocalTimeAsMilliseconds() / 1000.0; }

    // ------------------------------------------------------------ polling (CoopLobbyPolling state)

    public function Step()
    {
        var now : float;
        var reply, fetched : string;
        now = Clock();
        if(now < lastPoll) { lastPoll = now - 1; menuSince = now; }   // the clock wrapped
        reply = WO_LobbyResult();
        if(reply != "") { Parse(reply, now); }
        if(now - lastPoll >= 0.5)
        {
            lastPoll = now;
            polls += 1;
            if(waiting) { WO_LobbyRequest("/lobby?name=" + PlayerName()); }
            else { WO_LobbyRequest("/lobby"); }
        }
        if(fetchName != "")
        {
            fetched = WO_LobbyFetchState();
            if(fetched == "done")
            {
                Record("FETCHED " + fetchName);
                fetchedName = fetchName;
                fetchedAt = now;
                listRefreshedAt = now;
                listCheckedAt = 0;
                listUpdates = 0;
                fetchName = "";
                theGame.RefreshCrossProgressionSavesList();   // the game lists saves it found earlier: look again
            }
            else if(StrBeginsWith(fetched, "error"))
            {
                Record("FETCH_FAILED " + fetchName + " " + fetched);
                fetchName = "";
                waiting = false;
                ShowMessage("Could not download " + host + "'s save (" + fetched + "). Load a save yourself.");
            }
        }
        if(fetchedName != "") { LoadFetched(now); }
        // no lobby on the host's server: fall back to the save the launcher downloaded
        if(waiting && !reachable && now - menuSince > 8)
        {
            Record("NO_LOBBY: loading the launcher's save");
            waiting = false;
            HideDialog();
            Session().LoadLauncherSave();
        }
        if(Session().Role() == "host") { AutoStartForTests(); }
        if(dialogShown && DialogText() != dialogText) { ShowDialog(); }
    }

    private function Parse(reply : string, now : float)
    {
        var line, rest, key, value : string;
        if(!StrBeginsWith(reply, "200|"))
        {
            if(StrBeginsWith(reply, "error")) { reachable = false; }
            else { Record("LOBBY_REFUSED " + StrReplaceAll(reply, "|", " ")); }
            return;
        }
        if(!reachable) { Record("LOBBY_FOUND"); }
        reachable = true;
        answers += 1;
        StrSplitFirst(reply, "|", line, rest);   // the status line
        while(rest != "")
        {
            if(!StrSplitFirst(rest, "|", line, rest))
            {
                line = rest;
                rest = "";
            }
            if(!StrSplitFirst(line, "=", key, value)) { continue; }
            if(key == "host") { host = value; }
            else if(key == "state") { lobbyState = value; }
            else if(key == "seq") { seq = StringToInt(value, 0); }
            else if(key == "mode") { mode = value; }
            else if(key == "save") { save = value; }
            else if(key == "options") { options = StringToInt(value, 0); }
            else if(key == "age") { age = StringToInt(value, 0); }
            else if(key == "newest") { newest = value; }
            else if(key == "players") { players = value; }
        }
        if(Session().Role() == "host" && startRequested && lobbyState == "started" && mode == "save")
        {
            startRequested = false;
            Record("HOST_LOADS " + save);
            HideDialog();
            LoadNamed(save);
        }
        if(Session().Role() == "join" && waiting && lobbyState == "started" && seq != seenSeq) { FollowHost(); }
    }

    // The host started: load its save (downloading it first if needed) or start the same new game.
    private function FollowHost()
    {
        var saveName : string;
        seenSeq = seq;
        if(mode == "new" && age <= 120)
        {
            newGames += 1;
            Record("FOLLOW_NEW_GAME options=" + options);
            waiting = false;
            HideDialog();
            StartNewGame(options);
            return;
        }
        // the host's newest save: the one it started with, or a later one when this player comes back
        // (from the main menu, or late)
        saveName = newest;
        if(saveName == "" && mode == "save") { saveName = save; }
        if(saveName == "")
        {
            Record("FOLLOW_WAIT the host has no save yet");
            seenSeq = -1;
            return;
        }
        waiting = false;
        LoadNamed(saveName);
    }

    // Always the host's copy, downloaded over any save of this player's with the same name: autosave
    // and quicksave names repeat, so a save of the same name here may be this player's own, older one.
    private function LoadNamed(saveName : string)
    {
        if(WO_LobbyFetchSave(saveName))
        {
            fetches += 1;
            fetchName = saveName;
            Record("FETCH " + saveName);
            ShowDialog();   // the lobby popup stays up while downloading: its ticks watch the download
            return;
        }
        Record("FETCH_NOT_STARTED " + saveName);
        ShowMessage("Could not download " + host + "'s save " + saveName + ". Go back to the main menu to try again.");
    }

    // The game re-read its save folder (after RefreshCrossProgressionSavesList): look again now.
    public function OnSaveListUpdated()
    {
        listUpdates += 1;
        listCheckedAt = 0;
    }

    // The downloaded save, once the game's save list has it. The owner's rejoin gave up after 10 s
    // with the save on disk (a folder full of saves takes longer to list than the tests' empty one):
    // the list is asked for again every 3 s and the save waited for 45 s.
    private function LoadFetched(now : float)
    {
        var info : SSavegameInfo;
        var saves : array<SSavegameInfo>;
        if(now - listCheckedAt < 0.5) { return; }
        listCheckedAt = now;
        if(Session().FindSave(fetchedName, info))
        {
            loads += 1;
            Record("LOAD " + fetchedName + " after " + FloatToStringPrec(now - fetchedAt, 1) + " s");
            HideDialog();
            Session().LoadSave(fetchedName);
            fetchedName = "";
            return;
        }
        if(now - fetchedAt > 45)
        {
            theGame.ListSavedGames(saves);
            Record("LOAD_FAILED " + fetchedName + " is not listed (" + saves.Size() + " saves listed, " + listUpdates + " list updates)");
            ShowMessage("Downloaded " + host + "'s save " + fetchedName + ", but the game does not list it: load it from Load Game.");
            fetchedName = "";
            return;
        }
        if(now - listRefreshedAt >= 3)
        {
            listRefreshedAt = now;
            theGame.RefreshCrossProgressionSavesList();
        }
    }

    private function StartNewGame(newOptions : int)
    {
        var menu : CR4IngameMenu;
        menu = (CR4IngameMenu)((CR4MenuBase)theGame.GetGuiManager().GetRootMenu()).GetSubMenu();
        if(!menu)
        {
            Record("NEW_GAME_FAILED no main menu");
            ShowMessage(host + " started a new game, but the main menu was not found: start it yourself.");
            return;
        }
        Session().ExpectHostWorld("");
        menu.CoopStartNewGame(newOptions);
    }

    // ------------------------------------------------------------ host

    public function Start()
    {
        if(Session().Role() != "host") { return; }
        if(newest == "")
        {
            ShowMessage("You have no co-op save yet. Choose New Game: everyone waiting starts it with you.");
            return;
        }
        starts += 1;
        startRequested = true;
        Record("HOST_START with " + newest);
        WO_LobbyRequest("/lobby/start?mode=save");
    }

    private function AutoStartForTests()
    {
        var menu : CR4IngameMenu;
        if(players == "" || lobbyState == "started" || startRequested) { return; }
        if(autoStartWhenJoined)
        {
            autoStartWhenJoined = false;
            Record("TEST host starts: " + players + " waiting");
            Start();
        }
        else if(autoNewGameOptions > 0)
        {
            Record("TEST host starts a new game: " + players + " waiting");
            menu = (CR4IngameMenu)((CR4MenuBase)theGame.GetGuiManager().GetRootMenu()).GetSubMenu();
            if(menu) { menu.CoopStartNewGame(autoNewGameOptions); }
            autoNewGameOptions = 0;
        }
    }

    // ------------------------------------------------------------ dialog

    private function DialogText() : string
    {
        var text : string;
        if(fetchName != "") { return "Downloading " + host + "'s save " + fetchName + "..."; }
        if(fetchedName != "") { return "Loading " + host + "'s save " + fetchedName + "..."; }
        if(!reachable) { return "Looking for " + Session().HostName() + "'s co-op lobby..."; }
        if(Session().Role() == "host")
        {
            text = "You are hosting.<br>Waiting to join: ";
            if(players == "") { text += "nobody yet"; } else { text += StrReplaceAll(players, ",", ", "); }
            if(newest == "") { text += "<br><br>You have no co-op save yet: choose New Game, and everyone waiting starts it with you."; }
            else { text += "<br><br>OK: start with your newest save (" + newest + "). Everyone waiting loads it.<br>New Game: everyone waiting starts the same new game with you."; }
            text += "<br>Close this to use the menu; Co-op lobby (first in the menu) opens it again.";
            return text;
        }
        text = "Waiting for " + host + " to start the co-op game.";
        if(players != "") { text += "<br>In the lobby: " + StrReplaceAll(players, ",", ", "); }
        if(lobbyState == "started" && newest == "") { text += "<br>" + host + " is playing but has no save yet: wait for them to save."; }
        text += "<br><br>OK: stop waiting and play on your own.";
        return text;
    }

    private function ShowDialog()
    {
        var buttons : EUserDialogButtons;
        if(dialogShown) { theGame.GetGuiManager().HideUserDialog(COOP_LOBBY_DIALOG()); }
        dialogText = DialogText();
        buttons = UDB_Ok;
        if(Session().Role() == "host" && reachable && newest != "") { buttons = UDB_OkCancel; }
        // a progress dialog: the popup asks for progress every 200 ms in real time, also while the
        // menu pauses the game, and each request drives the lobby (CR4MessagePopup wrapper below)
        theGame.GetGuiManager().ShowProgressDialog(COOP_LOBBY_DIALOG(), "Co-op lobby", dialogText, false, buttons, 100, UMPT_GraphicsRefresh, '');
        dialogShown = true;
    }

    private function HideDialog()
    {
        if(!dialogShown) { return; }
        dialogShown = false;
        theGame.GetGuiManager().HideUserDialog(COOP_LOBBY_DIALOG());
    }

    private function ShowMessage(text : string)
    {
        HideDialog();
        theGame.GetGuiManager().ShowUserDialogAdv(COOP_LOBBY_DIALOG() + 1, "Co-op lobby", text, false, UDB_Ok);
    }

    public function OnDialogAnswer(ok : bool)
    {
        dialogShown = false;
        if(Session().Role() == "host")
        {
            if(ok && reachable && newest != "") { Start(); }
            return;
        }
        if(ok && waiting)
        {
            waiting = false;
            Record("JOIN_STOPPED waiting");
        }
    }
}

state CoopLobbyPolling in r_CoopLobby
{
    event OnEnterState(prevStateName : name)
    {
        super.OnEnterState(prevStateName);
        Poll();
    }

    entry function Poll()
    {
        while(parent.IsActive() || parent.IsWaiting())
        {
            parent.Step();
            Sleep(0.1);
        }
        parent.GotoState('CoopLobbyIdle');
    }
}

state CoopLobbyIdle in r_CoopLobby
{
}

function COOP_LOBBY_DIALOG() : int
{
    return 47320;
}

// The "Co-op lobby" entry, first in the main menu, for a host or a joining player.
@wrapMethod(IngameMenuStructureCreator)
function PopulateMenuData() : CScriptedFlashArray
{
    var items : CScriptedFlashArray;
    var lobbyEntry : CScriptedFlashObject;
    var i : int;
    items = wrappedMethod();
    if(!parentMenu.isMainMenu || theGame.r_getMultiplayerClient().getCoopSession().Role() == "") { return items; }
    // a leaf entry like Continue or Options (an empty child list): without one the menu treats it as
    // an empty sub-menu and the click never reaches OnItemActivated
    lobbyEntry = CreateMenuItem("coop_lobby", "coop_lobby", NameToFlashUInt('CoopLobby'), IGMActionType_Button, true);
    lobbyEntry.SetMemberFlashString("label", "Co-op lobby");
    lobbyEntry.SetMemberFlashString("listTitle", "Co-op lobby");
    items.PushBackFlashObject(lobbyEntry);
    for(i = items.GetLength() - 1; i > 0; i -= 1) { items.SetElementFlashObject(i, items.GetElementFlashObject(i - 1)); }
    items.SetElementFlashObject(0, lobbyEntry);
    return items;
}

@wrapMethod(CR4IngameMenu)
function OnItemActivated(actionType : int, menuTag : int)
{
    if(menuTag == NameToFlashUInt('CoopLobby'))
    {
        theGame.r_getMultiplayerClient().getCoopLobby().OnEntryActivated();
        return true;
    }
    wrappedMethod(actionType, menuTag);
    return true;
}

// The host's New Game choice: the options it picked, then the start itself (after any confirmation).
@wrapMethod(CR4IngameMenu)
function TryStartNewGame(optionsArray : int)
{
    theGame.r_getMultiplayerClient().getCoopLobby().OnHostNewGameChosen(optionsArray);
    if((optionsArray & IGMC_EP1_Save) == IGMC_EP1_Save || (optionsArray & IGMC_EP2_Save) == IGMC_EP2_Save)
    {
        theGame.r_getMultiplayerClient().getCoopLobby().OnHostNewGame(optionsArray);   // these start without a confirmation
    }
    wrappedMethod(optionsArray);
}

@wrapMethod(CR4IngameMenu)
function NewGameRequested()
{
    var chosen : int;
    chosen = theGame.r_getMultiplayerClient().getCoopLobby().HostNewGameOptions();
    if((chosen & IGMC_EP1_Save) != IGMC_EP1_Save && (chosen & IGMC_EP2_Save) != IGMC_EP2_Save)
    {
        theGame.r_getMultiplayerClient().getCoopLobby().OnHostNewGame(chosen);
    }
    wrappedMethod();
}

// A joining player starts the host's new game: as New Game would, without asking to overwrite
// the autosave (the host already chose).
@addMethod(CR4IngameMenu)
public function CoopStartNewGame(newOptions : int)
{
    if((newOptions & IGMC_EP1_Save) == IGMC_EP1_Save || (newOptions & IGMC_EP2_Save) == IGMC_EP2_Save || !hasValidAutosaveData())
    {
        TryStartNewGame(newOptions);
        return;
    }
    fetchNewGameConfigFromTag(newOptions);
    TutorialMessagesEnable(currentNewGameConfig.tutorialsOn);
    if(currentNewGameConfig.bardsBalladOn) { updateAccessibilityPresetValues(AP_BardsTale, false); }
    NewGameRequested();
}

@wrapMethod(CR4GuiManager)
function UserDialogCallback(messageId : int, actionId : EUserMessageAction)
{
    wrappedMethod(messageId, actionId);
    if(messageId == COOP_LOBBY_DIALOG())
    {
        theGame.r_getMultiplayerClient().getCoopLobby().OnDialogAnswer(actionId == UMA_Ok);
    }
}

// The lobby popup's progress requests: the lobby's clock in the main menu.
@wrapMethod(CR4MessagePopup)
function OnProgressUpdateRequested()
{
    var data : W3MessagePopupData;
    var lobby : r_CoopLobby;
    data = GetCurrentMessageData();
    if(!data || data.messageId != COOP_LOBBY_DIALOG())
    {
        wrappedMethod();
        return true;
    }
    lobby = theGame.r_getMultiplayerClient().getCoopLobby();
    lobby.Step();
    data = GetCurrentMessageData();
    if(data && data.messageId == COOP_LOBBY_DIALOG() && lobby.IsDialogShown())
    {
        DisplayProgressBar(100, UMPT_GraphicsRefresh);   // ask again in 200 ms
    }
    return true;
}

@wrapMethod(CR4Game)
function OnGameSaveListUpdated()
{
    wrappedMethod();
    theGame.r_getMultiplayerClient().getCoopLobby().OnSaveListUpdated();
}
