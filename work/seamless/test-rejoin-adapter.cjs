// Execute the recovery methods extracted from the production WitcherScript.
// Only syntax/defaults/out-parameters and engine/native APIs are adapted here.
// This does NOT validate WitcherScript compilation, callbacks or engine behavior.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const sourcePath = path.join(__dirname, '../WitcherOnline/witcher/mods/modWitcherOnline/content/scripts/local/seamlessCampaign.ws');
const source = fs.readFileSync(process.argv[2] === '--mutations' ? sourcePath : process.argv[2] || sourcePath, 'utf8');
if (process.argv[2] === '--mutations') {
    const {spawnSync} = require('node:child_process');
    const root = path.join(__dirname, 'test-results', 'adapter-mutations-' + Date.now()); fs.mkdirSync(root, {recursive: true});
    const mutants = [
        ['drop-pending', 'reconnecting = true;', 'reconnecting = true; pendingWire = "";'],
        ['reset-cursor', 'reconnecting = true;', 'reconnecting = true; cursor = 0;'],
        ['lower-replay-floor', 'if(latest > recoveryFloor) { recoveryFloor = latest; }', 'recoveryFloor = latest;'],
        ['repeat-dialogue', 'eventId <= liveFloor || WO_Str(19) != currentSceneConversation', 'false || WO_Str(19) != currentSceneConversation'],
        ['skip-removal', 'if(removeFact) { applied = SC_ApplyFactRemoval(target); }', 'if(removeFact) { applied = true; }'],
        ['enable-abandoned-scene', 'if(recoverySceneBlocked) { lastStatus = "DISCONNECTED_SCENE_REQUIRES_EXIT"; return true; }', 'if(false) { return true; }'],
        ['consume-resume-sequence', 'reconnecting = false;', 'reconnecting = false; requestSeq += 1;'],
    ];
    for (const [name, before, after] of mutants) {
        assert(source.includes(before), 'Missing mutation anchor ' + name);
        const file = path.join(root, name + '.ws'); fs.writeFileSync(file, source.replace(before, after));
        const r = spawnSync(process.execPath, [__filename, file], {encoding: 'utf8'});
        fs.writeFileSync(path.join(root, name + '.log'), r.stdout + r.stderr);
        assert(r.status !== 0 && /AssertionError|Historical choice executed/.test(r.stderr), 'Mutation escaped or failed without an assertion: ' + name);
        console.log('CAUGHT ' + name);
    }
    console.log('Rejoin adapter mutations caught: ' + mutants.length + '/' + mutants.length);
    process.exit(0);
}
let checks = 0;
function eq(a, b) { checks++; assert.deepEqual(a, b); }
Array.prototype.Size = function() { return this.length; };
Array.prototype.Clear = function() { this.length = 0; };
Array.prototype.Contains = function(v) { return this.includes(v); };
Array.prototype.PushBack = function(v) { this.push(v); };
function method(name) {
    const start = source.indexOf('function ' + name + '(');
    assert(start >= 0, 'Missing production method ' + name);
    const brace = source.indexOf('{', start); let end = brace + 1, depth = 1;
    // Production methods here contain no braces inside string literals.
    for (; depth; end++) { if (source[end] === '{') depth++; if (source[end] === '}') depth--; }
    const header = source.slice(start, brace);
    const args = header.slice(header.indexOf('(') + 1, header.indexOf(')')).split(',').filter(x => x.trim()).map(x => x.trim().split(/\s*:\s*/)[0]);
    let body = source.slice(brace + 1, end - 1).replace(/var ([\w, ]+)\s*:\s*([\w<>]+)\s*;/g, (_, names, type) =>
        'var ' + names.split(',').map(n => n.trim() + '=' + (type === 'string' ? '""' : type === 'bool' ? 'false' : type.startsWith('array') ? '[]' : type === 'int' || type === 'float' ? '0' : 'null')).join(',') + ';');
    body = body.replaceAll('SC_ParseFactValue(WO_Str(idx + 3), value, validFor)',
        'parseFact(WO_Str(idx + 3), parsed => { value = parsed.value; validFor = parsed.validFor; })');
    return new Function('s', ...args, 'with(s) {' + body + '}');
}
function fixture() {
    const state = {}, sent = [], facts = new Map(), calls = [];
    for (const [, name, type] of source.matchAll(/private var (\w+)\s*:\s*([\w<>]+);/g))
        state[name] = type === 'string' ? '' : type === 'bool' ? false : type.startsWith('array') ? [] : 0;
    for (const [, name, val] of source.matchAll(/default (\w+) = ([^;]+);/g)) state[name] = JSON.parse(val);
    let now = 100, reply = [];
    Object.assign(state, {
        initialized: true, enabled: true, ready: true, effectsEnabled: true,
        sessionId: 'adapter_session_0001', role: 'guest', proof: '-', epoch: '123',
        requestSeq: 6, cursor: 3, latest: 3, liveFloor: 3, floorInitialized: true,
        ackedThrough: 3, conversation: 'oldTalk', desiredConversation: 'oldTalk', owner: 'SecondPC',
        currentSceneConversation: 'oldTalk', localPromptInstance: 'oldPrompt', conversationLease: 'lease-1',
        SC_IsToken: x => typeof x === 'string' && x.length > 0,
        StringToInt: (x, fallback) => /^-?\d+$/.test(x) ? Number(x) : fallback,
        StrBeginsWith: (s, prefix) => s.startsWith(prefix),
        SC_IsInteger: s => /^-?\d+$/.test(s),
        SC_IsFactRemovalAllowed: s => s.startsWith('sc_test_'),
        SC_CanApplyEffect: (kind, target) => kind === 'fact' && target.startsWith('sc_test_'),
        parseFact: (s, out) => { const value = Number(s); out({value, validFor: -1}); return Number.isInteger(value); },
        WO_Send: wire => sent.push(wire),
        WO_Str: i => i === -3 ? '' + reply.length : i === -2 ? '2147483647' : i === -1 ? 'SCServer' : (reply[i] ?? ''),
        WO_SCWatchFact: () => true, WO_SCBeginRemoteFact: () => true, WO_SCEndRemoteFact: () => true,
        WNB_FactOpsActive: () => false,
        SC_ApplyFactRemoval: target => { calls.push(['absent', target]); facts.delete(target); return true; },
        SC_ApplyFactSet: (target, value) => { calls.push(['set', target, value]); facts.set(target, value); return true; },
        WO_SCAckFactChange: () => true,
        WNB_FactOpsAck: () => true,
        theGame: { GetEngineTimeAsSeconds: () => now, r_getMultiplayerClient: () => ({ getUsername: () => 'SecondPC' }) },
    });
    const names = ['Initialize', 'IsReady', 'IsEnabled', 'OwnsConversation', 'Halt', 'Capabilities', 'BeginRecovery',
        'SendRequest', 'Hello', 'Tick', 'OnMessage', 'ClearConversation', 'CompleteCapture', 'ReadState', 'SelectedConversation',
        'ApplyEvent', 'ApplyTransaction', 'ApplyRemoteFact', 'ReadDialogue', 'RequestChoice', 'InterceptChoice', 'OnSceneEnded'];
    for (const name of names) { const fn = method(name); state[name] = (...args) => fn(state, ...args); }
    state.ApplyChoice = () => { throw new Error('Historical choice executed'); };
    function deliver(status, ...args) {
        reply = ['sc', '1', '123', 'tick', state.sessionId, '' + state.requestSeq, status, ...args.map(String)];
        state.OnMessage();
        eq(state.halted, false);
    }
    function tick() { state.Tick(); return sent.at(-1); }
    function expire() { state.attempts = 12; now += 10; tick(); eq(state.reconnecting, true); }
    function event(latest, id, type, ...payload) {
        deliver('STATE', latest, 'true', '', '', 0, '', '', '', 1, id, type, 'SecondPC', ...payload);
        tick(); eq(state.pendingOp, 'ACK'); deliver('OK', id);
    }
    return {state, sent, facts, calls, deliver, tick, expire, event, advance: seconds => { now += seconds; }};
}
{
    const f = fixture(), s = f.state;
    f.facts.set('sc_test_removed', 0);
    s.SendRequest('EFFECT', '123 oldTx oldTalk fact sc_test_removed 0');
    const pending = s.pendingWire;
    f.expire(); eq(s.pendingWire, pending); eq(s.requestSeq, 6); eq(s.cursor, 3); eq(s.IsReady(), false);
    eq(s.InterceptChoice(0), true); // An abandoned engine scene never becomes a free local choice.
    eq(f.tick(), 'coop sc 1 adapter_session_0001 6 RESUME 123 guest - fact,journal,fact_remove');
    f.deliver('OK', 'oldTx'); eq(s.reconnecting, true); eq(s.requestSeq, 6); // delayed pre-resume reply
    f.deliver('RESUMED', 123, 8, 6); eq(s.pendingWire, pending); eq(s.liveFloor, 8);
    eq(f.tick(), pending); f.deliver('OK', 'oldTx'); eq(s.requestSeq, 7); eq(s.conversation, '');
    f.tick(); eq(s.pendingOp, 'GET_STATE');
    f.event(8, 4, 'DIALOG_CHOICE', 'oldTalk', 'lease-1', 'oldPrompt', 'yes');
    f.tick(); f.event(8, 5, 'TRANSACTION', 'offlineRemove', 'online', 'quest', 'questA', 1, 'single', 'fact', 'sc_test_removed', 'absent');
    f.tick(); f.event(8, 6, 'TRANSACTION', 'offlineSet', 'online', 'quest', 'questA', 1, 'single', 'fact', 'sc_test_changed', '9');
    f.tick(); f.event(8, 7, 'CLOSE', 'oldTalk', 'LEASE_EXPIRED');
    f.tick(); f.event(8, 8, 'OPEN', 'otherTalk', 'npc', 'npcB');
    f.tick(); eq(s.IsReady(), true); eq(s.cursor, 8); eq(s.transactionCount, 2);
    eq(s.engineChoiceCount, 0); eq(f.facts.has('sc_test_removed'), false); eq(f.facts.get('sc_test_changed'), 9);
    eq(s.InterceptChoice(0), true); s.OnSceneEnded(); eq(s.recoverySceneBlocked, false);
    // Rejoin again without resetting the cursor: no repeat engine writes.
    if (!s.pendingWire) s.SendRequest('GET_STATE', '123 8 -');
    f.expire(); f.tick(); f.deliver('RESUMED', 123, 8, s.requestSeq - 1);
    f.tick(); f.deliver('STATE', 8, 'true', '', '', 0, '', '', '', 0); f.tick();
    eq(s.IsReady(), true); eq(s.transactionCount, 2); eq(f.calls.length, 2); eq(s.recoveryCount, 2);
}
{
    const f = fixture(), s = f.state;
    s.liveFloor = 5;
    s.SendRequest('GET_STATE', '123 3 oldTalk');
    f.deliver('STATE', 5, 'true', 'oldTalk', 'SecondPC', 10000, '', '', '', 1,
        4, 'DIALOG_CHOICE', 'SecondPC', 'oldTalk', 'lease-1', 'oldPrompt', 'yes');
    eq(s.engineChoiceCount, 0); eq(s.cursor, 4);
}
{
    const f = fixture(), s = f.state;
    s.SendRequest('GET_STATE', '123 3 oldTalk'); f.expire(); f.tick(); f.deliver('RESUMED', 123, 8, 6);
    f.tick(); // A cached pre-outage STATE must not lower the catch-up barrier.
    f.deliver('STATE', 3, 'true', '', '', 0, '', '', '', 0);
    eq(s.recoveryFloor, 8); f.tick(); eq(s.IsReady(), false); eq(s.pendingOp, 'GET_STATE');
}
{
    const f = fixture(), s = f.state;
    s.captureTx = 'fs_nonce_1_2'; s.captureInFlight = true; s.captureFromSnapshot = true;
    s.SendRequest('EFFECT', '123 fs_nonce_1_2 oldTalk fact sc_test_removed absent');
    f.expire(); f.tick(); f.deliver('RESUMED', 123, 4, 6); f.tick(); f.deliver('OK', 'fs_nonce_1_2');
    eq(s.captureCommits, 1); eq(s.captureTx, ''); eq(s.requestSeq, 7);
}
{
    const f = fixture(), s = f.state;
    s.SendRequest('GET_STATE', '123 3 oldTalk'); f.deliver('HELLO_REQUIRED');
    eq(s.pendingOp, 'GET_STATE'); eq(s.reconnecting, true); eq(s.requestSeq, 6);
}
{
    const f = fixture(), s = f.state;
    s.ready = false; s.epoch = ''; s.Hello(); f.deliver('SESSION_ACTIVE');
    const sends = f.sent.length;
    for (let i = 0; i < 100; i++) f.tick();
    eq(f.sent.length, sends); f.advance(2); f.tick(); eq(f.sent.length, sends + 1);
    // Initial connection can outlast the retry window without losing HELLO.
    s.attempts = 12; f.advance(10); f.tick(); eq(s.halted, false); eq(s.pendingOp, 'HELLO');
    const before = f.sent.length; f.tick(); eq(f.sent.length, before);
    f.advance(2); f.tick(); eq(f.sent.length, before + 1);
}
console.log('Rejoin adapter source checks passed: ' + checks + ' assertions (engine APIs stubbed)');
