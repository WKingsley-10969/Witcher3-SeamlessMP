// Party death and revive. While a party member is alive in the same region, a blow that would
// kill this player knocks them down instead (state CoopDowned): they lie on the ground, take no
// damage, and their figure on the other screens lies down too (it is reported as not alive). A
// party member who stands beside them and holds Interact for COOP_REVIVE_HOLD seconds gets them
// up with COOP_REVIVE_HEALTH of their health. If nobody does within COOP_DOWN_TIME, they get up
// beside a party member instead. Alone, with every party member down or away, in water, on a
// horse or boat, in a scene, or when the game kills the player outright (a quest, a fall into
// the abyss), death is unchanged. Nothing is written into saves: the blow is capped where the
// game lowers health, not with the game's saved immortality flags.
//
// "coop dn state downSeq x y z target targetSeq kneel": state up|down; downSeq counts this
// player's knock-downs; target/targetSeq: the party member this player last revived and that
// member's downSeq at the time ("-" 0: nobody); kneel 1 while kneeling to revive someone.
class r_CoopRevive
{
    private var events : array<string>;
    private var downed : bool;          // knocked down: from the blow until the downed state is left
    private var pushPending : bool;     // enter the downed state on the next tick (not inside the hit)
    private var getUp : bool;           // the downed state should end now
    private var downSeq : int;
    private var downAt : float;
    private var aloneSince : float;     // downed with no party member able to help (0: someone can)
    private var respawnAt : float;      // screen fading out: get up beside respawnPos then
    private var respawnPos : Vector;
    private var respawnBeside : string;
    private var saveLock : int;
    private var killing : bool;         // the game kills the player outright: no knock-down

    private var reviveTarget : string;  // sent with this player's state: who this player revived
    private var reviveTargetSeq : int;

    // party members' state, from their "dn" messages
    private var peerNames : array<string>;
    private var peerDown : array<bool>;
    private var peerSeq : array<int>;
    private var peerKneel : array<bool>;

    // reviving a party member: holding Interact beside them
    private var holdTarget : string;
    private var holdTime : float;
    private var hinted : string;
    private var kneeling : bool;
    private var lastTick : float;
    public var testHold : bool;         // bot tests: Interact held

    public var downs : int;
    public var revivesGiven : int;
    public var revivesReceived : int;
    public var respawns : int;
    public var realDeaths : int;
    public var peerDowns : int;
    public var peerKneelEnds : int;

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
    }

    public function IsDowned() : bool { return downed; }
    public function ShouldGetUp() : bool { return getUp; }

    // ------------------------------------------------------------ local game

    // Called where the game lowers this player's health: returns the amount to take. A lethal
    // amount is capped at 1 health point left and the player is knocked down instead.
    public function CapDamage(amount : float) : float
    {
        var health : float;
        var why : string;
        if(downed) { return 0; }
        if(killing) { return amount; }
        health = thePlayer.GetStat(BCS_Vitality);
        if(amount < health) { return amount; }
        why = WhyNotDown();
        Record("LETHAL " + FloatToStringPrec(amount, 0) + " health=" + FloatToStringPrec(health, 0) + " " + why);
        if(why != "") { return amount; }
        GoDown();
        return MaxF(0, health - 1);
    }

    public function OnKill(start : bool) { killing = start; }

    // Why a lethal blow would kill this player now ("": it knocks them down).
    public function WhyNotDown() : string
    {
        if(!InParty()) { return "not in a party"; }
        if(!thePlayer.IsAlive()) { return "already dead"; }
        if(thePlayer.IsUsingVehicle() || thePlayer.IsSwimming() || thePlayer.IsFistFightMinigameEnabled()) { return "riding, swimming or fist-fighting"; }
        if(thePlayer.WillBeUnconscious() || thePlayer.IsImmortal() || thePlayer.IsInvulnerable()) { return "the game protects this player itself"; }   // the game's own rules for this fight
        if(theGame.r_getMultiplayerClient().getCoopTalk().InScene()) { return "in a scene"; }
        if(Helper() == "") { return "no party member can help:" + HelperReport(); }
        return "";
    }

    // Each known player as Helper() sees them.
    private function HelperReport() : string
    {
        var globals : array<r_RemotePlayer>;
        var p : r_RemotePlayer;
        var text : string;
        var i : int;
        globals = theGame.r_getMultiplayerClient().getGlobalPlayers();
        text = " players=" + globals.Size() + " area=" + WO_CurrentAreaCode();
        for(i = 0; i < globals.Size(); i += 1)
        {
            p = globals[i];
            if(!p) { continue; }
            text += " [" + p.username + " alive=" + PeerAlive(p.username) + " area=" + p.area + " party=" + SameParty(p.username) + " down=" + PeerIsDown(p.username)
                + " inParty=" + p.inParty + " joined=" + p.joinedParty + "]";
        }
        return text;
    }

    private function GoDown()
    {
        downed = true;
        pushPending = true;
        getUp = false;
        downSeq += 1;
        downs += 1;
        downAt = theGame.GetEngineTimeAsSeconds();
        aloneSince = 0;
        respawnAt = 0;
        theGame.CreateNoSaveLock('coop_downed', saveLock, false, false);
        Record("DOWN seq=" + downSeq + " helper=" + Helper());
        SendState();
        theGame.GetGuiManager().ShowNotification("You are down. " + Helper() + " can revive you: otherwise you get up beside them in " + RoundF(COOP_DOWN_TIME()) + " s.");
    }

    // The downed state ended (the player stands again).
    public function OnDownedStateLeft()
    {
        if(!downed) { return; }
        downed = false;
        getUp = false;
        pushPending = false;
        theGame.ReleaseNoSaveLock(saveLock);
        Record("UP seq=" + downSeq);
        SendState();
    }

    // End the knock-down: health back to COOP_REVIVE_HEALTH, the downed state plays the get-up.
    private function GetUp(why : string)
    {
        if(!downed || getUp) { return; }
        getUp = true;
        thePlayer.SetHealthPerc(COOP_REVIVE_HEALTH());
        Record("GET_UP " + why);
        if(thePlayer.GetCurrentStateName() != 'CoopDowned') { OnDownedStateLeft(); }   // never got into it
    }

    // Nobody can help any more: die the way the game would have.
    private function DieForReal(why : string)
    {
        realDeaths += 1;
        Record("REAL_DEATH " + why);
        downed = false;
        getUp = false;
        pushPending = false;
        theGame.ReleaseNoSaveLock(saveLock);
        SendState();
        killing = true;
        thePlayer.Kill('CoopDowned', true);
        killing = false;
    }

    // ------------------------------------------------------------ network

    private function SendState()
    {
        var st, kneelFlag : string;
        st = "up";
        if(downed) { st = "down"; }
        kneelFlag = "0";
        if(kneeling) { kneelFlag = "1"; }
        WO_Send("coop dn " + st + " " + downSeq + " " + CoopNpcVec3(thePlayer.GetWorldPosition()) + " " + CoopEncode(reviveTarget) + " " + reviveTargetSeq + " " + kneelFlag);
    }

    public function OnMessage()
    {
        var sender, target : string;
        var count, k, seq, i : int;
        var down, kneel : bool;
        var near : array<r_RemotePlayer>;
        sender = WO_Str(-1);
        count = StringToInt(WO_Str(-3), 0);
        if(WO_Str(0) != "dn" || count < 8 || sender == theGame.r_getMultiplayerClient().getUsername()) { return; }
        if(!SameParty(sender)) { return; }
        down = WO_Str(1) == "down";
        seq = StringToInt(WO_Str(2), 0);
        target = CoopDecode(WO_Str(6));
        kneel = count >= 9 && WO_Str(8) == "1";
        k = PeerIndex(sender);
        if(k < 0)
        {
            peerNames.PushBack(sender);
            peerDown.PushBack(false);
            peerSeq.PushBack(0);
            peerKneel.PushBack(false);
            k = peerNames.Size() - 1;
        }
        if(peerKneel[k] && !kneel)
        {
            // their figure here stands up when they do, not after the whole kneel sequence
            near = theGame.r_getMultiplayerClient().getPlayers();
            for(i = 0; i < near.Size(); i += 1) { if(near[i] && near[i].username == sender) { near[i].EndKneel(); } }
            peerKneelEnds += 1;
            Record("PEER_KNEEL_END " + sender);
        }
        peerKneel[k] = kneel;
        if(down && !peerDown[k])
        {
            peerDowns += 1;
            Record("PEER_DOWN " + sender + " seq=" + seq);
            theGame.GetGuiManager().ShowNotification(sender + " is down! Stand beside them and hold Interact to revive them.");
        }
        if(!down && peerDown[k])
        {
            Record("PEER_UP " + sender + " seq=" + seq);
            theGame.GetGuiManager().ShowNotification(sender + " is back on their feet.");
        }
        peerDown[k] = down;
        peerSeq[k] = seq;
        if(target == theGame.r_getMultiplayerClient().getUsername() && StringToInt(WO_Str(7), -1) == downSeq && downed && !getUp && respawnAt == 0)
        {
            revivesReceived += 1;
            theGame.GetGuiManager().ShowNotification(sender + " revived you.");
            GetUp("revived by " + sender);
        }
    }

    // ------------------------------------------------------------ every frame

    public function Tick()
    {
        var now, dt : float;
        now = theGame.GetEngineTimeAsSeconds();
        dt = ClampF(now - lastTick, 0, 0.25);
        lastTick = now;
        if(downed) { TickDowned(now); }
        else { TickReviver(dt); }
    }

    private function TickDowned(now : float)
    {
        var helper : string;
        if(pushPending)
        {
            pushPending = false;
            thePlayer.PushState('CoopDowned');
        }
        if(getUp) { return; }
        if(now - downAt > 2 && thePlayer.GetCurrentStateName() != 'CoopDowned' && respawnAt == 0)
        {
            Record("DOWN_STATE_MISSING state=" + thePlayer.GetCurrentStateName());
            GetUp("the downed state did not start");
            return;
        }
        if(respawnAt > 0)
        {
            if(now >= respawnAt) { Respawn(); }
            return;
        }
        helper = Helper();
        if(helper == "")
        {
            if(aloneSince == 0) { aloneSince = now; }
            if(now - aloneSince >= 3) { DieForReal("no party member can help"); }   // a few seconds: updates can lag
            return;
        }
        aloneSince = 0;
        if(now - downAt >= COOP_DOWN_TIME())
        {
            respawnBeside = helper;
            respawnPos = PeerPos(helper);
            respawnAt = now + 1.2;
            theGame.FadeOutAsync(1.0);
            Record("RESPAWN_START beside " + helper);
        }
    }

    // Nobody came: get up beside the party member.
    private function Respawn()
    {
        var spot, safe : Vector;
        var rot : EulerAngles;
        var i : int;
        var found : bool;
        respawnAt = 0;
        // 1.5 m to one side of them, not on their spot: the first side the navmesh has room on
        for(i = 0; i < 8 && !found; i += 1)
        {
            spot = respawnPos + VecFromHeading(i * 45) * 1.5;
            found = theGame.GetWorld().NavigationFindSafeSpot(spot, 0.4, 1.0, safe) && VecDistance2D(safe, respawnPos) >= 1.0;
        }
        if(!found) { safe = respawnPos + VecFromHeading(90) * 1.5; }
        rot = thePlayer.GetWorldRotation();
        thePlayer.TeleportWithRotation(safe, rot);
        Record("RESPAWN_SPOT " + FloatToStringPrec(VecDistance2D(safe, respawnPos), 1) + " m from " + respawnBeside + " navmesh=" + found);
        respawns += 1;
        GetUp("respawned beside " + respawnBeside);
        theGame.FadeInAsync(1.0);
        theGame.GetGuiManager().ShowNotification("Nobody revived you: you got up beside " + respawnBeside + ".");
    }

    // This player stands: revive a downed party member by holding Interact beside them.
    private function TickReviver(dt : float)
    {
        var globals : array<r_RemotePlayer>;
        var p : r_RemotePlayer;
        var target : string;
        var targetPos : Vector;
        var i, k : int;
        target = "";
        if(InParty() && thePlayer.IsAlive())
        {
            globals = theGame.r_getMultiplayerClient().getGlobalPlayers();
            for(i = 0; i < globals.Size() && target == ""; i += 1)
            {
                p = globals[i];
                if(!p || !PeerIsDown(p.username) || p.area != WO_CurrentAreaCode()) { continue; }
                if(VecDistance(thePlayer.GetWorldPosition(), p.pos) <= COOP_REVIVE_RANGE())
                {
                    target = p.username;
                    targetPos = p.pos;
                }
            }
        }
        if(target == "")
        {
            StopKneel();
            holdTarget = "";
            holdTime = 0;
            hinted = "";
            return;
        }
        if(hinted != target)
        {
            hinted = target;
            theGame.GetGuiManager().ShowNotification("Hold Interact to revive " + target + ".");
        }
        if(!(testHold || theInput.IsActionPressed('Interact') || theInput.IsActionPressed('InteractHold')))
        {
            StopKneel();
            holdTarget = "";
            holdTime = 0;
            return;
        }
        if(holdTarget != target)
        {
            holdTarget = target;
            holdTime = 0;
            StartKneel(targetPos);
            Record("REVIVE_HOLD " + target + " kneeling=" + kneeling);
        }
        holdTime += dt;
        if(holdTime < COOP_REVIVE_HOLD()) { return; }
        StopKneel();
        k = PeerIndex(target);
        reviveTarget = target;
        reviveTargetSeq = peerSeq[k];
        peerDown[k] = false;   // until their own message says otherwise
        revivesGiven += 1;
        holdTarget = "";
        holdTime = 0;
        Record("REVIVED " + target + " seq=" + reviveTargetSeq);
        SendState();
        theGame.GetGuiManager().ShowNotification("You revived " + target + ".");
    }

    // Kneel beside the downed player while reviving: the game's examine-ground action, which the
    // other screens already show on this player's figure (anno.ws reports player actions).
    private function StartKneel(targetPos : Vector)
    {
        var rot : EulerAngles;
        rot = thePlayer.GetWorldRotation();
        rot.Yaw = VecHeading(targetPos - thePlayer.GetWorldPosition());
        thePlayer.TeleportWithRotation(thePlayer.GetWorldPosition(), rot);
        kneeling = thePlayer.PlayerStartAction(PEA_ExamineGround);
        if(kneeling) { SendState(); }
    }

    private function StopKneel()
    {
        if(!kneeling) { return; }
        kneeling = false;
        thePlayer.PlayerStopAction(PEA_ExamineGround);
        SendState();   // the other screens stand this player's figure up now
    }

    public function IsKneeling() : bool { return kneeling; }

    // ------------------------------------------------------------ helpers

    // A party member who can help this player: alive and standing, in this region.
    private function Helper() : string
    {
        var globals : array<r_RemotePlayer>;
        var p : r_RemotePlayer;
        var i : int;
        globals = theGame.r_getMultiplayerClient().getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1)
        {
            p = globals[i];
            if(!p || !PeerAlive(p.username) || PeerIsDown(p.username)) { continue; }
            if(p.area != WO_CurrentAreaCode() || !SameParty(p.username)) { continue; }
            return p.username;
        }
        return "";
    }

    private function PeerPos(user : string) : Vector
    {
        var globals : array<r_RemotePlayer>;
        var i : int;
        globals = theGame.r_getMultiplayerClient().getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1) { if(globals[i] && globals[i].username == user) { return globals[i].pos; } }
        return thePlayer.GetWorldPosition();
    }

    // Whether a player is alive, from the nearby players' list (the global list does not carry
    // it); one too far off to be listed counts as alive unless they reported being down.
    private function PeerAlive(user : string) : bool
    {
        var near : array<r_RemotePlayer>;
        var i : int;
        near = theGame.r_getMultiplayerClient().getPlayers();
        for(i = 0; i < near.Size(); i += 1) { if(near[i] && near[i].username == user) { return near[i].isAlive; } }
        return true;
    }

    // The figure of a downed party member: Interact on it revives instead of opening the party menu.
    public function IsDownedFigure(figure : CActor) : bool
    {
        var near : array<r_RemotePlayer>;
        var i : int;
        near = theGame.r_getMultiplayerClient().getPlayers();
        for(i = 0; i < near.Size(); i += 1)
        {
            if(near[i] && near[i].ghost == figure) { return PeerIsDown(near[i].username); }
        }
        return false;
    }

    private function PeerIsDown(user : string) : bool
    {
        var k : int;
        k = PeerIndex(user);
        return k >= 0 && peerDown[k];
    }

    private function PeerIndex(user : string) : int
    {
        var i : int;
        for(i = 0; i < peerNames.Size(); i += 1) { if(peerNames[i] == user) { return i; } }
        return -1;
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

// How long a downed player waits for a revive before getting up beside a party member.
function COOP_DOWN_TIME() : float
{
    return 30.0;
}

// How long to hold Interact beside a downed party member, and how close to stand.
function COOP_REVIVE_HOLD() : float
{
    return 3.0;
}

function COOP_REVIVE_RANGE() : float
{
    return 2.5;
}

// Share of full health a player gets up with (revived or after the wait).
function COOP_REVIVE_HEALTH() : float
{
    return 0.3;
}

// Knocked down: lying on the ground (the game's knock-out animation), no damage, no actions,
// until revived or the wait ends. Modelled on the game's Unconscious state, which stands up on
// its own after a few seconds.
state CoopDowned in CR4Player extends ExtendedMovable
{
    event OnEnterState(prevStateName : name)
    {
        super.OnEnterState(prevStateName);
        parent.BlockAllActions('CoopDowned', true);
        parent.SetBehaviorVariable('unconsciousEnd', 0);
        LieDown();
    }

    event OnLeaveState(nextStateName : name)
    {
        super.OnLeaveState(nextStateName);
        parent.BlockAllActions('CoopDowned', false);
        parent.SetBehaviorVariable('unconsciousEnd', 0);
        theGame.r_getMultiplayerClient().getCoopRevive().OnDownedStateLeft();
    }

    // IsKnockedUnconscious(): the game's damage code leaves a knocked-out player alone.
    event OnCheckUnconscious()
    {
        return true;
    }

    entry function LieDown()
    {
        parent.RaiseForceEvent('Unconscious');
        thePlayer.SetRequiredItems('Any', 'None');
        thePlayer.ProcessRequiredItems(true);
        parent.OnForcedHolsterWeapon();
        while(!theGame.r_getMultiplayerClient().getCoopRevive().ShouldGetUp())
        {
            Sleep(0.2);
        }
        parent.SetBehaviorVariable('unconsciousEnd', 1);
        Sleep(3.0);
        parent.GotoStateAuto();
    }
}

@wrapMethod(CActor)
function DrainVitality(amount : float)
{
    if(this == thePlayer) { amount = theGame.r_getMultiplayerClient().getCoopRevive().CapDamage(amount); }
    wrappedMethod(amount);
}

@wrapMethod(CActor)
function Kill(source : name, optional ignoreImmortalityMode : bool, optional attacker : CGameplayEntity)
{
    if(this == thePlayer) { theGame.r_getMultiplayerClient().getCoopRevive().OnKill(true); }
    wrappedMethod(source, ignoreImmortalityMode, attacker);
    if(this == thePlayer) { theGame.r_getMultiplayerClient().getCoopRevive().OnKill(false); }
}
