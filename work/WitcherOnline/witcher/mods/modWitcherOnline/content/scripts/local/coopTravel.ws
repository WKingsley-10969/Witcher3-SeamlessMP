// Travel together (party). When a party member fast-travels, everyone in the party who was with
// them (within COOP_TRAVEL_RANGE of where they stood) fast-travels to the same signpost in their
// own game, with its own loading screen. When a party member who was with this player changes
// region some other way (a quest moving them, a boat), this game follows to where they arrived.
// Players who were elsewhere are left where they are, so the party can still split up.
//
// "coop tr ft seq area pin x y z fromArea": fast travel to signpost pin (area code; 0: same
// region) from x y z in region fromArea.
class r_CoopTravel
{
    private var events : array<string>;
    private var seq : int;
    private var following : bool;      // replaying a party member's travel here: not announced again
    private var followAt : float;      // when to travel (0: nothing pending)
    private var followArea : int;
    private var followPin : string;
    private var followFrom : string;
    private var nudgeAt : float;       // after following within the region: step aside from the signpost spot

    // party members as last seen, to notice a region change that was not a fast travel
    private var peerNames : array<string>;
    private var peerAreas : array<int>;
    private var peerPos : array<Vector>;
    private var peerNear : array<bool>;        // within range of this player in the same region
    private var peerTravelAt : array<float>;   // when their last fast travel was announced
    private var lastPeerCheck : float;

    public var travelsSent : int;
    public var travelsFollowed : int;
    public var travelsIgnored : int;
    public var regionFollows : int;
    public var lastIgnored : string;

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

    public function IsFollowing() : bool { return following; }

    // ------------------------------------------------------------ local game

    // This player fast-travels (map menu), to a signpost in this region or another.
    public function OnLocalFastTravel(area : name, pin : name)
    {
        var areaCode : int;
        if(following || !InParty()) { return; }
        areaCode = 0;
        if(area != '' && WO_AreaToCode(area) != WO_CurrentAreaCode()) { areaCode = WO_AreaToCode(area); }
        seq += 1;
        travelsSent += 1;
        Record("FT_SENT " + NameToString(pin) + " area=" + areaCode);
        WO_Send("coop tr ft " + seq + " " + areaCode + " " + CoopEncode(NameToString(pin)) + " " + CoopNpcVec3(thePlayer.GetWorldPosition()) + " " + WO_CurrentAreaCode());
    }

    // ------------------------------------------------------------ network

    public function OnMessage()
    {
        var sender : string;
        var count : int;
        sender = WO_Str(-1);
        count = StringToInt(WO_Str(-3), 0);
        if(WO_Str(0) != "tr" || count < 3 || sender == theGame.r_getMultiplayerClient().getUsername()) { return; }
        if(!SameParty(sender)) { return; }
        if(WO_Str(1) == "ft" && count >= 9) { OnFastTravel(sender); }
    }

    private function OnFastTravel(sender : string)
    {
        var from : Vector;
        var fromArea, i : int;
        from = Vector(StringToFloat(WO_Str(5), 0), StringToFloat(WO_Str(6), 0), StringToFloat(WO_Str(7), 0));
        fromArea = StringToInt(WO_Str(8), -1);
        i = PeerIndex(sender);
        if(i >= 0) { peerTravelAt[i] = theGame.GetEngineTimeAsSeconds(); }
        if(fromArea != WO_CurrentAreaCode() || VecDistance(thePlayer.GetWorldPosition(), from) > COOP_TRAVEL_RANGE())
        {
            Ignore(sender + " travelled from elsewhere");
            return;
        }
        if(!CanTravel(sender)) { return; }
        followArea = StringToInt(WO_Str(3), 0);
        followPin = CoopDecode(WO_Str(4));
        followFrom = sender;
        followAt = theGame.GetEngineTimeAsSeconds() + 1.0;
        Record("FT_IN " + sender + " " + followPin + " area=" + followArea);
        theGame.GetGuiManager().ShowNotification(sender + " is travelling: following");
    }

    private function CanTravel(sender : string) : bool
    {
        if(thePlayer.IsInCombat()) { Ignore(sender + " travelled while this player fights"); return false; }
        if(theGame.r_getMultiplayerClient().getCoopTalk().InScene()) { Ignore(sender + " travelled while this player is in a scene"); return false; }
        return true;
    }

    private function Ignore(why : string)
    {
        travelsIgnored += 1;
        lastIgnored = why;
        Record("FT_IGNORED " + why);
    }

    // ------------------------------------------------------------ every frame

    public function Tick()
    {
        var now : float;
        now = theGame.GetEngineTimeAsSeconds();
        if(followAt > 0 && now >= followAt)
        {
            followAt = 0;
            Follow();
        }
        if(nudgeAt > 0 && now >= nudgeAt)
        {
            nudgeAt = 0;
            StepAside();
        }
        if(now - lastPeerCheck >= 1.0)
        {
            lastPeerCheck = now;
            WatchPeers(now);
        }
    }

    // Run the same fast travel here.
    private function Follow()
    {
        var manager : CCommonMapManager;
        var pin : name;
        var worldPath : string;
        manager = theGame.GetCommonMapManager();
        if(followArea == 0) { worldPath = theGame.GetWorld().GetDepotPath(); }
        else { worldPath = manager.GetWorldPathFromAreaType(WO_AreaFromCode(followArea)); }
        if(!FindPin(worldPath, followPin, pin))
        {
            Ignore("no signpost " + followPin + " in " + worldPath);
            return;
        }
        following = true;
        if(followArea == 0) { manager.PerformLocalFastTravelTeleport(pin); }
        else { manager.PerformGlobalFastTravelTeleport(WO_AreaFromCode(followArea), pin); }
        following = false;
        if(followArea == 0) { nudgeAt = theGame.GetEngineTimeAsSeconds() + 1.0; }
        travelsFollowed += 1;
        Record("FT_FOLLOWED " + followFrom + " " + followPin);
    }

    // Both players land on the signpost's spot: stand 1.5 m to the side of it instead.
    private function StepAside()
    {
        var spot, safe : Vector;
        var rot : EulerAngles;
        spot = thePlayer.GetWorldPosition() + VecFromHeading(thePlayer.GetHeading() + 90) * 1.5;
        if(!theGame.GetWorld().NavigationFindSafeSpot(spot, 0.5, 2.0, safe)) { return; }
        rot = thePlayer.GetWorldRotation();
        thePlayer.TeleportWithRotation(safe, rot);
    }

    // A signpost tag from its text: scripts cannot make a name from a string, so it is looked up
    // among the destination's map pins.
    private function FindPin(worldPath : string, text : string, out pin : name) : bool
    {
        var pins : array<SCommonMapPinInstance>;
        var i : int;
        pins = theGame.GetCommonMapManager().GetMapPinInstances(worldPath);
        for(i = 0; i < pins.Size(); i += 1)
        {
            if(NameToString(pins[i].tag) == text)
            {
                pin = pins[i].tag;
                return true;
            }
        }
        return false;
    }

    // A party member who was here and is now in another region, without announcing a fast
    // travel (a quest moved them, a boat): follow them there.
    private function WatchPeers(now : float)
    {
        var globals : array<r_RemotePlayer>;
        var p : r_RemotePlayer;
        var rot : EulerAngles;
        var i, k : int;
        if(!InParty()) { return; }
        globals = theGame.r_getMultiplayerClient().getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1)
        {
            p = globals[i];
            if(!p || !SameParty(p.username) || p.area <= 0) { continue; }
            k = PeerIndex(p.username);
            if(k < 0)
            {
                peerNames.PushBack(p.username);
                peerAreas.PushBack(p.area);
                peerPos.PushBack(p.pos);
                peerNear.PushBack(false);
                peerTravelAt.PushBack(-100);
                k = peerNames.Size() - 1;
            }
            if(p.area != peerAreas[k] && peerAreas[k] == WO_CurrentAreaCode() && peerNear[k] && now - peerTravelAt[k] > 60
                && !following && followAt == 0)
            {
                if(CanTravel(p.username))
                {
                    regionFollows += 1;
                    Record("REGION_FOLLOW " + p.username + " area=" + p.area);
                    theGame.GetGuiManager().ShowNotification(p.username + " went to another region: following");
                    theGame.ScheduleWorldChangeToPosition(theGame.GetCommonMapManager().GetWorldPathFromAreaType(WO_AreaFromCode(p.area)), p.pos, thePlayer.GetWorldRotation());
                }
            }
            peerAreas[k] = p.area;
            peerPos[k] = p.pos;
            peerNear[k] = p.area == WO_CurrentAreaCode() && VecDistance(p.pos, thePlayer.GetWorldPosition()) <= COOP_TRAVEL_RANGE();
        }
    }

    private function PeerIndex(user : string) : int
    {
        var i : int;
        for(i = 0; i < peerNames.Size(); i += 1) { if(peerNames[i] == user) { return i; } }
        return -1;
    }

    // ------------------------------------------------------------ helpers

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

// How close to a travelling party member this player must have been to travel along.
function COOP_TRAVEL_RANGE() : float
{
    return 60.0;
}

@wrapMethod(CCommonMapManager)
function PerformLocalFastTravelTeleport(destinationPinTag : name)
{
    theGame.r_getMultiplayerClient().getCoopTravel().OnLocalFastTravel('', destinationPinTag);
    wrappedMethod(destinationPinTag);
}

@wrapMethod(CCommonMapManager)
function PerformGlobalFastTravelTeleport(destinationArea : name, destinationPinTag : name)
{
    theGame.r_getMultiplayerClient().getCoopTravel().OnLocalFastTravel(destinationArea, destinationPinTag);
    wrappedMethod(destinationArea, destinationPinTag);
}
