// Shared enemies (true co-op, milestone 1). The party leader's game owns the hostile NPCs near the party and
// broadcasts them ("en" channel); members mirror them as puppets (AI off, moved and healed from the leader's
// state) and send their hits to the leader ("hit" channel), who applies them to the real NPC. The leader's
// monsters attack members' ghosts; those hits go to the member ("hurt" channel) and land on their Geralt.
// Unmatched local hostiles near a member are hidden while they mirror the leader's world.

import function WO_FactsBaseline() : bool;
import function WO_FactsPage(pageSize : int) : string;

class r_CoopHostEnemy
{
    public var npc : CNewNPC;
    public var netId : int;
    public var lastSeenAt : float;
    public var deadAt : float;
    public var attackSeq : int;
    public var attackAnim : name;
    public var attackTarget : string;  // the player it attacks, for members' copies to attack the same
    public var hitAnimTime : float;  // animation time of the current attack's hit
    public var hitSeq : int;         // hits it took, for members to replay the reaction
    public var hitBy : string;
    public var hitReaction : int;
    public var moveSeq : int;        // its other animated moves (dodges, taunts, ...), for members to replay
    public var moveAnim : name;
    public var moveAnimTime : float;
    public var projSeq : int;        // its last projectile, for members to fire a harmless copy
    public var projAt : float;
    public var projTemplate : string;
    public var projFrom : Vector;
    public var projTo : Vector;
    public var projAngle : float;
    public var projSpeed : float;
    public var projRange : float;
    public var objSeq : int;         // objects its attacks spawned (roots, ice, trails ...): the last few, for members
    public var objTemplates : array<string>;
    public var objPositions : array<Vector>;
    public var objYaws : array<float>;
    public var objTimes : array<float>;
    public var stride : r_CoopStride;
}

class r_CoopPuppet
{
    public var npc : CNewNPC;
    public var netId : int;
    public var spawned : bool;  // created here (destroyed on release) or a local twin (AI given back on release)
    public var aiId : int;
    public var target : Vector;
    public var yaw : float;
    public var hp : float;
    public var alive : bool;
    public var predictUntil : float;
    public var attackSeq : int;
    public var attackPlayedAt : float;
    public var attackActor : CActor;  // whom the leader's monster attacked (this player, or another player's character)
    public var slotAnimAt : float;  // an attack or move started playing (it stands meanwhile)
    public var moveSeq : int;
    public var projSeq : int;
    public var objSeq : int;
    public var animAiId : int;
    public var hitSeq : int;
    public var wasInHitAnim : bool;
    public var wasDodging : bool;
    public var targetSpeed : float;   // how fast the leader's monster moves (m/s, smoothed), for its locomotion
    public var lastTargetAt : float;
    public var stride : r_CoopStride;
    public var reactUntil : float;  // forced idle lifted until then, so the AI plays the hit reaction
    public var addedNoFinishers : array<name>;
    public var flying : bool;   // in flight as the leader's monster: no gravity, free of the navmesh
    public var immortality : int;   // the leader's monster's EActorImmortalityMode, set here on AIC_Combat
    public var untargetable : bool; // out of gameplay visibility (no lock-on), as the leader's
}

// Feet swinging along the actor's facing over 1.5 s windows while it moves: a walking stride swings a foot tens of
// centimeters back and forth, a slide barely at all. Diagnostics for the locomotion of puppets.
class r_CoopStride
{
    public var bones : array<int>;
    public var lows : array<float>;
    public var highs : array<float>;
    public var boneLabel : string;
    public var pelvis : int;
    public var tries : int;
    public var windowStart : float;
    public var maxSwing : float;
    public var lastPos : Vector;
    public var lastAt : float;
    public var speed : float;

    default windowStart = -1;

    // the actor's own speed from its positions (m/s, smoothed); velocity reads 0 on monsters
    public function OwnSpeed(actor : CActor, now : float) : float
    {
        var pos : Vector;

        pos = actor.GetWorldPosition();
        if(lastAt > 0 && now - lastAt > 0.01)
        {
            speed = 0.8 * speed + 0.2 * VecDistance2D(pos, lastPos) / (now - lastAt);
        }
        lastPos = pos;
        lastAt = now;
        return speed;
    }

    public function Update(actor : CActor, moving : bool, now : float)
    {
        var base, facing : Vector;
        var offset : float;
        var i : int;

        if(!moving)
        {
            // a movement shorter than a window still counts
            if(windowStart >= 0 && now - windowStart >= 0.5)
            {
                CloseWindow();
            }
            windowStart = -1;
            return;
        }
        // searched while moving, once the actor is posed where it walks
        if(bones.Size() == 0 && tries < 30)
        {
            tries += 1;
            FindBones(actor);
        }
        if(bones.Size() == 0)
        {
            return;
        }
        if(windowStart >= 0 && now - windowStart > 1.5)
        {
            CloseWindow();
            windowStart = -1;
        }
        // against the pelvis of the same pose, so a slide moving the root between poses doesn't count
        base = actor.GetWorldPosition();
        if(pelvis >= 0)
        {
            base = MatrixGetTranslation(actor.GetBoneWorldMatrixByIndex(pelvis));
        }
        facing = VecFromHeading(actor.GetHeading());
        for(i = 0; i < bones.Size(); i += 1)
        {
            offset = VecDot(MatrixGetTranslation(actor.GetBoneWorldMatrixByIndex(bones[i])) - base, facing);
            if(windowStart < 0)
            {
                lows[i] = offset;
                highs[i] = offset;
            }
            else
            {
                lows[i] = MinF(lows[i], offset);
                highs[i] = MaxF(highs[i], offset);
            }
        }
        if(windowStart < 0)
        {
            windowStart = now;
        }
    }

    private function CloseWindow()
    {
        var i : int;

        for(i = 0; i < bones.Size(); i += 1)
        {
            maxSwing = MaxF(maxSwing, highs[i] - lows[i]);
        }
    }

    // the feet by their usual names, else the bones nearest points at foot height around the body (skeletons name
    // their feet differently; the root under the body doesn't count); the torso stands in for a missing pelvis
    private function FindBones(actor : CActor)
    {
        var offsets : array<Vector>;
        var pos, probe, found : Vector;
        var heading : float;
        var bone, i : int;

        pelvis = actor.GetBoneIndex('pelvis');
        if(pelvis < 0)
        {
            pelvis = actor.GetTorsoBoneIndex();
        }
        AddBone(actor.GetBoneIndex('l_foot'));
        AddBone(actor.GetBoneIndex('r_foot'));
        if(bones.Size() > 0)
        {
            boneLabel = "feet";
            return;
        }
        if(!actor.GetRootAnimatedComponent())
        {
            return;
        }
        pos = actor.GetWorldPosition();
        heading = actor.GetHeading();
        offsets.PushBack(VecFromHeading(heading) * 0.6 + VecFromHeading(heading - 90) * 0.3);
        offsets.PushBack(VecFromHeading(heading + 180) * 0.6 + VecFromHeading(heading - 90) * 0.3);
        offsets.PushBack(VecFromHeading(heading - 90) * 0.6);
        offsets.PushBack(VecFromHeading(heading + 90) * 0.6);
        for(i = 0; i < offsets.Size(); i += 1)
        {
            probe = pos + offsets[i];
            probe.Z += 0.1;
            bone = actor.GetRootAnimatedComponent().FindNearestBoneWS(probe);
            if(bone > 0)
            {
                found = MatrixGetTranslation(actor.GetBoneWorldMatrixByIndex(bone));
                if(VecDistance2D(found, pos) >= 0.05 && found.Z - pos.Z <= 0.5)
                {
                    AddBone(bone);
                }
            }
        }
        boneLabel = "";
        for(i = 0; i < bones.Size(); i += 1)
        {
            boneLabel += "#" + bones[i];
        }
    }

    private function AddBone(bone : int)
    {
        if(bone >= 0 && !bones.Contains(bone))
        {
            bones.PushBack(bone);
            lows.PushBack(0);
            highs.PushBack(0);
        }
    }
}

class r_CoopSuppressed
{
    public var npc : CNewNPC;
    public var aiId : int;
}

class r_CoopHit
{
    public var seq : int;
    public var netId : int;
    public var frac : float;
    public var effects : array<int>;  // what the hit applies (burning, knockdown, ...), applied by the leader
}

// a leader monster's hit on a member's ghost: raw damage before the ghost's own stats
class r_CoopHurt
{
    public var user : string;
    public var seq : int;
    public var netId : int;
    public var hitReaction : int;
    public var attackSeq : int;     // the attack that landed it, to line it up with the puppet's swing
    public var hitAnimTime : float;
    public var due : float;         // member: when to apply it
    public var receivedAt : float;
    public var types : array<name>;
    public var values : array<float>;
    public var effects : array<int>; // EEffectType of the hit's buffs (bleeding, knockdown, ...)
}

class r_CoopAck
{
    public var user : string;
    public var session : int;
    public var lastSeq : int;
}

class r_CoopEnemies
{
    private var loggedRole : int;
    private var loggedStatusAt : float;
    private var epoch : int;    // this game as leader: changes on restart so members drop stale ids
    private var session : int;  // this game as member: lets the leader restart hit numbering
    private var nextNetId : int;
    private var nextHitSeq : int;

    private var hostEnemies : array<r_CoopHostEnemy>;
    private var acks : array<r_CoopAck>;
    private var hurts : array<r_CoopHurt>;
    private var nextHurtSeq : int;
    private var lastHurtSend : float;
    private var lastHurtSentCount : int;
    private var armedGhosts : array<CActor>;
    private var wasHost : bool;
    private var lastHostSend : float;
    private var hostSeq : int;

    private var puppets : array<r_CoopPuppet>;
    private var suppressed : array<r_CoopSuppressed>;
    private var leaderName : string;
    private var leaderEpoch : int;
    private var lastSnapshotAt : float;
    private var pendingHits : array<r_CoopHit>;
    private var lastPuppetAction : W3DamageAction;  // this player's last damaging hit on a puppet, and its claim
    private var lastPuppetHit : r_CoopHit;
    private var lastHitSend : float;
    private var lastHitSentCount : int;
    private var hurtAck : int;
    private var lastSentHurtAck : int;
    private var leaderListsMyHurts : bool;
    private var delayedHurts : array<r_CoopHurt>;

    // corpses of shared enemies, the newest last, for corpse loot (coopLoot.ws): "<leader epoch>.<netId>", the
    // same on the leader's game and on members', and the dead NPC in this world
    private var corpseKeys : array<string>;
    private var corpseNpcs : array<CNewNPC>;
    private var corpseTimes : array<float>;
    // copies killed in flight, falling to the ground (as btTaskFalling), and since when
    private var fallingCopies : array<CNewNPC>;
    private var fallingSince : array<float>;

    // journal entries (quests, objectives) whose status changed this session, latest status per tag
    private var journalTags : array<name>;
    private var journalStatus : array<int>;
    private var journalTick : int;
    private var lastJournalSend : float;
    private var applyingJournal : bool;
    private var journalIndexTags : array<name>;
    private var journalIndexEntries : array<CJournalBase>;
    private var journalIndexBuiltAt : float;

    // scenes and the leader's tracking (sent with the journal list)
    private var currentScene : string;
    private var sceneSkipSeq : int;
    private var sceneSkipValue : int;
    private var applyingSkip : bool;
    private var sentTrackedQuest : name;
    private var sentHighlighted : name;
    private var leaderTrackedQuest : name;
    private var leaderHighlighted : name;
    private var leaderSceneSeen : string;
    private var leaderSkipSeen : int;

    // quest facts: changes since this save was loaded, read from the engine by the client ASI
    private var factsReady : bool;
    private var nextFactsTry : float;
    private var lastFactsSend : float;
    private var factsTick : int;

    // set while this game changes a puppet itself, so the damage hook lets it through
    public var applyingHostState : bool;

    // diagnostics for logs and the test bot
    public var hitsSent : int;
    public var hitsApplied : int;
    public var puppetsSpawned : int;
    public var puppetsKilled : int;  // puppets that died with the leader's monster
    public var puppetFlights : int;  // puppets that took off with the leader's monster
    public var copiesPutDown : int;  // copies killed in flight that did not fall by themselves
    public var statesMirrored : int;  // untouchable phases started or ended on copies
    public var controlStatesMirrored : int;  // knockdowns, staggers ... put on copies
    public var twinsBound : int;
    public var spawnFailures : int;
    public var lastError : string;
    public var lastHitFrac : float;
    public var hurtsCaptured : int;
    public var ghostHitsSeen : int;
    public var hurtsApplied : int;
    public var hurtsDodged : int;
    public var hurtDamageTaken : float;
    public var attacksSeen : int;
    public var attacksPlayed : int;
    public var attackPlayFailures : int;
    public var puppetAttackEvents : int;  // member: attack animations that really played on puppets
    public var puppetOwnAttacks : int;    // member: attacks a puppet started by itself (should not happen)
    public var puppetWrongTargets : int;  // member: mirrored attacks a puppet aimed at someone else than the leader's monster
    public var puppetDodgesSeen : int;    // member: puppets really dodging
    public var dodgesMirrored : int;      // member: the leader's monsters' dodges passed on to their puppets
    public var movesSeen : int;
    public var lastMoveAnim : name;
    public var movesPlayed : int;
    public var movePlayFailures : int;
    public var projectilesSeen : int;
    public var hitEffectsSent : int;     // member: effects its hits carried
    public var hitEffectsApplied : int;  // leader: effects of members' hits applied to its monsters
    public var hitEffectsHeld : int;     // leader: of those, ones the monster had right after
    public var signVisualsPlayed : int;  // other players' sign visuals shown at their copies (remotePlayer.ws)
    public var signVisualsActive : int;
    public var signVisualsByType : array<int>;  // by ESignType
    public var quenShieldsShown : int;
    public var quenHitsShown : int;      // shields that went down with the sign's burst
    public var yrdenRunesShown : int;
    public var lastSignVisual : string;  // the last one's type, effects and whether the first went active
    public var assumeOldSigns : bool;    // tests: read others' snapshots as from a version without fields 73-79
    public var meleeHitsSent : int;
    public var signHitsSent : int;
    public var projectilesFired : int;
    public var projectileFailures : int;
    public var objectsSeen : int;           // leader: objects its shared monsters' attacks spawned
    public var objectsSpawned : int;        // member: harmless copies of them spawned here
    public var objectFailures : int;
    public var mirrorDamageDropped : int;   // member: damage those copies (and copied projectiles) tried to deal here
    public var lastHurtDelay : float;
    public var hitReactionsMirrored : int;
    public var hitAnimsSeen : int;  // puppets entering a hit animation (shows the reactions really play)
    public var hostMaxSwing : float;    // stride of the leader's real monsters while they move (calibration)
    public var puppetMaxSwing : float;  // stride of puppets while their leader's monster moves
    public var strideBone : string;
    public var puppetLocomotion : bool;  // off: puppets only slide (the glide baseline for the stride tests)
    public var hurtEffectsApplied : int;
    public var journalApplied : int;
    public var lastJournalApplied : name;
    public var journalMessages : int;   // journal lists accepted from the leader
    public var journalMissing : int;    // entries this game could not find
    public var lastJournalSeen : string;
    public var trackedApplied : int;
    public var lastTrackedApplied : name;
    public var skipsApplied : int;
    public var factsApplied : int;
    public var lastFactApplied : string;
    public var lastJournalAppliedStatus : int;

    default puppetLocomotion = true;
    default lastHostSend = -999;
    default lastSnapshotAt = -999;
    default lastHitSend = -999;
    default lastHurtSend = -999;
    default lastJournalSend = -999;
    default lastFactsSend = -999;
    default journalIndexBuiltAt = -999;

    private function EnsureIds()
    {
        if(epoch == 0)
        {
            epoch = RandRange(1000000000, 1);
            session = RandRange(1000000000, 1);
            nextNetId = 1;
            nextHitSeq = 1;
            nextHurtSeq = 1;
        }
    }

    // 0 off, 1 leader of a party with members, 2 member
    public function GetRole() : int
    {
        var client : r_MultiplayerClient;
        var globals : array<r_RemotePlayer>;
        var localOnly : bool;
        var me : string;
        var i : int;

        client = theGame.r_getMultiplayerClient();
        localOnly = theGame.GetInGameConfigWrapper().GetVarValue('MPGhosts_Main', 'MPGhosts_LocalEnemiesOnly');
        if(!client || localOnly)
        {
            return 0;
        }

        if(client.getInParty() && client.getJoinedParty() != "" && client.getJoinedParty() != "none")
        {
            return 2;
        }

        me = client.getUsername();
        globals = client.getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1)
        {
            if(globals[i] && globals[i].inParty && globals[i].joinedParty == me)
            {
                return 1;
            }
        }
        return 0;
    }

    // called every frame from the client's tick while in game
    public function Tick()
    {
        var client : r_MultiplayerClient;
        var role : int;
        var now : float;

        client = theGame.r_getMultiplayerClient();
        if(!client || !thePlayer)
        {
            return;
        }

        EnsureIds();
        now = theGame.GetEngineTimeAsSeconds();
        RetryFactsBaseline(now);
        LandFallingCopies(now);
        role = GetRole();
        // for the player's log (uploaded to the host): who runs the enemies, and how many are shared
        if(role != loggedRole || now - loggedStatusAt >= 10.0 || now < loggedStatusAt)
        {
            if(role != loggedRole || HostEnemyCount() + PuppetCount() + SuppressedCount() > 0)
            {
                WO_Log("coop enemies role=" + role + " party=" + client.getJoinedParty() + " area=" + WO_CurrentAreaCode() + " shared=" + HostEnemyCount()
                    + " copies=" + PuppetCount() + " suppressed=" + SuppressedCount() + " hostilesNear=" + CoopHostilesNear(30));
            }
            loggedRole = role;
            loggedStatusAt = now;
        }

        if(role == 1)
        {
            if(now - lastHostSend >= 0.1)
            {
                HostCollect(client, now);
                HostSend();
                lastHostSend = now;
            }
            MeasureHostStrides(now);
            SendHurts(now);
            if(TrackingChanged())
            {
                lastJournalSend = -999;
            }
            SendJournal(now);
            SendFacts(now);
            wasHost = true;
        }
        else if(wasHost)
        {
            hostEnemies.Clear();
            hurts.Clear();
            DisarmGhosts();
            HostSend();
            SendHurts(now);
            wasHost = false;
        }

        if(role == 2)
        {
            if(leaderName != client.getJoinedParty())
            {
                ReleaseAll();
                pendingHits.Clear();
                leaderName = client.getJoinedParty();
                leaderEpoch = 0;
                hurtAck = 0;
                delayedHurts.Clear();
            }

            // the leader's snapshots also stop while its game sits in a menu; far from the leader, this world
            // runs its own monsters again
            if(now - lastSnapshotAt > 8.0 || !LeaderNear())
            {
                ReleaseAll();
            }
            else
            {
                ArmLeaderGhost();
                UpdatePuppets(now);
            }
            ApplyDueHurts(now);
            SendHits(now);
            // Quest progress goes both ways: the leader applies a member's changes as members
            // apply the leader's (forward only, so echoes are no-ops).
            SendJournal(now);
            SendFacts(now);
        }
        else if(puppets.Size() > 0 || suppressed.Size() > 0)
        {
            ReleaseAll();
            leaderName = "";
        }
        if(role != 2 && !wasHost && armedGhosts.Size() > 0)
        {
            DisarmGhosts();
        }
    }

    // ---------------------------------------------------------------- leader

    private function HostCollect(client : r_MultiplayerClient, now : float)
    {
        var candidates : array<CActor>;
        var entities : array<CGameplayEntity>;
        var globals : array<r_RemotePlayer>;
        var attitudeRef : CGameplayEntity;
        var npc : CNewNPC;
        var e : r_CoopHostEnemy;
        var me : string;
        var area : int;
        var i, j : int;

        candidates = thePlayer.GetNPCsAndPlayersInRange(40, 48, '', FLAG_Attitude_Hostile + FLAG_OnlyAliveActors + FLAG_ExcludePlayer);

        me = client.getUsername();
        area = WO_CurrentAreaCode();
        globals = client.getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1)
        {
            if(!globals[i] || !globals[i].inParty || globals[i].joinedParty != me || globals[i].area != area
                || VecDistance(globals[i].pos, thePlayer.GetWorldPosition()) > COOP_SHARE_RANGE())
            {
                continue;
            }

            // hostile to the member's ghost (armed below) as well as to this Geralt
            attitudeRef = GhostOf(globals[i].username);
            if(!attitudeRef)
            {
                attitudeRef = thePlayer;
            }
            entities.Clear();
            FindGameplayEntitiesInSphere(entities, globals[i].pos, 40, 48, '', FLAG_Attitude_Hostile + FLAG_OnlyAliveActors, attitudeRef);
            for(j = 0; j < entities.Size(); j += 1)
            {
                if((CActor)entities[j] && !candidates.Contains((CActor)entities[j]))
                {
                    candidates.PushBack((CActor)entities[j]);
                }
            }
        }

        for(i = 0; i < candidates.Size(); i += 1)
        {
            npc = (CNewNPC)candidates[i];
            if(!npc || npc.HasTag('MPEntity') || npc.IsHorse())
            {
                continue;
            }

            e = FindHostEnemyByNpc(npc);
            if(!e)
            {
                if(hostEnemies.Size() >= 24)
                {
                    continue;
                }
                e = new r_CoopHostEnemy in this;
                e.npc = npc;
                e.netId = nextNetId;
                e.deadAt = -1;
                nextNetId += 1;
                hostEnemies.PushBack(e);
            }
            e.lastSeenAt = now;
        }

        // one already shared stays shared while it is above or around the party: a flying monster circles high
        // over the fight (a griffin climbs past 80 m), out of the 40 m spheres above
        for(i = 0; i < hostEnemies.Size(); i += 1)
        {
            e = hostEnemies[i];
            if(!e.npc || !e.npc.IsAlive() || e.lastSeenAt == now)
            {
                continue;
            }
            if(VecDistance2D(e.npc.GetWorldPosition(), thePlayer.GetWorldPosition()) < 45)
            {
                e.lastSeenAt = now;
                continue;
            }
            for(j = 0; j < globals.Size(); j += 1)
            {
                if(globals[j] && globals[j].inParty && globals[j].joinedParty == me && VecDistance2D(e.npc.GetWorldPosition(), globals[j].pos) < 45)
                {
                    e.lastSeenAt = now;
                }
            }
        }

        ArmGhosts(client);

        // keep dead enemies for a few seconds so members see the death; drop ones out of range
        for(i = hostEnemies.Size() - 1; i >= 0; i -= 1)
        {
            e = hostEnemies[i];
            if(!e.npc)
            {
                hostEnemies.Erase(i);
                continue;
            }
            if(e.deadAt < 0 && !e.npc.IsAlive())
            {
                e.deadAt = now;
                RememberCorpse(e.npc, epoch, e.netId);
            }
            if((e.deadAt >= 0 && now - e.deadAt > 4.0) || (e.deadAt < 0 && now - e.lastSeenAt > 3.0))
            {
                hostEnemies.Erase(i);
            }
        }
    }

    // "en epoch seq area acks{user session lastSeq} templates{path}
    //  enemies{netId tpl appearance x y z yaw hp alive attackSeq attackAnim hitSeq hitBy hitReaction moveSeq moveAnim
    //  attackTarget stance immortality untargetable states projSeq [projTpl fromX fromY fromZ toX toY toZ angle speed range]
    //  objSeq objCount {objTpl x y z yaw}}" (projSeq 0 = no projectile in the last 1.5 s; the objects are those its attacks
    //  spawned in the last 1.5 s, at most 4, the last one numbered objSeq)
    private function HostSend()
    {
        var templates : array<string>;
        var body : string;
        var tpl : string;
        var pos : Vector;
        var e : r_CoopHostEnemy;
        var tplIndex : int;
        var alive : int;
        var i, j : int;
        var now : float;

        now = theGame.GetEngineTimeAsSeconds();
        hostSeq += 1;
        body = "";
        for(i = 0; i < hostEnemies.Size(); i += 1)
        {
            e = hostEnemies[i];
            tpl = CoopEncode(e.npc.GetReadableName());
            tplIndex = templates.FindFirst(tpl);
            if(tplIndex < 0)
            {
                templates.PushBack(tpl);
                tplIndex = templates.Size() - 1;
            }

            pos = e.npc.GetWorldPosition();
            alive = 0;
            if(e.deadAt < 0)
            {
                alive = 1;
            }

            body += " " + e.netId + " " + tplIndex + " " + CoopEncode(NameToString(e.npc.GetAppearance()))
                + " " + FloatToStringPrec(pos.X, 2) + " " + FloatToStringPrec(pos.Y, 2) + " " + FloatToStringPrec(pos.Z, 2)
                + " " + FloatToStringPrec(e.npc.GetHeading(), 1) + " " + FloatToStringPrec(MaxF(0, e.npc.GetHealthPercents()), 4)
                + " " + alive + " " + e.attackSeq + " " + CoopEncode(NameToString(e.attackAnim))
                + " " + e.hitSeq + " " + CoopEncode(e.hitBy) + " " + e.hitReaction
                + " " + e.moveSeq + " " + CoopEncode(NameToString(e.moveAnim)) + " " + CoopEncode(e.attackTarget)
                + " " + (int)e.npc.GetCurrentStance() + " " + (int)e.npc.GetImmortalityMode()
                + " " + CoopBit(!e.npc.GetGameplayVisibility()) + " " + StateMask(e.npc);

            if(e.projSeq > 0 && now - e.projAt < 1.5)
            {
                tpl = CoopEncode(e.projTemplate);
                tplIndex = templates.FindFirst(tpl);
                if(tplIndex < 0)
                {
                    templates.PushBack(tpl);
                    tplIndex = templates.Size() - 1;
                }
                body += " " + e.projSeq + " " + tplIndex
                    + " " + FloatToStringPrec(e.projFrom.X, 2) + " " + FloatToStringPrec(e.projFrom.Y, 2) + " " + FloatToStringPrec(e.projFrom.Z, 2)
                    + " " + FloatToStringPrec(e.projTo.X, 2) + " " + FloatToStringPrec(e.projTo.Y, 2) + " " + FloatToStringPrec(e.projTo.Z, 2)
                    + " " + FloatToStringPrec(e.projAngle, 1) + " " + FloatToStringPrec(e.projSpeed, 1) + " " + FloatToStringPrec(e.projRange, 1);
            }
            else
            {
                body += " 0";
            }

            TrimObjects(e, now);
            body += " " + e.objSeq + " " + e.objTimes.Size();
            for(j = 0; j < e.objTimes.Size(); j += 1)
            {
                tpl = CoopEncode(e.objTemplates[j]);
                tplIndex = templates.FindFirst(tpl);
                if(tplIndex < 0)
                {
                    templates.PushBack(tpl);
                    tplIndex = templates.Size() - 1;
                }
                body += " " + tplIndex + " " + FloatToStringPrec(e.objPositions[j].X, 2) + " " + FloatToStringPrec(e.objPositions[j].Y, 2)
                    + " " + FloatToStringPrec(e.objPositions[j].Z, 2) + " " + FloatToStringPrec(e.objYaws[j], 1);
            }
        }

        WO_Send("coop en " + epoch + " " + hostSeq + " " + WO_CurrentAreaCode() + " " + AcksText() + " " + TemplatesText(templates)
            + " " + hostEnemies.Size() + body);
    }

    private function AcksText() : string
    {
        var text : string;
        var i : int;

        text = "" + acks.Size();
        for(i = 0; i < acks.Size(); i += 1)
        {
            text += " " + acks[i].user + " " + acks[i].session + " " + acks[i].lastSeq;
        }
        return text;
    }

    private function TemplatesText(templates : array<string>) : string
    {
        var text : string;
        var i : int;

        text = "" + templates.Size();
        for(i = 0; i < templates.Size(); i += 1)
        {
            text += " " + templates[i];
        }
        return text;
    }

    public function CountSignVisual(type : ESignType)
    {
        while(signVisualsByType.Size() <= (int)type)
        {
            signVisualsByType.PushBack(0);
        }
        signVisualsByType[(int)type] += 1;
    }

    public function SignVisualsOf(type : ESignType) : int
    {
        if((int)type < signVisualsByType.Size())
        {
            return signVisualsByType[(int)type];
        }
        return 0;
    }

    // tests: zero the diagnostics between scenarios run in one game session
    public function ResetDiagnostics()
    {
        hitsSent = 0;
        hitsApplied = 0;
        puppetsSpawned = 0;
        puppetsKilled = 0;
        twinsBound = 0;
        spawnFailures = 0;
        lastError = "";
        lastHitFrac = 0;
        hurtsCaptured = 0;
        ghostHitsSeen = 0;
        hurtsApplied = 0;
        hurtsDodged = 0;
        hurtDamageTaken = 0;
        attacksSeen = 0;
        attacksPlayed = 0;
        attackPlayFailures = 0;
        puppetAttackEvents = 0;
        puppetOwnAttacks = 0;
        puppetWrongTargets = 0;
        puppetDodgesSeen = 0;
        dodgesMirrored = 0;
        movesSeen = 0;
        lastMoveAnim = '';
        movesPlayed = 0;
        movePlayFailures = 0;
        projectilesSeen = 0;
        hitEffectsSent = 0;
        hitEffectsApplied = 0;
        hitEffectsHeld = 0;
        signVisualsPlayed = 0;
        signVisualsActive = 0;
        signVisualsByType.Clear();
        quenShieldsShown = 0;
        quenHitsShown = 0;
        yrdenRunesShown = 0;
        lastSignVisual = "";
        assumeOldSigns = false;
        meleeHitsSent = 0;
        signHitsSent = 0;
        projectilesFired = 0;
        projectileFailures = 0;
        lastHurtDelay = 0;
        hitReactionsMirrored = 0;
        hitAnimsSeen = 0;
        hostMaxSwing = 0;
        puppetMaxSwing = 0;
        strideBone = "";
        puppetLocomotion = true;
        hurtEffectsApplied = 0;
    }

    public function SetPuppetLocomotion(on : bool)
    {
        puppetLocomotion = on;
    }

    private function MeasureHostStrides(now : float)
    {
        var e : r_CoopHostEnemy;
        var i : int;

        for(i = 0; i < hostEnemies.Size(); i += 1)
        {
            e = hostEnemies[i];
            if(!e.npc || e.deadAt >= 0)
            {
                continue;
            }
            if(!e.stride)
            {
                e.stride = new r_CoopStride in this;
            }
            e.stride.Update(e.npc, e.stride.OwnSpeed(e.npc, now) > 1.0, now);
            hostMaxSwing = MaxF(hostMaxSwing, e.stride.maxSwing);
            strideBone = e.stride.boneLabel + "/" + e.stride.pelvis;
        }
    }

    private function FindHostEnemyByNpc(npc : CNewNPC) : r_CoopHostEnemy
    {
        var i : int;

        for(i = 0; i < hostEnemies.Size(); i += 1)
        {
            if(hostEnemies[i].npc == npc)
            {
                return hostEnemies[i];
            }
        }
        return NULL;
    }

    private function FindHostEnemy(netId : int) : r_CoopHostEnemy
    {
        var i : int;

        for(i = 0; i < hostEnemies.Size(); i += 1)
        {
            if(hostEnemies[i].netId == netId)
            {
                return hostEnemies[i];
            }
        }
        return NULL;
    }

    private function FindAck(user : string, memberSession : int) : r_CoopAck
    {
        var ack : r_CoopAck;
        var i : int;

        for(i = 0; i < acks.Size(); i += 1)
        {
            if(acks[i].user == user)
            {
                if(acks[i].session != memberSession)
                {
                    acks[i].session = memberSession;
                    acks[i].lastSeq = 0;
                }
                return acks[i];
            }
        }

        ack = new r_CoopAck in this;
        ack.user = user;
        ack.session = memberSession;
        acks.PushBack(ack);
        return ack;
    }

    // "hit leader epoch session hurtAck count {seq netId fraction}": all hits the member has not seen
    // acknowledged yet, and the last hurt it applied
    private function OnHits(sender : string, count : int)
    {
        var client : r_MultiplayerClient;
        var ack : r_CoopAck;
        var effects : array<int>;
        var n, i, j, idx, seq, effectCount : int;

        client = theGame.r_getMultiplayerClient();
        if(count < 6 || WO_Str(1) != client.getUsername() || StringToInt(WO_Str(2), 0) != epoch || !IsMyPartyMember(sender))
        {
            return;
        }

        PruneHurts(sender, StringToInt(WO_Str(4), 0));
        ack = FindAck(sender, StringToInt(WO_Str(3), 0));
        n = StringToInt(WO_Str(5), 0);
        idx = 6;
        // "seq netId frac effectCount {effect}" per hit
        for(i = 0; i < n && idx + 3 < count; i += 1)
        {
            seq = StringToInt(WO_Str(idx), 0);
            effectCount = StringToInt(WO_Str(idx + 3), 0);
            effects.Clear();
            for(j = 0; j < effectCount && idx + 4 + j < count; j += 1)
            {
                effects.PushBack(StringToInt(WO_Str(idx + 4 + j), 0));
            }
            if(seq > ack.lastSeq)
            {
                ApplyHit(sender, StringToInt(WO_Str(idx + 1), 0), StringToFloat(WO_Str(idx + 2), 0), effects);
                ack.lastSeq = seq;
            }
            idx += 4 + effectCount;
        }
    }

    private function ApplyHit(sender : string, netId : int, frac : float, effects : array<int>)
    {
        var e : r_CoopHostEnemy;
        var action : W3DamageAction;
        var attacker : CActor;
        var difficultyMult : float;
        var i : int;

        e = FindHostEnemy(netId);
        if(!e || !e.npc || !e.npc.IsAlive() || (frac <= 0 && effects.Size() == 0))
        {
            return;
        }

        attacker = GhostOf(sender);

        // the damage processor scales an NPC attacker's damage by the NPC difficulty multiplier (3.3x was
        // measured); the member's game already applied its own stats, so divide that back out
        difficultyMult = 1;
        if(attacker && !attacker.IgnoresDifficultySettings())
        {
            difficultyMult = CalculateAttributeValue(attacker.GetAttributeValue(theGame.params.DIFFICULTY_DMG_MULTIPLIER));
            if(difficultyMult <= 0)
            {
                difficultyMult = 1;
            }
        }

        action = new W3DamageAction in theGame.damageMgr;
        action.Initialize(attacker, e.npc, theGame, "W3Coop", EHRT_Light, CPS_Undefined, false, false, false, false);
        if(frac > 0)
        {
            action.AddDamage(theGame.params.DAMAGE_NAME_DIRECT, MinF(frac, 1) * e.npc.GetMaxHealth() / difficultyMult);
        }
        // its own resistances decide whether they take hold; processed also without damage, as Aard's are
        for(i = 0; i < effects.Size(); i += 1)
        {
            action.AddEffectInfo((EEffectType)effects[i]);
        }
        if(effects.Size() > 0)
        {
            action.SetProcessBuffsIfNoDamage(true);
        }
        hitEffectsApplied += effects.Size();
        action.SetCannotReturnDamage(true);
        theGame.damageMgr.ProcessAction(action);
        delete action;
        for(i = 0; i < effects.Size(); i += 1)
        {
            if(e.npc.HasBuff((EEffectType)effects[i]))
            {
                hitEffectsHeld += 1;
            }
        }
        hitsApplied += 1;
    }

    private function IsMyPartyMember(user : string) : bool
    {
        var client : r_MultiplayerClient;
        var globals : array<r_RemotePlayer>;
        var i : int;

        client = theGame.r_getMultiplayerClient();
        globals = client.getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1)
        {
            if(globals[i] && globals[i].username == user)
            {
                return globals[i].inParty && globals[i].joinedParty == client.getUsername();
            }
        }
        return false;
    }

    // the player behind an actor: this game's Geralt or another player's character here; "" for anyone else
    private function UserOf(actor : CActor) : string
    {
        var players : array<r_RemotePlayer>;
        var i : int;

        if(actor && actor == thePlayer)
        {
            return theGame.r_getMultiplayerClient().getUsername();
        }
        players = theGame.r_getMultiplayerClient().getPlayers();
        for(i = 0; actor && i < players.Size(); i += 1)
        {
            if(players[i] && players[i].ghost == actor)
            {
                return players[i].username;
            }
        }
        return "";
    }

    private function GhostOf(user : string) : CActor
    {
        var players : array<r_RemotePlayer>;
        var i : int;

        players = theGame.r_getMultiplayerClient().getPlayers();
        for(i = 0; i < players.Size(); i += 1)
        {
            if(players[i] && players[i].username == user)
            {
                return players[i].ghost;
            }
        }
        return NULL;
    }

    // Party members' ghosts join the player's attitude group and become gameplay-visible, so this game's
    // monsters attack them as they would the leader (they stay invulnerable). Undone when they leave.
    private function ArmGhosts(client : r_MultiplayerClient)
    {
        var players : array<r_RemotePlayer>;
        var wanted : array<CActor>;
        var ghost : CActor;
        var i : int;

        players = client.getPlayers();
        for(i = 0; i < players.Size(); i += 1)
        {
            if(players[i] && players[i].ghost && IsMyPartyMember(players[i].username))
            {
                wanted.PushBack(players[i].ghost);
            }
        }

        for(i = armedGhosts.Size() - 1; i >= 0; i -= 1)
        {
            if(!wanted.Contains(armedGhosts[i]))
            {
                Disarm(armedGhosts[i]);
                armedGhosts.Erase(i);
            }
        }

        for(i = 0; i < wanted.Size(); i += 1)
        {
            ghost = wanted[i];
            if(!armedGhosts.Contains(ghost))
            {
                ghost.SetTemporaryAttitudeGroup(thePlayer.GetAttitudeGroup(), AGP_Default);
                armedGhosts.PushBack(ghost);
            }
            // Witcher Online hides ghosts from gameplay again in some states (e.g. mounting)
            ghost.SetGameplayVisibility(true);
        }
    }

    // a member: the leader's character too, so that puppets can go for it when their own AI plays the leader's monster's
    // attacks on the leader (PlayAttack)
    private function ArmLeaderGhost()
    {
        var ghost : CActor;

        ghost = GhostOf(leaderName);
        if(!ghost)
        {
            return;
        }
        if(!armedGhosts.Contains(ghost))
        {
            ghost.SetTemporaryAttitudeGroup(thePlayer.GetAttitudeGroup(), AGP_Default);
            armedGhosts.PushBack(ghost);
        }
        ghost.SetGameplayVisibility(true);
    }

    private function Disarm(ghost : CActor)
    {
        if(ghost)
        {
            ghost.SetTemporaryAttitudeGroup('friendly_to_player', AGP_Default);
            ghost.SetGameplayVisibility(false);
        }
    }

    private function DisarmGhosts()
    {
        var i : int;

        for(i = 0; i < armedGhosts.Size(); i += 1)
        {
            Disarm(armedGhosts[i]);
        }
        armedGhosts.Clear();
    }

    private function GhostOwner(ghost : CActor) : string
    {
        var players : array<r_RemotePlayer>;
        var i : int;

        players = theGame.r_getMultiplayerClient().getPlayers();
        for(i = 0; i < players.Size(); i += 1)
        {
            if(players[i] && players[i].ghost == ghost && IsMyPartyMember(players[i].username))
            {
                return players[i].username;
            }
        }
        return "";
    }

    // Called for every damage action before it is processed; true drops it. On the leader, a shared
    // monster's hit on a member's ghost is recorded for that member, and ghosts' own AI deals no damage
    // (members' hits arrive as claims instead).
    public function OnBeforeDamage(act : W3DamageAction) : bool
    {
        var attacker, victim : CActor;
        var e : r_CoopHostEnemy;
        var user : string;

        attacker = (CActor)act.attacker;
        victim = (CActor)act.victim;

        // the projectiles and attack objects copied here for the leader's monsters never hurt (some name no attacker)
        if(act.causer && ((CEntity)act.causer).HasTag('W3CoopMirror'))
        {
            mirrorDamageDropped += 1;
            return true;
        }
        // a member's puppets only hurt it through the leader's hits
        if((CNewNPC)attacker && IsPuppet((CNewNPC)attacker) && act.GetBuffSourceName() != "W3CoopHurt")
        {
            return true;
        }

        if(!wasHost)
        {
            return false;
        }
        // ...and effects applied for a member's hit (burning) tick only in the member's world, which claims them
        if(attacker && attacker.HasTag('MPEntity') && (act.GetBuffSourceName() != "W3Coop" || act.IsDoTDamage()))
        {
            return true;
        }

        if(victim && victim.HasTag('MPEntity') && !act.IsDoTDamage())
        {
            ghostHitsSeen += 1;
            e = FindHostEnemyByNpc((CNewNPC)attacker);
            if(!e)
            {
                // a projectile's own damage (the leshen's crows name no attacker): the monster that fired it
                e = FindHostEnemyByNpc(ProjectileCaster(act.causer));
            }
            user = GhostOwner(victim);
            if(e && user != "")
            {
                QueueHurt(user, e, act);
            }
        }
        return false;
    }

    private function QueueHurt(user : string, e : r_CoopHostEnemy, act : W3DamageAction)
    {
        var dts : array<SRawDamage>;
        var effects : array<EEffectType>;
        var h : r_CoopHurt;
        var i : int;

        h = new r_CoopHurt in this;
        act.GetEffectTypes(effects);
        for(i = 0; i < effects.Size(); i += 1)
        {
            h.effects.PushBack((int)effects[i]);
        }
        act.GetDTs(dts);
        for(i = 0; i < dts.Size(); i += 1)
        {
            if(dts[i].dmgVal > 0)
            {
                h.types.PushBack(dts[i].dmgType);
                h.values.PushBack(dts[i].dmgVal);
            }
        }
        if(h.types.Size() == 0)
        {
            return;
        }

        h.user = user;
        h.seq = nextHurtSeq;
        h.netId = e.netId;
        h.hitReaction = (int)act.GetHitReactionType();
        h.attackSeq = e.attackSeq;
        h.hitAnimTime = e.hitAnimTime;
        nextHurtSeq += 1;
        hurts.PushBack(h);
        if(hurts.Size() > 16)
        {
            hurts.Erase(0);
        }
        hurtsCaptured += 1;
        lastHurtSend = -999;
    }

    private function PruneHurts(user : string, lastSeq : int)
    {
        var i : int;

        for(i = hurts.Size() - 1; i >= 0; i -= 1)
        {
            if(hurts[i].user == user && hurts[i].seq <= lastSeq)
            {
                hurts.Erase(i);
            }
        }
    }

    // "hurt epoch count {user seq netId hitReaction attackSeq hitAnimTime types {type value} effects {type}}": every
    // hurt not yet acknowledged
    private function SendHurts(now : float)
    {
        var text : string;
        var h : r_CoopHurt;
        var i, j : int;

        if((hurts.Size() == 0 && lastHurtSentCount == 0) || now - lastHurtSend < 0.1)
        {
            return;
        }

        text = "coop hurt " + epoch + " " + hurts.Size();
        for(i = 0; i < hurts.Size(); i += 1)
        {
            h = hurts[i];
            text += " " + h.user + " " + h.seq + " " + h.netId + " " + h.hitReaction + " " + h.attackSeq
                + " " + FloatToStringPrec(h.hitAnimTime, 2) + " " + h.types.Size();
            for(j = 0; j < h.types.Size(); j += 1)
            {
                text += " " + NameToString(h.types[j]) + " " + FloatToStringPrec(h.values[j], 2);
            }
            text += " " + h.effects.Size();
            for(j = 0; j < h.effects.Size(); j += 1)
            {
                text += " " + h.effects[j];
            }
        }
        WO_Send(text);
        lastHurtSend = now;
        lastHurtSentCount = hurts.Size();
    }

    // A shared monster started (AET_DurationStart) or finished (AET_DurationEnd, where the hit is processed) an
    // attack's hit window. Members replay the animation on its puppet.
    public function OnEnemyAttack(npc : CNewNPC, eventType : EAnimationEventType, animInfo : SAnimationEventAnimInfo)
    {
        var e : r_CoopHostEnemy;
        var p : r_CoopPuppet;

        if(!wasHost)
        {
            // a member: the attack animation really plays on the puppet (its own attack events fire), soon after the
            // leader's attack was mirrored (an attack started late in the 1.1 s window reaches its hit window up to a
            // second later); any other is an attack of the puppet's own AI
            p = FindPuppetByNpc(npc);
            if(eventType == AET_DurationStart && p && theGame.GetEngineTimeAsSeconds() - p.attackPlayedAt < 2.5)
            {
                puppetAttackEvents += 1;
                if(npc.GetTarget() != p.attackActor)
                {
                    puppetWrongTargets += 1;
                }
            }
            else if(eventType == AET_DurationStart && p)
            {
                puppetOwnAttacks += 1;
            }
            return;
        }
        e = FindHostEnemyByNpc(npc);
        if(!e)
        {
            return;
        }

        if(eventType == AET_DurationStart)
        {
            e.attackSeq += 1;
            e.attackAnim = GetAnimNameFromEventAnimInfo(animInfo);
            // the target can be momentarily unset: then still the last player it went for
            if(UserOf(npc.GetTarget()) != "")
            {
                e.attackTarget = UserOf(npc.GetTarget());
            }
            e.hitAnimTime = GetLocalAnimTimeFromEventAnimInfo(animInfo);
            attacksSeen += 1;
            lastHostSend = -999;  // send it now, not on the next 100 ms tick
        }
        else if(eventType == AET_DurationEnd)
        {
            e.hitAnimTime = GetLocalAnimTimeFromEventAnimInfo(animInfo);
        }
    }

    // One of its other animated moves (a behavior-tree task that plays an animation: dodge, jump back, taunt,
    // shot, ...); every animation event of it arrives here, a new one is a new name or a restart.
    // A shared monster shot a projectile (arrow, bolt, spit, boulder, ...).
    public function OnEnemyProjectile(proj : CProjectileTrajectory, angle : float, speed : float, target : Vector, range : float)
    {
        var e : r_CoopHostEnemy;

        if(!wasHost || !proj)
        {
            return;
        }
        e = FindHostEnemyByNpc((CNewNPC)proj.caster);
        if(!e)
        {
            return;
        }
        e.projSeq += 1;
        e.projAt = theGame.GetEngineTimeAsSeconds();
        e.projTemplate = proj.GetReadableName();
        e.projFrom = proj.GetWorldPosition();
        e.projTo = target;
        e.projAngle = angle;
        e.projSpeed = speed;
        e.projRange = range;
        projectilesSeen += 1;
        lastHostSend = -999;
    }

    public function OnEnemyMove(npc : CNewNPC, animInfo : SAnimationEventAnimInfo)
    {
        var e : r_CoopHostEnemy;
        var anim : name;
        var t : float;

        if(!wasHost)
        {
            return;
        }
        e = FindHostEnemyByNpc(npc);
        anim = GetAnimNameFromEventAnimInfo(animInfo);
        if(!e || !IsNameValid(anim))
        {
            return;
        }
        t = GetLocalAnimTimeFromEventAnimInfo(animInfo);
        if(anim == e.moveAnim && t >= e.moveAnimTime)
        {
            e.moveAnimTime = t;
            return;
        }
        e.moveSeq += 1;
        e.moveAnim = anim;
        e.moveAnimTime = t;
        movesSeen += 1;
        lastMoveAnim = anim;
        lastHostSend = -999;
    }

    // A shared monster took damage here: members replay the hit reaction on its puppet (the hitter's own game
    // already played it).
    public function OnEnemyDamaged(npc : CNewNPC, action : W3DamageAction)
    {
        var e : r_CoopHostEnemy;
        var attacker : CActor;

        if(!wasHost || !action.DealsAnyDamage() || action.IsDoTDamage())
        {
            return;
        }
        e = FindHostEnemyByNpc(npc);
        if(!e)
        {
            return;
        }

        attacker = (CActor)action.attacker;
        e.hitBy = "";
        if(attacker == thePlayer)
        {
            e.hitBy = theGame.r_getMultiplayerClient().getUsername();
        }
        else if(attacker && attacker.HasTag('MPEntity'))
        {
            e.hitBy = GhostOwner(attacker);
        }
        e.hitSeq += 1;
        e.hitReaction = (int)action.GetHitReactionType();
        lastHostSend = -999;
    }

    public function PendingHurtCount() : int
    {
        return hurts.Size();
    }

    // ---------------------------------------------------------------- member

    // inbound COOP message from the client's pump; fields are read with WO_Str
    public function OnMessage()
    {
        var client : r_MultiplayerClient;
        var sender : string;
        var count : int;

        client = theGame.r_getMultiplayerClient();
        sender = WO_Str(-1);
        count = StringToInt(WO_Str(-3), 0);
        if(!client || sender == client.getUsername() || count < 1)
        {
            return;
        }

        EnsureIds();
        if(WO_Str(0) == "en")
        {
            OnSnapshot(sender, count);
        }
        else if(WO_Str(0) == "hit")
        {
            OnHits(sender, count);
        }
        else if(WO_Str(0) == "hurt")
        {
            OnHurts(sender, count);
        }
        else if(WO_Str(0) == "jr")
        {
            OnJournal(sender, count);
        }
        else if(WO_Str(0) == "fx")
        {
            OnFacts(sender, count);
        }
    }

    private function OnSnapshot(sender : string, count : int)
    {
        var templates : array<string>;
        var seen : array<int>;
        var pos : Vector;
        var attackAnim, moveAnim : name;
        var hitBy, projTpl, attackTarget : string;
        var snapshotEpoch, n, i, idx, netId, tplIndex, attackSeq, hitSeq, hitReaction, moveSeq, projSeq, projIndex, stance, immortality, states : int;
        var objSeq, objCount, objIndex, j : int;
        var objTpls : array<string>;
        var objPositions : array<Vector>;
        var objYaws : array<float>;
        var hp, yaw, projAngle, projSpeed, projRange : float;
        var projFrom, projTo : Vector;
        var alive, untargetable : bool;
        var app : string;

        if(GetRole() != 2 || sender != leaderName || count < 4)
        {
            return;
        }

        if(StringToInt(WO_Str(3), 0) != WO_CurrentAreaCode() || !LeaderNear())
        {
            ReleaseAll();
            return;
        }

        snapshotEpoch = StringToInt(WO_Str(1), 0);
        if(snapshotEpoch != leaderEpoch)
        {
            // the leader restarted: its enemy ids and hit acknowledgements start over
            ReleaseAll();
            pendingHits.Clear();
            hurtAck = 0;
            leaderEpoch = snapshotEpoch;
        }
        lastSnapshotAt = theGame.GetEngineTimeAsSeconds();

        idx = 4;
        n = StringToInt(WO_Str(idx), 0);
        idx += 1;
        for(i = 0; i < n && idx + 2 < count; i += 1)
        {
            if(WO_Str(idx) == theGame.r_getMultiplayerClient().getUsername() && StringToInt(WO_Str(idx + 1), 0) == session)
            {
                PruneHits(StringToInt(WO_Str(idx + 2), 0));
            }
            idx += 3;
        }

        n = StringToInt(WO_Str(idx), 0);
        idx += 1;
        for(i = 0; i < n && idx < count; i += 1)
        {
            templates.PushBack(CoopDecode(WO_Str(idx)));
            idx += 1;
        }

        n = StringToInt(WO_Str(idx), 0);
        idx += 1;
        for(i = 0; i < n && idx + 20 < count; i += 1)
        {
            netId = StringToInt(WO_Str(idx), 0);
            tplIndex = StringToInt(WO_Str(idx + 1), 0);
            app = CoopDecode(WO_Str(idx + 2));
            pos.X = StringToFloat(WO_Str(idx + 3), 0);
            pos.Y = StringToFloat(WO_Str(idx + 4), 0);
            pos.Z = StringToFloat(WO_Str(idx + 5), 0);
            pos.W = 1;
            yaw = StringToFloat(WO_Str(idx + 6), 0);
            hp = StringToFloat(WO_Str(idx + 7), 0);
            alive = WO_Str(idx + 8) == "1";
            attackSeq = StringToInt(WO_Str(idx + 9), 0);
            attackAnim = '';
            if(WO_Str(idx + 10) != "-")
            {
                attackAnim = WO_NameAt(idx + 10);
            }
            hitSeq = StringToInt(WO_Str(idx + 11), 0);
            hitBy = CoopDecode(WO_Str(idx + 12));
            hitReaction = StringToInt(WO_Str(idx + 13), 0);
            moveSeq = StringToInt(WO_Str(idx + 14), 0);
            moveAnim = '';
            if(WO_Str(idx + 15) != "-")
            {
                moveAnim = WO_NameAt(idx + 15);
            }
            attackTarget = CoopDecode(WO_Str(idx + 16));
            stance = StringToInt(WO_Str(idx + 17), 0);
            immortality = StringToInt(WO_Str(idx + 18), 0);
            untargetable = WO_Str(idx + 19) == "1";
            states = StringToInt(WO_Str(idx + 20), 0);
            idx += 21;
            projSeq = StringToInt(WO_Str(idx), 0);
            idx += 1;
            projTpl = "";
            if(projSeq != 0)
            {
                if(idx + 9 >= count)
                {
                    break;
                }
                projIndex = StringToInt(WO_Str(idx), 0);
                if(projIndex >= 0 && projIndex < templates.Size())
                {
                    projTpl = templates[projIndex];
                }
                projFrom = Vector(StringToFloat(WO_Str(idx + 1), 0), StringToFloat(WO_Str(idx + 2), 0), StringToFloat(WO_Str(idx + 3), 0));
                projTo = Vector(StringToFloat(WO_Str(idx + 4), 0), StringToFloat(WO_Str(idx + 5), 0), StringToFloat(WO_Str(idx + 6), 0));
                projAngle = StringToFloat(WO_Str(idx + 7), 0);
                projSpeed = StringToFloat(WO_Str(idx + 8), 0);
                projRange = StringToFloat(WO_Str(idx + 9), 0);
                idx += 10;
            }
            if(idx + 1 >= count)
            {
                break;
            }
            objSeq = StringToInt(WO_Str(idx), 0);
            objCount = StringToInt(WO_Str(idx + 1), 0);
            idx += 2;
            objTpls.Clear();
            objPositions.Clear();
            objYaws.Clear();
            for(j = 0; j < objCount && idx + 4 < count; j += 1)
            {
                objIndex = StringToInt(WO_Str(idx), 0);
                if(objIndex >= 0 && objIndex < templates.Size())
                {
                    objTpls.PushBack(templates[objIndex]);
                    objPositions.PushBack(Vector(StringToFloat(WO_Str(idx + 1), 0), StringToFloat(WO_Str(idx + 2), 0), StringToFloat(WO_Str(idx + 3), 0), 1));
                    objYaws.PushBack(StringToFloat(WO_Str(idx + 4), 0));
                }
                idx += 5;
            }

            if(tplIndex >= 0 && tplIndex < templates.Size())
            {
                ApplyEnemy(netId, templates[tplIndex], app, pos, yaw, hp, alive, attackSeq, attackAnim, hitSeq, hitBy, hitReaction,
                    moveSeq, moveAnim, attackTarget, stance, immortality, untargetable, states);
                if(projSeq != 0 && projTpl != "")
                {
                    ApplyProjectile(netId, projSeq, projTpl, projFrom, projTo, projAngle, projSpeed, projRange);
                }
                if(objSeq != 0 && objTpls.Size() > 0)
                {
                    ApplyObjects(netId, objSeq, objTpls, objPositions, objYaws);
                }
                seen.PushBack(netId);
            }
        }

        for(i = puppets.Size() - 1; i >= 0; i -= 1)
        {
            if(!seen.Contains(puppets[i].netId))
            {
                ReleasePuppet(puppets[i]);
                puppets.Erase(i);
            }
        }

        SuppressUnmatched();
    }

    private function OnHurts(sender : string, count : int)
    {
        var me, user : string;
        var listed : bool;
        var h : r_CoopHurt;
        var p : r_CoopPuppet;
        var now : float;
        var n, i, j, idx, seq, typeCount, effectCount, effectsAt : int;

        if(GetRole() != 2 || sender != leaderName || leaderEpoch == 0 || count < 3 || StringToInt(WO_Str(1), 0) != leaderEpoch)
        {
            return;
        }

        me = theGame.r_getMultiplayerClient().getUsername();
        now = theGame.GetEngineTimeAsSeconds();
        n = StringToInt(WO_Str(2), 0);
        idx = 3;
        for(i = 0; i < n && idx + 6 < count; i += 1)
        {
            user = WO_Str(idx);
            seq = StringToInt(WO_Str(idx + 1), 0);
            typeCount = StringToInt(WO_Str(idx + 6), 0);
            effectsAt = idx + 7 + typeCount * 2;
            if(effectsAt >= count)
            {
                break;
            }
            effectCount = StringToInt(WO_Str(effectsAt), 0);
            if(effectsAt + 1 + effectCount > count)
            {
                break;
            }
            if(user == me)
            {
                listed = true;
                if(seq > hurtAck)
                {
                    h = new r_CoopHurt in this;
                    h.seq = seq;
                    h.netId = StringToInt(WO_Str(idx + 2), 0);
                    h.hitReaction = StringToInt(WO_Str(idx + 3), 0);
                    h.attackSeq = StringToInt(WO_Str(idx + 4), 0);
                    h.hitAnimTime = StringToFloat(WO_Str(idx + 5), 0);
                    for(j = 0; j < typeCount; j += 1)
                    {
                        h.types.PushBack(WO_NameAt(idx + 7 + j * 2));
                        h.values.PushBack(StringToFloat(WO_Str(idx + 8 + j * 2), 0));
                    }
                    for(j = 0; j < effectCount; j += 1)
                    {
                        h.effects.PushBack(StringToInt(WO_Str(effectsAt + 1 + j), 0));
                    }

                    // land it when this world's copy of the swing reaches the hit (immediately if this world
                    // missed that attack); a dodge before then avoids it
                    h.receivedAt = now;
                    h.due = now;
                    p = FindPuppet(h.netId);
                    if(p && p.alive && p.attackSeq == h.attackSeq && p.attackPlayedAt > 0)
                    {
                        h.due = MaxF(now, p.attackPlayedAt + MinF(h.hitAnimTime, 1.5));
                    }
                    delayedHurts.PushBack(h);
                    hurtAck = seq;
                }
            }
            idx = effectsAt + 1 + effectCount;
        }
        leaderListsMyHurts = listed;
    }

    private function ApplyDueHurts(now : float)
    {
        var i : int;

        for(i = 0; i < delayedHurts.Size(); i += 1)
        {
            if(delayedHurts[i].due <= now)
            {
                lastHurtDelay = now - delayedHurts[i].receivedAt;
                ApplyHurt(delayedHurts[i]);
                delayedHurts.Erase(i);
                i -= 1;
            }
        }
    }

    // The leader's monster hit this player's ghost: apply its raw damage here, with the monster's local copy
    // as attacker, so this game's armor, Quen and difficulty count. A hit landing mid-dodge misses.
    private function ApplyHurt(h : r_CoopHurt)
    {
        var action : W3DamageAction;
        var p : r_CoopPuppet;
        var attacker : CActor;
        var before : float;
        var i : int;

        if(thePlayer.IsCurrentlyDodging())
        {
            hurtsDodged += 1;
            return;
        }

        p = FindPuppet(h.netId);
        if(p && p.alive)
        {
            attacker = p.npc;
        }

        action = new W3DamageAction in theGame.damageMgr;
        action.Initialize(attacker, thePlayer, theGame, "W3CoopHurt", (EHitReactionType)h.hitReaction, CPS_AttackPower, true, false, false, false);
        for(i = 0; i < h.types.Size(); i += 1)
        {
            action.AddDamage(h.types[i], h.values[i]);
        }
        // the monster's buffs; this game's immunities and resistances decide whether they take hold
        for(i = 0; i < h.effects.Size(); i += 1)
        {
            action.AddEffectInfo((EEffectType)h.effects[i]);
        }
        hurtEffectsApplied += h.effects.Size();
        before = thePlayer.GetStat(BCS_Vitality);
        theGame.damageMgr.ProcessAction(action);
        delete action;
        hurtDamageTaken += MaxF(0, before - thePlayer.GetStat(BCS_Vitality));
        hurtsApplied += 1;
    }

    private function ApplyEnemy(netId : int, tpl : string, app : string, pos : Vector, yaw : float, hp : float, alive : bool,
        attackSeq : int, attackAnim : name, hitSeq : int, hitBy : string, hitReaction : int, moveSeq : int, moveAnim : name,
        attackTarget : string, stance : int, immortality : int, untargetable : bool, states : int)
    {
        var p : r_CoopPuppet;
        var npc : CNewNPC;
        var spawned : bool;
        var now : float;

        now = theGame.GetEngineTimeAsSeconds();
        p = FindPuppet(netId);
        if(!p)
        {
            if(!alive || VecDistance(thePlayer.GetWorldPosition(), pos) > 70)
            {
                return;
            }

            npc = FindTwin(tpl, pos);
            if(npc)
            {
                twinsBound += 1;
            }
            else
            {
                npc = SpawnPuppet(tpl, app, pos, yaw);
                spawned = true;
            }
            if(!npc)
            {
                return;
            }
            p = MakePuppet(npc, netId, spawned);
            p.attackSeq = attackSeq;  // don't replay an attack, move or hit from before this puppet existed
            p.hitSeq = hitSeq;
            p.moveSeq = moveSeq;
        }

        // hits by others (this player's own hits already reacted here)
        if(hitSeq != p.hitSeq)
        {
            p.hitSeq = hitSeq;
            if(p.alive && hitBy != "" && hitBy != theGame.r_getMultiplayerClient().getUsername())
            {
                MirrorHit(p, hitBy, hitReaction);
            }
        }

        if(attackSeq != p.attackSeq)
        {
            p.attackSeq = attackSeq;
            if(p.alive && IsNameValid(attackAnim))
            {
                PlayAttack(p, attackAnim, attackTarget);
            }
        }

        // the newest of its attacks and moves plays, as on the leader
        if(moveSeq != p.moveSeq)
        {
            p.moveSeq = moveSeq;
            if(p.alive && IsNameValid(moveAnim))
            {
                PlayMove(p, moveAnim);
            }
        }

        if(p.alive)
        {
            ApplyStates(p, immortality, untargetable, states);
        }

        // flying or on the ground as the leader's (before the move: in flight it is not pulled down to the ground)
        if(p.alive && (stance == (int)NS_Fly) != p.flying)
        {
            SetPuppetFlying(p, stance == (int)NS_Fly);
        }

        if(p.lastTargetAt > 0 && now - p.lastTargetAt > 0.02)
        {
            p.targetSpeed = 0.5 * p.targetSpeed + 0.5 * VecDistance2D(pos, p.target) / (now - p.lastTargetAt);
        }
        p.lastTargetAt = now;
        p.target = pos;
        p.yaw = yaw;
        // after a local hit the leader's health arrives a moment later; don't flash back up meanwhile
        if(now >= p.predictUntil || hp < p.hp)
        {
            p.hp = hp;
        }

        if(!alive && p.alive)
        {
            KillPuppet(p);
        }
    }

    private function FindTwin(tpl : string, pos : Vector) : CNewNPC
    {
        var entities : array<CGameplayEntity>;
        var npc, best : CNewNPC;
        var dist, bestDist : float;
        var i : int;

        bestDist = 10.0;
        FindGameplayEntitiesInSphere(entities, pos, 10.0, 32, '', FLAG_OnlyAliveActors, thePlayer);
        for(i = 0; i < entities.Size(); i += 1)
        {
            npc = (CNewNPC)entities[i];
            if(!npc || npc.HasTag('MPEntity') || IsPuppet(npc) || npc.GetReadableName() != tpl)
            {
                continue;
            }
            dist = VecDistance(npc.GetWorldPosition(), pos);
            if(dist < bestDist)
            {
                bestDist = dist;
                best = npc;
            }
        }

        if(best)
        {
            Unsuppress(best);
        }
        return best;
    }

    private function SpawnPuppet(tpl : string, app : string, pos : Vector, yaw : float) : CNewNPC
    {
        var template : CEntityTemplate;
        var ent : CEntity;
        var npc : CNewNPC;
        var rot : EulerAngles;

        template = (CEntityTemplate)LoadResource(tpl, true);
        if(!template)
        {
            spawnFailures += 1;
            lastError = "no template '" + tpl + "'";
            return NULL;
        }

        rot.Yaw = yaw;
        ent = theGame.CreateEntity(template, pos, rot, true, false, false, PM_DontPersist);
        npc = (CNewNPC)ent;
        if(!npc)
        {
            if(ent)
            {
                ent.Destroy();
            }
            spawnFailures += 1;
            lastError = "'" + tpl + "' did not spawn an NPC";
            return NULL;
        }

        if(app != "")
        {
            npc.ApplyAppearance(app);
        }
        puppetsSpawned += 1;
        return npc;
    }

    private function MakePuppet(npc : CNewNPC, netId : int, spawned : bool) : r_CoopPuppet
    {
        var p : r_CoopPuppet;

        p = new r_CoopPuppet in this;
        p.npc = npc;
        p.netId = netId;
        p.spawned = spawned;
        p.alive = true;
        p.hp = npc.GetHealthPercents();
        p.target = npc.GetWorldPosition();
        p.yaw = npc.GetHeading();
        p.aiId = ForceIdle(npc);
        // a finisher would kill it here, outside the leader's say ('DisableFinishers' blocks the killing-blow
        // finisher, 'DisableFinisher' the one on a living target)
        BlockFinisher(p, 'DisableFinishers');
        BlockFinisher(p, 'DisableFinisher');
        puppets.PushBack(p);
        return p;
    }

    // Replays another player's hit on a puppet through the damage manager with a negligible damage, so the
    // vanilla reaction path runs (the leader's health is restored right after).
    // The forced idle tree swallows hit reactions; lift it briefly so the monster's own AI plays one. Its
    // attacks in that time do no damage here (OnBeforeDamage drops a puppet's own damage).
    private function OpenReactionWindow(p : r_CoopPuppet)
    {
        if(p.aiId != 0)
        {
            p.npc.CancelAIBehavior(p.aiId);
            p.aiId = 0;
        }
        p.reactUntil = theGame.GetEngineTimeAsSeconds() + 0.8;
    }

    private function MirrorHit(p : r_CoopPuppet, hitBy : string, hitReaction : int)
    {
        var action : W3DamageAction;

        OpenReactionWindow(p);

        action = new W3DamageAction in theGame.damageMgr;
        action.Initialize(GhostOf(hitBy), p.npc, theGame, "W3CoopHitFx", (EHitReactionType)hitReaction, CPS_Undefined, true, false, false, false);
        action.AddDamage(theGame.params.DAMAGE_NAME_DIRECT, COOP_FX_DAMAGE());
        action.SetCannotReturnDamage(true);
        applyingHostState = true;
        theGame.damageMgr.ProcessAction(action);
        applyingHostState = false;
        delete action;
        hitReactionsMirrored += 1;
    }

    private function BlockFinisher(p : r_CoopPuppet, ability : name)
    {
        if(!p.npc.HasAbility(ability))
        {
            p.npc.AddAbility(ability, false);
            p.addedNoFinishers.PushBack(ability);
        }
    }

    // The puppet's own AI attacks the player the leader's monster attacks (this game's Geralt, or that player's character
    // here): its idle tree is off for the attack and it notices that player. The leader's exact animation can't be
    // played: as a slot animation it is accepted and never runs (a monster's graph plays attacks only from combat), and
    // the graph refuses the attack event out of combat. A puppet's own hits do no damage (OnBeforeDamage).
    private function PlayAttack(p : r_CoopPuppet, anim : name, target : string)
    {
        var actor : CActor;

        p.attackPlayedAt = theGame.GetEngineTimeAsSeconds();
        if(target == theGame.r_getMultiplayerClient().getUsername())
        {
            actor = thePlayer;
        }
        else
        {
            actor = GhostOf(target);
        }
        if(!actor)
        {
            // not attacking a player (yet), or that player's character isn't spawned here
            return;
        }
        if(p.aiId != 0)
        {
            p.npc.CancelAIBehavior(p.aiId);
            p.aiId = 0;
        }
        if(p.animAiId != 0)
        {
            p.npc.CancelAIBehavior(p.animAiId);
            p.animAiId = 0;
        }
        // long enough to start an attack, short enough not to start a second
        p.reactUntil = MaxF(p.reactUntil, p.attackPlayedAt + 1.1);
        p.attackActor = actor;
        p.npc.SetAttitude(actor, AIA_Hostile);
        // its AI keeps the first hostile it noticed (often this player): it has to forget the others to switch
        if(p.npc.GetTarget() != actor)
        {
            p.npc.ForgetAllActors();
        }
        p.npc.NoticeActor(actor);
        attacksPlayed += 1;
    }

    // A shared monster's attack spawned an object (the spriggan's roots, a giant's ground trail, ice ...): kept 1.5 s for
    // members to spawn a harmless copy. Actors are left out: a summoned monster is shared as an enemy of its own.
    public function OnEnemyObject(npc : CNewNPC, entity : CEntity)
    {
        var e : r_CoopHostEnemy;

        if(!wasHost || !entity || (CActor)entity)
        {
            return;
        }
        e = FindHostEnemyByNpc(npc);
        if(!e)
        {
            return;
        }
        e.objSeq += 1;
        e.objTemplates.PushBack(entity.GetReadableName());
        e.objPositions.PushBack(entity.GetWorldPosition());
        e.objYaws.PushBack(entity.GetHeading());
        e.objTimes.PushBack(theGame.GetEngineTimeAsSeconds());
        TrimObjects(e, theGame.GetEngineTimeAsSeconds());
        objectsSeen += 1;
    }

    // Only the last 4 objects of the last 1.5 s.
    private function TrimObjects(e : r_CoopHostEnemy, now : float)
    {
        while(e.objTimes.Size() > 4 || (e.objTimes.Size() > 0 && now - e.objTimes[0] > 1.5))
        {
            e.objTemplates.Erase(0);
            e.objPositions.Erase(0);
            e.objYaws.Erase(0);
            e.objTimes.Erase(0);
        }
    }

    // The leader's monster's attack objects not spawned here yet: harmless copies where the leader's are (tagged, their
    // damage never counts here; a damage area's owner is this world's puppet, whose damage is dropped too). The
    // leader's real ones hurt this player through hurts.
    private function ApplyObjects(netId : int, seq : int, tpls : array<string>, positions : array<Vector>, yaws : array<float>)
    {
        var p : r_CoopPuppet;
        var template : CEntityTemplate;
        var ent : CEntity;
        var area : CDamageAreaEntity;
        var tags : array<name>;
        var rot : EulerAngles;
        var first, i : int;

        p = FindPuppet(netId);
        if(!p || seq <= p.objSeq)
        {
            return;
        }
        first = seq - tpls.Size() + 1;
        for(i = 0; i < tpls.Size() && p.alive; i += 1)
        {
            if(first + i <= p.objSeq)
            {
                continue;
            }
            template = (CEntityTemplate)LoadResource(tpls[i], true);
            if(!template)
            {
                objectFailures += 1;
                lastError = "object '" + tpls[i] + "' could not be loaded";
                continue;
            }
            tags.Clear();
            tags.PushBack('W3CoopMirror');
            rot.Yaw = yaws[i];
            ent = theGame.CreateEntity(template, positions[i], rot, true, false, false, PM_DontPersist, tags);
            if(!ent)
            {
                objectFailures += 1;
                lastError = "object '" + tpls[i] + "' could not be spawned";
                continue;
            }
            area = (CDamageAreaEntity)ent;
            if(area)
            {
                area.owner = p.npc;
            }
            // they end by themselves; a copy left behind would stay
            ent.DestroyAfter(20);
            objectsSpawned += 1;
        }
        p.objSeq = seq;
    }

    // The leader's monster fired a projectile (in the last 1.5 s): a harmless copy flies from this world's puppet
    // (the hit itself arrives as a hurt, and a puppet's own damage is dropped anyway).
    private function ApplyProjectile(netId : int, seq : int, tpl : string, from : Vector, to : Vector, angle : float, speed : float,
        range : float)
    {
        var p : r_CoopPuppet;
        var template : CEntityTemplate;
        var ent : CEntity;
        var proj : W3AdvancedProjectile;
        var trajectory : CProjectileTrajectory;
        var tags : array<name>;

        p = FindPuppet(netId);
        if(!p || seq == p.projSeq)
        {
            return;
        }
        p.projSeq = seq;
        if(!p.alive)
        {
            return;
        }
        template = (CEntityTemplate)LoadResource(tpl, true);
        if(template)
        {
            // tagged: its damage here never counts (OnBeforeDamage)
            tags.PushBack('W3CoopMirror');
            ent = theGame.CreateEntity(template, from, VecToRotation(to - from), true, false, false, PM_DontPersist, tags);
        }
        proj = (W3AdvancedProjectile)ent;
        trajectory = (CProjectileTrajectory)ent;
        if(!proj && trajectory)
        {
            // a monster's own projectile class (the leshen's roots and crows): fired as the monster's task fires it
            trajectory.Init(p.npc);
            trajectory.ShootProjectileAtPosition(angle, speed, to, range);
            if((W3LeshyRootProjectile)trajectory)
            {
                trajectory.PlayEffect('ground_fx');
            }
            projectilesFired += 1;
            return;
        }
        if(!proj)
        {
            if(ent)
            {
                ent.Destroy();
            }
            projectileFailures += 1;
            lastError = "projectile '" + tpl + "' could not be fired";
            return;
        }
        proj.Init(p.npc);
        proj.projDMG = 0;
        proj.projSilverDMG = 0;
        proj.projEfect = EET_Undefined;
        proj.ShootProjectileAtPosition(angle, speed, to, range);
        projectilesFired += 1;
    }

    // KNOWN LIMIT: the slot animation is accepted but does not play on a monster's graph out of combat (see PlayAttack),
    // so dodges, taunts and jump-backs don't show on puppets yet. Warning the puppet of an attack (as the game does for
    // dodges) with its AI free didn't make it dodge either. enemy_moves fails on it (puppetDodgesSeen).
    private function PlayMove(p : r_CoopPuppet, anim : name)
    {
        if(StrFindFirst(NameToString(anim), "dodge") >= 0)
        {
            dodgesMirrored += 1;
        }
        if(PlaySlotAnim(p, anim))
        {
            movesPlayed += 1;
        }
        else
        {
            movePlayFailures += 1;
            lastError = "move animation '" + NameToString(anim) + "' did not play";
        }
    }

    private function PlaySlotAnim(p : r_CoopPuppet, anim : name) : bool
    {
        var action : CAIPlayAnimationSlotAction;

        p.slotAnimAt = theGame.GetEngineTimeAsSeconds();
        if(p.animAiId != 0)
        {
            p.npc.CancelAIBehavior(p.animAiId);
        }
        action = new CAIPlayAnimationSlotAction in p.npc;
        action.OnCreated();
        action.animName = anim;
        action.slotName = 'NPC_ANIM_SLOT';
        action.blendInTime = 0.1;
        action.blendOutTime = 0.2;
        p.animAiId = p.npc.ForceAIBehavior(action, BTAP_Emergency);
        return p.animAiId != 0;
    }

    // within sharing range of the leader, in the same area
    private function LeaderNear() : bool
    {
        var globals : array<r_RemotePlayer>;
        var i : int;

        globals = theGame.r_getMultiplayerClient().getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1)
        {
            if(globals[i] && globals[i].username == leaderName)
            {
                return globals[i].area == WO_CurrentAreaCode()
                    && VecDistance(globals[i].pos, thePlayer.GetWorldPosition()) <= COOP_SHARE_RANGE();
            }
        }
        return false;
    }

    private function ForceIdle(npc : CNewNPC) : int
    {
        var tree : CAIDoNothingAction;

        tree = new CAIDoNothingAction in npc;
        tree.OnCreated();
        return npc.ForceAIBehavior(tree, BTAP_AboveCombat);
    }

    private function UpdatePuppets(now : float)
    {
        var p : r_CoopPuppet;
        var current : float;
        var i : int;

        for(i = puppets.Size() - 1; i >= 0; i -= 1)
        {
            p = puppets[i];
            if(!p.npc)
            {
                puppets.Erase(i);
                continue;
            }
            if(!p.alive)
            {
                continue;
            }

            if(p.flying)
            {
                // its forced idle tree may switch gravity back on
                ((CMovingPhysicalAgentComponent)p.npc.GetMovingAgentComponent()).SetGravity(false);
            }
            MovePuppet(p);
            DrivePuppetLocomotion(p);
            if(!p.stride)
            {
                p.stride = new r_CoopStride in this;
            }
            p.stride.Update(p.npc, p.targetSpeed > 1.0, now);
            puppetMaxSwing = MaxF(puppetMaxSwing, p.stride.maxSwing);
            strideBone = p.stride.boneLabel + "/" + p.stride.pelvis;

            if(p.npc.IsInHitAnim() && !p.wasInHitAnim)
            {
                hitAnimsSeen += 1;
            }
            p.wasInHitAnim = p.npc.IsInHitAnim();
            if(p.npc.IsCurrentlyDodging() && !p.wasDodging)
            {
                puppetDodgesSeen += 1;
            }
            p.wasDodging = p.npc.IsCurrentlyDodging();

            if(p.aiId == 0 && now >= p.reactUntil)
            {
                p.aiId = ForceIdle(p.npc);
            }
            // during a mirrored attack on another player, its perception keeps noticing this one: back to that player
            else if(p.aiId == 0 && p.attackActor && p.attackActor != thePlayer && p.npc.GetTarget() == thePlayer)
            {
                p.npc.ForgetActor(thePlayer);
                p.npc.NoticeActor(p.attackActor);
            }

            current = p.npc.GetHealthPercents();
            if(current >= 0 && p.hp > 0 && AbsF(current - p.hp) > 0.002)
            {
                applyingHostState = true;
                p.npc.SetHealthPerc(p.hp);
                applyingHostState = false;
            }
        }
    }

    // The slide keeps it on the leader's positions; the gameplay move speed and direction make its behavior graph
    // play the matching walk or run (as Witcher Online does for horses).
    private function DrivePuppetLocomotion(p : r_CoopPuppet)
    {
        var agent : CMovingAgentComponent;
        var speed, now : float;

        agent = p.npc.GetMovingAgentComponent();
        now = theGame.GetEngineTimeAsSeconds();
        // standing: slow target, a mirrored attack or move playing, or no snapshot lately (stalled link)
        if(!puppetLocomotion || p.targetSpeed < 0.4 || now - p.slotAnimAt < 1.2 || now - p.lastTargetAt > 0.5)
        {
            agent.SetGameplayRelativeMoveSpeed(0);
            return;
        }
        speed = 1;
        if(p.targetSpeed > 4.5)
        {
            speed = 3;
        }
        else if(p.targetSpeed > 2.0)
        {
            speed = 2;
        }
        agent.SetGameplayMoveDirection(VecHeading(p.target - p.npc.GetWorldPosition()));
        agent.SetGameplayRelativeMoveSpeed(speed);
    }

    private function MovePuppet(p : r_CoopPuppet)
    {
        var adjustor : CMovementAdjustor;
        var ticket : SMovementAdjustmentRequestTicket;
        var rot : EulerAngles;
        var dist : float;

        dist = VecDistance(p.npc.GetWorldPosition(), p.target);
        if(dist > 12)
        {
            rot = p.npc.GetWorldRotation();
            rot.Yaw = p.yaw;
            p.npc.TeleportWithRotation(p.target, rot);
            return;
        }
        if(dist < 0.1 && AbsF(AngleDistance(p.yaw, p.npc.GetHeading())) < 3)
        {
            return;
        }

        adjustor = p.npc.GetMovingAgentComponent().GetMovementAdjustor();
        adjustor.Cancel(adjustor.GetRequest('w3coop_puppet'));
        ticket = adjustor.CreateNewRequest('w3coop_puppet');
        adjustor.AdjustmentDuration(ticket, 0.15);
        adjustor.AdjustLocationVertically(ticket, true);
        adjustor.ScaleAnimationLocationVertically(ticket, true);
        adjustor.RotateTo(ticket, p.yaw);
        adjustor.SlideTo(ticket, p.target);
    }

    // Effects that take a monster out of the fight for a while without damage (they put it in a critical state),
    // mirrored from the leader's monster to its copies. Damage over time is not: a copy's own ticks would be sent
    // to the leader as this player's hits.
    private function StateEffects() : array<EEffectType>
    {
        var types : array<EEffectType>;

        types.PushBack(EET_Knockdown);
        types.PushBack(EET_HeavyKnockdown);
        types.PushBack(EET_Stagger);
        types.PushBack(EET_LongStagger);
        types.PushBack(EET_Immobilized);
        types.PushBack(EET_Paralyzed);
        types.PushBack(EET_Blindness);
        types.PushBack(EET_Confusion);
        types.PushBack(EET_Frozen);
        types.PushBack(EET_Tangled);
        types.PushBack(EET_Hypnotized);
        return types;
    }

    // Which of StateEffects the actor has, one bit each in that order.
    private function StateMask(npc : CNewNPC) : int
    {
        var types : array<EEffectType>;
        var mask, bit, i : int;

        types = StateEffects();
        bit = 1;
        for(i = 0; i < types.Size(); i += 1)
        {
            if(npc.HasBuff(types[i]))
            {
                mask += bit;
            }
            bit *= 2;
        }
        return mask;
    }

    // The leader's monster's untouchable phases (immortality, out of gameplay visibility: a noonwraith's or
    // alghoul's) and its knockdowns, staggers and the like, on its copy. Effects added here carry the source
    // "W3CoopState" and only those are removed; while one lasts the forced idle tree is lifted so the copy's own
    // AI plays the critical state, as the leader's does.
    private function ApplyStates(p : r_CoopPuppet, immortality : int, untargetable : bool, states : int)
    {
        var types : array<EEffectType>;
        var creator : CGameplayEntity;
        var bit, i : int;
        var has : bool;

        if(immortality != p.immortality)
        {
            p.immortality = immortality;
            if(immortality == (int)AIM_None)
            {
                p.npc.SetImmortalityMode(AIM_None, AIC_Combat);
            }
            else
            {
                p.npc.SetImmortalityMode((EActorImmortalityMode)immortality, AIC_Combat);
            }
            statesMirrored += 1;
        }
        if(untargetable != p.untargetable)
        {
            p.untargetable = untargetable;
            p.npc.SetGameplayVisibility(!untargetable);
            statesMirrored += 1;
        }

        types = StateEffects();
        bit = 1;
        for(i = 0; i < types.Size(); i += 1)
        {
            has = (states / bit) % 2 == 1;
            bit *= 2;
            if(has)
            {
                OpenReactionWindow(p);
                if(!p.npc.HasBuff(types[i]))
                {
                    creator = GhostOf(leaderName);
                    if(!creator)
                    {
                        creator = thePlayer;
                    }
                    applyingHostState = true;
                    p.npc.AddEffectDefault(types[i], creator, "W3CoopState");
                    applyingHostState = false;
                    controlStatesMirrored += 1;
                }
            }
            else if(p.npc.HasBuff(types[i]))
            {
                p.npc.RemoveBuff(types[i], true, "W3CoopState");
            }
        }
    }

    // A copy leaving the leader's control (a local twin gets its own AI back): nothing of the leader's state stays.
    private function ClearStates(p : r_CoopPuppet)
    {
        var types : array<EEffectType>;
        var i : int;

        p.npc.SetImmortalityMode(AIM_None, AIC_Combat);
        p.npc.SetGameplayVisibility(true);
        types = StateEffects();
        for(i = 0; i < types.Size(); i += 1)
        {
            p.npc.RemoveBuff(types[i], true, "W3CoopState");
        }
        p.immortality = 0;
        p.untargetable = false;
    }

    // As the game's own take-off and landing (btTaskSpawnAnim, btTaskManageGravity): a flying stance, physical
    // movement, no gravity and free of the navmesh, so the slides follow the leader's monster up into the air.
    private function SetPuppetFlying(p : r_CoopPuppet, fly : bool)
    {
        var mac : CMovingPhysicalAgentComponent;

        p.flying = fly;
        mac = (CMovingPhysicalAgentComponent)p.npc.GetMovingAgentComponent();
        if(fly)
        {
            puppetFlights += 1;
            p.npc.EnablePhysicalMovement(true);
            if(mac)
            {
                mac.SnapToNavigableSpace(false);
                mac.SetGravity(false);
            }
            p.npc.SetBehaviorVariable('npcStance', (int)NS_Fly);
        }
        else
        {
            p.npc.SetBehaviorVariable('npcStance', (int)NS_Normal);
            if(mac)
            {
                mac.SnapToNavigableSpace(true);
                mac.SetGravity(true);
            }
            p.npc.EnablePhysicalMovement(false);
        }
    }

    // As btTaskFalling: on the ground (within 0.5 m) it snaps back to the navmesh; one still up after 4 s is put
    // down where it is (a dead actor's physics may not carry it).
    private function LandFallingCopies(now : float)
    {
        var mac : CMovingPhysicalAgentComponent;
        var npc : CNewNPC;
        var pos : Vector;
        var height : float;
        var i : int;

        for(i = fallingCopies.Size() - 1; i >= 0; i -= 1)
        {
            npc = fallingCopies[i];
            if(npc)
            {
                height = npc.GetDistanceFromGround(50);
                if(height > 0.5 && now - fallingSince[i] < 4.0)
                {
                    continue;
                }
                if(height > 0.5)
                {
                    pos = npc.GetWorldPosition();
                    pos.Z -= height;
                    npc.Teleport(pos);
                    copiesPutDown += 1;
                }
                mac = (CMovingPhysicalAgentComponent)npc.GetMovingAgentComponent();
                if(mac)
                {
                    mac.SnapToNavigableSpace(true);
                }
                npc.EnablePhysicalMovement(false);
            }
            fallingCopies.Erase(i);
            fallingSince.Erase(i);
        }
    }

    private function KillPuppet(p : r_CoopPuppet)
    {
        var mac : CMovingPhysicalAgentComponent;

        // a monster killed in flight falls, as the leader's does: gravity on, physical movement until it lands
        if(p.flying)
        {
            p.flying = false;
            mac = (CMovingPhysicalAgentComponent)p.npc.GetMovingAgentComponent();
            if(mac)
            {
                mac.SetGravity(true);
            }
            fallingCopies.PushBack(p.npc);
            fallingSince.PushBack(theGame.GetEngineTimeAsSeconds());
        }
        p.alive = false;
        puppetsKilled += 1;
        if(p.animAiId != 0)
        {
            p.npc.CancelAIBehavior(p.animAiId);
            p.animAiId = 0;
        }
        if(p.aiId != 0)
        {
            p.npc.CancelAIBehavior(p.aiId);
            p.aiId = 0;
        }
        applyingHostState = true;
        p.npc.Kill('W3Coop', true);
        applyingHostState = false;
        RememberCorpse(p.npc, leaderEpoch, p.netId);
    }

    // a puppet the leader no longer reports: spawned ones go away, local twins get their own AI back
    private function ReleasePuppet(p : r_CoopPuppet)
    {
        var i : int;

        if(!p.npc || !p.alive)
        {
            return;
        }
        if(p.flying)
        {
            SetPuppetFlying(p, false);
        }
        ClearStates(p);
        if(p.animAiId != 0)
        {
            p.npc.CancelAIBehavior(p.animAiId);
            p.animAiId = 0;
        }
        if(p.aiId != 0)
        {
            p.npc.CancelAIBehavior(p.aiId);
            p.aiId = 0;
        }
        if(p.spawned)
        {
            p.npc.Destroy();
        }
        else
        {
            for(i = 0; i < p.addedNoFinishers.Size(); i += 1)
            {
                p.npc.RemoveAbility(p.addedNoFinishers[i]);
            }
        }
    }

    public function ReleaseAll()
    {
        var i : int;

        for(i = 0; i < puppets.Size(); i += 1)
        {
            ReleasePuppet(puppets[i]);
        }
        puppets.Clear();
        delayedHurts.Clear();

        for(i = suppressed.Size() - 1; i >= 0; i -= 1)
        {
            Unsuppress(suppressed[i].npc);
        }
        suppressed.Clear();
    }

    // local hostiles near this member that the leader's world doesn't have: hidden and idle while in the party
    private function SuppressUnmatched()
    {
        var actors : array<CActor>;
        var npc : CNewNPC;
        var s : r_CoopSuppressed;
        var i : int;

        for(i = suppressed.Size() - 1; i >= 0; i -= 1)
        {
            if(!suppressed[i].npc)
            {
                suppressed.Erase(i);
            }
        }

        actors = thePlayer.GetNPCsAndPlayersInRange(30, 48, '', FLAG_Attitude_Hostile + FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
        for(i = 0; i < actors.Size(); i += 1)
        {
            npc = (CNewNPC)actors[i];
            if(!npc || npc.HasTag('MPEntity') || npc.IsHorse() || IsPuppet(npc) || IsSuppressed(npc))
            {
                continue;
            }

            s = new r_CoopSuppressed in this;
            s.npc = npc;
            s.aiId = ForceIdle(npc);
            npc.SetVisibility(false);
            npc.SetGameplayVisibility(false);
            npc.EnableCharacterCollisions(false);
            suppressed.PushBack(s);
        }
    }

    private function IsSuppressed(npc : CNewNPC) : bool
    {
        var i : int;

        for(i = 0; i < suppressed.Size(); i += 1)
        {
            if(suppressed[i].npc == npc)
            {
                return true;
            }
        }
        return false;
    }

    private function Unsuppress(npc : CNewNPC)
    {
        var i : int;

        for(i = suppressed.Size() - 1; i >= 0; i -= 1)
        {
            if(suppressed[i].npc == npc)
            {
                if(npc)
                {
                    npc.CancelAIBehavior(suppressed[i].aiId);
                    npc.SetVisibility(true);
                    npc.SetGameplayVisibility(true);
                    npc.EnableCharacterCollisions(true);
                }
                suppressed.Erase(i);
            }
        }
    }

    private function FindPuppet(netId : int) : r_CoopPuppet
    {
        var i : int;

        for(i = 0; i < puppets.Size(); i += 1)
        {
            if(puppets[i].netId == netId)
            {
                return puppets[i];
            }
        }
        return NULL;
    }

    private function FindPuppetByNpc(npc : CNewNPC) : r_CoopPuppet
    {
        var i : int;

        for(i = 0; i < puppets.Size(); i += 1)
        {
            if(puppets[i].npc == npc)
            {
                return puppets[i];
            }
        }
        return NULL;
    }

    public function IsPuppet(npc : CNewNPC) : bool
    {
        if(FindPuppetByNpc(npc))
        {
            return true;
        }
        return false;
    }

    // damage the local player dealt to a puppet (after this game's stats, resistances and crits) goes to the
    // leader as a fraction of max health; the caller then zeroes it here
    public function OnPuppetDamaged(npc : CNewNPC, action : W3DamageAction)
    {
        var p : r_CoopPuppet;
        var hit : r_CoopHit;
        var dmg, maxHp : float;

        p = FindPuppetByNpc(npc);
        if(!p || !p.alive)
        {
            return;
        }
        OpenReactionWindow(p);
        if(action.attacker != thePlayer)
        {
            return;
        }

        if(npc.UsesVitality())
        {
            dmg = action.processedDmg.vitalityDamage;
        }
        else
        {
            dmg = action.processedDmg.essenceDamage;
        }
        maxHp = npc.GetMaxHealth();
        if(dmg <= 0 || maxHp <= 0)
        {
            return;
        }

        hit = NewHit(p);
        hit.frac = MinF(1, dmg / maxHp);
        lastHitFrac = hit.frac;
        if(action.IsActionMelee())
        {
            meleeHitsSent += 1;
        }
        if(action.IsActionWitcherSign())
        {
            signHitsSent += 1;
        }
        // its effects are added after the damage; OnAfterDamage puts them on this hit
        lastPuppetAction = action;
        lastPuppetHit = hit;

        p.hp = MaxF(0.001, p.hp - hit.frac);
        p.predictUntil = theGame.GetEngineTimeAsSeconds() + 0.6;
    }

    // After this player's hit on a puppet was fully processed: the effects it applied (Igni's burning, Aard's
    // knockdown, ...) go to the leader with the hit, or alone if it did no damage. Damage over time stays here:
    // this world's effect ticks with this player's skills and its ticks are claimed, and the leader's copy of the
    // effect does no damage (a ghost's own damage is dropped there).
    public function OnAfterDamage(action : W3DamageAction)
    {
        var p : r_CoopPuppet;
        var hit : r_CoopHit;
        var effects : array<EEffectType>;
        var i : int;

        if(action.attacker != thePlayer || action.IsDoTDamage())
        {
            return;
        }
        p = FindPuppetByNpc((CNewNPC)action.victim);
        if(!p || !p.alive)
        {
            return;
        }
        action.GetEffectTypes(effects);
        if(effects.Size() == 0)
        {
            return;
        }
        if(action == lastPuppetAction && pendingHits.Contains(lastPuppetHit))
        {
            hit = lastPuppetHit;
        }
        else
        {
            hit = NewHit(p);
            if(action.IsActionWitcherSign())
            {
                signHitsSent += 1;
            }
        }
        for(i = 0; i < effects.Size(); i += 1)
        {
            hit.effects.PushBack((int)effects[i]);
        }
        hitEffectsSent += effects.Size();
    }

    private function NewHit(p : r_CoopPuppet) : r_CoopHit
    {
        var hit : r_CoopHit;

        hit = new r_CoopHit in this;
        hit.seq = nextHitSeq;
        hit.netId = p.netId;
        nextHitSeq += 1;
        pendingHits.PushBack(hit);
        if(pendingHits.Size() > 32)
        {
            pendingHits.Erase(0);
        }
        hitsSent += 1;
        lastHitSend = -999;
        return hit;
    }

    private function PruneHits(lastSeq : int)
    {
        var i : int;

        for(i = pendingHits.Size() - 1; i >= 0; i -= 1)
        {
            if(pendingHits[i].seq <= lastSeq)
            {
                pendingHits.Erase(i);
            }
        }
    }

    // resends every unacknowledged hit until the leader's snapshot acknowledges it
    private function SendHits(now : float)
    {
        var text : string;
        var i, j : int;

        if(pendingHits.Size() == 0 && lastHitSentCount == 0 && hurtAck == lastSentHurtAck && !leaderListsMyHurts)
        {
            return;
        }
        if(now - lastHitSend < 0.1)
        {
            return;
        }

        text = "coop hit " + leaderName + " " + leaderEpoch + " " + session + " " + hurtAck + " " + pendingHits.Size();
        for(i = 0; i < pendingHits.Size(); i += 1)
        {
            text += " " + pendingHits[i].seq + " " + pendingHits[i].netId + " " + FloatToStringPrec(pendingHits[i].frac, 4)
                + " " + pendingHits[i].effects.Size();
            for(j = 0; j < pendingHits[i].effects.Size(); j += 1)
            {
                text += " " + pendingHits[i].effects[j];
            }
        }
        WO_Send(text);
        lastHitSend = now;
        lastHitSentCount = pendingHits.Size();
        lastSentHurtAck = hurtAck;
    }

    // ---------------------------------------------------------------- journal (milestone 3)

    // Every game records its quest and objective updates (the HUD hears about all of them, also the quest
    // system's own); each game sends them to the other (the leader to members, members to the leader), which
    // applies the ones that move it forward.
    public function OnJournalChange(journalEntry : CJournalBase)
    {
        var tag : name;
        var status, i : int;

        if(!journalEntry || applyingJournal)
        {
            return;
        }
        tag = journalEntry.GetUniqueScriptTag();
        if(!IsNameValid(tag))
        {
            return;
        }
        status = (int)theGame.GetJournalManager().GetEntryStatus(journalEntry);

        i = journalTags.FindFirst(tag);
        if(i < 0)
        {
            journalTags.PushBack(tag);
            journalStatus.PushBack(status);
            if(journalTags.Size() > 48)
            {
                journalTags.Erase(0);
                journalStatus.Erase(0);
            }
        }
        else
        {
            journalStatus[i] = status;
        }
        lastJournalSend = -999;
    }

    private function TrackingChanged() : bool
    {
        var manager : CWitcherJournalManager;
        var trackedTag, highlightedTag : name;

        manager = theGame.GetJournalManager();
        if(manager.GetTrackedQuest())
        {
            trackedTag = manager.GetTrackedQuest().GetUniqueScriptTag();
        }
        if(manager.GetHighlightedObjective())
        {
            highlightedTag = manager.GetHighlightedObjective().GetUniqueScriptTag();
        }
        if(trackedTag == sentTrackedQuest && highlightedTag == sentHighlighted)
        {
            return false;
        }
        sentTrackedQuest = trackedTag;
        sentHighlighted = highlightedTag;
        return true;
    }

    // "jr epoch tick trackedQuest highlightedObjective scene skipSeq skipValue count {tag status}"; the tick
    // changes every send so a member that joins later still gets it (the client passes unchanged state once)
    private function SendJournal(now : float)
    {
        var text : string;
        var i : int;

        if(theGame.r_getMultiplayerClient().getSeamlessCampaign().IsEnabled()) return;

        if(now - lastJournalSend < 1.0)
        {
            return;
        }
        journalTick += 1;
        text = "coop jr " + epoch + " " + journalTick + " " + CoopEncode(NameToString(sentTrackedQuest))
            + " " + CoopEncode(NameToString(sentHighlighted)) + " " + CoopEncode(currentScene) + " " + sceneSkipSeq
            + " " + sceneSkipValue + " " + journalTags.Size();
        for(i = 0; i < journalTags.Size(); i += 1)
        {
            // tags can contain spaces ("Win unique card from crossroads innkeeper A485F434-...")
            text += " " + CoopEncode(NameToString(journalTags[i])) + " " + journalStatus[i];
        }
        WO_Send(text);
        lastJournalSend = now;
    }

    // From the leader: statuses, its tracking and scene skips. From a member (on the leader): only
    // the statuses, so either player's quest updates reach the other; tracking stays the leader's.
    private function OnJournal(sender : string, count : int)
    {
        var trackedTag, highlightedTag : name;

        if(theGame.r_getMultiplayerClient().getSeamlessCampaign().IsEnabled()) return;
        if(theGame.r_getMultiplayerClient().getCoopTalk().IsSyncing()) return;  // as facts, see OnFacts

        if(GetRole() == 1)
        {
            if(count >= 9 && IsMyPartyMember(sender))
            {
                journalMessages += 1;
                ApplyJournalStatuses(count);
            }
            return;
        }
        if(GetRole() != 2 || sender != leaderName || leaderEpoch == 0 || count < 9 || StringToInt(WO_Str(1), 0) != leaderEpoch)
        {
            return;
        }

        journalMessages += 1;
        if(WO_Str(3) != "-")
        {
            trackedTag = WO_NameAt(3);
        }
        if(WO_Str(4) != "-")
        {
            highlightedTag = WO_NameAt(4);
        }
        ApplyLeaderSkip(CoopDecode(WO_Str(5)), StringToInt(WO_Str(6), 0), StringToInt(WO_Str(7), 0));
        ApplyJournalStatuses(count);

        // after the statuses: a quest the leader just activated can be tracked here too
        ApplyLeaderTracking(trackedTag, highlightedTag);
    }

    // The "count {tag status}" part of a journal list: each entry that moves this game forward.
    private function ApplyJournalStatuses(count : int)
    {
        var manager : CWitcherJournalManager;
        var journalEntry : CJournalBase;
        var tag : name;
        var status, current, n, i, idx : int;

        manager = theGame.GetJournalManager();
        n = StringToInt(WO_Str(8), 0);
        idx = 9;
        for(i = 0; i < n && idx + 1 < count; i += 1)
        {
            // the client restores the spaces of encoded fields, so this is the exact tag
            tag = WO_NameAt(idx);
            status = StringToInt(WO_Str(idx + 1), 0);
            idx += 2;

            lastJournalSeen = NameToString(tag) + "=" + status;
            journalEntry = FindJournalEntry(tag);
            if(!journalEntry)
            {
                journalMissing += 1;
                continue;
            }
            current = (int)manager.GetEntryStatus(journalEntry);
            if(JournalAdvances(current, status))
            {
                applyingJournal = true;
                manager.ActivateEntry(journalEntry, (EJournalStatus)status, true, true);
                applyingJournal = false;
                journalApplied += 1;
                lastJournalApplied = tag;
                lastJournalAppliedStatus = status;
            }
        }
    }

    // The leader's tracked quest and highlighted objective, applied when the leader changes them (so a member
    // can still track something else in between) and only for quests that are active here.
    private function ApplyLeaderTracking(trackedTag : name, highlightedTag : name)
    {
        var manager : CWitcherJournalManager;
        var journalQuest : CJournalQuest;
        var journalObjective : CJournalQuestObjective;

        manager = theGame.GetJournalManager();
        if(trackedTag != leaderTrackedQuest)
        {
            journalQuest = (CJournalQuest)FindJournalEntry(trackedTag);
            if(!IsNameValid(trackedTag) || (journalQuest && manager.GetEntryStatus(journalQuest) == JS_Active))
            {
                leaderTrackedQuest = trackedTag;
            }
            if(journalQuest && manager.GetEntryStatus(journalQuest) == JS_Active && manager.GetTrackedQuest() != journalQuest)
            {
                manager.SetTrackedQuest(journalQuest);
                trackedApplied += 1;
                lastTrackedApplied = trackedTag;
            }
        }
        if(highlightedTag != leaderHighlighted)
        {
            journalObjective = (CJournalQuestObjective)FindJournalEntry(highlightedTag);
            if(!IsNameValid(highlightedTag) || (journalObjective && manager.GetEntryStatus(journalObjective) == JS_Active))
            {
                leaderHighlighted = highlightedTag;
            }
            if(journalObjective && manager.GetEntryStatus(journalObjective) == JS_Active)
            {
                manager.SetHighlightedObjective(journalObjective);
            }
        }
    }

    // ---------------------------------------------------------------- quest facts

    // A save was loaded: fact changes count from here (the journal list works the same way).
    public function OnSessionStart()
    {
        factsReady = WO_FactsBaseline();
        nextFactsTry = theGame.GetEngineTimeAsSeconds() + 2;
    }

    // the facts DB may not be readable yet when the player spawns
    private function RetryFactsBaseline(now : float)
    {
        if(!factsReady && now >= nextFactsTry)
        {
            factsReady = WO_FactsBaseline();
            nextFactsTry = now + 2;
        }
    }

    public function FactsReady() : bool
    {
        return factsReady;
    }

    // "fx epoch tick page pages count {id sum}": one page of the facts this session changed, in turn
    private function SendFacts(now : float)
    {
        var page : string;

        if(theGame.r_getMultiplayerClient().getSeamlessCampaign().IsEnabled()) return;

        if(!factsReady || now - lastFactsSend < 0.5)
        {
            return;
        }
        lastFactsSend = now;
        page = WO_FactsPage(40);
        if(page != "")
        {
            factsTick += 1;
            WO_Send("coop fx " + epoch + " " + factsTick + " " + page);
        }
    }

    // Forward only, like the journal: a fact goes up to the sender's sum, never down (whoever is further
    // along keeps its own value). Members apply the leader's facts and the leader a member's, so quest
    // progress made on either PC reaches the other and its own quest graphs react to it.
    private function OnFacts(sender : string, count : int)
    {
        var id : string;
        var sum, current, n, i, idx : int;

        if(theGame.r_getMultiplayerClient().getSeamlessCampaign().IsEnabled()) return;
        // in a shared conversation both games set its facts themselves; one arriving from the
        // other game mid-scene would change the choices here. Pages keep cycling: applied after.
        if(theGame.r_getMultiplayerClient().getCoopTalk().IsSyncing()) return;

        if(GetRole() == 1)
        {
            if(count < 6 || !IsMyPartyMember(sender)) { return; }
        }
        else if(GetRole() != 2 || sender != leaderName || leaderEpoch == 0 || count < 6 || StringToInt(WO_Str(1), 0) != leaderEpoch)
        {
            return;
        }

        n = StringToInt(WO_Str(5), 0);
        idx = 6;
        for(i = 0; i < n && idx + 1 < count; i += 1)
        {
            id = WO_Str(idx);
            sum = StringToInt(WO_Str(idx + 1), 0);
            idx += 2;

            if(!CoopFactShared(id)) { continue; }
            current = FactsQuerySum(id);
            if(sum > current)
            {
                FactsAdd(id, sum - current);
                factsApplied += 1;
                lastFactApplied = id;
            }
        }
    }

    // ---------------------------------------------------------------- scenes

    public function OnSceneStarted(scene : CStoryScene)
    {
        if(scene)
        {
            currentScene = scene.GetPath();
        }
    }

    public function OnSceneEnded()
    {
        currentScene = "";
    }

    // the bots have no quest scene to share; they name one
    public function SetSceneForTest(path : string)
    {
        currentScene = path;
    }

    // The leader skipped a line or cutscene: members in the same scene skip with it.
    public function OnLocalSkip(value : int)
    {
        if(!wasHost || applyingSkip)
        {
            return;
        }
        sceneSkipSeq += 1;
        sceneSkipValue = value;
        lastJournalSend = -999;
    }

    private function ApplyLeaderSkip(scene : string, skipSeq : int, skipValue : int)
    {
        var count, i : int;

        if(theGame.r_getMultiplayerClient().getCoopTalk().IsSyncing()) { return; }

        // a new scene of the leader's: its earlier skips belong to another scene
        if(scene != leaderSceneSeen)
        {
            leaderSceneSeen = scene;
            leaderSkipSeen = skipSeq;
            return;
        }
        if(skipSeq <= leaderSkipSeen)
        {
            return;
        }
        count = Min(skipSeq - leaderSkipSeen, 3);
        leaderSkipSeen = skipSeq;
        if(scene == "" || scene != currentScene)
        {
            return;
        }

        applyingSkip = true;
        for(i = 0; i < count; i += 1)
        {
            theGame.GetStorySceneSystem().SendSignal(SSST_Skip, skipValue);
        }
        applyingSkip = false;
        skipsApplied += count;
    }

    private function FindJournalEntry(tag : name) : CJournalBase
    {
        var journalEntry : CJournalBase;
        var i : int;

        journalEntry = theGame.GetJournalManager().GetEntryByTag(tag);
        if(journalEntry)
        {
            return journalEntry;
        }

        i = journalIndexTags.FindFirst(tag);
        if(i < 0 && theGame.GetEngineTimeAsSeconds() - journalIndexBuiltAt > 5.0)
        {
            BuildJournalIndex();
            i = journalIndexTags.FindFirst(tag);
        }
        if(i >= 0)
        {
            return journalIndexEntries[i];
        }
        return NULL;
    }

    // Quests this game knows and their objectives, by unique tag: GetEntryByTag doesn't find objectives that
    // are still inactive here (the map menu walks the same hierarchy).
    private function BuildJournalIndex()
    {
        var quests : array<CJournalBase>;
        var journalQuest : CJournalQuest;
        var phase : CJournalQuestPhase;
        var child : CJournalBase;
        var i, j, k : int;

        journalIndexTags.Clear();
        journalIndexEntries.Clear();
        theGame.GetJournalManager().GetActivatedOfType('CJournalQuest', quests);
        for(i = 0; i < quests.Size(); i += 1)
        {
            journalQuest = (CJournalQuest)quests[i];
            if(!journalQuest)
            {
                continue;
            }
            journalIndexTags.PushBack(journalQuest.GetUniqueScriptTag());
            journalIndexEntries.PushBack(journalQuest);
            for(j = 0; j < journalQuest.GetNumChildren(); j += 1)
            {
                phase = (CJournalQuestPhase)journalQuest.GetChild(j);
                if(!phase)
                {
                    continue;
                }
                for(k = 0; k < phase.GetNumChildren(); k += 1)
                {
                    child = phase.GetChild(k);
                    if((CJournalQuestObjective)child)
                    {
                        journalIndexTags.PushBack(child.GetUniqueScriptTag());
                        journalIndexEntries.PushBack(child);
                    }
                }
            }
        }
        journalIndexBuiltAt = theGame.GetEngineTimeAsSeconds();
    }

    // inactive -> active -> succeeded/failed; never back, never from one outcome to the other
    private function JournalAdvances(current : int, wanted : int) : bool
    {
        if(current == (int)JS_Inactive)
        {
            return wanted != (int)JS_Inactive;
        }
        if(current == (int)JS_Active)
        {
            return wanted == (int)JS_Success || wanted == (int)JS_Failed;
        }
        return false;
    }

    public function JournalStatusOf(tag : name) : int
    {
        var journalEntry : CJournalBase;

        journalEntry = FindJournalEntry(tag);
        if(!journalEntry)
        {
            return -1;
        }
        return (int)theGame.GetJournalManager().GetEntryStatus(journalEntry);
    }

    public function JournalRecorded(tag : name) : bool
    {
        return journalTags.Contains(tag);
    }

    // ---------------------------------------------------------------- corpses

    private function RememberCorpse(npc : CNewNPC, ofEpoch : int, netId : int)
    {
        if(!npc || ofEpoch == 0 || corpseNpcs.Contains(npc))
        {
            return;
        }
        corpseKeys.PushBack(ofEpoch + "." + netId);
        corpseNpcs.PushBack(npc);
        corpseTimes.PushBack(theGame.GetEngineTimeAsSeconds());
        if(corpseKeys.Size() > 48)
        {
            corpseKeys.Erase(0);
            corpseNpcs.Erase(0);
            corpseTimes.Erase(0);
        }
    }

    public function CorpseCount() : int { return corpseKeys.Size(); }
    public function CorpseKeyAt(i : int) : string { return corpseKeys[i]; }
    public function CorpseNpcAt(i : int) : CNewNPC { return corpseNpcs[i]; }
    public function CorpseDiedAt(i : int) : float { return corpseTimes[i]; }

    // The key of a shared enemy's corpse in this world, "" for any other actor.
    public function CorpseKeyOf(actor : CActor) : string
    {
        var i : int;
        for(i = corpseNpcs.Size() - 1; i >= 0; i -= 1)
        {
            if(corpseNpcs[i] && (CActor)corpseNpcs[i] == actor)
            {
                return corpseKeys[i];
            }
        }
        return "";
    }

    public function CorpseOfKey(key : string) : CNewNPC
    {
        var i : int;
        i = corpseKeys.FindFirst(key);
        if(i < 0)
        {
            return NULL;
        }
        return corpseNpcs[i];
    }

    // ---------------------------------------------------------------- diagnostics

    public function HostEnemyCount() : int
    {
        return hostEnemies.Size();
    }

    public function HostEnemyAt(i : int) : CNewNPC
    {
        return hostEnemies[i].npc;
    }

    public function HostNetIdOf(npc : CNewNPC) : int
    {
        var e : r_CoopHostEnemy;

        e = FindHostEnemyByNpc(npc);
        if(e)
        {
            return e.netId;
        }
        return 0;
    }

    public function PuppetCount() : int
    {
        return puppets.Size();
    }

    public function PuppetAt(i : int) : CNewNPC
    {
        return puppets[i].npc;
    }

    public function PuppetHostHp(i : int) : float
    {
        return puppets[i].hp;
    }

    public function PuppetAlive(i : int) : bool
    {
        return puppets[i].alive;
    }

    public function PuppetFlying(i : int) : bool
    {
        return puppets[i].flying;
    }

    public function PuppetSpawned(i : int) : bool
    {
        return puppets[i].spawned;
    }

    public function PuppetTarget(i : int) : Vector
    {
        return puppets[i].target;
    }

    public function PuppetInHitAnim(i : int) : bool
    {
        return puppets[i].npc.IsInHitAnim();
    }

    public function SuppressedCount() : int
    {
        return suppressed.Size();
    }

    public function PendingHitCount() : int
    {
        return pendingHits.Size();
    }
}

// what a puppet keeps of a hit, so the vanilla hit reaction runs (its health is the leader's anyway)
function COOP_FX_DAMAGE() : float
{
    return 0.01;
}

// players farther apart than this run their own monsters (the leader's world doesn't simulate far away)
function COOP_SHARE_RANGE() : float
{
    return 60.0;
}

@wrapMethod(CNewNPC)
function OnPreAttackEvent(animEventName : name, animEventType : EAnimationEventType, data : CPreAttackEventData, animInfo : SAnimationEventAnimInfo)
{
    var client : r_MultiplayerClient;

    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        client.getCoopEnemies().OnEnemyAttack(this, animEventType, animInfo);
    }
    return wrappedMethod(animEventName, animEventType, data, animInfo);
}

// The monster that fired a projectile (for damage that names no attacker), NULL for anything else.
function ProjectileCaster(causer : IScriptable) : CNewNPC
{
    var proj : CProjectileTrajectory;

    proj = (CProjectileTrajectory)causer;
    if(!proj)
    {
        return NULL;
    }
    return (CNewNPC)proj.caster;
}

// The projectile a monster's task has just fired from about this spot (the task keeps it to itself): the newest
// one of this caster not reported yet.
function CoopReportTaskProjectile(npc : CNewNPC, near : Vector, speed : float, target : Vector, range : float)
{
    var entities : array<CGameplayEntity>;
    var proj, best : CProjectileTrajectory;
    var client : r_MultiplayerClient;
    var i : int;

    client = theGame.r_getMultiplayerClient();
    if(!client || !npc)
    {
        return;
    }
    FindGameplayEntitiesInSphere(entities, near, 2.0, 16);
    for(i = 0; i < entities.Size(); i += 1)
    {
        proj = (CProjectileTrajectory)entities[i];
        if(proj && (CNewNPC)proj.caster == npc && !proj.HasTag('W3CoopReported'))
        {
            best = proj;
        }
    }
    if(best)
    {
        best.AddTag('W3CoopReported');
        client.getCoopEnemies().OnEnemyProjectile(best, 0, speed, target, range);
    }
}

function CoopReportObject(npc : CNewNPC, entity : CEntity)
{
    var client : r_MultiplayerClient;

    client = theGame.r_getMultiplayerClient();
    if(client && npc && entity)
    {
        client.getCoopEnemies().OnEnemyObject(npc, entity);
    }
}

// Monster attacks that spawn an object next to the monster or its target (the spriggan's roots, a giant's trail ...).
@wrapMethod(CBTTaskSpawnEntityOffset)
function SpawnEntity()
{
    wrappedMethod();
    CoopReportObject(GetNPC(), entity);
}

@wrapMethod(CBTTaskSpawnMultipleEntitiesAttack)
function CreateEntity(_SpawnPos : Vector, _Rotation : EulerAngles) : CEntity
{
    var spawned : CEntity;

    spawned = wrappedMethod(_SpawnPos, _Rotation);
    CoopReportObject(GetNPC(), spawned);
    return spawned;
}

@wrapMethod(CBTTaskSpawnMultipleEntities3StateAttack)
function CreateEntity(_SpawnPos : Vector, _Rotation : EulerAngles) : CEntity
{
    var spawned : CEntity;

    spawned = wrappedMethod(_SpawnPos, _Rotation);
    CoopReportObject(GetNPC(), spawned);
    return spawned;
}

// The leshen's root: travels underground to its target and bursts out (W3LeshyRootProjectile).
@wrapMethod(CBTTaskLeshyRootAttack)
function ShootProjectile()
{
    var npc : CNewNPC;
    var target : CActor;
    var from : Vector;

    wrappedMethod();
    npc = GetNPC();
    target = GetCombatTarget();
    if(npc && target)
    {
        from = npc.GetWorldPosition() + VecFromHeading(npc.GetHeading()) * 3.0;
        from.Z += 1.5;
        CoopReportTaskProjectile(npc, from, 20, target.GetWorldPosition(), attackRange);
    }
}

// The leshen's crows (W3LeshyBirdProjectile), fired at its target's torso.
@wrapMethod(CBTTaskLeshyBirdAttack)
function ShootProjectile()
{
    var npc : CNewNPC;
    var from : Vector;

    wrappedMethod();
    npc = GetNPC();
    if(npc && npc.GetTarget())
    {
        from = npc.GetWorldPosition() + VecFromHeading(npc.GetHeading()) * 2.5;
        from.Z += 1.0;
        CoopReportTaskProjectile(npc, from, 8, npc.GetTarget().GetBoneWorldPosition('torso'), attackRange);
    }
}

function CoopProjectileShot(proj : W3AdvancedProjectile, angle : float, speed : float, target : Vector, range : float)
{
    var client : r_MultiplayerClient;

    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        client.getCoopEnemies().OnEnemyProjectile(proj, angle, speed, target, range);
    }
}

@wrapMethod(W3AdvancedProjectile)
function ShootProjectileAtPosition(angle : float, velocity : float, target : Vector, optional range : float, optional collisionGroups : array<name>)
{
    wrappedMethod(angle, velocity, target, range, collisionGroups);
    CoopProjectileShot(this, angle, velocity, target, range);
}

@wrapMethod(W3AdvancedProjectile)
function ShootProjectileAtNode(angle : float, velocity : float, target : CNode, optional range : float, optional collisionGroups : array<name>)
{
    wrappedMethod(angle, velocity, target, range, collisionGroups);
    CoopProjectileShot(this, angle, velocity, target.GetWorldPosition(), range);
}

@wrapMethod(W3AdvancedProjectile)
function ShootProjectileAtBone(angle : float, velocity : float, target : CEntity, targetBone : name, optional range : float, optional collisionGroups : array<name>)
{
    wrappedMethod(angle, velocity, target, targetBone, range, collisionGroups);
    CoopProjectileShot(this, angle, velocity, target.GetWorldPosition(), range);
}

@wrapMethod(W3AdvancedProjectile)
function ShootCakeProjectileAtPosition(cakeAngle : float, cakeHeight : float, shootAngle : float, velocity : float, target : Vector, range : float, optional collisionGroups : array<name>)
{
    wrappedMethod(cakeAngle, cakeHeight, shootAngle, velocity, target, range, collisionGroups);
    CoopProjectileShot(this, shootAngle, velocity, target, range);
}

@wrapMethod(CBTTaskPlayAnimationEventDecorator)
function OnAnimEvent(animEventName : name, animEventType : EAnimationEventType, animInfo : SAnimationEventAnimInfo) : bool
{
    var client : r_MultiplayerClient;
    var attack : CBTTaskAttack;
    var reaction : CBTTaskHitReactionDecorator;

    // attacks and hit reactions are mirrored on their own
    attack = (CBTTaskAttack)this;
    reaction = (CBTTaskHitReactionDecorator)this;
    if(!attack && !reaction)
    {
        client = theGame.r_getMultiplayerClient();
        if(client)
        {
            client.getCoopEnemies().OnEnemyMove(GetNPC(), animInfo);
        }
    }
    return wrappedMethod(animEventName, animEventType, animInfo);
}

// Spaces separate fields on the wire; '*' can't appear in depot paths or appearance names.
function CoopEncode(text : string) : string
{
    if(text == "")
    {
        return "-";
    }
    return StrReplaceAll(text, " ", "*");
}

function CoopDecode(text : string) : string
{
    if(text == "-")
    {
        return "";
    }
    return StrReplaceAll(text, "*", " ");
}

@wrapMethod(W3DamageManagerProcessor)
function ProcessAction(act : W3DamageAction)
{
    var client : r_MultiplayerClient;
    var coop : r_CoopEnemies;

    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        coop = client.getCoopEnemies();
    }
    if(coop && coop.OnBeforeDamage(act))
    {
        return;
    }

    wrappedMethod(act);
    if(coop)
    {
        coop.OnAfterDamage(act);
    }
}

// Damage to a puppet is computed here as usual, sent to the leader, and not applied locally: the leader's
// health comes back in its next snapshot.
@wrapMethod(CNewNPC)
function OnTakeDamage(action : W3DamageAction)
{
    var client : r_MultiplayerClient;
    var coop : r_CoopEnemies;

    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        coop = client.getCoopEnemies();
    }
    if(coop && !coop.applyingHostState && coop.IsPuppet(this))
    {
        coop.OnPuppetDamaged(this, action);
        // a negligible remainder instead of zero keeps the vanilla hit reaction (it needs damage dealt)
        action.SetAllProcessedDamageAs(0);
        action.processedDmg.vitalityDamage = COOP_FX_DAMAGE();
        action.processedDmg.essenceDamage = COOP_FX_DAMAGE();
    }
    else if(coop)
    {
        coop.OnEnemyDamaged(this, action);
    }

    wrappedMethod(action);
}

@wrapMethod(CR4ScriptedHud)
function OnQuestEvent(journalQuest : CJournalQuest)
{
    var client : r_MultiplayerClient;

    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        client.getCoopEnemies().OnJournalChange(journalQuest);
    }
    return wrappedMethod(journalQuest);
}

@wrapMethod(CR4ScriptedHud)
function OnQuestObjectiveEvent(journalQuest : CJournalQuest, journalObjective : CJournalQuestObjective)
{
    var client : r_MultiplayerClient;

    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        client.getCoopEnemies().OnJournalChange(journalQuest);
        client.getCoopEnemies().OnJournalChange(journalObjective);
    }
    return wrappedMethod(journalQuest, journalObjective);
}

// Facts that belong to one player's game rather than the shared story: the load marker and
// tutorial progress (each player sees their own tutorials). Everything else is shared.
function CoopFactShared(id : string) : bool
{
    return id != "game_is_loaded" && StrFindFirst(id, "tutorial") != 0 && StrFindFirst(id, "Tutorial") != 0
        && id != "RemasterSkillResetAndRefund" && StrFindFirst(id, "coop_rw_") != 0
        // Custom Player Characters: each player's own character, appearance and creator
        && StrFindFirst(id, "nr_") != 0 && StrFindFirst(id, "item_use_nr_") != 0;
}

// Hostile NPCs within range of this player (for the log).
function CoopHostilesNear(range : float) : int
{
    var actors : array<CActor>;
    var npc : CNewNPC;
    var i, n : int;
    actors = thePlayer.GetNPCsAndPlayersInRange(range, 50, '', FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
    for(i = 0; i < actors.Size(); i += 1)
    {
        npc = (CNewNPC)actors[i];
        if(npc && npc.GetAttitude(thePlayer) == AIA_Hostile) { n += 1; }
    }
    return n;
}
