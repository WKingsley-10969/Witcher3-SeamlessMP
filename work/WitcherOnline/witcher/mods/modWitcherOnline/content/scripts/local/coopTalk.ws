// Shared conversations (party). When a player talks to an NPC, party members nearby join the
// same conversation in their own game: each game starts that NPC's conversation the way the
// Talk button does (the probe showed both get the same scene, lines and choices), so the
// joiner watches it with camera, voice and subtitles, and its own quest graph runs it too.
// Whoever picks a choice first decides it (owner decision, 2026-10-26): the pick goes through in
// that player's game, is shown above the choices in the others' as "<name> chose: <text>", and is
// applied there when the same choice list comes up (matched by text, so a game that is a line or
// two behind still follows). A pick that arrives for a list this game already answered itself
// is dropped (both picked at once: each game keeps its own, logged as CONFLICT). Menus the
// conversation opens (a shop, a barber) are closed in the joiner's game: trading is for the
// one who asked. Records events (scene, lines, choices) for tests.
//
// Scenes a quest starts by itself (no Talk pressed) are shared too: the joiner is brought beside
// the starter and its own quest graph, kept at the same step by the shared quest progress, starts
// the same scene there. If it does not within a few seconds, the joiner goes back where it was.
// When both games start the same scene on their own, the leader chooses and the other listens.
//
// Joining is offered, not forced (COOP_WATCH_MODE): by default a Watch / Skip prompt; Skip keeps
// playing, and the outcome still arrives through the shared quest progress. Always joins without
// asking, Never declines every offer. Console: coopwatch ask / always / never.
//
// "cv open id scene voice tpl app x y z px py pz": the starter (NPC at x y z, starter at p); an
// empty voice and template mark a scene the quest started (x y z is then the starter too)
// "cv pick id set index text" (from the starter or any listener; id is the starter's conversation)
// "cv vote id set index text" (older clients' suggestion) / "cv joined id scene" / "cv close id"
class r_CoopTalkPick
{
    public var listNo : int;
    public var index : int;
    public var text : string;
    public var at : float;
    public var reported : bool;
    public var who : string;
}

class r_CoopTalk
{
    private var events : array<string>;
    private var scenePath : string;
    private var inScene : bool;

    // starter side
    private var talkedTo : CNewNPC;    // the NPC this player just pressed Talk on
    private var talkedAt : float;
    private var convId : int;          // this player's open conversation, 0 when none
    private var listeners : array<string>;

    // joiner side
    private var role : int;            // 0 none, 1 starter, 2 joining, 3 listening
    private var hostName : string;     // the starter whose conversation this game joined
    private var hostConv : int;
    private var hostScene : string;
    private var joinNpc : CNewNPC;
    private var joinTalkAt : float;    // when to press Talk here; 0 once pressed
    private var joinStartedAt : float;
    private var joinAuto : bool;       // joining a scene the quest started: wait for it, press nothing
    private var joinFrom : Vector;     // where this player stood before being brought over
    private var joinFromRot : EulerAngles;
    private var auto : bool;           // the starter's scene was started by the quest, not by Talk

    // an offer to join a party member's conversation, waiting for this player's answer
    private var offerOpen : bool;
    private var offerSender : string;
    private var offerConv : int;
    private var offerScene : string;
    private var offerVoice : string;
    private var offerTpl : string;
    private var offerApp : string;
    private var offerNpcPos : Vector;
    private var offerStarterPos : Vector;
    private var offerAuto : bool;
    private var picks : array<r_CoopTalkPick>;
    private var applying : bool;
    private var applyAt : float;
    private var applyIndex : int;

    private var choiceSet : int;       // choice lists seen in the current conversation
    private var choiceTexts : array<string>;
    private var choicesOpen : bool;
    private var choicesAt : float;      // engine time the current choice list appeared
    private var answeredSet : int;      // the last choice list answered here (its number in the conversation)
    // "<name> chose: <text>" for a pick made in another game, shown above the choices only while
    // they are on screen: the dialogue box's field for it lies over the subtitles otherwise
    private var pickAlert : string;
    private var pickAlertShown : bool;

    public var linesSeen : int;
    public var choiceSets : int;
    public var joins : int;
    public var joinFailures : int;
    public var sceneMismatches : int;
    public var picksSent : int;
    public var picksApplied : int;
    public var alertsShown : int;      // "<name> chose" shown above the choices
    public var votesSent : int;
    public var votesReceived : int;
    public var menusClosed : int;
    public var autoOpens : int;        // quest-started scenes this game announced
    public var autoJoins : int;        // quest-started scenes joined
    public var autoMissed : int;       // brought over, but this game's quest started no scene
    public var handovers : int;        // both games started it: this one became the listener
    public var offersShown : int;      // Watch / Skip prompts shown
    public var offersSkipped : int;    // answered Skip, or declined by the Never setting
    public var offersGone : int;       // the conversation ended before an answer
    public var lastVote : string;

    public function InScene() : bool { return inScene; }
    public function GetScenePath() : string { return scenePath; }
    public function IsApplying() : bool { return applying; }
    // A shared conversation is running here: the older leader-follows dialogue sync stays out of it.
    public function IsSyncing() : bool { return role == 3 || (role == 1 && convId != 0); }
    public function IsListening() : bool { return role == 3; }
    public function ListenerCount() : int { return listeners.Size(); }
    public function LastChoiceCount() : int { return choiceTexts.Size(); }
    public function ChoicesAge() : float
    {
        if(!choicesOpen) { return -1; }
        return theGame.GetEngineTimeAsSeconds() - choicesAt;
    }

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
        if(events.Size() > 200) { events.Erase(0); }
    }

    // ------------------------------------------------------------ local game

    // The local player pressed Talk on an NPC (not a joiner's replayed Talk).
    public function OnLocalTalk(npc : CNewNPC)
    {
        if(role == 2 || role == 3) { return; }
        talkedTo = npc;
        talkedAt = theGame.GetEngineTimeAsSeconds();
    }

    public function OnSceneStarted(scene : CStoryScene)
    {
        var now : float;
        now = theGame.GetEngineTimeAsSeconds();
        inScene = true;
        scenePath = "";
        if(scene) { scenePath = scene.GetPath(); }
        choiceSet = 0;
        answeredSet = 0;
        choicesOpen = false;
        Record("SCENE " + scenePath);
        // the scene's actors are this world's own NPCs: no stand-ins or hidden copies around it
        if(InParty()) { theGame.r_getMultiplayerClient().getCoopNpcs().HoldAround(thePlayer.GetWorldPosition()); }
        if(role == 2)
        {
            role = 3;
            if(joinAuto) { autoJoins += 1; }
            if(scenePath != hostScene)
            {
                sceneMismatches += 1;
                Record("MISMATCH host=" + hostScene);
            }
            WO_Send("coop cv joined " + hostConv + " " + CoopEncode(scenePath));
            return;
        }
        if(role == 0 && talkedTo && now - talkedAt < 3.0 && InParty())
        {
            convId += 1;
            role = 1;
            auto = false;
            listeners.Clear();
            WO_Send("coop cv open " + convId + " " + CoopEncode(scenePath) + " " + CoopEncode(NpcVoice(talkedTo)) + " "
                + CoopEncode(talkedTo.GetReadableName()) + " " + CoopEncode(NameToString(talkedTo.GetAppearance())) + " "
                + CoopNpcVec3(talkedTo.GetWorldPosition()) + " " + CoopNpcVec3(thePlayer.GetWorldPosition()));
        }
        else if(role == 0 && InParty())
        {
            // the quest started this scene: offer it to the party the same way
            convId += 1;
            role = 1;
            auto = true;
            autoOpens += 1;
            listeners.Clear();
            Record("AUTO_OPEN " + scenePath);
            WO_Send("coop cv open " + convId + " " + CoopEncode(scenePath) + " - - - "
                + CoopNpcVec3(thePlayer.GetWorldPosition()) + " " + CoopNpcVec3(thePlayer.GetWorldPosition()));
        }
        talkedTo = NULL;
    }

    public function OnSceneEnded()
    {
        inScene = false;
        choicesOpen = false;
        Record("END " + scenePath);
        if(role == 1)
        {
            WO_Send("coop cv close " + convId);
            convId = 0;
            listeners.Clear();
            picks.Clear();
            applyAt = 0;
            pickAlert = "";
            pickAlertShown = false;
            theGame.r_getMultiplayerClient().clearDialogPickAlert();
        }
        if(role == 3 || role == 2) { LeaveConversation(); }
        else { theGame.r_getMultiplayerClient().getCoopNpcs().ReleaseScene(); }
        role = 0;
    }

    public function OnSentence(text : string)
    {
        linesSeen += 1;
        Record("LINE " + text);
    }

    public function OnChoices(choices : array<SSceneChoice>)
    {
        var text : string;
        var i : int;
        choiceSets += 1;
        choiceTexts.Clear();
        for(i = 0; i < choices.Size(); i += 1)
        {
            if(i > 0) { text += " | "; }
            text += choices[i].description + " [a" + (int)choices[i].dialogAction;
            if(choices[i].previouslyChoosen) { text += " seen"; }
            if(choices[i].disabled) { text += " off"; }
            text += "]";
            choiceTexts.PushBack(choices[i].description);
        }
        Record("CHOICES " + choices.Size() + " " + text);
        choicesOpen = choices.Size() > 0;
        choicesAt = theGame.GetEngineTimeAsSeconds();
        if(choicesOpen) { choiceSet += 1; }
    }

    // Called before a choice is accepted here. True would keep the click from the scene: no longer
    // used, since whoever picks first decides.
    public function InterceptChoice(index : int) : bool
    {
        return false;
    }

    public function OnAccepted(index : int)
    {
        var text : string;
        var conv, i : int;
        Record("ACCEPT " + index);
        choicesOpen = false;
        answeredSet = choiceSet;
        if(pickAlertShown) { theGame.r_getMultiplayerClient().clearDialogPickAlert(); }
        pickAlertShown = false;
        pickAlert = "";
        if(index >= 0 && index < choiceTexts.Size()) { text = choiceTexts[index]; }
        // this list is answered here: picks the others sent for it are too late
        for(i = picks.Size() - 1; i >= 0; i -= 1)
        {
            if(picks[i].index >= 0 && picks[i].index < choiceTexts.Size() && choiceTexts[picks[i].index] == picks[i].text)
            {
                if(!applying && picks[i].text != text) { Record("CONFLICT kept " + text + " over " + picks[i].who + "'s " + picks[i].text); }
                picks.Erase(i);
            }
        }
        if(applying) { return; }
        conv = 0;
        if(role == 1) { conv = convId; }
        else if(role == 3) { conv = hostConv; }
        if(conv != 0)
        {
            WO_Send("coop cv pick " + conv + " " + choiceSet + " " + index + " " + CoopEncode(text));
            picksSent += 1;
        }
    }

    // ------------------------------------------------------------ network

    public function OnMessage()
    {
        var sender, kind : string;
        var count : int;
        sender = WO_Str(-1);
        count = StringToInt(WO_Str(-3), 0);
        if(WO_Str(0) != "cv" || count < 3 || sender == theGame.r_getMultiplayerClient().getUsername()) { return; }
        kind = WO_Str(1);
        Record("MSG " + kind + " from " + sender + " fields=" + count + " party=" + SameParty(sender) + " role=" + role);
        if(!SameParty(sender)) { return; }
        if(kind == "open" && count >= 13) { OnOpen(sender); }
        else if(kind == "pick" && count >= 5) { OnPick(sender); }
        else if(kind == "vote" && count >= 5) { OnVote(sender); }
        else if(kind == "joined") { OnJoined(sender); }
        else if(kind == "close") { OnClose(sender); }
    }

    private function OnOpen(sender : string)
    {
        var npc : CNewNPC;
        var npcPos, starterPos, spot, safe : Vector;
        var rot : EulerAngles;
        if(role == 1 && inScene && CoopDecode(WO_Str(3)) == scenePath)
        {
            // both games started the same scene: one chooses, the other listens
            if(!ChoosesOver(sender))
            {
                WO_Send("coop cv close " + convId);
                convId = 0;
                listeners.Clear();
                hostName = sender;
                hostConv = StringToInt(WO_Str(2), 0);
                hostScene = scenePath;
                picks.Clear();
                role = 3;
                handovers += 1;
                Record("HANDOVER to " + sender);
                WO_Send("coop cv joined " + hostConv + " " + CoopEncode(scenePath));
            }
            return;
        }
        if(role != 0 || inScene || offerOpen || thePlayer.IsInCombat() || thePlayer.IsUsingVehicle()) { return; }
        offerSender = sender;
        offerConv = StringToInt(WO_Str(2), 0);
        offerScene = CoopDecode(WO_Str(3));
        offerVoice = CoopDecode(WO_Str(4));
        offerTpl = CoopDecode(WO_Str(5));
        offerApp = CoopDecode(WO_Str(6));
        offerNpcPos = Vector(StringToFloat(WO_Str(7), 0), StringToFloat(WO_Str(8), 0), StringToFloat(WO_Str(9), 0));
        offerStarterPos = Vector(StringToFloat(WO_Str(10), 0), StringToFloat(WO_Str(11), 0), StringToFloat(WO_Str(12), 0));
        offerAuto = offerVoice == "" && offerTpl == "";
        if(offerAuto && VecDistance(thePlayer.GetWorldPosition(), offerStarterPos) > COOP_SCENE_RANGE()) { return; }
        if(!offerAuto && VecDistance(thePlayer.GetWorldPosition(), offerNpcPos) > COOP_TALK_RANGE()) { return; }

        if(COOP_WATCH_MODE() == 2)
        {
            offersSkipped += 1;
            Record("OFFER_DECLINED setting " + offerSender + " " + offerScene);
            return;
        }
        if(COOP_WATCH_MODE() == 1)
        {
            AcceptOffer();
            return;
        }
        npc = NULL;
        if(!offerAuto) { npc = theGame.r_getMultiplayerClient().getCoopNpcs().FindForScene(offerVoice, offerTpl, offerApp, offerNpcPos); }
        offerOpen = true;
        offersShown += 1;
        Record("OFFER " + offerSender + " " + offerScene);
        theGame.GetGuiManager().ShowUserDialogAdv(COOP_WATCH_DIALOG(), CoopWatchTitle(), CoopWatchText(offerSender, npc, offerAuto), false, UDB_YesNo);
    }

    // The Watch / Skip prompt was answered.
    public function OnWatchAnswer(watch : bool)
    {
        if(!offerOpen) { return; }
        offerOpen = false;
        if(!watch)
        {
            offersSkipped += 1;
            Record("OFFER_SKIPPED " + offerSender);
            return;
        }
        if(role != 0 || inScene || thePlayer.IsInCombat() || thePlayer.IsUsingVehicle())
        {
            Record("OFFER_TOO_LATE busy");
            return;
        }
        Record("OFFER_WATCH " + offerSender);
        AcceptOffer();
    }

    private function AcceptOffer()
    {
        if(offerAuto) { JoinAuto(); }
        else { JoinTalk(); }
    }

    // Join a conversation started with Talk: find this world's NPC, stand beside the starter,
    // press Talk on it.
    private function JoinTalk()
    {
        var npc : CNewNPC;
        var spot, safe : Vector;
        var rot : EulerAngles;
        npc = theGame.r_getMultiplayerClient().getCoopNpcs().HoldForScene(offerVoice, offerTpl, offerApp, offerNpcPos);
        if(!npc)
        {
            joinFailures += 1;
            Record("JOIN_FAILED no copy of " + offerVoice);
            return;
        }
        hostName = offerSender;
        hostConv = offerConv;
        hostScene = offerScene;
        joinNpc = npc;
        picks.Clear();
        // stand beside the starter, facing the NPC, as if walking up together
        spot = offerStarterPos + VecFromHeading(VecHeading(offerNpcPos - offerStarterPos) + 90) * 1.2;
        if(!theGame.GetWorld().NavigationFindSafeSpot(spot, 0.5, 3.0, safe)) { safe = spot; }
        rot.Yaw = VecHeading(offerNpcPos - safe);
        thePlayer.TeleportWithRotation(safe, rot);
        joinTalkAt = theGame.GetEngineTimeAsSeconds() + 0.5;
        joinAuto = false;
        role = 2;
        Record("JOINING " + hostName + " " + hostScene);
    }

    // A scene the starter's quest started: come over and let this game's quest start it here.
    private function JoinAuto()
    {
        var spot, safe, starterPos : Vector;
        var rot : EulerAngles;
        starterPos = offerStarterPos;
        hostName = offerSender;
        hostConv = offerConv;
        hostScene = offerScene;
        joinNpc = NULL;
        picks.Clear();
        joinFrom = thePlayer.GetWorldPosition();
        joinFromRot = thePlayer.GetWorldRotation();
        if(VecDistance(joinFrom, starterPos) > 3.0)
        {
            spot = starterPos + VecFromHeading(VecHeading(joinFrom - starterPos)) * 1.5;
            if(!theGame.GetWorld().NavigationFindSafeSpot(spot, 0.5, 3.0, safe)) { safe = spot; }
            rot.Yaw = VecHeading(starterPos - safe);
            thePlayer.TeleportWithRotation(safe, rot);
        }
        joinAuto = true;
        joinTalkAt = 0;
        joinStartedAt = theGame.GetEngineTimeAsSeconds();
        joins += 1;
        role = 2;
        Record("JOINING_AUTO " + hostName + " " + hostScene);
    }

    // Both games started the same scene: the leader chooses; between members, the earlier name.
    private function ChoosesOver(other : string) : bool
    {
        if(theGame.r_getMultiplayerClient().getCoopEnemies().GetRole() == 1) { return true; }
        if(!theGame.r_getMultiplayerClient().getInParty()) { return true; }
        if(theGame.r_getMultiplayerClient().getJoinedParty() == other) { return false; }
        return StrCmp(theGame.r_getMultiplayerClient().getUsername(), other) < 0;
    }

    // A pick from anyone in this conversation: the starter's (here listening) or a listener's (here
    // the starter, or another listener of the same starter).
    private function OnPick(sender : string)
    {
        var pick : r_CoopTalkPick;
        var conv : int;
        conv = StringToInt(WO_Str(2), 0);
        if(!(((role == 2 || role == 3) && conv == hostConv) || (role == 1 && conv == convId && listeners.Contains(sender)))) { return; }
        pick = new r_CoopTalkPick in this;
        pick.listNo = StringToInt(WO_Str(3), 0);
        pick.index = StringToInt(WO_Str(4), -1);
        pick.text = CoopDecode(WO_Str(5));
        pick.at = theGame.GetEngineTimeAsSeconds();
        pick.who = sender;
        // both picked the same list at once: this game already went on with its own
        if(!choicesOpen && pick.listNo == answeredSet && answeredSet > 0)
        {
            Record("CONFLICT late " + sender + "'s " + pick.text);
            return;
        }
        picks.PushBack(pick);
        Record("PICK_IN " + sender + " " + pick.index + " " + pick.text);
        pickAlert = sender + " chose: " + pick.text;
        pickAlertShown = false;
    }

    private function OnVote(sender : string)
    {
        if(role != 1 || StringToInt(WO_Str(2), 0) != convId) { return; }
        votesReceived += 1;
        lastVote = sender + ": " + CoopDecode(WO_Str(5));
        Record("VOTE_IN " + lastVote);
        pickAlert = sender + " > " + CoopDecode(WO_Str(5));
        pickAlertShown = false;
    }

    private function OnJoined(sender : string)
    {
        if(role != 1 || StringToInt(WO_Str(2), 0) != convId) { return; }
        if(!listeners.Contains(sender)) { listeners.PushBack(sender); }
        Record("LISTENER " + sender + " " + CoopDecode(WO_Str(3)));
    }

    private function OnClose(sender : string)
    {
        if(offerOpen && sender == offerSender && StringToInt(WO_Str(2), 0) == offerConv)
        {
            offerOpen = false;
            offersGone += 1;
            Record("OFFER_GONE " + sender);
            theGame.GetGuiManager().HideUserDialog(COOP_WATCH_DIALOG());
        }
        if(sender != hostName || StringToInt(WO_Str(2), 0) != hostConv) { return; }
        Record("HOST_CLOSED");
        if(role == 2)  // never got in
        {
            if(joinAuto) { ReturnFromJoin(); }
            LeaveConversation();
            role = 0;
        }
    }

    // ------------------------------------------------------------ every frame

    public function Tick()
    {
        var module : CR4HudModuleDialog;
        var root : CR4Menu;
        var now : float;
        var i : int;
        now = theGame.GetEngineTimeAsSeconds();

        if(role == 2 && joinNpc && joinTalkAt > 0 && now >= joinTalkAt)
        {
            joinTalkAt = 0;
            joinStartedAt = now;
            joins += 1;
            applying = true;
            joinNpc.OnInteraction("Talk", thePlayer);
            applying = false;
        }
        if(role == 2 && !joinAuto && joinTalkAt == 0 && !inScene && now - joinStartedAt > 4.0)
        {
            joinFailures += 1;
            Record("JOIN_FAILED no scene");
            LeaveConversation();
            role = 0;
        }
        if(role == 2 && joinAuto && !inScene && now - joinStartedAt > COOP_SCENE_WAIT())
        {
            // this game's quest is not at that scene: go back to where this player was
            autoMissed += 1;
            Record("AUTO_MISSED " + hostScene);
            ReturnFromJoin();
            LeaveConversation();
            role = 0;
        }
        if(role != 3 && !(role == 1 && convId != 0)) { return; }

        // menus the conversation opens are for the one who asked
        root = theGame.GetGuiManager().GetRootMenu();
        if(role == 3 && root)
        {
            // the scene waits (OpenGUIPanelForScene) until the panel reports it opened; closing
            // before that would leave the conversation waiting for good
            if(theGame.GetGuiManager().GetLastOpenedCommonMenuName() == 'None') { theGame.GetGuiManager().SetLastOpenedCommonMenuName(root.GetMenuName()); }
            root.CloseMenu();
            menusClosed += 1;
            Record("MENU_CLOSED");
        }

        // who chose, while the choices are on screen
        if(choicesOpen && pickAlert != "" && !pickAlertShown)
        {
            ShowAlert(pickAlert);
            pickAlertShown = true;
            alertsShown += 1;
            Record("ALERT " + pickAlert);
        }
        // a pick made in another game, once the same choice list is up here
        if(choicesOpen && applyAt == 0)
        {
            for(i = 0; i < picks.Size(); i += 1)
            {
                if(picks[i].index >= 0 && picks[i].index < choiceTexts.Size() && choiceTexts[picks[i].index] == picks[i].text)
                {
                    applyIndex = picks[i].index;
                    applyAt = now + 1.5;  // the list settles on screen and "<name> chose" can be read first
                    picks.Erase(i);
                    // the scene takes the highlighted line on accept, whatever index is passed
                    module = (CR4HudModuleDialog)((CR4ScriptedHud)theGame.GetHud()).GetHudModule("DialogModule");
                    if(module) { module.OnDialogOptionSelected(applyIndex); }
                    break;
                }
                if(!picks[i].reported)
                {
                    picks[i].reported = true;
                    Record("PICK_UNMATCHED " + picks[i].index + " " + picks[i].text);
                }
            }
        }
        if(applyAt > 0 && now >= applyAt)
        {
            applyAt = 0;
            module = (CR4HudModuleDialog)((CR4ScriptedHud)theGame.GetHud()).GetHudModule("DialogModule");
            if(module && choicesOpen)
            {
                applying = true;
                module.OnDialogOptionSelected(applyIndex);
                module.OnDialogOptionAccepted(applyIndex);
                applying = false;
                picksApplied += 1;
                Record("APPLIED " + applyIndex);
            }
        }
    }

    private function ReturnFromJoin()
    {
        if(VecDistance(thePlayer.GetWorldPosition(), joinFrom) > 3.0) { thePlayer.TeleportWithRotation(joinFrom, joinFromRot); }
        joinAuto = false;
    }

    private function LeaveConversation()
    {
        theGame.r_getMultiplayerClient().getCoopNpcs().ReleaseScene();
        theGame.r_getMultiplayerClient().clearDialogPickAlert();
        joinNpc = NULL;
        picks.Clear();
        applyAt = 0;
        pickAlert = "";
        pickAlertShown = false;
    }

    // ------------------------------------------------------------ helpers

    private function ShowAlert(text : string)
    {
        theGame.r_getMultiplayerClient().showDialogPickAlert(text, false);
    }

    private function InParty() : bool
    {
        return theGame.r_getMultiplayerClient().getInParty() || theGame.r_getMultiplayerClient().getCoopEnemies().GetRole() == 1;
    }

    // In one party: my leader, a member of mine, or a member of the same leader.
    private function SameParty(user : string) : bool
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
}

// How far from the NPC a party member may be and still be brought into the conversation.
function COOP_TALK_RANGE() : float
{
    return 40.0;
}

// How far from the starter a party member may be and still be brought into a scene the quest started.
function COOP_SCENE_RANGE() : float
{
    return 60.0;
}

// How far around a scene playing here synced NPCs are left to be themselves.
function COOP_SCENE_HOLD_RADIUS() : float
{
    return 25.0;
}

// How long a brought-over member waits for its own quest to start that scene.
function COOP_SCENE_WAIT() : float
{
    return 10.0;
}

// The Watch / Skip prompt's message id (the game's own ids are below 1000 or named).
function COOP_WATCH_DIALOG() : int
{
    return 47311;
}

// 0 ask (default), 1 always join, 2 never join. Set with the console: coopwatch ask / always / never.
function COOP_WATCH_MODE() : int
{
    var value : string;
    value = theGame.GetInGameConfigWrapper().GetVarValue('MPGhosts_Main', 'MPGhosts_JoinScenes');
    if(value == "1") { return 1; }
    if(value == "2") { return 2; }
    return 0;
}

exec function coopwatch(mode : string)
{
    var value : string;
    value = "0";
    if(mode == "always") { value = "1"; }
    else if(mode == "never") { value = "2"; }
    theGame.GetInGameConfigWrapper().SetVarValue('MPGhosts_Main', 'MPGhosts_JoinScenes', value);
    theGame.SaveUserSettings();
    GetWitcherPlayer().DisplayHudMessage("Join conversations: " + mode);
}

function CoopWatchTitle() : string
{
    return "Watch together?";
}

function CoopWatchText(sender : string, npc : CNewNPC, auto : bool) : string
{
    var who : string;
    if(auto) { return sender + " is in a story scene.<br>Watch it with them? Skip to keep playing; the outcome still reaches you."; }
    who = "someone";
    if(npc) { who = npc.GetDisplayName(); }
    return sender + " is talking to " + who + ".<br>Watch the conversation? Skip to keep playing; the outcome still reaches you.";
}

function CoopNpcVec3(v : Vector) : string
{
    return FloatToStringPrec(v.X, 2) + " " + FloatToStringPrec(v.Y, 2) + " " + FloatToStringPrec(v.Z, 2);
}
