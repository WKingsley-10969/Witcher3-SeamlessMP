// Experimental coordinator adapter. Disabled unless WO_SCConfig("enabled") == "1".
// This applies explicitly allowlisted absolute fact/journal state, not quest graphs.
// Exactly-once engine rewards and remote spectator scenes are NOT implemented.
import function WO_SCConfig(key : string) : string;
import function WO_SCWatchFact(target : string) : bool;
import function WO_SCBeginRemoteFact(target : string) : bool;
import function WO_SCEndRemoteFact() : bool;
import function WO_SCResetFacts() : int;
import function WO_SCReadFactChange() : string;
import function WO_SCAckFactChange(generation : int, revision : int) : bool;
import function WO_SCInstance() : string;

function SC_IsToken(value : string, maximum : int) : bool
{
    var i : int;
    var ch : string;
    if(StrLen(value) < 1 || StrLen(value) > maximum || value == "-")
    {
        return false;
    }
    for(i = 0; i < StrLen(value); i += 1)
    {
        ch = StrMid(value, i, 1);
        if(StrFindFirst("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:/%-", ch) < 0)
        {
            return false;
        }
    }
    return true;
}

function SC_IsSession(value : string) : bool
{
    var i : int;
    if(StrLen(value) < 16 || StrLen(value) > 64)
    {
        return false;
    }
    for(i = 0; i < StrLen(value); i += 1)
    {
        if(StrFindFirst("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-", StrMid(value, i, 1)) < 0)
        {
            return false;
        }
    }
    return true;
}

function SC_IsInteger(value : string) : bool
{
    var i, start : int;
    if(StrLen(value) < 1 || StrLen(value) > 11) { return false; }
    if(StrMid(value, 0, 1) == "-") { start = 1; }
    if(start == StrLen(value)) { return false; }
    for(i = start; i < StrLen(value); i += 1)
    {
        if(StrFindFirst("0123456789", StrMid(value, i, 1)) < 0) { return false; }
    }
    // Round-trip also rejects overflow, plus signs and leading zero aliases.
    return "" + StringToInt(value, 0) == value;
}

function SC_SplitSpaces(text : string) : array<string>
{
    var parts : array<string>;
    var token, remaining : string;
    remaining = text;
    while(StrSplitFirst(remaining, " ", token, remaining) && parts.Size() < 16)
    {
        parts.PushBack(token);
    }
    parts.PushBack(remaining);
    return parts;
}

// Ledger fact values are `value` (permanent) or `value@validFor` (captured FactsSet duration).
function SC_ParseFactValue(text : string, out value : int, out validFor : int) : bool
{
    var left, right : string;
    validFor = -1;
    if(!StrSplitFirst(text, "@", left, right))
    {
        if(!SC_IsInteger(text)) { return false; }
        value = StringToInt(text, 0);
        return true;
    }
    if(!SC_IsInteger(left) || !SC_IsInteger(right)) { return false; }
    value = StringToInt(left, 0);
    validFor = StringToInt(right, 0);
    return validFor > 0;
}

// Development probe: records which targets pass through scripted FactsSet while a
// probe window is open, to compare against a whole-DB diff. Never creates the client.
function SC_ProbeFactsSet(id : string)
{
    if(theGame.r_multiplayerClient) { theGame.r_multiplayerClient.getSeamlessCampaign().NoteFactsSet(id); }
}

class r_SeamlessCampaign
{
    private var initialized : bool;
    private var enabled : bool;
    private var ready : bool;
    private var reconnecting : bool;
    private var catchingUp : bool;
    private var recoveryFloor : int;
    private var recoveryCount : int;
    private var recoverySceneBlocked : bool;
    private var halted : bool;
    private var effectsEnabled : bool;
    private var sessionStarted : bool;
    private var sessionId : string;
    private var role : string;
    private var proof : string;
    private var epoch : string;
    private var pendingWire : string;
    private var pendingOp : string;
    private var queuedOp : string;
    private var queuedArgs : string;
    private var requestSeq : int;
    private var attempts : int;
    private var cursor : int;
    private var latest : int;
    private var liveFloor : int;
    private var ackDue : int;
    private var lastSend : float;
    private var retryDelay : float;
    private var nextPoll : float;
    private var nextRenew : float;
    private var floorInitialized : bool;
    private var conversation : string;
    private var desiredConversation : string;
    private var scopeKind : string;
    private var scopeId : string;
    private var owner : string;
    private var wantOpen : bool;
    private var wantListen : bool;
    private var listenRequested : bool;
    private var nextListen : float;
    private var observedConversation : string;
    private var observedOwner : string;
    private var wantClose : bool;
    private var voteId : string;
    private var voteChoices : string;
    private var voteResult : string;
    private var deferredVote : string;
    private var deferredCast : string;
    private var deferredChoice : string;
    private var lastStatus : string;
    private var lastChoice : string;
    private var applyingChoice : bool;
    private var appliedCount : int;
    private var transactionCount : int;
    private var scenePaths : array<string>;
    private var sceneConversations : array<string>;
    private var sceneKinds : array<string>;
    private var sceneScopes : array<string>;
    private var sceneMain : array<bool>;
    private var currentScene : string;
    private var currentSceneConversation : string;
    private var currentMain : bool;
    private var choiceConversations : array<string>;
    private var choiceIds : array<string>;
    private var choiceDescriptions : array<string>;
    private var choiceIndices : array<int>;
    private var localChoices : array<SSceneChoice>;
    private var choicesActive : bool;
    private var needsVote : bool;
    private var conversationLease : string;
    private var promptInstance : string;
    private var promptChoices : string;
    private var promptMain : bool;
    private var acceptedPromptChoice : string;
    private var acceptedPromptEvent : int;
    private var localPromptInstance : string;
    private var lastAppliedPrompt : string;
    private var deferredChoiceInstance : string;
    private var deferredVoteInstance : string;
    private var deferredCastInstance : string;
    private var needsPublish : bool;
    private var refreshDialogue : bool;
    private var nextDialoguePoll : float;
    private var engineChoiceCount : int;
    private var lastVoteStatus : string;
    private var captureNonce : string;
    private var captureTx : string;
    private var captureArgs : string;
    private var captureScope : string;
    private var captureGeneration : int;
    private var captureRevision : int;
    private var captureRemoveTarget : string;
    private var captureInFlight : bool;
    private var captureCommits : int;
    private var captureFromSnapshot : bool;
    private var snapshotWatching : bool;
    private var nextSnapshotRead : float;
    private var probeFactsSet : bool;
    private var captureOrphan : bool;
    private var ackedThrough : int;
    private var loadCount : int;
    private var probeFactsSetIds : array<string>;

    default requestSeq = 1;
    default retryDelay = 0.75;
    default nextRenew = -1;
    default lastStatus = "DISABLED";

    private function Initialize()
    {
        if(initialized)
        {
            return;
        }
        initialized = true;
        enabled = WO_SCConfig("enabled") == "1";
        if(!enabled)
        {
            return;
        }
        role = WO_SCConfig("role");
        sessionId = WO_SCConfig("session");
        effectsEnabled = WO_SCConfig("effects") == "1";
        proof = "-";
        if(role == "host")
        {
            proof = WO_SCConfig("proof");
        }
        if((role != "host" && role != "guest") || !SC_IsSession(sessionId)
            || (role == "host" && !SC_IsToken(proof, 128)))
        {
            Halt("INVALID_LOCAL_CONFIG");
        }
        else
        {
            lastStatus = "CONNECTING";
        }
    }

    public function IsEnabled() : bool
    {
        Initialize();
        return enabled;
    }

    public function BlocksLegacyDialogSync() : bool
    {
        return IsEnabled();
    }

    public function IsApplyingChoice() : bool { return applyingChoice; }
    public function IsReady() : bool { return ready && !halted && !reconnecting && !catchingUp; }
    public function GetRecoveryCount() : int { return recoveryCount; }
    public function GetStatus() : string { return lastStatus; }
    public function GetCursor() : int { return cursor; }
    public function GetLatest() : int { return latest; }
    public function GetEpoch() : string { return epoch; }
    public function GetAppliedCount() : int { return appliedCount; }
    public function GetTransactionCount() : int { return transactionCount; }
    public function GetLastChoice() : string { return lastChoice; }
    public function GetLease() : string { return conversationLease; }
    public function GetPromptInstance() : string { return promptInstance; }
    public function GetPromptChoices() : string { return promptChoices; }
    public function GetAcceptedChoice() : string { return acceptedPromptChoice; }
    public function GetAcceptedChoiceEvent() : int { return acceptedPromptEvent; }
    public function GetEngineChoiceCount() : int { return engineChoiceCount; }
    public function GetLastVoteStatus() : string { return lastVoteStatus; }
    public function GetConversation() : string { return conversation; }
    public function GetOwner() : string { return owner; }
    public function GetObservedConversation() : string { return observedConversation; }
    public function GetCaptureCommits() : int { return captureCommits; }
    public function GetLoadCount() : int { return loadCount; }
    // Watches a fact through the whole-DB snapshot tracker, which also sees native
    // FactsAdd and quest-graph writes. Only allowlisted targets (sc_test_ or vetted
    // real quest facts) are accepted natively. Must be called before the change.
    public function WatchSnapshotFact(target : string) : bool
    {
        if(!IsReady() || !effectsEnabled || !SC_IsFactTargetAllowed(target) || !WO_SCWatchFact(target)) { return false; }
        snapshotWatching = true;
        return true;
    }
    public function BeginFactsSetProbe() { probeFactsSet = true; probeFactsSetIds.Clear(); }
    public function EndFactsSetProbe() : array<string> { probeFactsSet = false; return probeFactsSetIds; }
    public function NoteFactsSet(id : string)
    {
        if(probeFactsSet && probeFactsSetIds.Size() < 512 && !probeFactsSetIds.Contains(id)) { probeFactsSetIds.PushBack(id); }
    }
    public function GetVoteId() : string { return voteId; }
    public function GetVoteResult() : string { return voteResult; }
    public function HasPendingRequest() : bool
    {
        return pendingWire != "" || queuedOp != "" || wantOpen || wantListen || wantClose || ackDue > 0 || captureTx != "";
    }
    public function OwnsConversation() : bool
    {
        return IsReady() && conversation != "" && owner == theGame.r_getMultiplayerClient().getUsername();
    }

    private function Halt(reason : string)
    {
        halted = true;
        ready = false;
        lastStatus = reason;
        // Never log pendingWire: HELLO includes the host proof.
    }

    public function RetryConnection()
    {
        if(!enabled || lastStatus == "INVALID_LOCAL_CONFIG")
        {
            return;
        }
        halted = false;
        attempts = 0;
        lastSend = -999;
        if(pendingWire == "")
        {
            ready = false;
        }
    }

    private function Capabilities() : string
    {
        if(effectsEnabled) { return "fact,journal,fact_remove"; }
        return "-";
    }

    private function BeginRecovery()
    {
        // Keep pendingWire, pendingOp, sequence and capture receipt intact. RESUME
        // authenticates the transport without spending that sequence on HELLO.
        reconnecting = true;
        catchingUp = true;
        recoverySceneBlocked = recoverySceneBlocked || currentSceneConversation != "";
        ClearConversation();
        currentScene = "";
        currentSceneConversation = "";
        localChoices.Clear();
        choicesActive = false;
        needsPublish = false;
        needsVote = false;
        observedConversation = "";
        observedOwner = "";
        lastSend = -999;
        lastStatus = "RECONNECTING";
    }

    public function OnSessionStart()
    {
        WO_SCResetFacts();
        WNB_FactOpsReset();
        Initialize();
        if(!sessionStarted)
        {
            sessionStarted = true;
            return;
        }
        if(!enabled) { return; }
        ReconcileAfterLoad();
    }

    // A load replaces the engine world with the save's, which may be older than the
    // ledger. The ledger stays the authority: every committed transaction is an
    // absolute value, so replaying all of them from event 1 on top of the loaded
    // world is idempotent and leaves the latest committed value. Dialogue choices
    // are never re-executed (liveFloor). The pending request, if any, is kept: its
    // sequence number is already used, so dropping it would conflict.
    private function ReconcileAfterLoad()
    {
        loadCount += 1;
        recoverySceneBlocked = false;
        // Scene and prompt state belonged to the unloaded world.
        currentScene = "";
        currentSceneConversation = "";
        choicesActive = false;
        localChoices.Clear();
        needsPublish = false;
        needsVote = false;
        // Its NPC and scene are gone here: close or stop listening on the server.
        if(conversation != "") { wantClose = true; }
        else { ClearConversation(); }
        // Native capture queues and watches were reset above; callers watch again.
        snapshotWatching = false;
        captureRemoveTarget = "";
        // A commit already in flight was a real action before the load. Finish it, but
        // its native queue entry no longer exists to acknowledge.
        captureOrphan = captureTx != "";
        // New nonce, so this process's earlier captured writes replay like remote ones:
        // the loaded save may not contain them.
        captureNonce = "";
        if(latest > liveFloor) { liveFloor = latest; }
        cursor = 0;
        ackDue = 0;
        nextPoll = 0;
        if(!halted) { lastStatus = "RECONCILING_AFTER_LOAD"; }
    }

    private function SendRequest(op : string, args : string) : bool
    {
        if(!enabled || halted || pendingWire != "" || requestSeq < 1 || requestSeq > 1000000)
        {
            return false;
        }
        pendingOp = op;
        pendingWire = "coop sc 1 " + sessionId + " " + requestSeq + " " + op + " " + args;
        attempts = 1;
        retryDelay = 0.75;
        lastSend = theGame.GetEngineTimeAsSeconds();
        WO_Send(pendingWire);
        return true;
    }

    private function Hello() : bool
    {
        return SendRequest("HELLO", role + " " + proof + " " + Capabilities());
    }

    private function QueueRequest(op : string, args : string) : bool
    {
        if(!IsReady() || queuedOp != "") { return false; }
        queuedOp = op;
        queuedArgs = args;
        return true;
    }

    public function Tick()
    {
        var now : float;
        Initialize();
        if(!enabled || halted)
        {
            return;
        }
        now = theGame.GetEngineTimeAsSeconds();
        if(reconnecting)
        {
            if(now - lastSend >= 2.0 || now < lastSend)
            {
                WO_Send("coop sc 1 " + sessionId + " " + requestSeq + " RESUME " + epoch + " "
                    + role + " " + proof + " " + Capabilities());
                lastSend = now;
            }
            return;
        }
        if(pendingWire != "")
        {
            if(now - lastSend >= retryDelay || now < lastSend)
            {
                if(attempts >= 12)
                {
                    if(epoch != "" && pendingOp != "HELLO") { BeginRecovery(); }
                    else
                    {
                        // Initial HELLO is also safe to retry through a long outage.
                        attempts = 1;
                        retryDelay = 2.0;
                        lastSend = now;
                        lastStatus = "CONNECTING";
                    }
                    return;
                }
                WO_Send(pendingWire);
                lastSend = now;
                attempts += 1;
            }
            return;
        }
        if(!ready)
        {
            Hello();
            return;
        }
        if(ackDue > 0)
        {
            SendRequest("ACK", epoch + " " + ackDue);
            return;
        }
        if(catchingUp)
        {
            if(cursor >= recoveryFloor)
            {
                catchingUp = false;
                recoveryCount += 1;
                lastStatus = "RECOVERED";
            }
            else
            {
                SendRequest("GET_STATE", epoch + " " + cursor + " -");
                return;
            }
        }
        if(wantClose)
        {
            if(wantOpen || wantListen) { return; }
            if(OwnsConversation())
            {
                SendRequest("CLOSE", epoch + " " + conversation);
            }
            else
            {
                if(conversation != "") { SendRequest("UNLISTEN", epoch + " " + conversation); }
                else { wantClose = false; }
            }
            return;
        }
        // A LISTEN sent before the owner's OPEN returns NO_CONVERSATION. Retry once
        // a snapshot shows the requested conversation, so a listener is registered
        // before the owner can freeze vote membership.
        if(listenRequested && conversation == "" && !wantListen && !wantOpen
            && observedConversation == desiredConversation && (now >= nextListen || now < nextListen - 5.0))
        {
            wantListen = true;
        }
        if(wantListen)
        {
            SendRequest("LISTEN", epoch + " " + desiredConversation);
            return;
        }
        if(wantOpen)
        {
            SendRequest("OPEN", epoch + " " + desiredConversation + " " + scopeKind + " " + scopeId);
            return;
        }
        if(OwnsConversation() && (now >= nextRenew || now < nextRenew - 10.0))
        {
            SendRequest("RENEW", epoch + " " + conversation);
            return;
        }
        if(queuedOp != "")
        {
            if(SendRequest(queuedOp, queuedArgs)) { queuedOp = ""; queuedArgs = ""; }
            return;
        }
        if(captureTx == "" && effectsEnabled && OwnsConversation()) { PumpCapture(); }
        if(captureTx == "" && snapshotWatching && OwnsConversation() && (now >= nextSnapshotRead || now < nextSnapshotRead - 5.0))
        {
            // Each read copies the whole facts DB, so it is throttled.
            nextSnapshotRead = now + 0.5;
            PumpSnapshot();
        }
        if(captureTx != "" && OwnsConversation() && conversation == captureScope)
        {
            // First send, or resend after a reconnect cleared the pending request.
            // The server answers a committed id with DUPLICATE, so this is safe.
            if(SendRequest("EFFECT", epoch + " " + captureArgs)) { captureInFlight = true; }
            return;
        }
        if(needsPublish && OwnsConversation()) { ScheduleBoundChoices(); }
        if(queuedOp != "") { return; }
        if(refreshDialogue && conversation != "")
        {
            SendRequest("GET_DIALOGUE", epoch + " " + conversation);
            return;
        }
        if(needsVote && currentMain && OwnsConversation() && promptInstance == localPromptInstance) { ScheduleBoundVote(); }
        if(deferredVote != "")
        {
            SendRequest("VOTE_OPEN", epoch + " " + conversation + " " + conversationLease + " " + deferredVoteInstance);
            return;
        }
        if(deferredCast != "" && voteId != "")
        {
            SendRequest("VOTE_CAST", epoch + " " + voteId + " " + conversationLease + " " + deferredCastInstance + " " + deferredCast);
            return;
        }
        if(deferredChoice != "" && OwnsConversation())
        {
            if(promptMain && voteResult != "" && (currentSceneConversation == "" || BoundChoiceIndex(voteResult) >= 0))
            {
                deferredChoice = voteResult;
            }
            if(promptMain && voteResult != deferredChoice)
            {
                // Wait for the binding vote; never accept the local engine choice early.
            }
            else
            {
                SendRequest("CHOICE", epoch + " " + conversation + " " + conversationLease + " " + deferredChoiceInstance + " " + deferredChoice);
                return;
            }
        }
        if(conversation != "" && (now >= nextDialoguePoll || now < nextDialoguePoll - 1.0))
        {
            SendRequest("GET_DIALOGUE", epoch + " " + conversation);
            nextDialoguePoll = now + 0.25;
            return;
        }
        if(now >= nextPoll || now < nextPoll - 1.0)
        {
            SendRequest("GET_STATE", epoch + " " + cursor + " " + SelectedConversation());
            nextPoll = now + 0.1;
        }
    }

    private function SelectedConversation() : string
    {
        if(desiredConversation != "") { return desiredConversation; }
        if(conversation != "") { return conversation; }
        return "-";
    }

    // Called while the native transport's current COOP message is still selected.
    public function OnMessage()
    {
        var count, replySeq, expectedSeq : int;
        var status, completedOp : string;
        Initialize();
        count = StringToInt(WO_Str(-3), 0);
        if(!enabled || halted || StringToInt(WO_Str(-2), 0) != 2147483647 || WO_Str(-1) != "SCServer"
            || count < 7 || WO_Str(0) != "sc" || WO_Str(1) != "1" || WO_Str(4) != sessionId)
        {
            return;
        }
        replySeq = StringToInt(WO_Str(5), -1);
        if(pendingWire == "" || replySeq != requestSeq)
        {
            return;
        }
        status = WO_Str(6);
        if(pendingOp != "HELLO" && WO_Str(2) != epoch) { Halt("CAMPAIGN_REPLACED"); return; }
        if(status == "RESUMED")
        {
            if(!reconnecting) { return; }
            expectedSeq = StringToInt(WO_Str(9), -1);
            recoveryFloor = StringToInt(WO_Str(8), -1);
            if(count != 10 || WO_Str(7) != epoch || WO_Str(2) != epoch
                || recoveryFloor < cursor || recoveryFloor > 20000
                || (expectedSeq != requestSeq && expectedSeq != requestSeq - 1))
            {
                Halt("INVALID_RESUME_STATE");
                return;
            }
            if(recoveryFloor > liveFloor) { liveFloor = recoveryFloor; }
            reconnecting = false;
            ready = true;
            attempts = 0;
            lastSend = -999;
            lastStatus = "CATCHING_UP";
            // Retransmit the original request. Its committed response remains cached.
            return;
        }
        if(reconnecting)
        {
            if(status == "SESSION_ACTIVE" || status == "USERNAME_ACTIVE") { return; }
            if(status == "STALE_EPOCH" || status == "HOST_AUTH_FAILED" || status == "SESSION_OWNED"
                || status == "CAPABILITY_REQUIRED" || status == "BAD_REQUEST" || status == "UNKNOWN_OP"
                || status == "HELLO_REQUIRED" || status == "STORAGE_ERROR" || status == "REQUEST_CONFLICT"
                || status == "BAD_SEQUENCE" || status == "ALREADY_APPLIED" || status == "SESSION_LIMIT_OR_SEQUENCE")
            { Halt("RESUME_" + status); }
            // A delayed response to the original request is ignored until RESUME
            // supplies the replay floor. Its exact retry will retrieve the same result.
            return;
        }
        if(status == "STORAGE_ERROR")
        {
            // Keep the exact pending request. Caller can retry after storage is repaired.
            Halt(status);
            return;
        }
        if(status == "BAD_SEQUENCE" || status == "ALREADY_APPLIED")
        {
            if(pendingOp != "HELLO") { Halt("REQUEST_SEQUENCE_CONFLICT"); return; }
            expectedSeq = StringToInt(WO_Str(7), 0);
            if(status == "ALREADY_APPLIED") { expectedSeq += 1; }
            if(count < 8 || expectedSeq < 1 || expectedSeq > 1000000)
            {
                Halt("BAD_SEQUENCE_RESPONSE");
                return;
            }
            pendingWire = "";
            pendingOp = "";
            captureInFlight = false;
            requestSeq = expectedSeq;
            ready = false;
            lastStatus = "RECONNECT_RECONCILE_STATE";
            return;
        }
        if(status == "HELLO_REQUIRED")
        {
            if(pendingOp == "HELLO") { Halt("HELLO_REFUSED"); return; }
            BeginRecovery();
            return;
        }
        if(status == "STALE_EPOCH") { Halt("CAMPAIGN_REPLACED"); return; }
        if(status == "SESSION_ACTIVE" || status == "USERNAME_ACTIVE")
        {
            // A restarted process may need to wait for the old endpoint's lease.
            attempts = 1;
            retryDelay = 2.0;
            lastSend = theGame.GetEngineTimeAsSeconds();
            return;
        }
        if(status == "CAPABILITY_REQUIRED") { Halt(status); return; }
        if(status == "BAD_REQUEST" || status == "HOST_AUTH_FAILED" || status == "SESSION_OWNED"
            || status == "SESSION_ACTIVE" || status == "USERNAME_ACTIVE" || status == "REQUEST_CONFLICT"
            || status == "SESSION_LIMIT_OR_SEQUENCE")
        {
            Halt(status);
            return;
        }
        completedOp = pendingOp;
        pendingWire = "";
        pendingOp = "";
        requestSeq += 1;
        lastStatus = status;
        if(captureInFlight)
        {
            captureInFlight = false;
            if(!CompleteCapture(status, count)) { return; }
        }
        if(status == "WELCOME")
        {
            if(count != 9 || WO_Str(7) != WO_Str(2))
            {
                Halt("BAD_WELCOME");
                return;
            }
            if(epoch != "" && epoch != WO_Str(2)) { Halt("CAMPAIGN_REPLACED"); return; }
            epoch = WO_Str(2);
            latest = StringToInt(WO_Str(8), -1);
            if(latest < cursor || latest > 20000)
            {
                Halt("CAMPAIGN_REPLACED_OR_REPLAY_LIMIT");
                return;
            }
            if(!floorInitialized)
            {
                liveFloor = latest;
                floorInitialized = true;
            }
            recoveryFloor = latest;
            catchingUp = cursor < recoveryFloor;
            ready = true;
            nextPoll = 0;
            return;
        }
        // A cached pre-disconnect response may describe a scene/lease which has
        // already ended. Consume its receipt, then drain state without restoring it.
        if(catchingUp && completedOp != "GET_STATE" && completedOp != "ACK")
        {
            nextPoll = 0;
            return;
        }
        if(status == "STATE")
        {
            ReadState(count);
            return;
        }
        if(status == "DIALOGUE")
        {
            ReadDialogue(count);
            return;
        }
        if(completedOp == "GET_DIALOGUE" && status == "NO_CONVERSATION")
        {
            ClearConversation();
            return;
        }
        if(completedOp == "ACK" && status == "OK")
        {
            if(ackDue > ackedThrough) { ackedThrough = ackDue; }
            ackDue = 0;
        }
        if(completedOp == "OPEN")
        {
            wantOpen = false;
            if(status == "OK")
            {
                conversation = desiredConversation;
                owner = theGame.r_getMultiplayerClient().getUsername();
                if(count < 9 || !SC_IsToken(WO_Str(8), 96)) { Halt("MISSING_DIALOGUE_LEASE"); return; }
                conversationLease = WO_Str(8);
                refreshDialogue = true;
                nextRenew = theGame.GetEngineTimeAsSeconds() + 2.0;
            }
            else if(status == "BUSY" && count >= 9)
            {
                // Only listen to the exact requested conversation, not a colliding different scope alias.
                if(WO_Str(7) == desiredConversation) { wantListen = true; listenRequested = true; }
            }
        }
        if(completedOp == "LISTEN")
        {
            wantListen = false;
            if(status == "OK" && count >= 9)
            {
                conversation = desiredConversation;
                owner = WO_Str(8);
                refreshDialogue = true;
            }
            else { nextListen = theGame.GetEngineTimeAsSeconds() + 1.0; }
        }
        if(completedOp == "RENEW")
        {
            nextRenew = theGame.GetEngineTimeAsSeconds() + 2.0;
            if(status != "OK") { owner = ""; }
        }
        if(completedOp == "CLOSE")
        {
            wantClose = false;
            if(status == "OK") { ClearConversation(); }
        }
        if(completedOp == "UNLISTEN")
        {
            wantClose = false;
            if(status == "OK" || status == "NO_CONVERSATION") { ClearConversation(); }
        }
        if(completedOp == "VOTE_OPEN")
        {
            deferredVote = "";
            if(status == "OK" && count >= 9) { voteId = WO_Str(7); voteChoices = WO_Str(8); voteResult = ""; }
            deferredVoteInstance = "";
            refreshDialogue = true;
        }
        if(completedOp == "VOTE_CAST") { lastVoteStatus = status; deferredCast = ""; deferredCastInstance = ""; refreshDialogue = true; }
        if(completedOp == "CHOICE") { deferredChoice = ""; deferredChoiceInstance = ""; refreshDialogue = true; }
        if(completedOp == "CHOICES")
        {
            refreshDialogue = true;
            if(status != "OK") { Halt("PROMPT_PUBLISH_" + status); return; }
        }
        nextPoll = 0;
    }

    // Turns the next captured FactsSet (a remove/add pair recorded synchronously for
    // one target) into one ledger fact effect for the scope this client owns.
    private function PumpCapture()
    {
        var wire, valueText : string;
        var parts : array<string>;
        var validFor : int;
        wire = WNB_FactOpsPeek();
        // Peek reports DISABLED without WO_SC_CAPTURE=1, and ERROR <reason> after an overflow.
        if(wire == "" || wire == "DISABLED") { return; }
        if(StrBeginsWith(wire, "ERROR "))
        {
            Halt("CAPTURE_RECONCILE_REQUIRED");
            return;
        }
        parts = SC_SplitSpaces(wire);
        if(parts.Size() != 9 || !SC_IsInteger(parts[0]) || !SC_IsInteger(parts[1])
            || !SC_IsInteger(parts[5]) || !SC_IsInteger(parts[6]) || !SC_IsFactTargetAllowed(parts[4]))
        {
            Halt("CAPTURE_BAD_RECORD");
            return;
        }
        // An operation captured under another scope waits for that scope's owner.
        if(parts[2] != conversation) { return; }
        if(parts[3] == "remove")
        {
            if(captureRemoveTarget != "" || !WNB_FactOpsAck(StringToInt(parts[0], 0), StringToInt(parts[1], 0)))
            {
                Halt("CAPTURE_UNPAIRED_REMOVE");
                return;
            }
            captureRemoveTarget = parts[4];
            return;
        }
        validFor = StringToInt(parts[6], 0);
        if(parts[3] != "add" || captureRemoveTarget != parts[4] || (validFor < 1 && validFor != -1))
        {
            Halt("CAPTURE_UNPAIRED_ADD");
            return;
        }
        valueText = parts[5];
        if(validFor > 0) { valueText += "@" + parts[6]; }
        // Process-random prefix: generations restart at 1 in every game process.
        if(captureNonce == "") { captureNonce = WO_SCInstance(); }
        captureGeneration = StringToInt(parts[0], 0);
        captureRevision = StringToInt(parts[1], 0);
        captureTx = "fx_" + captureNonce + "_" + parts[0] + "_" + parts[1];
        captureScope = conversation;
        captureArgs = captureTx + " " + conversation + " fact " + parts[4] + " " + valueText;
    }

    // Turns the next snapshot-detected change of a watched fact into a ledger fact
    // effect. The native wire is "generation revision target exists value".
    private function PumpSnapshot()
    {
        var wire, valueText : string;
        var parts : array<string>;
        wire = WO_SCReadFactChange();
        if(wire == "") { return; }
        if(StrBeginsWith(wire, "ERROR "))
        {
            Halt("SNAPSHOT_CAPTURE_" + StrAfterFirst(wire, " "));
            return;
        }
        parts = SC_SplitSpaces(wire);
        if(parts.Size() != 5 || !SC_IsInteger(parts[0]) || !SC_IsInteger(parts[1]) || !SC_IsFactTargetAllowed(parts[2])
            || (parts[3] != "0" && parts[3] != "1") || !SC_IsInteger(parts[4]))
        {
            Halt("SNAPSHOT_BAD_RECORD");
            return;
        }
        valueText = parts[4];
        if(parts[3] == "0")
        {
            if(!SC_IsFactRemovalAllowed(parts[2]))
            {
                Halt("SNAPSHOT_REMOVAL_NOT_VETTED");
                return;
            }
            valueText = "absent";
        }
        if(captureNonce == "") { captureNonce = WO_SCInstance(); }
        captureGeneration = StringToInt(parts[0], 0);
        captureRevision = StringToInt(parts[1], 0);
        captureFromSnapshot = true;
        captureTx = "fs_" + captureNonce + "_" + parts[0] + "_" + parts[1];
        captureScope = conversation;
        captureArgs = captureTx + " " + conversation + " fact " + parts[2] + " " + valueText;
    }

    // The local queue entry is acknowledged only after the ledger committed it.
    private function CompleteCapture(status : string, count : int) : bool
    {
        if(status != "OK" || count < 8 || WO_Str(7) != captureTx)
        {
            Halt("CAPTURE_COMMIT_" + status);
            return false;
        }
        if(!captureOrphan && ((captureFromSnapshot && !WO_SCAckFactChange(captureGeneration, captureRevision))
            || (!captureFromSnapshot && !WNB_FactOpsAck(captureGeneration, captureRevision))))
        {
            Halt("CAPTURE_ACK_FAILED");
            return false;
        }
        captureFromSnapshot = false;
        captureOrphan = false;
        captureTx = "";
        captureArgs = "";
        captureScope = "";
        captureRemoveTarget = "";
        captureCommits += 1;
        return true;
    }

    private function ReadDialogue(count : int)
    {
        if(count != 19 || WO_Str(7) != conversation || !SC_IsToken(WO_Str(8), 96))
        {
            Halt("BAD_DIALOGUE_STATE");
            return;
        }
        conversationLease = WO_Str(8);
        promptInstance = WO_Str(9);
        promptChoices = WO_Str(10);
        promptMain = WO_Str(11) == "true";
        acceptedPromptChoice = WO_Str(12);
        acceptedPromptEvent = StringToInt(WO_Str(13), -1);
        voteId = WO_Str(14);
        voteChoices = WO_Str(15);
        voteResult = WO_Str(16);
        owner = WO_Str(18);
        refreshDialogue = false;
        nextDialoguePoll = theGame.GetEngineTimeAsSeconds() + 0.25;
        if(acceptedPromptEvent < 0) { Halt("BAD_DIALOGUE_RECEIPT"); return; }
        // An owner who already voted can submit the binding result without a
        // second click. Only an ordered DIALOG_CHOICE event executes the scene.
        if(currentMain && OwnsConversation() && choicesActive && promptInstance == localPromptInstance
            && voteResult != "" && acceptedPromptChoice == "" && deferredChoice == "")
        {
            RequestChoice(voteResult);
        }
    }

    private function ReadState(count : int)
    {
        var eventId : int;
        if(count < 16)
        {
            Halt("BAD_STATE");
            return;
        }
        latest = StringToInt(WO_Str(7), -1);
        if(latest < cursor || latest > 20000)
        {
            Halt("BAD_STATE_CURSOR");
            return;
        }
        if(catchingUp)
        {
            // The first replay reply may be a cached GET_STATE from before the
            // outage. It cannot lower the floor supplied by RESUME.
            if(latest > recoveryFloor) { recoveryFloor = latest; }
            if(latest > liveFloor) { liveFloor = latest; }
        }
        observedConversation = WO_Str(9);
        observedOwner = WO_Str(10);
        // A snapshot never grants membership: seeing a conversation is not being
        // a registered listener/voter. Only OPEN/LISTEN replies set it.
        if(conversation != "")
        {
            conversation = observedConversation;
            owner = observedOwner;
            voteId = WO_Str(12);
            voteChoices = WO_Str(13);
            voteResult = WO_Str(14);
        }
        if(WO_Str(15) == "0") { return; }
        eventId = StringToInt(WO_Str(16), -1);
        if(count < 19 || eventId != cursor + 1 || eventId > latest)
        {
            Halt("EVENT_GAP_OR_INVALID_EVENT");
            return;
        }
        if(!ApplyEvent(count, eventId))
        {
            // Cursor does not advance after a rejected/partially applied transaction.
            Halt("ENGINE_APPLY_FAILED_AT_" + eventId);
            return;
        }
        cursor = eventId;
        // The server keeps ACKs monotonic; a replay after a load only acknowledges new events.
        if(eventId > ackedThrough) { ackDue = eventId; }
        nextPoll = 0;
    }

    private function ApplyEvent(count : int, eventId : int) : bool
    {
        var kind : string;
        kind = WO_Str(17);
        if(kind == "TRANSACTION") { return ApplyTransaction(count); }
        if(kind == "CHOICES" || kind == "DIALOG_VOTE_OPEN" || kind == "DIALOG_VOTE_RESULT")
        {
            if(count != 24) { return false; }
            if(WO_Str(19) == conversation) { refreshDialogue = true; }
            return true;
        }
        if(kind == "DIALOG_CHOICE")
        {
            if(count != 23) { return false; }
            if(WO_Str(19) == conversation && WO_Str(20) == conversationLease)
            {
                lastChoice = WO_Str(22);
                refreshDialogue = true;
            }
            if(eventId <= liveFloor || WO_Str(19) != currentSceneConversation
                || WO_Str(20) != conversationLease || WO_Str(21) != localPromptInstance) { return true; }
            if(WO_Str(18) != theGame.r_getMultiplayerClient().getUsername() || !OwnsConversation()) { return true; }
            if(lastAppliedPrompt == WO_Str(21)) { return true; }
            return ApplyChoice(WO_Str(22));
        }
        if(kind == "CHOICE")
        {
            if(count != 21) { return false; }
            // Never replay historical dialogue graph execution after joining/loading a save.
            if(eventId <= liveFloor || WO_Str(19) != currentSceneConversation) { return true; }
            if(WO_Str(18) != theGame.r_getMultiplayerClient().getUsername() || !OwnsConversation())
            {
                // Listening never drives a second quest graph. Real no-effects
                // cinematic playback needs separate verified engine hooks.
                lastChoice = WO_Str(20);
                return true;
            }
            // New adapters never execute unversioned dialogue events.
            return true;
        }
        if(kind == "OPEN") { return count == 22; }
        if(kind == "CLOSE")
        {
            if(count != 21) { return false; }
            // A replayed historical CLOSE must not end a current conversation of the same id.
            if(eventId > liveFloor && WO_Str(19) == conversation) { ClearConversation(); }
            return true;
        }
        if(kind == "VOTE_OPEN") { return count == 22; }
        if(kind == "VOTE_RESULT") { return count == 22; }
        return false;
    }

    private function ApplyTransaction(count : int) : bool
    {
        var members, i, idx, value, validFor : int;
        var kind, target : string;
        if(!effectsEnabled || count < 24 || !SC_IsToken(WO_Str(19), 96)) { return false; }
        members = StringToInt(WO_Str(23), 0);
        if(members < 1 || members > 4 || count != 24 + members * 4) { return false; }
        // Validate every member before any engine mutation. This is not engine rollback.
        for(i = 0; i < members; i += 1)
        {
            idx = 24 + i * 4;
            kind = WO_Str(idx + 1);
            target = WO_Str(idx + 2);
            if(!SC_IsToken(WO_Str(idx), 96) || !SC_IsToken(target, 96)) { return false; }
            if(kind == "fact")
            {
                if(WO_Str(idx + 3) == "absent")
                {
                    if(!SC_IsFactRemovalAllowed(target)) { return false; }
                    value = 0;
                }
                else if(!SC_ParseFactValue(WO_Str(idx + 3), value, validFor)) { return false; }
            }
            else
            {
                if(!SC_IsInteger(WO_Str(idx + 3))) { return false; }
                value = StringToInt(WO_Str(idx + 3), 0);
            }
            if(!SC_CanApplyEffect(kind, target, value)) { return false; }
        }
        // This process captured and already performed these writes in the engine.
        // A later process (new nonce) replays them like any remote transaction.
        if(captureNonce != "" && (StrBeginsWith(WO_Str(19), "fx_" + captureNonce + "_")
            || StrBeginsWith(WO_Str(19), "fs_" + captureNonce + "_")))
        {
            transactionCount += 1;
            return true;
        }
        for(i = 0; i < members; i += 1)
        {
            idx = 24 + i * 4;
            kind = WO_Str(idx + 1);
            target = WO_Str(idx + 2);
            if(kind == "fact")
            {
                if(WO_Str(idx + 3) == "absent")
                {
                    if(!ApplyRemoteFact(target, 0, -1, true)) { return false; }
                }
                else
                {
                    SC_ParseFactValue(WO_Str(idx + 3), value, validFor);
                    if(!ApplyRemoteFact(target, value, validFor, false)) { return false; }
                }
            }
            else if(kind == "journal")
            {
                value = StringToInt(WO_Str(idx + 3), 0);
                if(!SC_ApplyJournalAbsolute(target, value)) { return false; }
            }
            else { return false; }
            appliedCount += 1;
        }
        transactionCount += 1;
        return true;
    }

    private function ApplyRemoteFact(target : string, value : int, validFor : int, removeFact : bool) : bool
    {
        var applied, ended, suppressCapture : bool;
        if(!WO_SCWatchFact(target) || !WO_SCBeginRemoteFact(target)) { return false; }
        // A committed remote write must not be recaptured as a new local operation.
        suppressCapture = WNB_FactOpsActive();
        if(suppressCapture && !WNB_FactOpsBeginRemote())
        {
            WO_SCEndRemoteFact();
            return false;
        }
        if(removeFact) { applied = SC_ApplyFactRemoval(target); }
        else { applied = SC_ApplyFactSet(target, value, validFor); }
        // No Sleep/yield/callback queue between Begin and End. End is mandatory on failure too.
        ended = true;
        if(suppressCapture) { ended = WNB_FactOpsEndRemote(); }
        ended = WO_SCEndRemoteFact() && ended;
        return applied && ended;
    }

    private function ClearConversation()
    {
        conversation = "";
        desiredConversation = "";
        owner = "";
        voteId = "";
        voteChoices = "";
        voteResult = "";
        deferredVote = "";
        deferredCast = "";
        deferredChoice = "";
        queuedOp = "";
        queuedArgs = "";
        wantOpen = false;
        wantListen = false;
        listenRequested = false;
        wantClose = false;
        conversationLease = "";
        promptInstance = "";
        promptChoices = "";
        acceptedPromptChoice = "";
        acceptedPromptEvent = 0;
        deferredChoiceInstance = "";
        deferredCastInstance = "";
        deferredVoteInstance = "";
        refreshDialogue = false;
    }

    public function OpenConversation(id : string, kind : string, target : string) : bool
    {
        if(!IsReady() || conversation != "" || wantOpen || wantListen || listenRequested
            || !SC_IsToken(id, 96) || !SC_IsToken(target, 96) || (kind != "npc" && kind != "quest")) { return false; }
        desiredConversation = id;
        scopeKind = kind;
        scopeId = target;
        wantOpen = true;
        return true;
    }

    public function ListenConversation(id : string) : bool
    {
        if(!IsReady() || !SC_IsToken(id, 96)) { return false; }
        // Idempotent so callers may repeat it every tick without resending LISTEN.
        if(listenRequested && desiredConversation == id) { return true; }
        desiredConversation = id;
        listenRequested = true;
        wantListen = true;
        return true;
    }

    public function CloseConversation() : bool
    {
        if(!OwnsConversation()) { return false; }
        wantClose = true;
        return true;
    }

    public function LeaveConversation() : bool
    {
        if(!IsReady()) { return false; }
        if(conversation == "")
        {
            // Cancel a listen that has not been registered yet.
            if(!listenRequested) { return false; }
            listenRequested = false;
            wantListen = false;
            desiredConversation = "";
            return true;
        }
        wantClose = true;
        return true;
    }

    public function RequestChoice(choice : string) : bool
    {
        if(!OwnsConversation() || !SC_IsToken(choice, 96) || deferredChoice != "" || promptInstance == ""
            || acceptedPromptChoice != "" || conversationLease == "") { return false; }
        deferredChoice = choice;
        deferredChoiceInstance = promptInstance;
        return true;
    }

    public function PublishChoices(instance : string, choices : string, mainStory : bool) : bool
    {
        var mainValue : string;
        if(!OwnsConversation() || conversationLease == "" || !SC_IsToken(instance, 96) || !ValidChoiceCsv(choices)) { return false; }
        mainValue = "false";
        if(mainStory) { mainValue = "true"; }
        return QueueRequest("CHOICES", epoch + " " + conversation + " " + conversationLease + " " + instance + " " + choices
            + " " + mainValue);
    }

    private function ValidChoiceCsv(choices : string) : bool
    {
        var remaining, token : string;
        var seen : array<string>;
        if(StrLen(choices) < 1 || StrLen(choices) > 512) { return false; }
        remaining = choices;
        while(StrSplitFirst(remaining, ",", token, remaining))
        {
            if(!SC_IsToken(token, 96) || seen.Contains(token) || seen.Size() >= 7) { return false; }
            seen.PushBack(token);
        }
        return SC_IsToken(remaining, 96) && !seen.Contains(remaining);
    }

    public function RequestVote(choices : string) : bool
    {
        var remaining, token : string;
        var n : int;
        var seen : array<string>;
        if(!OwnsConversation() || deferredVote != "" || promptInstance == "" || acceptedPromptChoice != ""
            || conversationLease == "" || choices != promptChoices || StrLen(choices) > 512) { return false; }
        remaining = choices;
        while(StrSplitFirst(remaining, ",", token, remaining))
        {
            if(!SC_IsToken(token, 96) || seen.Contains(token)) { return false; }
            seen.PushBack(token);
            n += 1;
            if(n > 7) { return false; }
        }
        if(!SC_IsToken(remaining, 96) || seen.Contains(remaining) || n < 1) { return false; }
        deferredVote = choices;
        deferredVoteInstance = promptInstance;
        return true;
    }

    public function CastVote(choice : string) : bool
    {
        if(!IsReady() || voteId == "" || promptInstance == "" || !SC_IsToken(choice, 96) || deferredCast != "") { return false; }
        deferredCast = choice;
        deferredCastInstance = promptInstance;
        return true;
    }

    public function RequestFactSet(tx : string, target : string, value : int) : bool
    {
        return RequestEffect(tx, "fact", target, value);
    }

    public function RequestFactRemoval(tx : string, target : string) : bool
    {
        if(!OwnsConversation() || !effectsEnabled || !SC_IsToken(tx, 96)
            || !SC_IsFactRemovalAllowed(target)) { return false; }
        return QueueRequest("EFFECT", epoch + " " + tx + " " + conversation + " fact " + target + " absent");
    }

    public function RequestJournalSet(tx : string, target : string, value : int) : bool
    {
        return RequestEffect(tx, "journal", target, value);
    }

    private function RequestEffect(tx : string, kind : string, target : string, value : int) : bool
    {
        if(!OwnsConversation() || !effectsEnabled || !SC_IsToken(tx, 96) || !SC_IsToken(target, 96)
            || !SC_CanApplyEffect(kind, target, value)) { return false; }
        return QueueRequest("EFFECT", epoch + " " + tx + " " + conversation + " " + kind + " " + target + " " + value);
    }

    public function BeginTransaction(tx : string, memberCount : int, baseRevision : int) : bool
    {
        if(!OwnsConversation() || !effectsEnabled || !SC_IsToken(tx, 96) || memberCount < 1 || memberCount > 4
            || baseRevision < 0 || baseRevision > latest) { return false; }
        return QueueRequest("TX_BEGIN", epoch + " " + tx + " " + conversation + " " + baseRevision + " " + memberCount);
    }

    public function AddTransactionMember(tx : string, member : string, kind : string, target : string, value : int, expected : string) : bool
    {
        if(!OwnsConversation() || !effectsEnabled || !SC_IsToken(tx, 96) || !SC_IsToken(member, 96)
            || !SC_IsToken(target, 96) || !SC_CanApplyEffect(kind, target, value)
            || (expected != "-" && !SC_IsInteger(expected))) { return false; }
        return QueueRequest("TX_EFFECT", epoch + " " + tx + " " + member + " " + kind + " " + target + " " + value + " " + expected);
    }

    public function CommitTransaction(tx : string) : bool
    {
        if(!OwnsConversation() || !SC_IsToken(tx, 96)) { return false; }
        return QueueRequest("TX_COMMIT", epoch + " " + tx);
    }

    // Explicit scene allowlist: no filename heuristic makes a scene main story.
    public function BindScene(path : string, id : string, kind : string, target : string, mainStory : bool) : bool
    {
        if(StrLen(path) < 1 || StrLen(path) > 512 || scenePaths.Size() >= 64 || scenePaths.Contains(path)
            || !SC_IsToken(id, 96) || !SC_IsToken(target, 96) || (kind != "npc" && kind != "quest")) { return false; }
        scenePaths.PushBack(path);
        sceneConversations.PushBack(id);
        sceneKinds.PushBack(kind);
        sceneScopes.PushBack(target);
        sceneMain.PushBack(mainStory);
        return true;
    }

    public function BindChoice(id : string, choice : string, index : int, description : string) : bool
    {
        var i : int;
        if(!SC_IsToken(id, 96) || !SC_IsToken(choice, 96) || index < 0 || index > 31
            || StrLen(description) < 1 || StrLen(description) > 1024 || choiceIds.Size() >= 128) { return false; }
        for(i = 0; i < choiceIds.Size(); i += 1)
        {
            if(choiceConversations[i] == id && choiceIds[i] == choice) { return false; }
        }
        choiceConversations.PushBack(id);
        choiceIds.PushBack(choice);
        choiceIndices.PushBack(index);
        choiceDescriptions.PushBack(description);
        return true;
    }

    public function OnSceneStarted(scene : CStoryScene)
    {
        var i : int;
        if(!IsEnabled() || !scene) { return; }
        currentScene = scene.GetPath();
        currentSceneConversation = "";
        currentMain = false;
        i = scenePaths.FindFirst(currentScene);
        if(i < 0) { return; }
        currentSceneConversation = sceneConversations[i];
        currentMain = sceneMain[i];
        if(reconnecting || catchingUp || recoverySceneBlocked)
        {
            recoverySceneBlocked = true;
            return;
        }
        needsPublish = choicesActive;
        // This notification occurs AFTER the engine has begun the scene.
        // It cannot prevent a second quest graph from already running.
        if(conversation == "" && !wantOpen && !wantListen)
        {
            desiredConversation = sceneConversations[i];
            scopeKind = sceneKinds[i];
            scopeId = sceneScopes[i];
            wantOpen = true;
        }
    }

    public function OnSceneEnded()
    {
        if(!IsEnabled()) { return; }
        recoverySceneBlocked = false;
        if(currentSceneConversation != "" && desiredConversation == currentSceneConversation)
        {
            if(pendingOp == "OPEN" || pendingOp == "LISTEN") { wantClose = true; }
            else if(conversation != "") { wantClose = true; }
            else { wantOpen = false; wantListen = false; }
        }
        currentScene = "";
        currentSceneConversation = "";
        choicesActive = false;
        localChoices.Clear();
        currentMain = false;
        needsVote = false;
        needsPublish = false;
        localPromptInstance = "";
    }

    public function OnChoicesSet(choices : array<SSceneChoice>)
    {
        var i : int;
        var unchanged : bool;
        if(!IsEnabled()) { return; }
        if(recoverySceneBlocked) { return; }
        unchanged = choicesActive && choices.Size() == localChoices.Size();
        for(i = 0; i < choices.Size() && unchanged; i += 1)
        {
            unchanged = choices[i].description == localChoices[i].description && choices[i].disabled == localChoices[i].disabled
                && choices[i].dialogAction == localChoices[i].dialogAction;
        }
        // Repainting the same unanswered UI does not create a new server prompt.
        // ApplyChoice clears choicesActive BEFORE engine callbacks, so an
        // identical next prompt after acceptance still receives a fresh id.
        if(unchanged) { return; }
        localChoices = choices;
        choicesActive = choices.Size() > 0;
        localPromptInstance = "";
        if(choicesActive)
        {
            localPromptInstance = WO_SCInstance();
            if(!SC_IsToken(localPromptInstance, 96)) { Halt("PROMPT_ID_GENERATION_FAILED"); return; }
        }
        needsPublish = choicesActive && currentSceneConversation != "";
        needsVote = currentMain;
    }

    private function ScheduleBoundChoices()
    {
        var i, n : int;
        var csv : string;
        if(!choicesActive || currentSceneConversation == "" || localPromptInstance == "") { needsPublish = false; return; }
        for(i = 0; i < choiceIds.Size(); i += 1)
        {
            if(choiceConversations[i] == currentSceneConversation && BoundChoiceIndex(choiceIds[i]) >= 0)
            {
                if(n > 0) { csv += ","; }
                csv += choiceIds[i];
                n += 1;
            }
        }
        if(n < 1 || n > 8 || (currentMain && n < 2))
        {
            lastStatus = "SCENE_CHOICES_NOT_ALLOWLISTED";
            needsPublish = false;
            return;
        }
        if(PublishChoices(localPromptInstance, csv, currentMain)) { needsPublish = false; }
    }

    private function ScheduleBoundVote()
    {
        if(RequestVote(promptChoices))
        {
            needsVote = false;
            voteId = "";
            voteResult = "";
            deferredChoice = "";
        }
    }

    private function BoundChoiceIndex(choice : string) : int
    {
        var i, index : int;
        if(!choicesActive) { return -1; }
        for(i = 0; i < choiceIds.Size(); i += 1)
        {
            index = choiceIndices[i];
            if(choiceConversations[i] == currentSceneConversation && choiceIds[i] == choice
                && index < localChoices.Size() && !localChoices[index].disabled
                && localChoices[index].description == choiceDescriptions[i]) { return index; }
        }
        return -1;
    }

    private function ApplyChoice(choice : string) : bool
    {
        var index : int;
        var hud : CR4ScriptedHud;
        var module : CR4HudModuleDialog;
        index = BoundChoiceIndex(choice);
        if(index < 0 || !theGame.IsDialogOrCutscenePlaying()) { return false; }
        hud = (CR4ScriptedHud)theGame.GetHud();
        if(!hud) { return false; }
        module = (CR4HudModuleDialog)hud.GetHudModule("DialogModule");
        if(!module) { return false; }
        lastAppliedPrompt = localPromptInstance;
        choicesActive = false;
        engineChoiceCount += 1;
        applyingChoice = true;
        module.OnDialogOptionAccepted(index);
        applyingChoice = false;
        lastChoice = choice;
        return true;
    }

    // true means consume/block this local acceptance. Only a matching server
    // CHOICE event may call the engine acceptance path for an allowlisted scene.
    public function InterceptChoice(index : int) : bool
    {
        var i : int;
        var choice : string;
        if(recoverySceneBlocked) { lastStatus = "DISCONNECTED_SCENE_REQUIRES_EXIT"; return true; }
        if(!IsEnabled() || applyingChoice || currentSceneConversation == "") { return false; }
        if(!IsReady()) { lastStatus = "CHOICE_WAITING_FOR_COORDINATOR"; return true; }
        if(localPromptInstance == "" || promptInstance != localPromptInstance || conversationLease == "")
        { lastStatus = "CHOICE_WAITING_FOR_PROMPT"; return true; }
        for(i = 0; i < choiceIds.Size(); i += 1)
        {
            if(choiceConversations[i] == currentSceneConversation && choiceIndices[i] == index
                && BoundChoiceIndex(choiceIds[i]) == index) { choice = choiceIds[i]; break; }
        }
        if(choice == "") { lastStatus = "CHOICE_NOT_ALLOWLISTED"; return true; }
        if(currentMain)
        {
            if(voteId == "") { lastStatus = "MAIN_STORY_REQUIRES_EXPLICIT_VOTE"; return true; }
            CastVote(choice);
            if(OwnsConversation() && deferredChoice == "") { deferredChoice = choice; deferredChoiceInstance = promptInstance; }
        }
        else if(OwnsConversation()) { RequestChoice(choice); }
        else { lastStatus = "LISTENER_CANNOT_CHOOSE"; }
        return true;
    }
}
