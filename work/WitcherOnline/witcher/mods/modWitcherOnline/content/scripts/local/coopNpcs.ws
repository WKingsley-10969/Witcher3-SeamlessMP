// Shared nearby NPCs. The party leader's game lists the non-hostile NPCs near the party and
// broadcasts them ("np" channel); a member matches each one to its own copy (a voicetag unique
// in both worlds first, else template + appearance, nearest within 15 m).
//
// Every NPC has one owner, whose world runs it on its own AI. The leader owns them all, except
// that a member who walks up to one (within 4 m, a metre closer than the leader) takes it over,
// so the NPC reacts to that member at once and without lag; it goes back once that member walks
// off (beyond 7 m) or the leader comes closer. Ownership changes at most every 2 s. The owner of
// a member-owned NPC streams it to the leader ("nq" channel).
//
// A world that does not own an NPC never steers its own copy: two drivers on one body run it in
// place or drift it. It hides the copy instead (still on its own AI, so quest scripts find it and
// see it act) and shows an AI-free stand-in, tags stripped and talk disabled, that only the
// owner's stream moves. Taking ownership swaps the copy back in at the stand-in's spot and pose.
// A member's copy that already agrees with the leader's NPC (at work on the same spot, the
// leader's not walking) stays shown on its own AI, keeping its work animations, until it disagrees.
// A member-only NPC is hidden when the leader has others of the same template nearby (a
// duplicate townsperson). Hostile NPCs stay with coopEnemies.
// NOT mirrored yet: animations of stand-ins beyond walking, one-liners, scenes, interiors.
class r_CoopHostNpc
{
    public var npc : CNewNPC;
    public var netId : int;
    public var lastSeenAt : float;
    public var lastPos : Vector;
    public var lastPosAt : float;
    public var speed : float;  // m/s from its own positions, smoothed (velocity reads 0 on many NPCs)
    public var owner : string;        // "" while this, the leader's, world owns it, else the member who does
    public var ownerSince : float;
    public var matchedBy : string;    // a member with its own copy of it, so it can own it
    public var matchedAt : float;
    public var display : CNewNPC;     // shown instead of npc while a member owns it
    public var target : Vector;       // the owner's NPC, from its stream
    public var yaw : float;
    public var ownerSpeed : float;
    public var streamAt : float;
    public var pinUntil : float;      // just teleported back: send target until the move lands
    public var glide : r_CoopNpcGlide;
    public var track : r_CoopNpcTrack; // the owner's samples, for the stand-in
}

class r_CoopNpcPuppet
{
    public var npc : CNewNPC;         // this world's own copy; NULL when it has none
    public var display : CNewNPC;     // AI-free stand-in shown instead of npc, moved by the owner's stream
    public var owned : bool;          // this world owns it: npc shown on its own AI and streamed to the leader
    public var netId : int;
    public var voice : string;
    public var tpl : string;
    public var app : string;
    public var target : Vector;
    public var yaw : float;
    public var speed : float;
    public var lastAt : float;
    public var hostWork : bool;
    public var settledSince : float;
    public var handedBack : bool;
    public var localPos : Vector;    // its own last position, to see this world's AI walk it
    public var localPosAt : float;
    public var localSpeed : float;
    public var swapPos : Vector;     // where a swap put npc, checked once the teleport lands
    public var pinUntil : float;
    public var glide : r_CoopNpcGlide;
    public var track : r_CoopNpcTrack; // the leader's samples, for the stand-in
}

// The owner's samples of one NPC, stamped with the owner's clock and played back a little behind,
// so a stand-in moves between two known positions instead of chasing the newest: updates arrive
// ten times a second and unevenly, and chasing them walks it in spurts.
class r_CoopNpcTrack
{
    public var poses : array<Vector>;
    public var yaws : array<float>;
    public var times : array<float>;  // the owner's clock, oldest first; the last four samples
    // This clock minus the owner's, from the least delayed sample. It creeps up by 1 % of the
    // time between samples, so it follows a delay that grows without ever jumping: a jump moves
    // the playback time and shows as a hitch.
    public var offset : float;
    public var gait : int;            // 0 stand, 1 walk, 2 run, 3 sprint

    public function Add(pos : Vector, yaw : float, sentAt : float, now : float)
    {
        var n : int;
        n = times.Size();
        if(n > 0 && sentAt <= times[n - 1]) { return; }  // late or repeated
        // a teleport or a gap: start over rather than glide across it
        if(n > 0 && (VecDistance2D(pos, poses[n - 1]) > 8.0 || sentAt - times[n - 1] > 1.0))
        {
            poses.Clear();
            yaws.Clear();
            times.Clear();
            n = 0;
        }
        if(n == 0) { offset = now - sentAt; }
        else { offset = MinF(offset + 0.01 * (sentAt - times[n - 1]), now - sentAt); }
        poses.PushBack(pos);
        yaws.PushBack(yaw);
        times.PushBack(sentAt);
        if(times.Size() > 4)
        {
            poses.Erase(0);
            yaws.Erase(0);
            times.Erase(0);
        }
    }

    public function Clear()
    {
        poses.Clear();
        yaws.Clear();
        times.Clear();
        gait = 0;
    }

    // Where the NPC was at `now` on this clock, played `delay` behind: on the pair of samples
    // around that time (the history covers an update that arrives early), or at most 0.25 s past
    // the newest along its last motion. False before the first sample.
    public function At(now : float, delay : float, out pos : Vector, out yaw : float, out speed : float) : bool
    {
        var t, span, f : float;
        var n, i, k : int;
        n = times.Size();
        if(n == 0) { return false; }
        if(n == 1)
        {
            pos = poses[0];
            yaw = yaws[0];
            speed = 0;
            return true;
        }
        t = now - offset - delay;
        i = n - 2;
        for(k = 0; k < n - 1; k += 1)
        {
            if(t <= times[k + 1])
            {
                i = k;
                break;
            }
        }
        span = times[i + 1] - times[i];
        speed = VecDistance2D(poses[i], poses[i + 1]) / span;
        f = ClampF((t - times[i]) / span, 0, 1 + 0.25 / span);
        pos = poses[i] + (poses[i + 1] - poses[i]) * f;
        yaw = yaws[i + 1];
        if(f < 1) { yaw = yaws[i] + AngleDistance(yaws[i + 1], yaws[i]) * f; }
        return true;
    }
}

// How smoothly a stand-in moves, frame by frame, while the NPC it shows walks: a stall is a frame
// in which it covers under a third of the owner's pace, the jerk how much its pace changes between
// frames. Diagnostics only.
class r_CoopNpcGlide
{
    public var lastPos : Vector;
    public var lastAt : float;
    public var lastSpeed : float;
}

class r_CoopNpcHidden
{
    public var npc : CNewNPC;
    public var aiId : int;
}

class r_CoopNpcs
{
    private var hosted : array<r_CoopHostNpc>;
    private var retiredNpcs : array<CNewNPC>;  // dropped from the list lately: keep their id if they come back
    private var retiredIds : array<int>;
    private var puppets : array<r_CoopNpcPuppet>;
    private var unmatchedIds : array<int>;
    private var hidden : array<r_CoopNpcHidden>;
    private var leaderTemplates : array<string>;
    public var paired : int;           // this world's NPCs paired late with a stand-in
    private var lastHideScan : float;
    private var nextNetId : int;
    private var seq : int;
    private var lastSend : float;
    private var lastCollect : float;
    private var sceneNpc : CNewNPC;   // in a shared conversation here: shown as itself, left out of sync
    private var sceneHold : bool;     // a scene plays here: every synced NPC is itself, left out of sync, no stand-in shown
    private var sceneGoneSince : float;  // sceneHold, but no scene playing here since then (0 while one plays)
    private var lastSnapshotAt : float;
    private var wasHost : bool;

    public var snapshotsSent : int;
    public var snapshotsApplied : int;
    public var streamsSent : int;
    public var streamsApplied : int;
    public var matchedByVoice : int;
    public var matchedByTemplate : int;
    public var lastSnapshotCount : int;
    public var copiesSpawned : int;    // stand-ins for NPCs this world has no copy of
    public var takeovers : int;        // agreeing copies that disagreed and were swapped for a stand-in
    public var ridersLetGo : int;      // own copies that mounted and were shown as themselves again
    public var handbacks : int;
    public var worstSnapBack : float;  // how far such a copy had got: the stand-in walks back that far
    public var ownershipGiven : int;   // leader: NPCs handed to a member
    public var ownershipTaken : int;   // leader: NPCs taken back
    public var ownedGained : int;      // member: NPCs this world came to own
    public var ownedLost : int;
    public var worstSwapPop : float;   // how far a swapped-in copy landed from the stand-in it replaced
    public var overCap : int;          // copies left unsynced because the stand-in cap was reached
    public var glideFrames : int;      // frames a stand-in was measured while the NPC it shows walked
    public var glideStalls : int;
    public var glideJerk : float;      // summed |pace change| / owner's pace
    public var glideJumps : int;       // frames a stand-in moved faster than 8 m/s
    public var refFrames : int;        // the same, for the leader's own NPCs walking on their AI:
    public var refStalls : int;        // what natural walking scores
    public var refJerk : float;

    default nextNetId = 1;

    public function PuppetCount() : int { return puppets.Size(); }
    public function HostedCount() : int { return hosted.Size(); }
    public function UnmatchedCount() : int { return unmatchedIds.Size(); }
    public function HiddenCount() : int { return hidden.Size(); }
    public function OwnedCount() : int
    {
        var i, n : int;
        for(i = 0; i < puppets.Size(); i += 1) { if(puppets[i].owned) { n += 1; } }
        return n;
    }
    public function SpawnedCount() : int
    {
        var i, n : int;
        for(i = 0; i < puppets.Size(); i += 1) { if(!puppets[i].npc) { n += 1; } }
        return n;
    }
    public function DisplayCount() : int
    {
        var i, n : int;
        for(i = 0; i < puppets.Size(); i += 1) { if(puppets[i].display) { n += 1; } }
        for(i = 0; i < hosted.Size(); i += 1) { if(hosted[i].display) { n += 1; } }
        return n;
    }
    public function MemberOwnedCount() : int
    {
        var i, n : int;
        for(i = 0; i < hosted.Size(); i += 1) { if(hosted[i].owner != "") { n += 1; } }
        return n;
    }

    // Mean and worst distance between what this world shows and where the leader's NPC stands.
    public function PuppetError(out mean : float, out worst : float)
    {
        var i, n : int;
        var d : float;
        mean = 0;
        worst = 0;
        for(i = 0; i < puppets.Size(); i += 1)
        {
            if(puppets[i].owned || !Shown(puppets[i])) { continue; }
            d = VecDistance(Shown(puppets[i]).GetWorldPosition(), puppets[i].target);
            mean += d;
            worst = MaxF(worst, d);
            n += 1;
        }
        if(n > 0) { mean /= n; }
    }

    // One line per puppet for diagnostics: identity, distance to the leader's NPC, mode.
    public function Describe() : array<string>
    {
        var lines : array<string>;
        var i : int;
        for(i = 0; i < puppets.Size(); i += 1)
        {
            if(!Shown(puppets[i])) { continue; }
            lines.PushBack(puppets[i].netId + " voice=" + puppets[i].voice + " mode=" + Mode(puppets[i])
                + " off=" + FloatToStringPrec(VecDistance(Shown(puppets[i]).GetWorldPosition(), puppets[i].target), 2)
                + " speed=" + FloatToStringPrec(puppets[i].speed, 2) + " hostWork=" + puppets[i].hostWork);
        }
        return lines;
    }

    // Leader: one line per listed NPC: id, voicetag, owner, work state and job.
    public function DescribeHosted() : array<string>
    {
        var lines : array<string>;
        var i : int;
        for(i = 0; i < hosted.Size(); i += 1)
        {
            if(!hosted[i].npc) { continue; }
            lines.PushBack(hosted[i].netId + " voice=" + NpcVoice(hosted[i].npc) + " owner=" + hosted[i].owner + " work=" + hosted[i].npc.IsAtWork()
                + " job=" + NpcJob(hosted[i].npc) + " tpl=" + hosted[i].npc.GetReadableName());
        }
        return lines;
    }

    // The NPC with one voicetag, for diagnostics. Member: "mode=.. off=.. yawOff=.. hostSpeed=..";
    // leader: "owner=.. shown=x,y,z off=..". "" when there is none.
    public function DescribeVoice(voice : string) : string
    {
        var shown : CNewNPC;
        var i : int;
        for(i = 0; i < puppets.Size(); i += 1)
        {
            shown = Shown(puppets[i]);
            if(shown && puppets[i].voice == voice)
            {
                return "mode=" + Mode(puppets[i]) + " off=" + FloatToStringPrec(VecDistance(shown.GetWorldPosition(), puppets[i].target), 2)
                    + " yawOff=" + FloatToStringPrec(AbsF(AngleDistance(puppets[i].yaw, shown.GetHeading())), 0)
                    + " hostSpeed=" + FloatToStringPrec(puppets[i].speed, 2);
            }
        }
        for(i = 0; i < hosted.Size(); i += 1)
        {
            if(!hosted[i].npc || NpcVoice(hosted[i].npc) != voice) { continue; }
            if(!hosted[i].display) { return "owner=- shown=" + CoopNpcVec(hosted[i].npc.GetWorldPosition()); }
            return "owner=" + hosted[i].owner + " shown=" + CoopNpcVec(hosted[i].display.GetWorldPosition())
                + " off=" + FloatToStringPrec(VecDistance(hosted[i].display.GetWorldPosition(), hosted[i].target), 2);
        }
        return "";
    }

    // This world's copy of a party member's conversation NPC: a unique voicetag, else the same
    // template and appearance nearest the given spot. NULL when there is none.
    public function FindForScene(voice : string, tpl : string, app : string, pos : Vector) : CNewNPC
    {
        var actors : array<CGameplayEntity>;
        var npc, best : CNewNPC;
        var bestDist, d : float;
        var sameVoice, i : int;

        FindGameplayEntitiesInSphere(actors, pos, 60, 200, '', FLAG_OnlyAliveActors);
        for(i = 0; i < actors.Size(); i += 1)
        {
            npc = (CNewNPC)actors[i];
            if(npc && voice != "" && !npc.HasTag('w3coop_npc_copy') && !npc.HasTag('MPEntity') && NpcVoice(npc) == voice)
            {
                sameVoice += 1;
                best = npc;
            }
        }
        for(i = 0; i < puppets.Size(); i += 1)
        {
            if(voice != "" && puppets[i].npc && puppets[i].voice == voice && !best) { best = puppets[i].npc; sameVoice = 1; }
        }
        if(sameVoice != 1)
        {
            best = NULL;
            bestDist = 10.0;
            for(i = 0; i < actors.Size(); i += 1)
            {
                npc = (CNewNPC)actors[i];
                if(!npc || npc.HasTag('w3coop_npc_copy') || npc.HasTag('MPEntity') || npc.GetReadableName() != tpl || NameToString(npc.GetAppearance()) != app) { continue; }
                d = VecDistance(npc.GetWorldPosition(), pos);
                if(d < bestDist)
                {
                    bestDist = d;
                    best = npc;
                }
            }
        }
        return best;
    }

    // A party member started a conversation with an NPC: find this world's copy, show it as itself
    // in place of any stand-in and keep sync off it until ReleaseScene. NULL when there is none.
    public function HoldForScene(voice : string, tpl : string, app : string, pos : Vector) : CNewNPC
    {
        var best : CNewNPC;
        var i : int;

        best = FindForScene(voice, tpl, app, pos);
        if(!best) { return NULL; }

        sceneNpc = best;
        Unhide(best);
        for(i = 0; i < puppets.Size(); i += 1)
        {
            if(puppets[i].npc == best && puppets[i].display)
            {
                SwapToReal(best, puppets[i].display);
                puppets[i].display = NULL;
            }
        }
        for(i = 0; i < hosted.Size(); i += 1)
        {
            if(hosted[i].npc == best && hosted[i].display)
            {
                SwapToReal(best, hosted[i].display);
                hosted[i].display = NULL;
            }
        }
        return best;
    }

    // A scene started here: its actors are this world's own NPCs, so while it plays no stand-in is
    // shown anywhere, hidden copies are shown and every synced NPC is left out of sync until
    // ReleaseScene (the owner's playtest: a stand-in Vesemir over the scene's own in the ghouls
    // cutscene, which the hold kept beyond 25 m of the scene). Real NPCs stay where the scene put
    // them: no swap to the stand-in's spot, which could move a scene actor mid-shot.
    public function HoldScene()
    {
        var i : int;
        if(!sceneHold) { Record("SCENE_HOLD puppets=" + puppets.Size() + " hidden=" + hidden.Size()); }
        sceneHold = true;
        sceneGoneSince = 0;
        for(i = puppets.Size() - 1; i >= 0; i -= 1)
        {
            DropDisplay(puppets[i].npc, puppets[i].display);
            puppets[i].display = NULL;
            // a stand-in only: nothing of this world to show; the leader's list brings it back after the scene
            if(!puppets[i].npc) { puppets.Erase(i); continue; }
            Unhide(puppets[i].npc);
        }
        for(i = 0; i < hosted.Size(); i += 1)
        {
            if(hosted[i].npc && hosted[i].display)
            {
                DropDisplay(hosted[i].npc, hosted[i].display);
                hosted[i].display = NULL;
            }
        }
        for(i = hidden.Size() - 1; i >= 0; i -= 1) { Unhide(hidden[i].npc); }
    }

    // Left out of sync for a scene playing here.
    private function InSceneHold(npc : CNewNPC) : bool
    {
        if(!npc) { return false; }
        return sceneHold || (sceneNpc && npc == sceneNpc);
    }

    // The scene or shared conversation is over: sync takes the NPCs back. A leader whose member
    // still owns one shows its stand-in again; puppets and extra copies are picked up by the
    // next update.
    public function ReleaseScene()
    {
        var held : CNewNPC;
        var all : bool;
        var i : int;
        if(!sceneNpc && !sceneHold) { return; }
        if(sceneHold) { Record("SCENE_RELEASE"); }
        held = sceneNpc;
        all = sceneHold;
        sceneNpc = NULL;
        sceneHold = false;  // stand-ins may be shown again
        for(i = 0; i < hosted.Size(); i += 1)
        {
            if(hosted[i].npc && (all || hosted[i].npc == held) && hosted[i].owner != "" && !hosted[i].display)
            {
                hosted[i].display = ShowDisplay(hosted[i].npc, hosted[i].npc.GetReadableName(), NameToString(hosted[i].npc.GetAppearance()),
                    hosted[i].npc.GetWorldPosition(), hosted[i].npc.GetHeading());
                if(hosted[i].track) { hosted[i].track.Clear(); }
            }
        }
    }

    // A scene of this game ended: the joined NPC goes back to sync at once, the rest only once no scene
    // has played here for COOP_SCENE_LINGER (CheckSceneHold). A quest often starts its next scene a moment
    // later, and prepares it with the characters it finds: the prologue's nightmare, 1.4 s after the
    // sparring, found the second PC's own Ciri and Vesemir hidden behind stand-ins again and was left out
    // (that PC went straight to White Orchard while the first PC played the nightmare).
    public function SceneEnded()
    {
        if(!sceneHold)
        {
            ReleaseScene();
            return;
        }
        sceneNpc = NULL;
        if(sceneGoneSince == 0) { sceneGoneSince = theGame.GetEngineTimeAsSeconds(); }
    }

    // Every frame: a scene that started here before the party formed (a save that loads into one) is
    // held too, and a hold lets go once no scene has played here for COOP_SCENE_LINGER (also one a load
    // cut off).
    private function CheckSceneHold(role : int, now : float)
    {
        var playing : bool;
        playing = theGame.IsDialogOrCutscenePlaying() || thePlayer.IsInNonGameplayCutscene();
        if(!sceneHold && playing && role != 0) { HoldScene(); }
        if(!sceneHold) { return; }
        if(playing) { sceneGoneSince = 0; }
        else if(sceneGoneSince == 0) { sceneGoneSince = now; }
        else if(now - sceneGoneSince > COOP_SCENE_LINGER()) { ReleaseScene(); }
    }

    // What this world shows for the NPC with one voicetag: a stand-in or the real one; NULL if neither.
    public function ShownByVoice(voice : string) : CNewNPC
    {
        var i : int;
        for(i = 0; i < puppets.Size(); i += 1)
        {
            if(Shown(puppets[i]) && puppets[i].voice == voice) { return Shown(puppets[i]); }
        }
        for(i = 0; i < hosted.Size(); i += 1)
        {
            if(!hosted[i].npc || NpcVoice(hosted[i].npc) != voice) { continue; }
            if(hosted[i].display) { return hosted[i].display; }
            return hosted[i].npc;
        }
        return NULL;
    }

    // How many NPCs with one voicetag this world shows within 90 m: stand-ins plus real ones not
    // hidden behind a stand-in. One for a synced character; two means a duplicate is visible.
    public function VisibleCount(voice : string) : int
    {
        var entities : array<CGameplayEntity>;
        var npc : CNewNPC;
        var i, n : int;
        FindGameplayEntitiesInSphere(entities, thePlayer.GetWorldPosition(), 90, 256, '', FLAG_OnlyAliveActors);
        for(i = 0; i < entities.Size(); i += 1)
        {
            npc = (CNewNPC)entities[i];
            if(npc && !npc.HasTag('w3coop_npc_copy') && NpcVoice(npc) == voice && !HiddenHere(npc)) { n += 1; }
        }
        // Stand-ins may carry no voicetag: count them by what they stand in for.
        for(i = 0; i < puppets.Size(); i += 1) { if(puppets[i].display && puppets[i].voice == voice) { n += 1; } }
        for(i = 0; i < hosted.Size(); i += 1) { if(hosted[i].display && hosted[i].npc && NpcVoice(hosted[i].npc) == voice) { n += 1; } }
        return n;
    }

    private function HiddenHere(npc : CNewNPC) : bool
    {
        var i : int;
        if(IsHidden(npc)) { return true; }
        for(i = 0; i < puppets.Size(); i += 1) { if(puppets[i].npc == npc && puppets[i].display) { return true; } }
        for(i = 0; i < hosted.Size(); i += 1) { if(hosted[i].npc == npc && hosted[i].display) { return true; } }
        return false;
    }

    public function Tick()
    {
        var client : r_MultiplayerClient;
        var role : int;
        var now : float;

        client = theGame.r_getMultiplayerClient();
        if(!client || !thePlayer) { return; }
        now = theGame.GetEngineTimeAsSeconds();
        role = client.getCoopEnemies().GetRole();
        CheckSceneHold(role, now);

        if(role == 1)
        {
            if(now - lastCollect >= 0.2 || now < lastCollect)
            {
                HostCollect(client, now);
                HostOwnership(client, now);
                lastCollect = now;
            }
            if(now - lastSend >= 0.1 || now < lastSend)
            {
                HostSend(now);
                lastSend = now;
            }
            HostMoveDisplays(now);
            wasHost = true;
        }
        else if(wasHost)
        {
            HostRelease();
            HostSend(now);  // an empty list releases the members' puppets
            wasHost = false;
        }

        if(role == 2 && now - lastSnapshotAt <= 8.0)
        {
            UpdatePuppets(now);
            if(now - lastSend >= 0.2 || now < lastSend || (OwnedCount() > 0 && now - lastSend >= 0.1))
            {
                MemberSend(client);
                lastSend = now;
            }
            if(now - lastHideScan >= 1.0 || now < lastHideScan)
            {
                HideDuplicates();
                lastHideScan = now;
            }
        }
        else if(puppets.Size() > 0 || hidden.Size() > 0)
        {
            ReleaseAll();
        }
    }

    public function OnMessage()
    {
        if(WO_Str(0) == "np") { OnSnapshot(); }
        else if(WO_Str(0) == "nq") { OnStream(); }
    }

    // ---------------------------------------------------------------- leader

    // A rider is not shared: each world shows its own, on its own horse and AI, and they are matched again
    // once he dismounts. A stand-in has no horse; it ran after the leader's riding Vesemir at a gallop and
    // teleported every 12 m (the owner's playtest, "Follow Vesemir" in White Orchard).
    private function Shareable(npc : CNewNPC) : bool
    {
        return npc && npc.IsAlive() && !npc.HasTag('MPEntity') && !npc.HasTag('w3coop_npc_copy') && !npc.IsHorse() && !npc.IsInCombat()
            && !npc.IsUsingHorse()
            && npc.GetAttitude(thePlayer) != AIA_Hostile
            && !theGame.r_getMultiplayerClient().getCoopEnemies().IsPuppet(npc);
    }

    private function HostCollect(client : r_MultiplayerClient, now : float)
    {
        var candidates : array<CActor>;
        var entities : array<CGameplayEntity>;
        var globals : array<r_RemotePlayer>;
        var npc : CNewNPC;
        var h : r_CoopHostNpc;
        var me : string;
        var pos : Vector;
        var dt : float;
        var i, j : int;

        candidates = thePlayer.GetNPCsAndPlayersInRange(45, 64, '', FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
        me = client.getUsername();
        globals = client.getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1)
        {
            if(!globals[i] || !globals[i].inParty || globals[i].joinedParty != me || globals[i].area != WO_CurrentAreaCode()
                || VecDistance(globals[i].pos, thePlayer.GetWorldPosition()) > COOP_SHARE_RANGE()) { continue; }
            entities.Clear();
            FindGameplayEntitiesInSphere(entities, globals[i].pos, 45, 64, '', FLAG_OnlyAliveActors);
            for(j = 0; j < entities.Size(); j += 1)
            {
                if((CActor)entities[j] && !candidates.Contains((CActor)entities[j])) { candidates.PushBack((CActor)entities[j]); }
            }
        }

        for(i = 0; i < candidates.Size(); i += 1)
        {
            npc = (CNewNPC)candidates[i];
            if(!Shareable(npc)) { continue; }
            h = FindHosted(npc);
            if(!h)
            {
                if(hosted.Size() >= 24) { continue; }
                h = new r_CoopHostNpc in this;
                h.npc = npc;
                j = retiredNpcs.FindFirst(npc);
                if(j >= 0)
                {
                    // Same NPC, same id: a new id would make members adopt it twice.
                    h.netId = retiredIds[j];
                    retiredNpcs.Erase(j);
                    retiredIds.Erase(j);
                }
                else
                {
                    h.netId = nextNetId;
                    nextNetId += 1;
                }
                h.lastPos = npc.GetWorldPosition();
                h.lastPosAt = now;
                h.ownerSince = now;
                hosted.PushBack(h);
            }
            h.lastSeenAt = now;
        }

        for(i = hosted.Size() - 1; i >= 0; i -= 1)
        {
            h = hosted[i];
            // A hidden NPC may drop out of range queries; its owner being near it is enough.
            if(h.npc && h.owner != "" && Shareable(h.npc)) { h.lastSeenAt = now; }
            if(!h.npc || !Shareable(h.npc) || now - h.lastSeenAt > 3.0)
            {
                if(h.display) { TakeBack(h, now); }
                if(h.npc)
                {
                    if(retiredNpcs.Size() >= 32)
                    {
                        retiredNpcs.Erase(0);
                        retiredIds.Erase(0);
                    }
                    retiredNpcs.PushBack(h.npc);
                    retiredIds.PushBack(h.netId);
                }
                hosted.Erase(i);
                continue;
            }
            pos = h.npc.GetWorldPosition();
            dt = now - h.lastPosAt;
            if(dt > 0.05)
            {
                h.speed = CoopNpcSpeed(h.speed, VecDistance2D(pos, h.lastPos), dt, now < h.pinUntil);
                h.lastPos = pos;
                h.lastPosAt = now;
            }
        }
    }

    private function FindHosted(npc : CNewNPC) : r_CoopHostNpc
    {
        var i : int;
        for(i = 0; i < hosted.Size(); i += 1)
        {
            if(hosted[i].npc == npc) { return hosted[i]; }
        }
        return NULL;
    }

    private function FindHostedById(netId : int) : r_CoopHostNpc
    {
        var i : int;
        for(i = 0; i < hosted.Size(); i += 1)
        {
            if(hosted[i].netId == netId) { return hosted[i]; }
        }
        return NULL;
    }

    // A member in this leader's party and area, or NULL.
    private function PartyMember(client : r_MultiplayerClient, user : string) : r_RemotePlayer
    {
        var globals : array<r_RemotePlayer>;
        var i : int;
        globals = client.getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1)
        {
            if(globals[i] && globals[i].username == user)
            {
                if(globals[i].inParty && globals[i].joinedParty == client.getUsername() && globals[i].area == WO_CurrentAreaCode()) { return globals[i]; }
                return NULL;
            }
        }
        return NULL;
    }

    // Who runs each NPC: the leader, unless a member that has its own copy walked up to it.
    private function HostOwnership(client : r_MultiplayerClient, now : float)
    {
        var member : r_RemotePlayer;
        var h : r_CoopHostNpc;
        var pos : Vector;
        var mine, theirs : float;
        var i : int;

        for(i = 0; i < hosted.Size(); i += 1)
        {
            h = hosted[i];
            if(InSceneHold(h.npc)) { continue; }
            pos = h.npc.GetWorldPosition();
            if(h.display) { pos = h.display.GetWorldPosition(); }
            mine = VecDistance(thePlayer.GetWorldPosition(), pos);
            if(h.owner == "")
            {
                if(h.matchedBy == "" || now - h.matchedAt > 1.5 || now - h.ownerSince < 2.0) { continue; }
                member = PartyMember(client, h.matchedBy);
                if(!member) { continue; }
                theirs = VecDistance(member.pos, pos);
                if(theirs < 4.0 && theirs + 1.0 < mine) { GiveToMember(h, h.matchedBy, now); }
                continue;
            }
            // the quest moved the real one away from the stand-in (the owner's playtest: a marker led to
            // an invisible Ciri): taken back where it is
            if(h.npc && h.display && VecDistance(h.npc.GetWorldPosition(), h.display.GetWorldPosition()) > 8.0)
            {
                TakeBack(h, now);
                continue;
            }
            member = PartyMember(client, h.owner);
            if(member && now - h.streamAt <= 2.0)
            {
                if(now - h.ownerSince < 2.0) { continue; }
                theirs = VecDistance(member.pos, pos);
                if(theirs <= 7.0 && !(mine < 4.0 && mine + 1.0 < theirs)) { continue; }
            }
            TakeBack(h, now);
        }
    }

    private function GiveToMember(h : r_CoopHostNpc, user : string, now : float)
    {
        h.display = ShowDisplay(h.npc, h.npc.GetReadableName(), NameToString(h.npc.GetAppearance()), h.npc.GetWorldPosition(), h.npc.GetHeading());
        if(!h.display)
        {
            overCap += 1;
            return;
        }
        h.owner = user;
        h.ownerSince = now;
        h.target = h.npc.GetWorldPosition();
        h.yaw = h.npc.GetHeading();
        h.ownerSpeed = 0;
        h.streamAt = now;
        if(!h.track) { h.track = new r_CoopNpcTrack in this; }
        h.track.Clear();
        ownershipGiven += 1;
    }

    private function TakeBack(h : r_CoopHostNpc, now : float)
    {
        if(h.display) { h.target = h.display.GetWorldPosition(); }
        if(h.npc && h.display && (VecDistance(h.npc.GetWorldPosition(), h.display.GetWorldPosition()) > 8.0 || h.npc.IsUsingHorse()))
        {
            // its own quest moved it, or it mounted: shown where it is, not pulled back to the stand-in
            h.target = h.npc.GetWorldPosition();
            h.display.Destroy();
            ShowReal(h.npc);
        }
        else if(h.npc) { SwapToReal(h.npc, h.display); }
        else if(h.display) { h.display.Destroy(); }
        h.display = NULL;
        h.owner = "";
        h.ownerSince = now;
        h.pinUntil = now + 0.5;
        ownershipTaken += 1;
    }

    private function HostMoveDisplays(now : float)
    {
        var i : int;
        for(i = 0; i < hosted.Size(); i += 1)
        {
            if(!hosted[i].glide) { hosted[i].glide = new r_CoopNpcGlide in this; }
            if(!hosted[i].display)
            {
                if(hosted[i].npc) { MeasureGlide(hosted[i].npc, hosted[i].glide, hosted[i].speed, true); }
                continue;
            }
            if(hosted[i].track) { Glide(hosted[i].display, hosted[i].track, now); }
            MeasureGlide(hosted[i].display, hosted[i].glide, hosted[i].ownerSpeed, false);
        }
    }

    private function HostRelease()
    {
        var now : float;
        var i : int;
        now = theGame.GetEngineTimeAsSeconds();
        for(i = 0; i < hosted.Size(); i += 1)
        {
            if(hosted[i].display) { TakeBack(hosted[i], now); }
        }
        hosted.Clear();
    }

    // "np seq area sentAt templates{path} count {netId voice tplIndex appearance x y z yaw speed atWork owner}"
    // A member-owned NPC is sent where its owner has it.
    private function HostSend(now : float)
    {
        var templates : array<string>;
        var body, tpl : string;
        var pos : Vector;
        var yaw, speed : float;
        var h : r_CoopHostNpc;
        var i, tplIndex : int;

        seq += 1;
        for(i = 0; i < hosted.Size(); i += 1)
        {
            h = hosted[i];
            tpl = CoopEncode(h.npc.GetReadableName());
            tplIndex = templates.FindFirst(tpl);
            if(tplIndex < 0)
            {
                templates.PushBack(tpl);
                tplIndex = templates.Size() - 1;
            }
            pos = h.npc.GetWorldPosition();
            yaw = h.npc.GetHeading();
            speed = h.speed;
            if(h.display || now < h.pinUntil)
            {
                pos = h.target;
                yaw = h.yaw;
            }
            if(h.display) { speed = h.ownerSpeed; }
            body += " " + h.netId + " " + CoopEncode(NpcVoice(h.npc)) + " " + tplIndex + " " + CoopEncode(NameToString(h.npc.GetAppearance()))
                + " " + FloatToStringPrec(pos.X, 2) + " " + FloatToStringPrec(pos.Y, 2) + " " + FloatToStringPrec(pos.Z, 2)
                + " " + FloatToStringPrec(yaw, 1) + " " + FloatToStringPrec(speed, 2) + " " + (int)h.npc.IsAtWork() + " " + CoopEncode(h.owner);
        }
        body = " " + templates.Size() + TemplateList(templates) + " " + hosted.Size() + body;
        WO_Send("coop np " + seq + " " + WO_CurrentAreaCode() + " " + FloatToStringPrec(now, 3) + body);
        snapshotsSent += 1;
    }

    private function TemplateList(templates : array<string>) : string
    {
        var text : string;
        var i : int;
        for(i = 0; i < templates.Size(); i += 1) { text += " " + templates[i]; }
        return text;
    }

    // "nq seq area sentAt nMatched {netId} nOwned {netId x y z yaw speed}" from a party member.
    private function OnStream()
    {
        var client : r_MultiplayerClient;
        var matched : array<int>;
        var h : r_CoopHostNpc;
        var sender : string;
        var count, nMatched, nOwned, idx, i : int;
        var now, sentAt : float;

        client = theGame.r_getMultiplayerClient();
        count = StringToInt(WO_Str(-3), 0);
        sender = WO_Str(-1);
        if(!client || client.getCoopEnemies().GetRole() != 1 || count < 6 || !PartyMember(client, sender)) { return; }
        if(StringToInt(WO_Str(2), -1) != WO_CurrentAreaCode()) { return; }
        sentAt = StringToFloat(WO_Str(3), 0);
        nMatched = StringToInt(WO_Str(4), -1);
        if(nMatched < 0 || nMatched > 24 || count < 6 + nMatched) { return; }
        for(i = 0; i < nMatched; i += 1) { matched.PushBack(StringToInt(WO_Str(5 + i), 0)); }
        idx = 5 + nMatched;
        nOwned = StringToInt(WO_Str(idx), -1);
        idx += 1;
        if(nOwned < 0 || nOwned > 24 || count != idx + nOwned * 6) { return; }

        now = theGame.GetEngineTimeAsSeconds();
        for(i = 0; i < hosted.Size(); i += 1)
        {
            if(matched.Contains(hosted[i].netId))
            {
                hosted[i].matchedBy = sender;
                hosted[i].matchedAt = now;
            }
            else if(hosted[i].matchedBy == sender) { hosted[i].matchedBy = ""; }
        }
        for(i = 0; i < nOwned; i += 1)
        {
            h = FindHostedById(StringToInt(WO_Str(idx), 0));
            if(h && h.owner == sender)
            {
                h.target = Vector(StringToFloat(WO_Str(idx + 1), 0), StringToFloat(WO_Str(idx + 2), 0), StringToFloat(WO_Str(idx + 3), 0));
                h.yaw = StringToFloat(WO_Str(idx + 4), 0);
                h.ownerSpeed = StringToFloat(WO_Str(idx + 5), 0);
                h.streamAt = now;
                if(h.track) { h.track.Add(h.target, h.yaw, sentAt, now); }
            }
            idx += 6;
        }
        streamsApplied += 1;
    }

    // ---------------------------------------------------------------- member

    private function OnSnapshot()
    {
        var client : r_MultiplayerClient;
        var templates : array<string>;
        var seen : array<int>;
        var p : r_CoopNpcPuppet;
        var pos : Vector;
        var leaderVoices : array<string>;
        var voice, tpl, app, me : string;
        var count, nTemplates, n, i, j, idx, netId : int;
        var mine : bool;
        var now, sentAt : float;

        client = theGame.r_getMultiplayerClient();
        count = StringToInt(WO_Str(-3), 0);
        if(!client || count < 5) { return; }
        if(client.getCoopEnemies().GetRole() != 2 || WO_Str(-1) != client.getJoinedParty()) { return; }
        if(StringToInt(WO_Str(2), -1) != WO_CurrentAreaCode()) { ReleaseAll(); return; }

        sentAt = StringToFloat(WO_Str(3), 0);
        nTemplates = StringToInt(WO_Str(4), -1);
        if(nTemplates < 0 || count < 6 + nTemplates) { return; }
        for(i = 0; i < nTemplates; i += 1) { templates.PushBack(CoopDecode(WO_Str(5 + i))); }
        idx = 5 + nTemplates;
        n = StringToInt(WO_Str(idx), -1);
        idx += 1;
        if(n < 0 || n > 24 || count != idx + n * 11) { return; }

        now = theGame.GetEngineTimeAsSeconds();
        me = client.getUsername();
        // A voicetag only identifies an NPC when the leader's list has it once (two guards can share one).
        for(j = 0; j < n; j += 1) { leaderVoices.PushBack(CoopDecode(WO_Str(idx + j * 11 + 1))); }
        for(i = 0; i < n; i += 1)
        {
            netId = StringToInt(WO_Str(idx), 0);
            voice = CoopDecode(WO_Str(idx + 1));
            tpl = "";
            if(StringToInt(WO_Str(idx + 2), -1) >= 0 && StringToInt(WO_Str(idx + 2), -1) < templates.Size()) { tpl = templates[StringToInt(WO_Str(idx + 2), 0)]; }
            app = CoopDecode(WO_Str(idx + 3));
            pos = Vector(StringToFloat(WO_Str(idx + 4), 0), StringToFloat(WO_Str(idx + 5), 0), StringToFloat(WO_Str(idx + 6), 0));
            mine = CoopDecode(WO_Str(idx + 10)) == me;
            seen.PushBack(netId);

            p = FindPuppet(netId);
            if(!p) { p = Adopt(netId, voice, CoopCount(leaderVoices, voice) == 1, tpl, app, pos, StringToFloat(WO_Str(idx + 7), 0), WO_Str(idx + 9) == "1", mine); }
            if(p)
            {
                p.target = pos;
                p.yaw = StringToFloat(WO_Str(idx + 7), 0);
                p.speed = StringToFloat(WO_Str(idx + 8), 0);
                p.hostWork = WO_Str(idx + 9) == "1";
                p.lastAt = now;
                if(mine && !p.owned) { TakeOwnership(p, now); }
                else if(!mine && p.owned) { GiveUpOwnership(p); }
                if(!p.track) { p.track = new r_CoopNpcTrack in this; }
                if(!p.owned) { p.track.Add(pos, p.yaw, sentAt, now); }
                unmatchedIds.Remove(netId);
            }
            else if(!unmatchedIds.Contains(netId))
            {
                unmatchedIds.PushBack(netId);
            }
            idx += 11;
        }

        for(i = unmatchedIds.Size() - 1; i >= 0; i -= 1)
        {
            if(!seen.Contains(unmatchedIds[i])) { unmatchedIds.Erase(i); }
        }
        leaderTemplates = templates;
        lastSnapshotCount = n;
        lastSnapshotAt = now;
        snapshotsApplied += 1;
    }

    // Tell the leader which NPCs this world has a copy of (so it may own them) and where the
    // ones it owns are.
    private function MemberSend(client : r_MultiplayerClient)
    {
        var matched, owned : string;
        var pos : Vector;
        var p : r_CoopNpcPuppet;
        var nMatched, nOwned, i : int;
        var now : float;

        now = theGame.GetEngineTimeAsSeconds();
        for(i = 0; i < puppets.Size(); i += 1)
        {
            p = puppets[i];
            if(!p.npc) { continue; }
            matched += " " + p.netId;
            nMatched += 1;
            if(!p.owned) { continue; }
            pos = p.npc.GetWorldPosition();
            if(now < p.pinUntil) { pos = p.swapPos; }
            owned += " " + p.netId + " " + FloatToStringPrec(pos.X, 2) + " " + FloatToStringPrec(pos.Y, 2) + " " + FloatToStringPrec(pos.Z, 2)
                + " " + FloatToStringPrec(p.npc.GetHeading(), 1) + " " + FloatToStringPrec(p.localSpeed, 2);
            nOwned += 1;
        }
        if(nMatched == 0) { return; }
        seq += 1;
        WO_Send("coop nq " + seq + " " + WO_CurrentAreaCode() + " " + FloatToStringPrec(now, 3) + " " + nMatched + matched + " " + nOwned + owned);
        streamsSent += 1;
    }

    // This world's copy of the leader's NPC: a matching local NPC, shown on its own AI when it
    // agrees with the leader's or this world owns it, else hidden behind a stand-in; or only a
    // stand-in when this world has no copy. NULL when even that failed.
    private function Adopt(netId : int, voice : string, voiceUnique : bool, tpl : string, app : string, pos : Vector, yaw : float, hostWork : bool, mine : bool) : r_CoopNpcPuppet
    {
        var entities : array<CGameplayEntity>;
        var npc, best, display : CNewNPC;
        var p : r_CoopNpcPuppet;
        var bestDist, d : float;
        var sameVoice, i : int;
        var byVoice : bool;

        if(voice != "" && voiceUnique)
        {
            // enemy-sharing copies and other players are not this world's own NPCs. Two of one voice
            // (White Orchard has a Vesemir at the inn and the quest's in the field): the one nearest the
            // leader's, within 30 m
            FindGameplayEntitiesInSphere(entities, thePlayer.GetWorldPosition(), 90, 128, '', FLAG_OnlyAliveActors);
            bestDist = 1000000.0;
            for(i = 0; i < entities.Size(); i += 1)
            {
                npc = (CNewNPC)entities[i];
                if(npc && !npc.HasTag('w3coop_npc_copy') && !npc.HasTag('MPEntity') && !theGame.r_getMultiplayerClient().getCoopEnemies().IsPuppet(npc)
                    && NpcVoice(npc) == voice)
                {
                    sameVoice += 1;
                    d = VecDistance(npc.GetWorldPosition(), pos);
                    if(d < bestDist)
                    {
                        bestDist = d;
                        best = npc;
                    }
                }
            }
            if(sameVoice > 1 && bestDist >= 30.0) { best = NULL; }
            if(best) { byVoice = true; }
        }
        if(!best)
        {
            entities.Clear();
            bestDist = 15.0;
            FindGameplayEntitiesInSphere(entities, pos, 15.0, 32, '', FLAG_OnlyAliveActors);
            for(i = 0; i < entities.Size(); i += 1)
            {
                npc = (CNewNPC)entities[i];
                if(!npc || npc.HasTag('w3coop_npc_copy') || npc.GetReadableName() != tpl || NameToString(npc.GetAppearance()) != app) { continue; }
                d = VecDistance(npc.GetWorldPosition(), pos);
                if(d < bestDist)
                {
                    bestDist = d;
                    best = npc;
                }
            }
        }
        if(best && byVoice && FindPuppetByNpc(best))
        {
            // The leader listed this one-of-a-kind NPC under a new id: same puppet, new id.
            p = FindPuppetByNpc(best);
            p.netId = netId;
            return p;
        }
        // this world's own one rides: shown as itself on its own horse, no stand-in beside it (Shareable)
        if(best && best.IsUsingHorse() && !FindPuppetByNpc(best)) { return NULL; }
        if(best && (FindPuppetByNpc(best) || !(Shareable(best) || IsHidden(best)))) { best = NULL; }

        if(best)
        {
            Unhide(best);
            if(!mine && !(hostWork && best.IsAtWork()))
            {
                display = ShowDisplay(best, tpl, app, best.GetWorldPosition(), best.GetHeading());
                if(!display) { overCap += 1; }  // shown unsynced on its own AI rather than steered
            }
        }
        else
        {
            display = SpawnDisplay(tpl, app, pos, yaw);
            if(!display) { return NULL; }
        }

        p = new r_CoopNpcPuppet in this;
        p.npc = best;
        p.display = display;
        if(mine && best) { p.owned = true; }
        p.netId = netId;
        p.voice = voice;
        p.tpl = tpl;
        p.app = app;
        p.hostWork = hostWork;
        p.settledSince = -1;
        p.localPosAt = theGame.GetEngineTimeAsSeconds();
        if(best) { p.localPos = best.GetWorldPosition(); }
        puppets.PushBack(p);
        if(!best) { copiesSpawned += 1; }
        else if(byVoice) { matchedByVoice += 1; }
        else { matchedByTemplate += 1; }
        if(p.owned) { ownedGained += 1; }
        return p;
    }

    // This world now runs the NPC: its own copy takes the stand-in's place and pose.
    private function TakeOwnership(p : r_CoopNpcPuppet, now : float)
    {
        if(!p.npc) { return; }  // no copy here to run; the leader only hands over ones we have
        if(p.display)
        {
            p.swapPos = p.display.GetWorldPosition();
            p.pinUntil = now + 0.5;
            SwapToReal(p.npc, p.display);
            p.display = NULL;
        }
        p.owned = true;
        p.localPos = p.npc.GetWorldPosition();
        p.localPosAt = now;
        p.localSpeed = 0;
        ownedGained += 1;
    }

    // The leader runs it again: hide this world's copy where it stands behind a stand-in.
    private function GiveUpOwnership(p : r_CoopNpcPuppet)
    {
        p.owned = false;
        p.handedBack = false;
        p.settledSince = -1;
        ownedLost += 1;
        if(p.track) { p.track.Clear(); }  // samples from before this world owned it are stale
        if(!p.npc) { return; }
        p.display = ShowDisplay(p.npc, p.tpl, p.app, p.npc.GetWorldPosition(), p.npc.GetHeading());
        if(!p.display) { overCap += 1; }
    }

    private function UpdatePuppets(now : float)
    {
        var p : r_CoopNpcPuppet;
        var dist : float;
        var i : int;
        for(i = puppets.Size() - 1; i >= 0; i -= 1)
        {
            p = puppets[i];
            if(p.npc && !p.npc.IsAlive()) { p.npc = NULL; p.owned = false; }
            if(!Shown(p) || now - p.lastAt > 3.0)
            {
                Release(p);
                puppets.Erase(i);
                continue;
            }
            if(p.npc && now - p.localPosAt > 0.2)
            {
                p.localSpeed = CoopNpcSpeed(p.localSpeed, VecDistance2D(p.npc.GetWorldPosition(), p.localPos), now - p.localPosAt, now < p.pinUntil);
                p.localPos = p.npc.GetWorldPosition();
                p.localPosAt = now;
            }
            if(p.pinUntil > 0 && now >= p.pinUntil)
            {
                if(p.npc) { worstSwapPop = MaxF(worstSwapPop, VecDistance(p.npc.GetWorldPosition(), p.swapPos)); }
                p.pinUntil = 0;
            }
            if(p.npc && p.npc.IsUsingHorse())
            {
                // this world's own one mounted: let go, shown as itself on its own horse (Shareable)
                Record("RIDES_OWN " + p.voice + " " + p.tpl);
                DropDisplay(p.npc, p.display);
                p.display = NULL;
                Unhide(p.npc);
                puppets.Erase(i);
                ridersLetGo += 1;
                continue;
            }
            if(p.npc && (p.npc.IsInNonGameplayCutscene() || p.npc.IsInGameplayScene()))
            {
                // in a scene of this world (perhaps brought in from beyond the hold radius): the real
                // one, where the scene put it, never the stand-in
                if(p.display)
                {
                    p.display.Destroy();
                    p.display = NULL;
                    Record("SCENE_SHOWS " + p.voice + " " + p.tpl);
                }
                Unhide(p.npc);
                ShowReal(p.npc);
                continue;
            }
            if(p.npc && !p.display && !IsHidden(p.npc) && !p.npc.GetVisibility())
            {
                ShowReal(p.npc);  // hidden with nothing in its place: never leave a character invisible
                Record("RESHOWN " + p.voice + " " + p.tpl);
            }
            if(p.owned || InSceneHold(p.npc)) { continue; }
            if(!p.display)
            {
                // An agreeing copy on its own AI. The moment this world's routine walks it while
                // the leader's stands, or the leader's walks, swap in a stand-in to follow instead.
                dist = VecDistance(p.npc.GetWorldPosition(), p.target);
                if(!(dist > 0.5 || p.speed >= 0.4 || p.localSpeed > 0.3 || !p.hostWork
                    || AbsF(AngleDistance(p.yaw, p.npc.GetHeading())) > 25)) { continue; }
                p.display = ShowDisplay(p.npc, p.tpl, p.app, p.npc.GetWorldPosition(), p.npc.GetHeading());
                if(!p.display) { continue; }
                p.settledSince = -1;
                takeovers += 1;
                if(dist <= 12) { worstSnapBack = MaxF(worstSnapBack, dist); }  // farther is a teleport, not a walk back
            }
            dist = VecDistance(p.display.GetWorldPosition(), p.target);
            if(p.npc && !p.handedBack && p.hostWork && p.speed < 0.1 && dist < 0.3 && p.npc.IsAtWork()
                && VecDistance(p.npc.GetWorldPosition(), p.target) < 0.5)
            {
                // This world's copy went to work where the leader's works: show it again.
                if(p.settledSince < 0) { p.settledSince = now; }
                if(now - p.settledSince > 3.0)
                {
                    SwapToReal(p.npc, p.display);
                    p.display = NULL;
                    p.handedBack = true;  // once: a second disagreement keeps the stand-in, no loop
                    handbacks += 1;
                    continue;
                }
            }
            else { p.settledSince = -1; }
            if(p.track) { Glide(p.display, p.track, now); }
            if(!p.glide) { p.glide = new r_CoopNpcGlide in this; }
            MeasureGlide(p.display, p.glide, p.speed, false);
        }
    }


    // Hide a member-only NPC near this player when the leader has another NPC of the same
    // template nearby: an extra townsperson this world spawned. Anything unique stays visible.
    private function HideDuplicates()
    {
        var actors : array<CActor>;
        var npc : CNewNPC;
        var h : r_CoopNpcHidden;
        var i : int;

        for(i = hidden.Size() - 1; i >= 0; i -= 1)
        {
            if(!hidden[i].npc) { hidden.Erase(i); }
            else if(!leaderTemplates.Contains(CoopEncode(hidden[i].npc.GetReadableName())))
            {
                Record("UNHIDDEN " + NpcVoice(hidden[i].npc) + " " + hidden[i].npc.GetReadableName() + " (the leader lists none of it now)");
                Unhide(hidden[i].npc);
            }
        }
        actors = thePlayer.GetNPCsAndPlayersInRange(45, 64, '', FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
        for(i = 0; i < actors.Size(); i += 1)
        {
            npc = (CNewNPC)actors[i];
            if(!Shareable(npc) || FindPuppetByNpc(npc) || IsHidden(npc) || InSceneHold(npc) || !leaderTemplates.Contains(CoopEncode(npc.GetReadableName()))) { continue; }
            // the owner's playtest: kid Ciri, spawned (or spawned again) by the quest after this world
            // first saw the leader's, was hidden here for good, and her stand-in went with the leader's list
            if(PairWithStandIn(npc)) { continue; }
            if(NpcVoice(npc) != "") { continue; }
            h = new r_CoopNpcHidden in this;
            h.npc = npc;
            h.aiId = NpcForceIdle(npc);
            HideReal(npc);
            hidden.PushBack(h);
        }
    }

    // An NPC of this world for a puppet that only has a stand-in (no copy here when the leader's was
    // first listed): same voicetag, or same template and appearance within 15 m. It stays hidden behind
    // the stand-in, which the leader's stream moves, and is shown again when the leader drops it.
    private function PairWithStandIn(npc : CNewNPC) : bool
    {
        var voice : string;
        var i : int;
        voice = NpcVoice(npc);
        for(i = 0; i < puppets.Size(); i += 1)
        {
            if(puppets[i].npc || !puppets[i].display) { continue; }
            if((voice != "" && puppets[i].voice == voice) || (puppets[i].tpl == npc.GetReadableName() && puppets[i].app == NameToString(npc.GetAppearance())
                && VecDistance(puppets[i].display.GetWorldPosition(), npc.GetWorldPosition()) < 15.0))
            {
                puppets[i].npc = npc;
                puppets[i].localPos = npc.GetWorldPosition();
                puppets[i].localPosAt = theGame.GetEngineTimeAsSeconds();
                HideReal(npc);
                paired += 1;
                Record("PAIRED " + voice + " " + npc.GetReadableName() + " with its stand-in");
                return true;
            }
        }
        return false;
    }

    // Enemy sharing takes this NPC over (it turned hostile, as Vesemir in the prologue's sparring):
    // NPC sharing lets it go, shown as itself.
    public function ReleaseNpc(npc : CNewNPC)
    {
        var i : int;
        if(!npc) { return; }
        for(i = puppets.Size() - 1; i >= 0; i -= 1)
        {
            if(puppets[i].npc != npc) { continue; }
            if(puppets[i].display) { puppets[i].display.Destroy(); }
            puppets[i].display = NULL;
            puppets.Erase(i);
        }
        Unhide(npc);
        ShowReal(npc);
    }

    // For the player's log (uploaded to the host).
    private function Record(text : string)
    {
        WO_Log("coop npcs " + text);
    }

    private function IsHidden(npc : CNewNPC) : bool
    {
        var i : int;
        for(i = 0; i < hidden.Size(); i += 1) { if(hidden[i].npc == npc) { return true; } }
        return false;
    }

    private function Unhide(npc : CNewNPC)
    {
        var i : int;
        for(i = hidden.Size() - 1; i >= 0; i -= 1)
        {
            if(hidden[i].npc != npc) { continue; }
            if(npc)
            {
                npc.CancelAIBehavior(hidden[i].aiId);
                ShowReal(npc);
            }
            hidden.Erase(i);
        }
    }

    private function Release(p : r_CoopNpcPuppet)
    {
        // a rider stays on his horse where he is, never moved to the stand-in's spot
        if(p.npc && p.npc.IsUsingHorse()) { DropDisplay(p.npc, p.display); }
        else if(p.npc) { SwapToReal(p.npc, p.display); }
        else if(p.display) { p.display.Destroy(); }
        p.display = NULL;
    }

    public function ReleaseAll()
    {
        var i : int;
        for(i = 0; i < puppets.Size(); i += 1) { Release(puppets[i]); }
        puppets.Clear();
        unmatchedIds.Clear();
        for(i = hidden.Size() - 1; i >= 0; i -= 1) { Unhide(hidden[i].npc); }
        hidden.Clear();
    }

    private function FindPuppet(netId : int) : r_CoopNpcPuppet
    {
        var i : int;
        for(i = 0; i < puppets.Size(); i += 1)
        {
            if(puppets[i].netId == netId) { return puppets[i]; }
        }
        return NULL;
    }

    private function FindPuppetByNpc(npc : CNewNPC) : r_CoopNpcPuppet
    {
        var i : int;
        for(i = 0; i < puppets.Size(); i += 1)
        {
            if(puppets[i].npc == npc) { return puppets[i]; }
        }
        return NULL;
    }

    private function Shown(p : r_CoopNpcPuppet) : CNewNPC
    {
        if(p.display) { return p.display; }
        return p.npc;
    }

    private function Mode(p : r_CoopNpcPuppet) : string
    {
        if(p.owned) { return "owned"; }
        if(p.display && p.npc) { return "display"; }
        if(p.display) { return "stand-in"; }
        return "copy";
    }

    // ---------------------------------------------------------------- both

    // Show an AI-free stand-in where real stands and hide real. real keeps its own AI out of
    // sight, so quest scripts still find it and see it act; nothing here steers it.
    private function ShowDisplay(real : CNewNPC, tpl : string, app : string, pos : Vector, yaw : float) : CNewNPC
    {
        var display : CNewNPC;
        display = SpawnDisplay(tpl, app, pos, yaw);
        if(display && real) { HideReal(real); }
        return display;
    }

    // A stand-in carries no tags, so quest scripts that look NPCs up by tag never find it, and
    // cannot be talked to: talking is for the real NPC, which the talker's world owns.
    private function SpawnDisplay(tpl : string, app : string, pos : Vector, yaw : float) : CNewNPC
    {
        var template : CEntityTemplate;
        var ent : CEntity;
        var npc : CNewNPC;
        var tags : array<name>;
        var rot : EulerAngles;
        var i : int;

        // none while a scene plays here: the scene shows this world's own actors
        if(tpl == "" || sceneHold || DisplayCount() >= 12) { return NULL; }
        template = (CEntityTemplate)LoadResource(tpl, true);
        if(!template) { return NULL; }
        rot.Yaw = yaw;
        ent = theGame.CreateEntity(template, pos, rot, true, false, false, PM_DontPersist);
        npc = (CNewNPC)ent;
        if(!npc)
        {
            if(ent) { ent.Destroy(); }
            return NULL;
        }
        if(app != "") { npc.ApplyAppearance(app); }
        tags = npc.GetTags();
        for(i = 0; i < tags.Size(); i += 1) { npc.RemoveTag(tags[i]); }
        npc.AddTag('w3coop_npc_copy');
        if(npc.GetComponent('talk')) { npc.GetComponent('talk').SetEnabled(false); }
        npc.SetImmortalityMode(AIM_Invulnerable, AIC_Default, true);
        NpcForceIdle(npc);
        return npc;
    }

    private function HideReal(npc : CNewNPC)
    {
        npc.SetVisibility(false);
        npc.SetGameplayVisibility(false);
        npc.EnableCharacterCollisions(false);
    }

    // A rider's collisions are the riding's own: switched on while he sits on the horse, his body pushes against
    // it (the owner's playtest: the second PC's own riding Vesemir slid and went at twice the pace)
    private function ShowReal(npc : CNewNPC)
    {
        npc.SetVisibility(true);
        npc.SetGameplayVisibility(true);
        if(!npc.IsUsingHorse()) { npc.EnableCharacterCollisions(true); }
    }

    // The real NPC takes the stand-in's place and pose, and the stand-in goes.
    private function SwapToReal(real : CNewNPC, display : CNewNPC)
    {
        if(display)
        {
            real.TeleportWithRotation(display.GetWorldPosition(), display.GetWorldRotation());
            display.Destroy();
        }
        ShowReal(real);
    }

    // The stand-in goes and the real NPC is shown where it stands (a scene placed it).
    private function DropDisplay(real : CNewNPC, display : CNewNPC)
    {
        if(display) { display.Destroy(); }
        if(real) { ShowReal(real); }
    }

    private function MeasureGlide(npc : CNewNPC, glide : r_CoopNpcGlide, ownerSpeed : float, reference : bool)
    {
        var pos : Vector;
        var now, dt, pace : float;
        now = theGame.GetEngineTimeAsSeconds();
        pos = npc.GetWorldPosition();
        dt = now - glide.lastAt;
        if(dt > 0.005 && dt < 0.2)
        {
            pace = VecDistance2D(pos, glide.lastPos) / dt;
            if(pace >= 8.0)
            {
                if(!reference) { glideJumps += 1; }  // a teleport, or a stand-in flicking between two places
                pace = -1;
            }
            else if(ownerSpeed >= 0.5 && reference)
            {
                refFrames += 1;
                if(pace < ownerSpeed / 3) { refStalls += 1; }
                if(glide.lastSpeed >= 0) { refJerk += AbsF(pace - glide.lastSpeed) / ownerSpeed; }
            }
            else if(ownerSpeed >= 0.5)
            {
                glideFrames += 1;
                if(pace < ownerSpeed / 3) { glideStalls += 1; }
                if(glide.lastSpeed >= 0) { glideJerk += AbsF(pace - glide.lastSpeed) / ownerSpeed; }
            }
            glide.lastSpeed = pace;
        }
        glide.lastPos = pos;
        glide.lastAt = now;
    }

    // Play a stand-in along the owner's samples 0.15 s behind (one and a half updates, so there is
    // nearly always a newer sample to move towards): each frame it slides, over 0.1 s, to where the
    // NPC is 0.1 s further on, so it moves at the NPC's own pace instead of in spurts. Locomotion
    // plays the gait for that pace, with hysteresis so it does not flick between walk and run;
    // it stays on while the NPC moves, so the feet do not slide. Teleports when far behind. Only
    // for stand-ins: nothing else drives them.
    private function Glide(npc : CNewNPC, track : r_CoopNpcTrack, now : float)
    {
        var adjustor : CMovementAdjustor;
        var ticket : SMovementAdjustmentRequestTicket;
        var agent : CMovingAgentComponent;
        var rot : EulerAngles;
        var ahead : Vector;
        var yaw, speed, dist : float;

        if(!track.At(now + 0.1, 0.15, ahead, yaw, speed)) { return; }
        dist = VecDistance(npc.GetWorldPosition(), ahead);
        agent = npc.GetMovingAgentComponent();
        if(dist > 12)
        {
            rot = npc.GetWorldRotation();
            rot.Yaw = yaw;
            npc.TeleportWithRotation(ahead, rot);
            agent.SetGameplayRelativeMoveSpeed(0);
            track.gait = 0;
            return;
        }
        track.gait = CoopNpcGait(track.gait, speed);
        if(track.gait > 0)
        {
            agent.SetGameplayMoveDirection(yaw);
            agent.SetGameplayRelativeMoveSpeed(track.gait);
        }
        else
        {
            agent.SetGameplayRelativeMoveSpeed(0);
        }
        if(dist < 0.03 && AbsF(AngleDistance(yaw, npc.GetHeading())) < 2) { return; }
        adjustor = agent.GetMovementAdjustor();
        adjustor.Cancel(adjustor.GetRequest('w3coop_npc'));
        ticket = adjustor.CreateNewRequest('w3coop_npc');
        // in step it covers 0.1 s of walking per frame; behind, it catches up at about 3 m/s
        adjustor.AdjustmentDuration(ticket, ClampF(dist / 3.0, 0.1, 0.6));
        adjustor.AdjustLocationVertically(ticket, true);
        adjustor.ScaleAnimationLocationVertically(ticket, true);
        adjustor.RotateTo(ticket, yaw);
        adjustor.SlideTo(ticket, ahead);
    }
}

function NpcVoice(npc : CNewNPC) : string
{
    var voice : string;
    voice = NameToString(npc.GetVoicetag());
    if(voice == "None" || voice == "NONE") { return ""; }
    return voice;
}

function NpcForceIdle(npc : CNewNPC) : int
{
    var tree : CAIDoNothingAction;
    tree = new CAIDoNothingAction in npc;
    tree.OnCreated();
    return npc.ForceAIBehavior(tree, BTAP_AboveCombat);
}

function CoopNpcVec(v : Vector) : string
{
    return FloatToStringPrec(v.X, 2) + "," + FloatToStringPrec(v.Y, 2) + "," + FloatToStringPrec(v.Z, 2);
}

// The job of the action point an NPC works at, for diagnostics: the friendly name reads
// 'CLayer_"<layer path>"::::<job>' (ap_guarding, ap_spyglass, ...); "" when not at work.
// CNewNPC.FindActionPoint crashes the game from here (access violation, runs 20261024-214457 and
// 20261024-214651), so only the calls vanilla scripts make are used.
function NpcJob(npc : CNewNPC) : string
{
    var apID : SActionPointId;
    if(!npc.IsAtWork()) { return ""; }
    apID = npc.GetActiveActionPoint();
    if(!IsAPValid(apID)) { return ""; }
    return StrAfterLast(theGame.GetAPManager().GetFriendlyAPName(apID), "::::");
}

// Smoothed walking speed from one step of an NPC's positions. A teleport (a swap, or the NPC's
// own AI) is not walking: counted as such it makes a stand-in sprint on the spot.
function CoopNpcSpeed(smoothed : float, moved : float, dt : float, teleporting : bool) : float
{
    if(teleporting || moved > 8.0 * dt) { return 0; }
    return 0.6 * smoothed + 0.4 * moved / dt;
}

// Walk from 0.5 m/s, run from 2.2, sprint from 4.8; each drops back only well below its threshold
// (0.3, 1.8, 4.2), so a pace near a boundary does not flick the gait every update.
function CoopNpcGait(gait : int, speed : float) : int
{
    if(speed >= 4.8 || (gait == 3 && speed >= 4.2)) { return 3; }
    if(speed >= 2.2 || (gait >= 2 && speed >= 1.8)) { return 2; }
    if(speed >= 0.5 || (gait >= 1 && speed >= 0.3)) { return 1; }
    return 0;
}

function CoopCount(values : array<string>, value : string) : int
{
    var i, n : int;
    for(i = 0; i < values.Size(); i += 1) { if(values[i] == value) { n += 1; } }
    return n;
}

// How long the NPCs stay unsynced after a scene here, for a next scene the quest starts right after.
function COOP_SCENE_LINGER() : float
{
    return 8.0;
}
