// In-game test bot. Does nothing unless the W3T_SCENARIO environment variable is set.
// Env: W3T_SCENARIO (name), W3T_SAVE (part of a save filename; newest save if empty), W3T_DURATION (seconds in game).
// A session runs several scenarios in one game: W3T_SCENARIOS (comma-separated) and W3T_CONTROL, a file in which the
// harness writes "go N" (start scenario N) or "end".

import function W3T_GetEnv(key : string) : string;
import function W3T_Log(line : string);
import function W3T_TimeMs() : int;
import function W3T_ReadFile(path : string) : string;
import function W3T_Quit(code : int);

function W3T_Active() : bool
{
    return W3T_GetEnv("W3T_SCENARIO") != "";
}

function W3T_Split(text : string, separator : string) : array<string>
{
    var parts : array<string>;
    var left, right : string;

    while(text != "")
    {
        if(!StrSplitFirst(text, separator, left, right))
        {
            parts.PushBack(text);
            break;
        }
        parts.PushBack(left);
        text = right;
    }
    return parts;
}

// the harness's word in a session: N for "go N", -2 for "end", -1 for nothing yet
function W3T_SessionGo() : int
{
    var words : array<string>;

    words = W3T_Split(StrReplaceAll(StrReplaceAll(W3T_ReadFile(W3T_GetEnv("W3T_CONTROL")), "\r", ""), "\n", ""), " ");
    if(words.Size() >= 1 && words[0] == "end")
    {
        return -2;
    }
    if(words.Size() >= 2 && words[0] == "go")
    {
        return StringToInt(words[1], -1);
    }
    return -1;
}

function W3T_VecStr(v : Vector) : string
{
    return FloatToStringPrec(v.X, 2) + "," + FloatToStringPrec(v.Y, 2) + "," + FloatToStringPrec(v.Z, 2);
}

@addField(CR4Game)
var w3t_bot : W3T_Bot;

@addField(CR4Game)
var w3t_loadRequested : bool;

// theGame is const outside CR4Game, so its added fields are changed through methods.
@addMethod(CR4Game)
function W3T_ClaimLoad() : bool
{
    if(w3t_loadRequested)
    {
        return false;
    }
    w3t_loadRequested = true;
    return true;
}

@addMethod(CR4Game)
function W3T_StartBot()
{
    if(!w3t_bot)
    {
        w3t_bot = new W3T_Bot in this;
        w3t_bot.Start();
    }
    else
    {
        // A scenario loaded a save mid-run: the world (and maybe the latent loop) was
        // replaced. Re-entering the state restarts its single entry function.
        W3T_Log("BOT resumed after a load");
        if(w3t_bot.scenario == "seamless_reload_mh306")
        {
            // Spawn time, before the campaign adapter's replay has any reply: this is the save's own state.
            W3T_Log("RELOAD world as loaded: fact=" + FactsDoesExist("mh306_job_taken") + "/" + FactsQuerySum("mh306_job_taken")
                + " journal=" + W3T_QuestIsActive("AF164E2C-41CC196D-1AB4BFB6-1DAA9A91"));
        }
        w3t_bot.GotoState('W3T_Running', false, true);
    }
}

@wrapMethod(CR4StartupMoviesMenu)
function OnConfigUI()
{
    wrappedMethod();

    if(W3T_Active())
    {
        W3T_Log("MENU startup movies -> skip");
        CloseMenu();
    }
}

// The "story so far" recap (gamestart/recap_wip.usm, about 3 minutes) plays before the main menu.
@wrapMethod(CR4RecapMoviesMenu)
function OnConfigUI()
{
    wrappedMethod();

    if(W3T_Active())
    {
        W3T_Log("MENU recap movie -> skip");
        CloseMenu();
    }
}

// CDPR account / telemetry consent prompt: close it without signing in or answering consent questions
// (nothing is stored, so the owner still sees it on their own next launch).
@wrapMethod(CR4StartupExperienceMenu)
function OnConfigUI()
{
    wrappedMethod();

    if(W3T_Active())
    {
        W3T_Log("MENU startup experience (account/telemetry prompt) -> close without answering");
        CloseMenu();
    }
}

@wrapMethod(CR4MenuBase)
function OnConfigUI()
{
    wrappedMethod();

    if(W3T_Active())
    {
        W3T_Log("MENU open " + NameToString(GetMenuName()));
        // pause_menu: the pause menu pauses the game, and with it the bot that checks it stays open; the
        // world runs on here (as the co-op features do every frame) so the check can be made
        if(GetMenuName() == 'IngameMenu' && W3T_GetEnv("W3T_SCENARIO") == "pause_menu")
        {
            theGame.Unpause('IngameMenu');
            W3T_Log("MENU pause_menu: the game runs on under the pause menu");
        }
        // talk_share / scene_share: the shop pauses the game, and with it the bot that would close
        // it; the starter (which asked to trade) closes it here. The joiner's is the feature's to close.
        if(GetMenuName() == 'CommonMenu' && ((W3T_GetEnv("W3T_SCENARIO") == "talk_share" && W3T_GetEnv("W3T_ROLE") != "mover")
            || (W3T_GetEnv("W3T_SCENARIO") == "scene_share" && W3T_GetEnv("W3T_ROLE") == "mover")))
        {
            W3T_Log("MENU shop -> close (starter)");
            if(theGame.GetGuiManager().GetLastOpenedCommonMenuName() == 'None') { theGame.GetGuiManager().SetLastOpenedCommonMenuName(GetMenuName()); }
            CloseMenu();
        }
    }
}

// Logs every system dialog and answers it (OK / Yes) so nothing waits for a human.
@wrapMethod(CR4GuiManager)
function ShowProgressDialog( messageId : int, title : string, message : string, localizationNeeded:bool, type : EUserDialogButtons, progressValue:float, progressType:EUserMessageProgressType, progressTag:name)
{
    var text : string;

    wrappedMethod(messageId, title, message, localizationNeeded, type, progressValue, progressType, progressTag);

    if(!W3T_Active())
    {
        return;
    }

    if(localizationNeeded)
    {
        text = GetLocStringByKeyExt(title) + " | " + GetLocStringByKeyExt(message);
    }
    else
    {
        text = title + " | " + message;
    }
    W3T_Log("DIALOG id=" + messageId + " type=" + (int)type + " text=" + text);

    if(messageId == COOP_LOBBY_DIALOG())
    {
        W3T_Log("DIALOG the co-op lobby is left open");
        return;
    }
    if(W3T_GetEnv("W3T_SCENARIO") == "party_menu" && WO_IsPartyPrompt(messageId)) { theGame.W3T_AnswerPartyPrompt(messageId); return; }
    // anywhere else a party prompt is a person's (Interact on the other Geralt while watching a run): left
    // open for them. Answered Yes, it took the second PC out of the party mid-run in the owner's playtest
    if(WO_IsPartyPrompt(messageId))
    {
        W3T_Log("DIALOG party prompt left open for the player");
        return;
    }
    // watch_skip: the host answers Skip to the first Watch / Skip prompt and leaves the second open
    if(W3T_GetEnv("W3T_SCENARIO") == "watch_skip" && messageId == COOP_WATCH_DIALOG())
    {
        if(theGame.r_getMultiplayerClient().getCoopTalk().offersShown <= 1)
        {
            UserDialogCallback(messageId, UMA_No);
            HideUserDialog(messageId);
            W3T_Log("DIALOG answered No (skip)");
        }
        else
        {
            W3T_Log("DIALOG left unanswered");
        }
        return;
    }

    if(type == UDB_Ok || type == UDB_OkCancel)
    {
        UserDialogCallback(messageId, UMA_Ok);
        HideUserDialog(messageId);
        W3T_Log("DIALOG answered OK");
    }
    else if(type == UDB_YesNo)
    {
        UserDialogCallback(messageId, UMA_Yes);
        HideUserDialog(messageId);
        W3T_Log("DIALOG answered Yes");
    }
}

@wrapMethod(CR4CommonMainMenuBase)
function OnConfigUI()
{
    var saves : array<SSavegameInfo>;
    var wanted : string;
    var i : int;

    wrappedMethod();

    if(!W3T_Active() || !theGame.W3T_ClaimLoad())
    {
        return true;
    }

    if(StrBeginsWith(W3T_GetEnv("W3T_SCENARIO"), "lobby_"))
    {
        if(W3T_GetEnv("W3T_ROLE") == "mover")
        {
            if(W3T_GetEnv("W3T_SCENARIO") == "lobby_new") { theGame.r_getMultiplayerClient().getCoopLobby().SetTestAutoNewGame(2); }
            else { theGame.r_getMultiplayerClient().getCoopLobby().SetTestAutoStart(); }
            W3T_Log("MENU the host waits in the co-op lobby for someone to join");
        }
        else
        {
            W3T_Log("MENU waiting in the co-op lobby");
        }
        return true;
    }

    if(WO_SessionConfig("save") != "")
    {
        W3T_Log("MENU the co-op session loads the host's save " + WO_SessionConfig("save"));
        return true;
    }

    wanted = W3T_GetEnv("W3T_SAVE");
    theGame.ListSavedGames(saves);
    W3T_Log("MENU main menu, saves=" + saves.Size() + " wanted='" + wanted + "'");

    if(wanted == "")
    {
        W3T_Log("LOAD newest save");
        theGame.LoadLastGameInit();
        return true;
    }

    for(i = 0; i < saves.Size(); i += 1)
    {
        if(StrFindFirst(saves[i].filename, wanted) >= 0)
        {
            W3T_Log("LOAD " + saves[i].filename);
            theGame.LoadGameInit(saves[i], false);
            return true;
        }
    }

    W3T_Log("FAIL no save matches '" + wanted + "'");
    W3T_Quit(3);
}

@wrapMethod(CR4Player)
function OnSpawned(spawnData : SEntitySpawnData)
{
    wrappedMethod(spawnData);

    if(W3T_Active())
    {
        W3T_SkipLoadingVideo("player spawned");
        theGame.W3T_StartBot();
    }
}

@wrapMethod(CR4Game)
function OnAfterLoadingScreenGameStart()
{
    wrappedMethod();

    if(W3T_Active())
    {
        W3T_Log("LOADING screen finished");
    }
}

// The recap video on the loading screen otherwise plays to the end before the world starts.
function W3T_SkipLoadingVideo(when : string)
{
    if(theGame.IsLoadingScreenVideoPlaying())
    {
        W3T_Log("LOADING video playing at " + when + " -> cancel");
        theGame.GetGuiManager().CancelFlashbackVideo();
    }
}

statemachine class W3T_Bot
{
    public var startMs : int;
    public var reports : int;

    // free-form scenario state
    public var scenarioVec : Vector;
    public var scenarioFlag : bool;
    public var pauseOpens : int;                 // pause_menu: pause menus still open 2 s after Esc
    public var scenarioTime : float;
    public var scenarioCount : int;
    public var scenarioEntity : CEntity;
    public var scenarioEntities : array<CEntity>;
    public var scenarioStep : int;       // a fighting bot's moves
    public var scenarioText : string;    // last text a probe logged, to log only changes
    public var scFirstInstance : string;
    public var scSecondInstance : string;
    public var scFirstReceipt : int;
    public var qpNote : string;          // seamless_quest_probe: the notice taken
    public var qpQuestFact : string;
    public var qpQuests : array<string>;
    public var qpKeys : array<string>;          // quest_share: the notices the second PC takes
    public var qpFacts : array<string>;         // ... and the quest fact each one starts
    public var qpApplied : int;                 // ... applies counted once settled, to catch echo loops
    public var surveySeen : array<string>;     // monster_survey: "monster|kind|value" logged
    public var surveyLabels : array<string>;   // ... the second PC: monsters whose copy appeared
    public var surveyStartZ : array<float>;    // ... and the height it appeared at
    public var surveyCopies : array<CEntity>;  // ... and those copies
    public var bossScene : string;             // boss_fight: the scene last logged
    public var scenarioActAt : float;    // when it last moved
    public var scenarioSeenAt : float;   // when it last saw an enemy
    public var scenarioFarSince : float; // since when its target has been out of reach
    public var scenarioPos : Vector;     // where it stood when it last moved (stuck checks)
    public var scenarioValue : float;
    // prologue_coop after the wake-up (the owner's check): the second PC kills the ghouls, the quest moves on,
    // both travel to its new marker and no ghoul may show up on the way
    public var ghoulsSeen : int;          // samples with hostiles near, after the wake-up
    public var ghoulsClearAt : float;     // since when none are near (0: some are, or none seen yet)
    public var ghoulsCleared : bool;
    public var travelSteps : int;
    public var travelAt : float;
    public var ghoulsOnTheWay : int;      // samples with hostiles or enemy copies near while travelling
    public var objectivesAfter : string;
    public var hostilesText : string;     // the hostiles near as last logged
    // prologue_coop, the second PC after the wake-up: Vesemir riding ("Follow Vesemir")
    public var rideText : string;         // what shows of him, as last logged
    public var rideSeen : int;            // samples with a Vesemir on a horse
    public var rideBad : int;             // samples with a stand-in galloping or beside a riding own one
    public var ridePos : Vector;          // the stand-in at the last sample
    public var rideAt : float;
    public var ownVesemirPos : Vector;    // this world's own Vesemir at the last tick (shown, not a stand-in)
    public var ownVesemirAt : float;
    public var ownVesemirLoggedAt : float; // when his position was last logged (every 2 s)
    public var ownVesemirJumps : int;     // ticks in which he moved more than 25 m: a teleport

    // every scenario: the second PC showing enemies the leader's world doesn't (W3T_FightCheck)
    public var fightMismatchRun : int;   // reports in a row with a mismatch
    public var fightMismatches : int;    // mismatches that lasted 3 reports or more
    public var labelSceneChecks : int;   // scene_share: ticks seen inside a scene that hides labels
    public var labelSceneShown : int;    // ... with a player label still on screen
    public var scenarioName : name;

    public var scenario : string;        // the one running (empty in a session until the harness says go)
    public var scenarioIndex : int;      // its place in the session
    public var settleUntil : float;      // after a switch: let the last scenario's monsters go first
    public var begun : bool;             // the session's scenario has started after settling
    public var home : Vector;            // where the save put the player; each session scenario starts there
    public var homeSet : bool;

    public function Start()
    {
        startMs = W3T_TimeMs();
        scenarioIndex = -1;
        if(W3T_GetEnv("W3T_SCENARIOS") == "")
        {
            scenario = W3T_GetEnv("W3T_SCENARIO");
            scenarioIndex = 0;
            begun = true;
        }
        W3T_Log("BOT start scenario=" + W3T_GetEnv("W3T_SCENARIO"));
        GotoState('W3T_Running');
    }

    // a session's next scenario: the last one's leftovers go, the free-form state starts over
    public function NextScenario(index : int, next : string)
    {
        if(scenario != "")
        {
            W3T_EndScenario(this);
        }
        scenarioVec = Vector(0, 0, 0);
        scenarioFlag = false;
        scenarioTime = 0;
        scenarioCount = 0;
        scenarioEntity = NULL;
        scenarioEntities.Clear();
        scenarioStep = 0;
        scenarioActAt = 0;
        scenarioSeenAt = 0;
        scenarioFarSince = 0;
        scenarioPos = Vector(0, 0, 0);
        scenarioValue = 0;
        scenarioName = '';
        scenarioIndex = index;
        scenario = next;
        settleUntil = ElapsedS() + 5;
        begun = false;
        W3T_Log("SCENARIO " + next + " start");
    }

    public function ElapsedS() : float
    {
        return (W3T_TimeMs() - startMs) / 1000.0;
    }

    public var lastReportReal : float;
    public var lastReportGame : float;

    public function Report()
    {
        var line : string;
        var real : float;
        var game : float;
        var speed : float;

        // game seconds per real second: well below 1 means the engine runs at very low FPS
        real = ElapsedS();
        game = theGame.GetEngineTimeAsSeconds();
        if(real > lastReportReal && lastReportReal > 0)
        {
            speed = (game - lastReportGame) / (real - lastReportReal);
        }
        lastReportReal = real;
        lastReportGame = game;

        line = "STATE speed=" + FloatToStringPrec(speed, 2) + " t=" + FloatToStringPrec(ElapsedS(), 1)
            + " pos=" + W3T_VecStr(thePlayer.GetWorldPosition())
            + " area=" + NameToString(theGame.GetCommonMapManager().GetCurrentArea())
            + " hp=" + FloatToStringPrec(thePlayer.GetStat(BCS_Vitality), 0);
        W3T_Log(line);
        W3T_ReportExtra(this);
        reports += 1;
    }
}

// Every scenario, each report: on the second PC, the enemies it shows must be the leader's (coopEnemies
// FightMismatch), whatever quest or fight is on. A mismatch for 3 reports in a row (a new enemy is hidden or
// paired within a snapshot) counts, and the scenario can no longer pass.
function W3T_FightCheck(bot : W3T_Bot)
{
    var client : r_MultiplayerClient;
    var text : string;
    client = theGame.r_getMultiplayerClient();
    if(!client) { return; }
    text = client.getCoopEnemies().FightMismatch();
    if(text == "")
    {
        bot.fightMismatchRun = 0;
        return;
    }
    bot.fightMismatchRun += 1;
    if(bot.fightMismatchRun == 3)
    {
        bot.fightMismatches += 1;
        W3T_Log("FAIL-MARK fight differs from the leader's:" + text);
    }
}

state W3T_Running in W3T_Bot
{
    event OnEnterState(prevStateName : name)
    {
        RunLoop();
    }

    // Passes once the scenario condition holds for 3 reports in a row, then stays W3T_GRACE seconds so peers
    // can observe this instance too. Fails after W3T_DURATION seconds without a pass. In a session the harness
    // decides when to go on (and when a scenario failed); this game only reports.
    entry function RunLoop()
    {
        var duration : float;
        var grace : float;
        var passedAt : float;
        var startedAt : float;
        var streak : int;
        var session : array<string>;
        var go : int;

        duration = StringToFloat(W3T_GetEnv("W3T_DURATION"), 240.0);
        grace = StringToFloat(W3T_GetEnv("W3T_GRACE"), 20.0);
        session = W3T_Split(W3T_GetEnv("W3T_SCENARIOS"), ",");
        passedAt = -1;

        while(true)
        {
            parent.Report();
            W3T_FightCheck(parent);

            // a tutorial hint pauses the game until closed; the sandbox turns them off, this closes any that still shows
            if(theGame.GetTutorialSystem() && theGame.GetTutorialSystem().HasActiveTutorial())
            {
                theGame.GetTutorialSystem().HideTutorialHint('', true);
                W3T_Log("HINT closed a tutorial hint");
            }

            // the player is at 0,0,0 until the save has placed it, some seconds after the bot starts
            if(!parent.homeSet && VecLengthSquared(thePlayer.GetWorldPosition()) > 1)
            {
                parent.home = thePlayer.GetWorldPosition();
                parent.homeSet = true;
            }

            if(session.Size() > 0)
            {
                go = W3T_SessionGo();
                if(go == -2)
                {
                    W3T_Log("BOT session done after " + parent.reports + " reports");
                    W3T_Quit(0);
                }
                if(go >= 0 && go < session.Size() && go != parent.scenarioIndex)
                {
                    parent.NextScenario(go, session[go]);
                    startedAt = parent.ElapsedS();
                    passedAt = -1;
                    streak = 0;
                }
            }

            // keep stepping after a pass too: some scenarios act for their peers (e.g. the mover)
            if(parent.scenario != "" && parent.ElapsedS() >= parent.settleUntil)
            {
                if(!parent.begun)
                {
                    W3T_BeginScenario(parent);
                    parent.begun = true;
                }
                // no scenario passes once the second PC showed the fight differently from the leader's
                if(W3T_ScenarioCheck(parent) && parent.fightMismatches == 0)
                {
                    streak += 1;
                }
                else
                {
                    streak = 0;
                }

                if(passedAt < 0)
                {
                    if(streak >= 3)
                    {
                        passedAt = parent.ElapsedS();
                        W3T_Log("PASS condition met at t=" + FloatToStringPrec(passedAt, 1) + " scenario=" + parent.scenario);
                    }
                    else if(session.Size() == 0 && parent.ElapsedS() - startedAt > duration)
                    {
                        W3T_Log("FAIL condition not met within " + FloatToStringPrec(duration, 0) + " s");
                        W3T_Quit(1);
                    }
                }
                else if(session.Size() == 0 && parent.ElapsedS() - passedAt > grace)
                {
                    W3T_Log("BOT done after " + parent.reports + " reports");
                    W3T_Quit(0);
                }
            }

            // W3T_TICK: shorter steps for scenarios that act, like the showcase's fights
            Sleep(StringToFloat(W3T_GetEnv("W3T_TICK"), 1.0));
        }
    }
}
