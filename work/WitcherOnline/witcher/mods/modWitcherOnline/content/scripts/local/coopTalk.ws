// Shared conversations (party). When a player talks to an NPC, party members nearby join the
// same conversation in their own game: each game starts that NPC's conversation the way the
// Talk button does (the probe showed both get the same scene, lines and choices), so the
// joiner watches it with camera, voice and subtitles, and its own quest graph runs it too.
//
// A shared scene never plays for one player (owner, 2026-10-26): the game that starts it holds
// it at its first frame (cutscenes paused, time stopped, sound paused, "Waiting for <name>")
// until every party member it was offered to is in it too or has declined (Skip, too far, busy,
// its quest is elsewhere), and for COOP_SCENE_HOLD_MAX seconds at most. A joiner brought over
// to the scene is faded out for the move.
//
// Choices are voted on (owner, 2026-10-26): a click is a vote, not an answer. The list stays up
// with each voter's name beside the option they took, and anyone can change their vote. The
// choosing game (the starter, or the leader when both games started the scene) decides once
// everyone in the conversation has voted: the option they agree on or, after COOP_VOTE_TIE_WAIT
// seconds of disagreement, the party leader's vote. It sends the decision, and every game takes
// it when the same choice list is up there (matched by text, so a game a line behind still
// follows). A timed choice cannot wait: the first vote decides it. A line is skipped only once
// both players pressed skip on it. Menus the conversation opens (a shop, a barber) are closed in
// the joiner's game: trading is for the one who asked. Records events for tests and the log.
//
// Scenes a quest starts by itself (no Talk pressed) are shared too: the joiner is brought beside
// the starter and its own quest graph, kept at the same step by the shared quest progress, starts
// the same scene there. If it does not within a few seconds, the joiner goes back where it was.
// When both games start the same scene on their own, the leader chooses and the other listens.
//
// Joining is offered, not forced (COOP_WATCH_MODE): by default a Watch / Skip prompt; Skip keeps
// playing, and the outcome still arrives through the shared quest progress. Always joins without
// asking, Never declines every offer. Console: coopwatch ask / always / never; coophold on / off
// (holding scenes for the party); coopgo (lets a held scene go now).
//
// "cv open id scene voice tpl app x y z px py pz": the starter (NPC at x y z, starter at p); an
// empty voice and template mark a scene the quest started (x y z is then the starter too)
// "cv ballot id set index text": a vote, from anyone in the conversation (id is the starter's conversation)
// "cv decide id set index text": the choosing game's decision
// "cv joined id scene" / "cv decline starter id reason" / "cv left starter id" / "cv close id"
// "cv skip id line": this player pressed skip on that line
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
    private var joinFaded : bool;      // the screen is black for the move to the scene
    private var auto : bool;           // the starter's scene was started by the quest, not by Talk
    private var partyKnown : bool;     // the scene playing here was announced or joined in a party

    // the scene held at its start until the party is in it
    private var holding : bool;
    private var holdSince : float;
    private var holdFrames : int;      // frames held: a second clock, in case engine time stands with the game's
    private var holdAnswers : array<string>;  // party members that joined this scene or declined it

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
    private var picks : array<r_CoopTalkPick>;    // decisions of the choosing game, applied when their list is up
    private var ballots : array<r_CoopTalkPick>;  // everyone's current vote, this game's own too
    private var applying : bool;
    private var applyAt : float;
    private var applyIndex : int;

    private var choiceSet : int;       // choice lists seen in the current conversation
    private var choiceTexts : array<string>;
    private var choiceLocked : array<bool>;
    private var choicesOpen : bool;
    private var choicesAt : float;      // engine time the current choice list appeared
    private var choiceTimed : bool;     // the current list runs on a timer
    private var answeredSet : int;      // the last choice list answered here (its number in the conversation)
    private var decided : bool;         // the choosing game decided the current list
    private var tieSince : float;       // everyone voted, but not alike, since then (0 otherwise)
    private var marksAt : float;        // when to redraw the list with the voters' names (0: not due)
    // the line above the choices (the dialogue box's previous-line field): who is awaited, what was
    // chosen. Shown only while the choices or a held scene are on screen: it lies over the subtitles
    private var statusText : string;

    // line skips: both press skip on a line before it goes
    private var currentLine : string;
    private var skipLine : string;      // this player pressed skip on it
    private var skipValue : int;
    private var peerSkipLine : string;  // the other player pressed skip on it
    private var applyingSkip : bool;

    public var linesSeen : int;
    public var choiceSets : int;
    public var joins : int;
    public var joinFailures : int;
    public var sceneMismatches : int;
    public var picksSent : int;        // decisions sent
    public var picksApplied : int;     // decisions taken from the choosing game
    public var alertsShown : int;      // status lines shown above the choices
    public var votesSent : int;
    public var votesReceived : int;
    public var ties : int;
    public var menusClosed : int;
    public var autoOpens : int;        // quest-started scenes this game announced
    public var autoJoins : int;        // quest-started scenes joined
    public var autoMissed : int;       // brought over, but this game's quest started no scene
    public var handovers : int;        // both games started it: this one became the listener
    public var offersShown : int;      // Watch / Skip prompts shown
    public var offersSkipped : int;    // answered Skip, or declined by the Never setting
    public var offersGone : int;       // the conversation ended before an answer
    public var holds : int;            // scenes held for the party
    public var holdTimeouts : int;
    public var skipsShared : int;      // lines skipped by both
    public var lastVote : string;

    public function InScene() : bool { return inScene; }
    public function GetScenePath() : string { return scenePath; }
    public function IsApplying() : bool { return applying; }
    public function IsHolding() : bool { return holding; }
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
        if(StrFindFirst(text, "LINE ") != 0) { WO_Log("coop talk " + text); }
    }

    // A load or the main menu: no scene of this game goes on, whatever ended it. A listener whose
    // scene was cut off by a load stayed one for good, closing every menu (the owner's Esc).
    public function Reset()
    {
        EndHold("reset");
        FadeBack();
        // a scene of the new world already playing (a save that loads into one) is left alone
        if(theGame.IsDialogOrCutscenePlaying() && role != 3) { return; }
        if(role != 0 || inScene) { Record("RESET role=" + role + " inScene=" + inScene); }
        if(role == 1 && convId != 0) { WO_Send("coop cv close " + convId); }
        LeaveConversation();
        role = 0;
        convId = 0;
        listeners.Clear();
        inScene = false;
        choicesOpen = false;
        offerOpen = false;
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
        ballots.Clear();
        currentLine = "";
        skipLine = "";
        peerSkipLine = "";
        Record("SCENE " + scenePath);
        partyKnown = InParty();
        // the scene's actors are this world's own NPCs: no stand-ins or hidden copies while it plays
        if(InParty()) { theGame.r_getMultiplayerClient().getCoopNpcs().HoldScene(); }
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
            FadeBack();
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
            StartHold();
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
            StartHold();
        }
        talkedTo = NULL;
    }

    public function OnSceneEnded()
    {
        EndHold("scene ended");
        inScene = false;
        choicesOpen = false;
        Record("END " + scenePath);
        if(role == 1)
        {
            WO_Send("coop cv close " + convId);
            convId = 0;
            listeners.Clear();
            picks.Clear();
            ballots.Clear();
            applyAt = 0;
            ClearStatus();
        }
        if(role == 3) { WO_Send("coop cv left " + CoopEncode(hostName) + " " + hostConv); }
        if(role == 3 || role == 2) { LeaveConversation(); }
        else { theGame.r_getMultiplayerClient().getCoopNpcs().ReleaseScene(); }
        role = 0;
    }

    public function OnSentence(text : string)
    {
        linesSeen += 1;
        currentLine = text;
        Record("LINE " + text);
    }

    public function OnChoices(choices : array<SSceneChoice>)
    {
        var text : string;
        var i : int;
        choiceSets += 1;
        choiceTexts.Clear();
        choiceLocked.Clear();
        for(i = 0; i < choices.Size(); i += 1)
        {
            if(i > 0) { text += " | "; }
            text += choices[i].description + " [a" + (int)choices[i].dialogAction;
            if(choices[i].previouslyChoosen) { text += " seen"; }
            if(choices[i].disabled) { text += " off"; }
            text += "]";
            choiceTexts.PushBack(choices[i].description);
            choiceLocked.PushBack(choices[i].disabled);
        }
        Record("CHOICES " + choices.Size() + " " + text);
        choicesOpen = choices.Size() > 0;
        choicesAt = theGame.GetEngineTimeAsSeconds();
        choiceTimed = false;
        decided = false;
        tieSince = 0;
        if(choicesOpen)
        {
            choiceSet += 1;
            // votes the others cast here before this game reached the list: shown once it is drawn
            if(Shared()) { marksAt = choicesAt + 0.1; }
        }
    }

    // The current choice list runs on a timer (the dialogue box shows its bar).
    public function OnChoiceTimer()
    {
        if(!choicesOpen || choiceTimed) { return; }
        choiceTimed = true;
        Record("TIMED");
        TryDecide();
    }

    // Called before a choice is accepted here. True keeps the click from the scene: in a shared
    // conversation a click is this player's vote, and the list stays up.
    public function InterceptChoice(index : int) : bool
    {
        var conv : int;
        var text : string;
        if(applying || !choicesOpen || !Shared() || index < 0 || index >= choiceTexts.Size()) { return false; }
        if(choiceLocked[index]) { return false; }  // the game refuses it itself
        text = choiceTexts[index];
        conv = Conv();
        if(decided || applyAt > 0) { return true; }  // decided already: it goes through in a moment
        SetBallot(Me(), index, text);
        WO_Send("coop cv ballot " + conv + " " + choiceSet + " " + index + " " + CoopEncode(text));
        votesSent += 1;
        Record("VOTE " + index + " " + text);
        marksAt = theGame.GetEngineTimeAsSeconds() + 0.05;  // after the box has hidden the clicked list
        TryDecide();
        return true;
    }

    public function OnAccepted(index : int)
    {
        var text : string;
        var i : int;
        if(index >= 0 && index < choiceLocked.Size() && choiceLocked[index]) { return; }
        Record("ACCEPT " + index);
        choicesOpen = false;
        answeredSet = choiceSet;
        decided = false;
        tieSince = 0;
        marksAt = 0;
        ClearStatus();
        if(index >= 0 && index < choiceTexts.Size()) { text = choiceTexts[index]; }
        // this list is answered here: its decision and its votes are done
        for(i = picks.Size() - 1; i >= 0; i -= 1)
        {
            if(choiceTexts.Contains(picks[i].text)) { picks.Erase(i); }
        }
        for(i = ballots.Size() - 1; i >= 0; i -= 1)
        {
            if(choiceTexts.Contains(ballots[i].text)) { ballots.Erase(i); }
        }
    }

    // Called before a line skip goes to the scene. True holds it back until the other player skips
    // the same line too.
    public function InterceptSkip(value : int) : bool
    {
        if(applyingSkip || choicesOpen || !Shared() || currentLine == "") { return false; }
        if(peerSkipLine == currentLine)
        {
            // the other pressed skip on this line first: both have now
            WO_Send("coop cv skip " + Conv() + " " + CoopEncode(currentLine));
            peerSkipLine = "";
            skipLine = "";
            skipsShared += 1;
            Record("SKIP both");
            return false;
        }
        if(skipLine == currentLine) { return true; }
        skipLine = currentLine;
        skipValue = value;
        WO_Send("coop cv skip " + Conv() + " " + CoopEncode(currentLine));
        Record("SKIP_WAIT");
        theGame.GetGuiManager().ShowNotification("Skips when " + Others() + " skips too", 2.0);
        return true;
    }

    // ------------------------------------------------------------ network

    public function OnMessage()
    {
        var sender, kind : string;
        var count : int;
        sender = WO_Str(-1);
        count = StringToInt(WO_Str(-3), 0);
        if(WO_Str(0) != "cv" || count < 3 || sender == Me()) { return; }
        kind = WO_Str(1);
        Record("MSG " + kind + " from " + sender + " fields=" + count + " party=" + SameParty(sender) + " role=" + role);
        if(!SameParty(sender)) { return; }
        if(kind == "open" && count >= 13) { OnOpen(sender); }
        else if(kind == "ballot" && count >= 6) { OnBallot(sender); }
        else if(kind == "decide" && count >= 6) { OnDecide(sender); }
        else if(kind == "joined") { OnJoined(sender); }
        else if(kind == "decline" && count >= 5) { OnDecline(sender); }
        else if(kind == "left" && count >= 4) { OnLeft(sender); }
        else if(kind == "skip" && count >= 4) { OnSkip(sender); }
        else if(kind == "close") { OnClose(sender); }
    }

    private function OnOpen(sender : string)
    {
        var npc : CNewNPC;
        var conv : int;
        conv = StringToInt(WO_Str(2), 0);
        if(role == 1 && inScene && CoopDecode(WO_Str(3)) == scenePath)
        {
            // both games started the same scene: one chooses, the other listens
            if(!ChoosesOver(sender))
            {
                WO_Send("coop cv close " + convId);
                convId = 0;
                listeners.Clear();
                hostName = sender;
                hostConv = conv;
                hostScene = scenePath;
                picks.Clear();
                role = 3;
                handovers += 1;
                Record("HANDOVER to " + sender);
                WO_Send("coop cv joined " + hostConv + " " + CoopEncode(scenePath));
                EndHold("listening to " + sender);
            }
            else if(!listeners.Contains(sender))
            {
                // this game chooses: announce again, in case the other ignored this game's first
                // announcement (its scene was not linked to a party yet)
                Record("REOPEN for " + sender);
                WO_Send("coop cv open " + convId + " " + CoopEncode(scenePath) + " - - - "
                    + CoopNpcVec3(thePlayer.GetWorldPosition()) + " " + CoopNpcVec3(thePlayer.GetWorldPosition()));
            }
            return;
        }
        // already joining or in this one (an announcement repeated), or asked about it right now
        if(hostName == sender && conv == hostConv && (role == 2 || role == 3)) { return; }
        if(offerOpen && sender == offerSender && conv == offerConv) { return; }
        if(role != 0 || inScene || offerOpen || thePlayer.IsInCombat() || thePlayer.IsUsingVehicle())
        {
            Decline(sender, conv, "busy");
            return;
        }
        offerSender = sender;
        offerConv = conv;
        offerScene = CoopDecode(WO_Str(3));
        offerVoice = CoopDecode(WO_Str(4));
        offerTpl = CoopDecode(WO_Str(5));
        offerApp = CoopDecode(WO_Str(6));
        offerNpcPos = Vector(StringToFloat(WO_Str(7), 0), StringToFloat(WO_Str(8), 0), StringToFloat(WO_Str(9), 0));
        offerStarterPos = Vector(StringToFloat(WO_Str(10), 0), StringToFloat(WO_Str(11), 0), StringToFloat(WO_Str(12), 0));
        offerAuto = offerVoice == "" && offerTpl == "";
        if((offerAuto && VecDistance(thePlayer.GetWorldPosition(), offerStarterPos) > COOP_SCENE_RANGE())
            || (!offerAuto && VecDistance(thePlayer.GetWorldPosition(), offerNpcPos) > COOP_TALK_RANGE()))
        {
            Decline(sender, conv, "far");
            return;
        }

        if(COOP_WATCH_MODE() == 2)
        {
            offersSkipped += 1;
            Record("OFFER_DECLINED setting " + offerSender + " " + offerScene);
            Decline(sender, conv, "skip");
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
            Decline(offerSender, offerConv, "skip");
            return;
        }
        if(role != 0 || inScene || thePlayer.IsInCombat() || thePlayer.IsUsingVehicle())
        {
            Record("OFFER_TOO_LATE busy");
            Decline(offerSender, offerConv, "busy");
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
            Decline(offerSender, offerConv, "failed");
            return;
        }
        hostName = offerSender;
        hostConv = offerConv;
        hostScene = offerScene;
        joinNpc = npc;
        picks.Clear();
        // stand beside the starter, facing the NPC, as if walking up together (out of sight: the
        // owner saw Geralt jump across the screen)
        spot = offerStarterPos + VecFromHeading(VecHeading(offerNpcPos - offerStarterPos) + 90) * 1.2;
        if(!theGame.GetWorld().NavigationFindSafeSpot(spot, 0.5, 3.0, safe)) { safe = spot; }
        rot.Yaw = VecHeading(offerNpcPos - safe);
        FadeForJoin();
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
            FadeForJoin();
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
        return StrCmp(Me(), other) < 0;
    }

    // A vote from anyone in this conversation: the starter's (here listening) or a listener's (here
    // the starter, or another listener of the same starter).
    private function OnBallot(sender : string)
    {
        var conv : int;
        conv = StringToInt(WO_Str(2), 0);
        if(!(((role == 2 || role == 3) && conv == hostConv) || (role == 1 && conv == convId && listeners.Contains(sender)))) { return; }
        SetBallot(sender, StringToInt(WO_Str(4), -1), CoopDecode(WO_Str(5)));
        votesReceived += 1;
        lastVote = sender + ": " + CoopDecode(WO_Str(5));
        Record("VOTE_IN " + lastVote);
        if(choicesOpen) { marksAt = theGame.GetEngineTimeAsSeconds(); }
        TryDecide();
    }

    // The choosing game decided a list: taken here once the same list is up (Tick).
    private function OnDecide(sender : string)
    {
        var pick : r_CoopTalkPick;
        if(!((role == 2 || role == 3) && sender == hostName && StringToInt(WO_Str(2), 0) == hostConv)) { return; }
        pick = new r_CoopTalkPick in this;
        pick.listNo = StringToInt(WO_Str(3), 0);
        pick.index = StringToInt(WO_Str(4), -1);
        pick.text = CoopDecode(WO_Str(5));
        pick.at = theGame.GetEngineTimeAsSeconds();
        pick.who = sender;
        picks.PushBack(pick);
        Record("DECIDE_IN " + pick.index + " " + pick.text);
    }

    private function OnJoined(sender : string)
    {
        if(role != 1 || StringToInt(WO_Str(2), 0) != convId) { return; }
        if(!listeners.Contains(sender)) { listeners.PushBack(sender); }
        if(!holdAnswers.Contains(sender)) { holdAnswers.PushBack(sender); }
        Record("LISTENER " + sender + " " + CoopDecode(WO_Str(3)));
    }

    // A party member offered this game's scene will not be in it: the hold stops waiting for them.
    private function OnDecline(sender : string)
    {
        if(role != 1 || CoopDecode(WO_Str(2)) != Me() || StringToInt(WO_Str(3), 0) != convId) { return; }
        if(!holdAnswers.Contains(sender)) { holdAnswers.PushBack(sender); }
        Record("DECLINED " + sender + " " + WO_Str(4));
    }

    // A listener's scene ended (or it left): its vote is no longer awaited.
    private function OnLeft(sender : string)
    {
        var i : int;
        if(role != 1 || CoopDecode(WO_Str(2)) != Me() || StringToInt(WO_Str(3), 0) != convId) { return; }
        listeners.Remove(sender);
        for(i = ballots.Size() - 1; i >= 0; i -= 1) { if(ballots[i].who == sender) { ballots.Erase(i); } }
        Record("LEFT " + sender);
        TryDecide();
    }

    private function OnSkip(sender : string)
    {
        var line : string;
        var module : CR4HudModuleDialog;
        var conv : int;
        conv = StringToInt(WO_Str(2), 0);
        if(!(((role == 2 || role == 3) && conv == hostConv) || (role == 1 && conv == convId && listeners.Contains(sender)))) { return; }
        line = CoopDecode(WO_Str(3));
        if(skipLine != "" && line == skipLine && line == currentLine)
        {
            // this player pressed skip on it first: both have now
            skipLine = "";
            peerSkipLine = "";
            module = DialogModule();
            if(module)
            {
                applyingSkip = true;
                module.OnDialogSkipped(skipValue);
                applyingSkip = false;
                skipsShared += 1;
                Record("SKIP both (" + sender + " second)");
            }
            return;
        }
        peerSkipLine = line;
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
            FadeBack();
        }
    }

    // ------------------------------------------------------------ the hold at a scene's start

    private function StartHold()
    {
        if(holding || !COOP_SCENE_HOLD_ON()) { return; }
        holdAnswers.Clear();
        if(PendingNames() == "") { return; }  // nobody else in the party
        holding = true;
        holdSince = theGame.GetEngineTimeAsSeconds();
        holdFrames = 0;
        holds += 1;
        theGame.PauseCutscenes();
        theGame.SetTimeScale(0.001, 'w3coop_scene_wait', 100, false, true);
        theSound.SoundEvent("system_pause");
        Record("HOLD " + scenePath + " for " + PendingNames());
    }

    private function EndHold(reason : string)
    {
        if(!holding) { return; }
        holding = false;
        theGame.RemoveTimeScale('w3coop_scene_wait');
        theGame.UnpauseCutscenes();
        theSound.SoundEvent("system_resume");
        ClearStatus();
        Record("HOLD_END " + reason + " after " + FloatToStringPrec(theGame.GetEngineTimeAsSeconds() - holdSince, 1) + " s");
    }

    private function TickHold(now : float)
    {
        var pending : string;
        if(!holding) { return; }
        holdFrames += 1;
        pending = PendingNames();
        if(pending == "") { EndHold("all in"); return; }
        if(now - holdSince > COOP_SCENE_HOLD_MAX() || (float)holdFrames > COOP_SCENE_HOLD_MAX() * 120.0)
        {
            holdTimeouts += 1;
            EndHold("timeout, no answer from " + pending);
            return;
        }
        ShowStatus("Waiting for " + pending + " to join the scene");
    }

    // Lets a held scene go now (console: coopgo).
    public function GoNow()
    {
        EndHold("coopgo");
    }

    // Party members (in the party and online) not yet in this scene and not having declined it.
    private function PendingNames() : string
    {
        var globals : array<r_RemotePlayer>;
        var names : string;
        var i : int;
        globals = theGame.r_getMultiplayerClient().getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1)
        {
            if(!globals[i] || globals[i].username == Me() || !SameParty(globals[i].username)) { continue; }
            if(holdAnswers.Contains(globals[i].username) || listeners.Contains(globals[i].username)) { continue; }
            if(names != "") { names += ", "; }
            names += globals[i].username;
        }
        return names;
    }

    private function Decline(starter : string, conv : int, reason : string)
    {
        WO_Send("coop cv decline " + CoopEncode(starter) + " " + conv + " " + reason);
        Record("DECLINE " + starter + " " + reason);
    }

    private function FadeForJoin()
    {
        if(joinFaded) { return; }
        theGame.FadeOutAsync(0.0);
        joinFaded = true;
    }

    private function FadeBack()
    {
        if(!joinFaded) { return; }
        theGame.FadeInAsync(0.4);
        joinFaded = false;
    }

    // ------------------------------------------------------------ votes

    // A conversation shared with someone who is still in the party.
    private function Shared() : bool
    {
        var i : int;
        if(role == 3) { return SameParty(hostName); }
        if(role != 1 || convId == 0) { return false; }
        for(i = 0; i < listeners.Size(); i += 1) { if(SameParty(listeners[i])) { return true; } }
        return false;
    }

    private function Conv() : int
    {
        if(role == 1) { return convId; }
        return hostConv;
    }

    // Everyone whose vote counts: this player, the starter or its listeners, and anyone who voted.
    private function Voters() : array<string>
    {
        var voters : array<string>;
        var i : int;
        voters.PushBack(Me());
        if(role == 3 && !voters.Contains(hostName)) { voters.PushBack(hostName); }
        if(role == 1)
        {
            for(i = 0; i < listeners.Size(); i += 1) { if(SameParty(listeners[i]) && !voters.Contains(listeners[i])) { voters.PushBack(listeners[i]); } }
        }
        for(i = 0; i < ballots.Size(); i += 1) { if(!voters.Contains(ballots[i].who)) { voters.PushBack(ballots[i].who); } }
        return voters;
    }

    // Someone's vote on the list on screen here, "" if none.
    private function VoteOf(who : string) : string
    {
        var i : int;
        for(i = 0; i < ballots.Size(); i += 1)
        {
            if(ballots[i].who == who && choiceTexts.Contains(ballots[i].text)) { return ballots[i].text; }
        }
        return "";
    }

    private function SetBallot(who : string, index : int, text : string)
    {
        var b : r_CoopTalkPick;
        var i : int;
        for(i = ballots.Size() - 1; i >= 0; i -= 1) { if(ballots[i].who == who) { ballots.Erase(i); } }
        b = new r_CoopTalkPick in this;
        b.who = who;
        b.index = index;
        b.text = text;
        b.at = theGame.GetEngineTimeAsSeconds();
        ballots.PushBack(b);
    }

    private function LeaderName() : string
    {
        if(theGame.r_getMultiplayerClient().getCoopEnemies().GetRole() == 1) { return Me(); }
        return theGame.r_getMultiplayerClient().getJoinedParty();
    }

    // The choosing game: decide the list on screen once everyone voted.
    private function TryDecide()
    {
        var voters : array<string>;
        var text, first, leaderVote : string;
        var firstAt : float;
        var i : int;
        var agreed, everyone : bool;
        if(role != 1 || !choicesOpen || decided || applyAt > 0 || !Shared()) { return; }
        voters = Voters();
        if(choiceTimed)
        {
            // the timer will not wait for everyone: the first vote decides
            firstAt = -1;
            for(i = 0; i < ballots.Size(); i += 1)
            {
                if(choiceTexts.Contains(ballots[i].text) && (firstAt < 0 || ballots[i].at < firstAt)) { first = ballots[i].text; firstAt = ballots[i].at; }
            }
            if(first != "") { Decide(first, "timed, first vote"); }
            return;
        }
        everyone = true;
        agreed = true;
        first = VoteOf(voters[0]);
        for(i = 0; i < voters.Size(); i += 1)
        {
            text = VoteOf(voters[i]);
            if(text == "") { everyone = false; }
            else if(text != first) { agreed = false; }
        }
        if(!everyone) { tieSince = 0; return; }
        if(agreed) { Decide(first, "agreed"); return; }
        if(tieSince == 0)
        {
            tieSince = theGame.GetEngineTimeAsSeconds();
            ties += 1;
            Record("TIE");
        }
        if(theGame.GetEngineTimeAsSeconds() - tieSince >= COOP_VOTE_TIE_WAIT())
        {
            leaderVote = VoteOf(LeaderName());
            if(leaderVote == "") { leaderVote = VoteOf(Me()); }
            Decide(leaderVote, "votes differ: " + LeaderName() + "'s");
        }
    }

    private function Decide(text : string, why : string)
    {
        var index : int;
        index = choiceTexts.FindFirst(text);
        if(index < 0) { return; }
        decided = true;
        WO_Send("coop cv decide " + convId + " " + choiceSet + " " + index + " " + CoopEncode(text));
        picksSent += 1;
        Record("DECIDE " + index + " " + text + " (" + why + ")");
        applyIndex = index;
        applyAt = theGame.GetEngineTimeAsSeconds() + 0.3;  // "Chosen" can be read, and the others get the word
        ShowStatus("Chosen: " + text);
    }

    // The line above the choices while they are up: who is awaited, or the disagreement.
    private function TickVoteStatus(now : float)
    {
        var voters : array<string>;
        var waiting, text, first : string;
        var differ : bool;
        var left, i : int;
        if(!choicesOpen || !Shared() || decided || applyAt > 0) { return; }
        voters = Voters();
        first = "";
        for(i = 0; i < voters.Size(); i += 1)
        {
            text = VoteOf(voters[i]);
            if(text == "")
            {
                if(waiting != "") { waiting += ", "; }
                if(voters[i] == Me()) { waiting += "you"; }
                else { waiting += voters[i]; }
            }
            else if(first == "") { first = text; }
            else if(text != first) { differ = true; }
        }
        if(waiting != "")
        {
            ShowStatus("Waiting for " + waiting + " to choose");
            tieSince = 0;
            return;
        }
        if(!differ)
        {
            ShowStatus("All chose: " + first);
            return;
        }
        if(role != 1 && tieSince == 0) { tieSince = now; }  // the choosing game keeps its own (TryDecide)
        left = CeilF(MaxF(0.0, COOP_VOTE_TIE_WAIT() - (now - tieSince)));
        ShowStatus("Votes differ: change yours, or " + LeaderName() + "'s choice goes in " + left + " s");
    }

    // The list redrawn with the voters' names beside the options they took.
    private function ShowVoteMarks()
    {
        var module : CR4HudModuleDialog;
        var marks : array<string>;
        var names : string;
        var i, j : int;
        module = DialogModule();
        if(!module || !choicesOpen) { return; }
        for(i = 0; i < choiceTexts.Size(); i += 1)
        {
            names = "";
            for(j = 0; j < ballots.Size(); j += 1)
            {
                if(ballots[j].text != choiceTexts[i]) { continue; }
                if(names != "") { names += ", "; }
                names += ballots[j].who;
            }
            if(names != "") { names = "  <FONT COLOR='#8FD18F'>[" + names + "]</FONT>"; }
            marks.PushBack(names);
        }
        module.WO_ShowVoteMarks(marks);
    }

    // ------------------------------------------------------------ every frame

    public function Tick()
    {
        var module : CR4HudModuleDialog;
        var root : CR4Menu;
        var now : float;
        var i : int;
        now = theGame.GetEngineTimeAsSeconds();

        // a scene that was already playing when the party formed (both games loaded a save that starts in
        // one, as the owner's prologue checkpoint does): announced now, so the two scenes are linked (the
        // leader's game chooses where both run it)
        if(role == 0 && inScene && !partyKnown && scenePath != "" && InParty())
        {
            partyKnown = true;
            convId += 1;
            role = 1;
            auto = true;
            autoOpens += 1;
            listeners.Clear();
            Record("LATE_OPEN " + scenePath);
            WO_Send("coop cv open " + convId + " " + CoopEncode(scenePath) + " - - - "
                + CoopNpcVec3(thePlayer.GetWorldPosition()) + " " + CoopNpcVec3(thePlayer.GetWorldPosition()));
            StartHold();
        }
        TickHold(now);
        if(joinFaded && role != 2) { FadeBack(); }  // never left black

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
            Decline(hostName, hostConv, "failed");
            LeaveConversation();
            role = 0;
            FadeBack();
        }
        if(role == 2 && joinAuto && !inScene && now - joinStartedAt > COOP_SCENE_WAIT())
        {
            // this game's quest is not at that scene: go back to where this player was
            autoMissed += 1;
            Record("AUTO_MISSED " + hostScene);
            Decline(hostName, hostConv, "missed");
            ReturnFromJoin();
            LeaveConversation();
            role = 0;
            FadeBack();
        }
        if(role != 3 && !(role == 1 && convId != 0)) { return; }

        // menus the conversation opens are for the one who asked: closed while its scene plays here,
        // never the pause menu (Esc built it and this closed it the next frame, from the owner's playtest)
        root = theGame.GetGuiManager().GetRootMenu();
        if(role == 3 && root && inScene && root.GetMenuName() != 'CommonIngameMenu')
        {
            // the scene waits (OpenGUIPanelForScene) until the panel reports it opened; closing
            // before that would leave the conversation waiting for good
            if(theGame.GetGuiManager().GetLastOpenedCommonMenuName() == 'None') { theGame.GetGuiManager().SetLastOpenedCommonMenuName(root.GetMenuName()); }
            root.CloseMenu();
            menusClosed += 1;
            Record("MENU_CLOSED");
        }

        if(marksAt > 0 && now >= marksAt)
        {
            marksAt = 0;
            ShowVoteMarks();
        }
        TryDecide();  // a disagreement runs out
        TickVoteStatus(now);

        // the choosing game's decision, once the same choice list is up here
        if(choicesOpen && applyAt == 0)
        {
            for(i = 0; i < picks.Size(); i += 1)
            {
                if(picks[i].index >= 0 && picks[i].index < choiceTexts.Size() && choiceTexts[picks[i].index] == picks[i].text)
                {
                    applyIndex = picks[i].index;
                    applyAt = now + 0.3;  // "Chosen" can be read first
                    ShowStatus("Chosen: " + picks[i].text);
                    picks.Erase(i);
                    // the scene takes the highlighted line on accept, whatever index is passed
                    module = DialogModule();
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
            module = DialogModule();
            if(module && choicesOpen)
            {
                applying = true;
                module.OnDialogOptionSelected(applyIndex);
                module.OnDialogOptionAccepted(applyIndex);
                applying = false;
                if(role != 1) { picksApplied += 1; }
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
        ClearStatus();
        joinNpc = NULL;
        picks.Clear();
        ballots.Clear();
        applyAt = 0;
        marksAt = 0;
        decided = false;
    }

    // ------------------------------------------------------------ helpers

    private function ShowStatus(text : string)
    {
        if(text == statusText) { return; }
        statusText = text;
        theGame.r_getMultiplayerClient().showDialogPickAlert(text, false);
        alertsShown += 1;
        if(StrFindFirst(text, "Votes differ") != 0) { Record("STATUS " + text); }
    }

    private function ClearStatus()
    {
        if(statusText == "") { return; }
        statusText = "";
        theGame.r_getMultiplayerClient().clearDialogPickAlert();
    }

    private function DialogModule() : CR4HudModuleDialog
    {
        var hud : CR4ScriptedHud;
        hud = (CR4ScriptedHud)theGame.GetHud();
        if(!hud) { return NULL; }
        return (CR4HudModuleDialog)hud.GetHudModule("DialogModule");
    }

    private function Me() : string
    {
        return theGame.r_getMultiplayerClient().getUsername();
    }

    // The other people in this conversation, for messages.
    private function Others() : string
    {
        var voters : array<string>;
        var names : string;
        var i : int;
        voters = Voters();
        for(i = 0; i < voters.Size(); i += 1)
        {
            if(voters[i] == Me()) { continue; }
            if(names != "") { names += ", "; }
            names += voters[i];
        }
        if(names == "") { names = "the others"; }
        return names;
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

// How long a brought-over member waits for its own quest to start that scene.
function COOP_SCENE_WAIT() : float
{
    return 10.0;
}

// The longest a scene is held at its start for party members who neither join nor decline.
function COOP_SCENE_HOLD_MAX() : float
{
    return 60.0;
}

// How long votes may differ before the party leader's vote decides.
function COOP_VOTE_TIE_WAIT() : float
{
    return 15.0;
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

// Shared scenes are held at their start for the party (default on). Console: coophold on / off.
function COOP_SCENE_HOLD_ON() : bool
{
    return theGame.GetInGameConfigWrapper().GetVarValue('MPGhosts_Main', 'MPGhosts_HoldScenes') != "2";
}

exec function coophold(mode : string)
{
    var value : string;
    value = "1";
    if(mode == "off") { value = "2"; }
    theGame.GetInGameConfigWrapper().SetVarValue('MPGhosts_Main', 'MPGhosts_HoldScenes', value);
    theGame.SaveUserSettings();
    GetWitcherPlayer().DisplayHudMessage("Hold scenes for the party: " + mode);
}

// Lets a scene held for the party go now.
exec function coopgo()
{
    theGame.r_getMultiplayerClient().getCoopTalk().GoNow();
}

function CoopWatchTitle() : string
{
    return "Watch together?";
}

function CoopWatchText(sender : string, npc : CNewNPC, auto : bool) : string
{
    var who : string;
    if(auto) { return sender + " is in a story scene and waits for you.<br>Watch it with them? Skip to keep playing; the outcome still reaches you."; }
    who = "someone";
    if(npc) { who = npc.GetDisplayName(); }
    return sender + " is talking to " + who + " and waits for you.<br>Watch the conversation? Skip to keep playing; the outcome still reaches you.";
}

function CoopNpcVec3(v : Vector) : string
{
    return FloatToStringPrec(v.X, 2) + " " + FloatToStringPrec(v.Y, 2) + " " + FloatToStringPrec(v.Z, 2);
}
