// monster_survey: which parts of a monster's fight reach the second PC. Measures, does not pass/fail on them.
// The leader spawns each monster of W3T_SURVEY in turn (comma-separated template names under
// characters\npc_entities\monsters\, without .w2ent) 6 m ahead, near both players (both invulnerable), hurts
// it by 8 % every 4 s for 45 s so its health-driven phases begin, then kills it and anything hostile left.
// Both games log, once per monster and value, what they see of it:
//   SURVEY <side> <monster> buff <effect type>        its buffs (an aura, a shield, invisibility ...)
//   SURVEY <side> <monster> app <appearance>
//   SURVEY <side> <monster> stance <ENpcStance>       and "fly" while flying
//   SURVEY <side> <monster> air <metres>              above where it started, in whole metres (> 1)
//   SURVEY <side> <monster> mode <immortality mode>   and "hidden" while out of gameplay visibility
//   SURVEY <side> <monster> ent <name>                entities that appeared within 25 m of it (its adds,
//                                                     summons, doppelgangers, projectiles, traps ...)
// side is "leader" (the real monster) or "copy" (the second PC's puppet of it); survey_compare.py lists what
// the leader saw that the copy did not.

function W3T_SurveyList() : array<string>
{
    var list : array<string>;
    list = W3T_Split(W3T_GetEnv("W3T_SURVEY"), ",");
    if(list.Size() == 0)
    {
        list.PushBack("wraith_lvl1");
        list.PushBack("noonwraith_lvl1");
        list.PushBack("elemental_dao_lvl1");
        list.PushBack("lessog_lvl1");
        list.PushBack("gryphon_lvl1");
        list.PushBack("harpy_lvl1");
    }
    return list;
}

function W3T_SurveyLeader(bot : W3T_Bot, client : r_MultiplayerClient) : bool
{
    var list : array<string>;
    var template : CEntityTemplate;
    var monster : CNewNPC;
    var entities : array<CGameplayEntity>;
    var action : W3DamageAction;
    var i : int;
    var now : float;
    list = W3T_SurveyList();
    now = bot.ElapsedS();
    if(bot.scenarioStep < 0) { return false; }
    if(bot.scenarioStep >= list.Size()) { return now - bot.scenarioTime > 10; }
    if(client.getCoopEnemies().GetRole() != 1 || now < 25) { return false; }
    monster = (CNewNPC)bot.scenarioEntity;
    if(bot.scenarioCount == 0)
    {
        thePlayer.SetImmortalityMode(AIM_Invulnerable, AIC_Cheat, true);
        template = (CEntityTemplate)LoadResource(StrReplace("characters\npc_entities\monsters\X.w2ent", "X.w2ent", list[bot.scenarioStep] + ".w2ent"), true);
        if(!template)
        {
            W3T_Log("SURVEY leader " + list[bot.scenarioStep] + " missing template");
            bot.scenarioStep += 1;
            return false;
        }
        // what is around before it comes: only what appears afterwards is its own
        bot.scenarioEntities.Clear();
        FindGameplayEntitiesInSphere(entities, thePlayer.GetWorldPosition(), 40, 200);
        for(i = 0; i < entities.Size(); i += 1) { bot.scenarioEntities.PushBack(entities[i]); }
        bot.scenarioVec = thePlayer.GetWorldPosition() + VecFromHeading(thePlayer.GetHeading()) * 6.0;
        bot.scenarioEntity = theGame.CreateEntity(template, bot.scenarioVec, thePlayer.GetWorldRotation(), true, false, false, PM_DontPersist);
        monster = (CNewNPC)bot.scenarioEntity;
        if(!monster)
        {
            W3T_Log("SURVEY leader " + list[bot.scenarioStep] + " did not spawn an NPC");
            bot.scenarioStep += 1;
            return false;
        }
        W3T_Log("SURVEY leader " + list[bot.scenarioStep] + " spawned as '" + monster.GetReadableName() + "'");
        bot.scenarioCount = 1;
        bot.scenarioTime = now;
        bot.scenarioActAt = now;
        return false;
    }
    if(bot.scenarioCount == 1)
    {
        if(monster) { W3T_SurveyObserve(bot, "leader", list[bot.scenarioStep], monster, bot.scenarioVec.Z); }
        if(monster && monster.IsAlive() && now - bot.scenarioActAt >= 4 && monster.GetHealthPercents() > 0.2)
        {
            action = new W3DamageAction in theGame.damageMgr;
            action.Initialize(thePlayer, monster, thePlayer, "W3T", EHRT_Light, CPS_Undefined, true, false, false, false);
            action.AddDamage(theGame.params.DAMAGE_NAME_DIRECT, 0.08 * monster.GetMaxHealth());
            theGame.damageMgr.ProcessAction(action);
            delete action;
            bot.scenarioActAt = now;
        }
        if(!monster || !monster.IsAlive() || now - bot.scenarioTime > 45)
        {
            W3T_Log("SURVEY leader " + list[bot.scenarioStep] + " ends: kills it and what is hostile around");
            entities.Clear();
            FindGameplayEntitiesInSphere(entities, thePlayer.GetWorldPosition(), 40, 100, '', FLAG_Attitude_Hostile + FLAG_OnlyAliveActors, thePlayer);
            for(i = 0; i < entities.Size(); i += 1)
            {
                if((CNewNPC)entities[i] && !entities[i].HasTag('MPEntity')) { ((CNewNPC)entities[i]).Kill('W3T', true); }
            }
            if(monster && monster.IsAlive()) { monster.Kill('W3T', true); }
            bot.scenarioCount = 2;
            bot.scenarioTime = now;
        }
        return false;
    }
    if(bot.scenarioCount == 2 && now - bot.scenarioTime > 8)
    {
        bot.scenarioStep += 1;
        bot.scenarioCount = 0;
        bot.scenarioTime = now;
    }
    return false;
}

// The second PC: logs each copy (puppet) of the leader's monsters it has, by the leader's order of monsters.
function W3T_SurveyMember(bot : W3T_Bot, client : r_MultiplayerClient, leader : r_RemotePlayer) : bool
{
    var coop : r_CoopEnemies;
    var list : array<string>;
    var puppet : CNewNPC;
    var entities : array<CGameplayEntity>;
    var pos : Vector;
    var i, j, k : int;
    var now : float;
    coop = client.getCoopEnemies();
    list = W3T_SurveyList();
    now = bot.ElapsedS();
    if(!client.getInParty())
    {
        thePlayer.SetImmortalityMode(AIM_Invulnerable, AIC_Cheat, true);
        client.joinParty(leader.username);
        bot.scenarioTime = now;
        return false;
    }
    for(i = 0; i < coop.PuppetCount(); i += 1)
    {
        puppet = coop.PuppetAt(i);
        if(!puppet) { continue; }
        for(k = 0; k < list.Size(); k += 1)
        {
            // the template's whole file name (noonwraith_lvl1 ends in wraith_lvl1 too)
            if(StrEndsWith(puppet.GetReadableName(), StrMid("a\b", 1, 1) + list[k] + ".w2ent"))
            {
                if(!bot.surveyCopies.Contains(puppet))
                {
                    bot.surveyCopies.PushBack(puppet);
                    // what is around as it comes: only what appears afterwards is its own (as on the leader)
                    FindGameplayEntitiesInSphere(entities, thePlayer.GetWorldPosition(), 40, 200);
                    for(j = 0; j < entities.Size(); j += 1)
                    {
                        if(entities[j] != puppet && !bot.scenarioEntities.Contains(entities[j])) { bot.scenarioEntities.PushBack(entities[j]); }
                    }
                    // its starting height: the leader's spawn height is not known here
                    bot.surveyLabels.PushBack(list[k]);
                    pos = puppet.GetWorldPosition();
                    bot.surveyStartZ.PushBack(pos.Z);
                    W3T_Log("SURVEY copy " + list[k] + " appeared as '" + puppet.GetReadableName() + "' spawned=" + coop.PuppetSpawned(i));
                }
                W3T_SurveyObserve(bot, "copy", list[k], puppet, bot.surveyStartZ[bot.surveyLabels.FindFirst(list[k])]);
            }
        }
    }
    // the leader needs about a minute per monster
    return now - bot.scenarioTime > 25 + 58 * list.Size();
}

function W3T_SurveyObserve(bot : W3T_Bot, side : string, label : string, monster : CNewNPC, startZ : float)
{
    var buffs : array<CBaseGameplayEffect>;
    var entities : array<CGameplayEntity>;
    var pos : Vector;
    var i : int;
    var air : int;
    buffs = monster.GetBuffs();
    for(i = 0; i < buffs.Size(); i += 1)
    {
        if(buffs[i]) { W3T_SurveyNote(bot, side, label, "buff", NameToString(EffectTypeToName(buffs[i].GetEffectType()))); }
    }
    W3T_SurveyNote(bot, side, label, "app", NameToString(monster.GetAppearance()));
    W3T_SurveyNote(bot, side, label, "stance", IntToString((int)monster.GetCurrentStance()));
    if(monster.IsFlying()) { W3T_SurveyNote(bot, side, label, "stance", "fly"); }
    pos = monster.GetWorldPosition();
    air = (int)(pos.Z - startZ);
    if(air > 1) { W3T_SurveyNote(bot, side, label, "air", IntToString(air)); }
    W3T_SurveyNote(bot, side, label, "mode", IntToString((int)monster.GetImmortalityMode()));
    if(!monster.GetGameplayVisibility()) { W3T_SurveyNote(bot, side, label, "mode", "hidden"); }
    FindGameplayEntitiesInSphere(entities, monster.GetWorldPosition(), 25, 100);
    for(i = 0; i < entities.Size(); i += 1)
    {
        if(entities[i] == monster || entities[i] == thePlayer || entities[i].HasTag('MPEntity') || bot.scenarioEntities.Contains(entities[i])) { continue; }
        if((W3PlayerWitcher)entities[i] || (W3ActorRemains)entities[i]) { continue; }
        W3T_SurveyNote(bot, side, label, "ent", W3T_SurveyEntityName(entities[i]));
    }
}

// An entity's template file name (without folders), or its readable name.
function W3T_SurveyEntityName(entity : CEntity) : string
{
    var path : string;
    var parts : array<string>;
    path = entity.GetReadableName();
    parts = W3T_Split(StrReplaceAll(path, StrMid("a\b", 1, 1), "/"), "/");
    if(parts.Size() > 0) { path = parts[parts.Size() - 1]; }
    return StrReplaceAll(path, " ", "_");
}

function W3T_SurveyNote(bot : W3T_Bot, side : string, label : string, kind : string, value : string)
{
    var key : string;
    key = label + "|" + kind + "|" + value;
    if(bot.surveySeen.Contains(key)) { return; }
    bot.surveySeen.PushBack(key);
    W3T_Log("SURVEY " + side + " " + label + " " + kind + " " + value);
}

// monster_flight: a flying monster flies on the second PC too. The leader spawns W3T_MONSTER (a griffin unless
// set) 10 m above the ground ahead of both players: it starts in flight. After 50 s the leader kills it by
// damage, as a fight does. The second PC's copy must fly too (its flying stance, over 3 m above the ground)
// and, once dead, lie on the ground (under 1.5 m within 15 s).
function W3T_FlightMonster() : string
{
    if(W3T_GetEnv("W3T_MONSTER") != "") { return W3T_GetEnv("W3T_MONSTER"); }
    return "characters\npc_entities\monsters\gryphon_lvl1.w2ent";
}

function W3T_FlightLeader(bot : W3T_Bot, client : r_MultiplayerClient) : bool
{
    var template : CEntityTemplate;
    var monster : CNewNPC;
    var pos : Vector;
    var action : W3DamageAction;
    var height : float;
    var now : float;
    now = bot.ElapsedS();
    if(bot.scenarioStep < 0) { return false; }
    if(bot.scenarioStep == 0)
    {
        if(client.getCoopEnemies().GetRole() != 1 || now < 25) { return false; }
        template = (CEntityTemplate)LoadResource(W3T_FlightMonster(), true);
        if(!template) { W3T_Log("FLIGHT leader FAIL no template " + W3T_FlightMonster()); bot.scenarioStep = -1; return false; }
        thePlayer.SetImmortalityMode(AIM_Invulnerable, AIC_Cheat, true);
        pos = thePlayer.GetWorldPosition() + VecFromHeading(thePlayer.GetHeading()) * 8.0;
        pos.Z += 10;
        bot.scenarioEntity = theGame.CreateEntity(template, pos, thePlayer.GetWorldRotation(), true, false, false, PM_DontPersist);
        monster = (CNewNPC)bot.scenarioEntity;
        if(!monster) { W3T_Log("FLIGHT leader FAIL no monster"); bot.scenarioStep = -1; return false; }
        W3T_Log("FLIGHT leader spawned " + W3T_FlightMonster() + " 10 m up at " + W3T_VecStr(pos));
        bot.scenarioStep = 1;
        bot.scenarioTime = now;
        return false;
    }
    monster = (CNewNPC)bot.scenarioEntity;
    if(!monster) { W3T_Log("FLIGHT leader FAIL the monster is gone"); bot.scenarioStep = -1; return false; }
    height = monster.GetDistanceFromGround(50);
    W3T_Log("FLIGHT leader step=" + bot.scenarioStep + " flying=" + monster.IsFlying() + " stance=" + (int)monster.GetCurrentStance()
        + " height=" + FloatToStringPrec(height, 1) + " alive=" + monster.IsAlive() + " pos=" + W3T_VecStr(monster.GetWorldPosition()));
    if(monster.IsFlying() && height > 3) { bot.scenarioFlag = true; }
    if(bot.scenarioStep == 1 && now - bot.scenarioTime > 50)
    {
        if(!bot.scenarioFlag) { W3T_Log("FLIGHT leader FAIL its monster never flew: nothing to compare"); bot.scenarioStep = -1; return false; }
        W3T_Log("FLIGHT leader kills it by damage");
        action = new W3DamageAction in theGame.damageMgr;
        action.Initialize(thePlayer, monster, thePlayer, "W3T", EHRT_Heavy, CPS_Undefined, true, false, false, false);
        action.AddDamage(theGame.params.DAMAGE_NAME_DIRECT, 2 * monster.GetMaxHealth());
        theGame.damageMgr.ProcessAction(action);
        delete action;
        if(monster.IsAlive()) { W3T_Log("FLIGHT leader damage did not kill it: Kill()"); monster.Kill('W3T', true); }
        bot.scenarioStep = 2;
        bot.scenarioTime = now;
    }
    return bot.scenarioStep == 2 && now - bot.scenarioTime > 20;
}

function W3T_FlightMember(bot : W3T_Bot, client : r_MultiplayerClient, leader : r_RemotePlayer) : bool
{
    var coop : r_CoopEnemies;
    var copy : CNewNPC;
    var height : float;
    var i : int;
    var now : float;
    coop = client.getCoopEnemies();
    now = bot.ElapsedS();
    if(!client.getInParty())
    {
        thePlayer.SetImmortalityMode(AIM_Invulnerable, AIC_Cheat, true);
        client.joinParty(leader.username);
        return false;
    }
    if(bot.scenarioStep < 0) { return false; }
    for(i = 0; i < coop.PuppetCount(); i += 1)
    {
        if(coop.PuppetAt(i) && StrEndsWith(coop.PuppetAt(i).GetReadableName(), W3T_FlightMonster()))
        {
            bot.scenarioEntity = coop.PuppetAt(i);
            bot.scenarioCount = i + 1;
        }
    }
    copy = (CNewNPC)bot.scenarioEntity;
    if(!copy) { return false; }
    height = copy.GetDistanceFromGround(50);
    i = bot.scenarioCount - 1;
    W3T_Log("FLIGHT copy step=" + bot.scenarioStep + " flyingHere=" + (i < coop.PuppetCount() && coop.PuppetFlying(i)) + " stance=" + (int)copy.GetCurrentStance()
        + " height=" + FloatToStringPrec(height, 1) + " alive=" + copy.IsAlive() + " flights=" + coop.puppetFlights + " putDown=" + coop.copiesPutDown + " pos=" + W3T_VecStr(copy.GetWorldPosition()));
    if(bot.scenarioStep == 0 && copy.IsFlying() && height > 3)
    {
        W3T_Log("FLIGHT copy flies here too, " + FloatToStringPrec(height, 1) + " m up");
        bot.scenarioStep = 1;
    }
    if(bot.scenarioStep == 1 && !copy.IsAlive())
    {
        bot.scenarioStep = 2;
        bot.scenarioTime = now;
    }
    if(bot.scenarioStep == 2)
    {
        if(height < 1.5)
        {
            W3T_Log("FLIGHT copy lies on the ground after its death");
            bot.scenarioStep = 3;
        }
        else if(now - bot.scenarioTime > 15)
        {
            W3T_Log("FLIGHT copy FAIL still " + FloatToStringPrec(height, 1) + " m up 15 s after its death");
            bot.scenarioStep = -1;
        }
    }
    return bot.scenarioStep == 3;
}

// monster_states: a monster's untouchable phases and knockdowns show on the second PC. The leader spawns a
// drowner ahead of both players; 12 s later it makes it invulnerable and untargetable (as a noonwraith's or
// alghoul's phase) for 12 s, then knocks it down. The second PC's copy must be invulnerable and untargetable
// while the leader's is, targetable again after, and knocked down too.
function W3T_StatesLeader(bot : W3T_Bot, client : r_MultiplayerClient) : bool
{
    var template : CEntityTemplate;
    var monster : CNewNPC;
    var now : float;
    now = bot.ElapsedS();
    if(bot.scenarioStep < 0) { return false; }
    if(bot.scenarioStep == 0)
    {
        if(client.getCoopEnemies().GetRole() != 1 || now < 25) { return false; }
        template = (CEntityTemplate)LoadResource("characters\npc_entities\monsters\drowner_lvl1.w2ent", true);
        thePlayer.SetImmortalityMode(AIM_Invulnerable, AIC_Cheat, true);
        bot.scenarioEntity = theGame.CreateEntity(template, thePlayer.GetWorldPosition() + VecFromHeading(thePlayer.GetHeading()) * 6.0,
            thePlayer.GetWorldRotation(), true, false, false, PM_DontPersist);
        monster = (CNewNPC)bot.scenarioEntity;
        if(!monster) { W3T_Log("STATES leader FAIL no drowner"); bot.scenarioStep = -1; return false; }
        W3T_Log("STATES leader spawned a drowner");
        bot.scenarioStep = 1;
        bot.scenarioTime = now;
        return false;
    }
    monster = (CNewNPC)bot.scenarioEntity;
    if(!monster) { W3T_Log("STATES leader FAIL the drowner is gone"); bot.scenarioStep = -1; return false; }
    W3T_Log("STATES leader step=" + bot.scenarioStep + " mode=" + (int)monster.GetImmortalityMode() + " targetable=" + monster.GetGameplayVisibility()
        + " knockdown=" + monster.HasBuff(EET_Knockdown) + " alive=" + monster.IsAlive());
    if(bot.scenarioStep == 1 && now - bot.scenarioTime > 12)
    {
        W3T_Log("STATES leader makes it untouchable");
        // AIC_Default: the drowner's own combat tasks keep resetting AIC_Combat (btTaskManageVulnerability)
        monster.SetImmortalityMode(AIM_Invulnerable, AIC_Default);
        monster.SetGameplayVisibility(false);
        bot.scenarioStep = 2;
        bot.scenarioTime = now;
    }
    else if(bot.scenarioStep == 2 && now - bot.scenarioTime > 12)
    {
        W3T_Log("STATES leader ends the phase");
        monster.SetImmortalityMode(AIM_None, AIC_Default);
        monster.SetGameplayVisibility(true);
        bot.scenarioStep = 3;
        bot.scenarioTime = now;
    }
    else if(bot.scenarioStep == 3 && now - bot.scenarioTime > 8)
    {
        W3T_Log("STATES leader knocks it down");
        monster.AddEffectDefault(EET_Knockdown, thePlayer, "W3T");
        bot.scenarioStep = 4;
        bot.scenarioTime = now;
    }
    else if(bot.scenarioStep == 4 && now - bot.scenarioTime > 12)
    {
        W3T_Log("STATES leader kills it");
        monster.Kill('W3T', true);
        bot.scenarioStep = 5;
        bot.scenarioTime = now;
    }
    return bot.scenarioStep == 5 && now - bot.scenarioTime > 15;
}

function W3T_StatesMember(bot : W3T_Bot, client : r_MultiplayerClient, leader : r_RemotePlayer) : bool
{
    var coop : r_CoopEnemies;
    var copy : CNewNPC;
    var i : int;
    coop = client.getCoopEnemies();
    if(!client.getInParty())
    {
        thePlayer.SetImmortalityMode(AIM_Invulnerable, AIC_Cheat, true);
        client.joinParty(leader.username);
        return false;
    }
    for(i = 0; i < coop.PuppetCount(); i += 1)
    {
        if(coop.PuppetAt(i) && StrFindFirst(coop.PuppetAt(i).GetReadableName(), "drowner_lvl1") >= 0) { bot.scenarioEntity = coop.PuppetAt(i); }
    }
    copy = (CNewNPC)bot.scenarioEntity;
    if(!copy) { return false; }
    W3T_Log("STATES copy step=" + bot.scenarioStep + " mode=" + (int)copy.GetImmortalityMode() + " targetable=" + copy.GetGameplayVisibility()
        + " knockdown=" + copy.HasBuff(EET_Knockdown) + " alive=" + copy.IsAlive() + " mirrored=" + coop.statesMirrored + "/" + coop.controlStatesMirrored);
    // scenarioStep: 1 seen untouchable, 2 seen back to normal, 3 seen knocked down
    if(bot.scenarioStep == 0 && copy.GetImmortalityMode() == AIM_Invulnerable && !copy.GetGameplayVisibility())
    {
        W3T_Log("STATES copy is untouchable and untargetable, as the leader's");
        bot.scenarioStep = 1;
    }
    if(bot.scenarioStep == 1 && copy.GetImmortalityMode() == AIM_None && copy.GetGameplayVisibility())
    {
        W3T_Log("STATES copy is back to normal");
        bot.scenarioStep = 2;
    }
    if(bot.scenarioStep == 2 && copy.HasBuff(EET_Knockdown))
    {
        W3T_Log("STATES copy is knocked down, as the leader's");
        bot.scenarioStep = 3;
    }
    return bot.scenarioStep == 3;
}

// monster_objects: what a monster's attacks fire shows on the second PC too. The leader spawns a leshen next to
// both players and lets it fight for 100 s: its roots (underground, bursting out at the target) and crows are its
// own projectile classes. The leader must report at least one root it fired; the second PC must see at least one
// root fired here for it (tagged W3CoopMirror).
function W3T_ObjectsLeader(bot : W3T_Bot, client : r_MultiplayerClient) : bool
{
    var template : CEntityTemplate;
    var monster : CNewNPC;
    var entities : array<CGameplayEntity>;
    var i : int;
    var now : float;
    now = bot.ElapsedS();
    if(bot.scenarioStep < 0) { return false; }
    if(bot.scenarioStep == 0)
    {
        if(client.getCoopEnemies().GetRole() != 1 || now < 25) { return false; }
        template = (CEntityTemplate)LoadResource("characters\npc_entities\monsters\lessog_lvl1.w2ent", true);
        thePlayer.SetImmortalityMode(AIM_Invulnerable, AIC_Cheat, true);
        bot.scenarioEntity = theGame.CreateEntity(template, thePlayer.GetWorldPosition() + VecFromHeading(thePlayer.GetHeading()) * 8.0,
            thePlayer.GetWorldRotation(), true, false, false, PM_DontPersist);
        monster = (CNewNPC)bot.scenarioEntity;
        if(!monster) { W3T_Log("OBJECTS leader FAIL no leshen"); bot.scenarioStep = -1; return false; }
        W3T_Log("OBJECTS leader spawned a leshen");
        bot.scenarioStep = 1;
        bot.scenarioTime = now;
        return false;
    }
    FindGameplayEntitiesInRange(entities, thePlayer, 60, 100);
    for(i = 0; i < entities.Size(); i += 1)
    {
        if(entities[i].HasTag('W3CoopReported') && !bot.scenarioEntities.Contains(entities[i]))
        {
            bot.scenarioEntities.PushBack(entities[i]);
            if((W3LeshyRootProjectile)entities[i]) { bot.scenarioCount += 1; }
            W3T_Log("OBJECTS leader fired and reported " + W3T_SurveyEntityName(entities[i]));
        }
    }
    monster = (CNewNPC)bot.scenarioEntity;
    if(bot.scenarioStep == 1 && now - bot.scenarioTime > 100)
    {
        W3T_Log("OBJECTS leader roots reported: " + bot.scenarioCount + ", projectiles seen " + client.getCoopEnemies().projectilesSeen);
        if(monster) { monster.Kill('W3T', true); }
        if(bot.scenarioCount < 1) { W3T_Log("OBJECTS leader FAIL its leshen fired no root: nothing to compare"); bot.scenarioStep = -1; return false; }
        bot.scenarioStep = 2;
        bot.scenarioTime = now;
    }
    return bot.scenarioStep == 2 && now - bot.scenarioTime > 10;
}

function W3T_ObjectsMember(bot : W3T_Bot, client : r_MultiplayerClient, leader : r_RemotePlayer) : bool
{
    var entities : array<CGameplayEntity>;
    var i : int;
    if(!client.getInParty())
    {
        thePlayer.SetImmortalityMode(AIM_Invulnerable, AIC_Cheat, true);
        client.joinParty(leader.username);
        return false;
    }
    FindGameplayEntitiesInRange(entities, thePlayer, 60, 100);
    for(i = 0; i < entities.Size(); i += 1)
    {
        if(entities[i].HasTag('W3CoopMirror') && !bot.scenarioEntities.Contains(entities[i]))
        {
            bot.scenarioEntities.PushBack(entities[i]);
            if((W3LeshyRootProjectile)entities[i]) { bot.scenarioCount += 1; }
            W3T_Log("OBJECTS copy fired " + W3T_SurveyEntityName(entities[i]) + " for the leader's leshen (roots " + bot.scenarioCount
                + ", fired " + client.getCoopEnemies().projectilesFired + ", failed " + client.getCoopEnemies().projectileFailures + ")");
        }
    }
    return bot.scenarioCount >= 1;
}
