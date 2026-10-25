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
    var i, k : int;
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
            if(StrFindFirst(puppet.GetReadableName(), list[k] + ".w2ent") >= 0)
            {
                if(!bot.scenarioEntities.Contains(puppet))
                {
                    bot.scenarioEntities.PushBack(puppet);
                    // its starting height: the leader's spawn height is not known here
                    bot.surveyLabels.PushBack(list[k]);
                    bot.surveyStartZ.PushBack(puppet.GetWorldPosition().Z);
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
    air = (int)(monster.GetWorldPosition().Z - startZ);
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
