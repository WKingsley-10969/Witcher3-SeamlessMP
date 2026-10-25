# Experimental WitcherScript campaign adapter

`work/WitcherOnline/witcher/mods/modWitcherOnline/content/scripts/local/seamlessCampaign.ws`
implements the engine-facing coordinator client. It depends on the separate
`seamlessEffects.ws` test-target primitives and the native `WO_SCConfig` and
remote-fact watcher functions supplied by the integration owner.

This is a gated prototype. It does not implement arbitrary shared quests,
inventory/XP replication, remote quest-graph execution, or spectator playback.
No game was launched by this adapter implementation task. Use the root task's
recorded compiler and real-client results to describe actual validation.

## Configuration and capabilities

The native configuration provider defaults disabled. The adapter reads only:

| Key | Meaning |
| --- | --- |
| `enabled` | Exactly `1` enables the adapter; otherwise its callbacks are inert. |
| `role` | `host` or `guest`; coordinator authenticates the host. |
| `session` | Native random 32-hex session, or validated persistent `WO_SC_SESSION` supplied by a future launcher integration. |
| `proof` | Host secret, host only; never log requests or this value. |
| `effects` | Exactly `1` advertises `fact,journal`; otherwise advertise no effect capabilities. |

Even when effects are enabled, the engine primitives currently accept only
`sc_test_` fact targets and the exact test journal fixture names. A missing journal
entry fails preflight. No item or XP capability is advertised. Main-story scenes
are only those explicitly registered with `BindScene(..., true)`; no path or quest
name heuristic classifies the whole game as main story.

## Existing-script integration

These changes are integrated in the existing scripts. The list documents the
required boundaries for future ports.

1. Add a private `r_SeamlessCampaign` member to `r_MultiplayerClient`, and a lazy
   public `getSeamlessCampaign()` getter, using the existing `getCoopEnemies()`
   pattern (`new r_SeamlessCampaign in this`).
2. Call `parent.getSeamlessCampaign().Tick()` once per normal game tick, after the
   native pump, alongside the existing co-op tick.
3. For inbound COOP opcode 10, while `WO_Str` still addresses that message, call
   `client.getSeamlessCampaign().OnMessage()`. It accepts only `SCServer`, server
   player id `2147483647`, `sc` version 1, its session, and its outstanding sequence.
4. Return before existing automatic leader-dialogue synchronization whenever
   `BlocksLegacyDialogSync()` is true. Also suppress the old journal/fact mirror
   when this adapter is enabled: forward-only legacy updates conflict with
   explicitly committed decreases and absolute sets.
5. Existing `OnBlockingSceneStarted(scene)` and `OnBlockingSceneEnded(output)`
   wrappers call `OnSceneStarted(scene)` and `OnSceneEnded()` respectively.
6. Existing `OnDialogChoicesSet(choices, alternativeUI)` wrapper calls
   `OnChoicesSet(choices)` after recording the client's local choices.
   Player `OnSpawned` also calls `OnSessionStart`: native observations reset,
   and a later in-process load blocks the coordinator until campaign/save
   reconciliation is implemented. A transport ACK is not a save checkpoint.
7. Gate the **entire original body** of the dialogue acceptance wrapper:

```witcherscript
@wrapMethod(CR4HudModuleDialog)
function OnDialogOptionAccepted(index : int)
{
    if(!theGame.r_getMultiplayerClient().getSeamlessCampaign().InterceptChoice(index))
    {
        if(!theGame.r_getMultiplayerClient().isApplyingSyncedDialogChoice())
        {
            theGame.r_getMultiplayerClient().setLastDialog(index);
        }
        wrappedMethod(index);
        theGame.r_getMultiplayerClient().clearActiveDialogChoices();
    }
}
```

Do not add a bare `return;` to that native event wrapper: the real compiler treats
its event return type differently from a plain void function. Server-authorized
application temporarily sets `IsApplyingChoice()` and passes through this gate.

## Test-facing API

Obtain the object through `client.getSeamlessCampaign()`. Call `Tick()` normally;
it performs HELLO and polls without needing a special test transport.

| API | Behavior |
| --- | --- |
| `OpenConversation(id, kind, scope)` | Queue scoped OPEN; kind is `npc` or `quest`. |
| `ListenConversation(id)` | Join a selected scope as listener. |
| `CloseConversation()` | Owner requests CLOSE. |
| `LeaveConversation()` | Owner closes; guest requests UNLISTEN. |
| `RequestChoice(choiceId)` | Owner queues a coordinator choice; engine application still needs matching scene/choice bindings. |
| `RequestVote(choiceCsv)` | Owner opens a vote with 2–8 distinct bounded tokens. |
| `CastVote(choiceId)` | Listener/owner submits its choice. |
| `RequestFactSet(txId, target, value)` | Queue one absolute test fact SET. |
| `RequestJournalSet(txId, target, status)` | Queue one absolute test journal SET after helper validation. |
| `BeginTransaction(txId, count, baseRevision)` | Begin 1–4 explicitly counted members. |
| `AddTransactionMember(txId, memberId, kind, target, value, expected)` | Add a preflighted member; expected is an integer token or `-`. |
| `CommitTransaction(txId)` | Publish the complete declared transaction through coordinator validation. |
| `RetryConnection()` | Explicitly retry a halted request/replay without inventing a replacement mutation. |

Request methods return whether their local queue accepted the intent, **not**
whether the coordinator committed it or the engine applied it. Wait for state,
cursor and engine readback before advancing a test. Public methods can queue an
intent while the routine GET_STATE request is in flight; do not require the
transport to remain idle, since polling is continual. Send one transaction API
step at a time after observing the previous response.

`GetStatus`, `IsReady`, `GetEpoch`, `GetCursor`, `GetLatest`, `GetOwner`,
`GetConversation`, `GetVoteId`, `GetVoteResult`, `GetLastChoice`,
`GetAppliedCount`, `GetTransactionCount` and `HasPendingRequest` expose diagnostics.
`GetLastChoice` records local acceptance for the controller, or an observed
server choice for listeners. It alone does not prove local engine execution.
Applied counts count verified member applications, including idempotent replays;
they are not a claim of exactly-once engine reward execution.

Suggested fact smoke: guest opens a test NPC scope, both participants enable the
test effects capability, submit distinct transaction ids setting `sc_test_fact`
to 7, then 3, then 0. Wait for both cursors/readbacks between requests. Retry the
same transaction id and exact content and check no extra ledger event appears.
Use a different transaction id for a different value. Do not apply these tests to
production quest identifiers.

## Ordering, replay and durability boundary

Only one native request is outstanding. Retries resend its exact bytes every
0.75 engine seconds, at most 12 attempts before an explicit halt. Host proof is
retained solely for HELLO and is never copied into status messages. Sequence
recovery uses the coordinator's expected sequence and re-HELLO; it does not
blindly issue a replacement mutation under a new sequence.

Epoch and server tick are 64-bit wire strings, not script integers. Request
sequence and event ids are bounded small integers. Replay starts at cursor zero,
processes one ordered event per GET_STATE, requires contiguous ids, and rejects
campaigns beyond the prototype's 20,000-event limit. Server-reported sequence
recovery supports a script object recreated in the same process/session.
Without a launcher-supplied persistent session, fresh processes use distinct
sessions; durable coordinator transaction ids, not the script object, provide
mutation deduplication. The 64-session development limit makes persistent
launcher identities necessary before long-term use.

A TRANSACTION validates all members and capabilities before touching the engine.
Each fact uses native watch / BeginRemote / apply / EndRemote with no yield, so
remote writes are not recaptured as new local changes. Application failures do
not advance the event cursor or send ACK. A partial engine failure may have
already applied earlier members; retrying absolute SETs is idempotent, but there
is **no atomic engine rollback**. The server's atomic durable ledger is distinct
from the game's save file. Fact SET preserves the requested sum/existence, not
the original fact entry timestamps, expiry or history. Native fact capture does
not automatically publish production changes in this prototype.

Historical CHOICE events at or before initial WELCOME's event floor are never
executed against the engine after join/load. This prevents replaying old quest
graph choices and rewards. It also means historical dialogue cannot be restored
as a spectator scene by this adapter.
For a new matching CHOICE, only the local lease owner matching the event actor
may call the engine acceptance path. Listeners record the outcome without
advancing a second graph.

## Dialogue limitations and explicit bindings

Register a scene path with `BindScene(path, conversationId, scopeKind, scopeId,
mainStory)` and each permitted local choice with `BindChoice(conversationId,
choiceId, localIndex, exactLocalizedDescription)`. These registries are bounded
at 64 scenes and 128 choices. Unregistered scenes continue using their ordinary
local engine behavior; they do not become coordinated scenes automatically.
For a registered scene, missing readiness/choice mapping blocks acceptance.
Description and enabled-index checks prevent guessing that unrelated local
choices represent the same choice. Localized bindings need separate validation
for each language and scene branch.

An allowlisted main-story choice set automatically opens a vote only if its
bound choices form a supported 2–8-choice set. Local clicks become votes. The
owner ultimately submits the coordinator's binding result, including when it
differs from the owner's own vote. A guest leaving its local scene requests
UNLISTEN; an owner leaving requests CLOSE. Scope collisions are not silently
reassigned to a different conversation alias.

The engine's scene-start callback occurs **after** a scene has started. Reserving
a scope there cannot stop two pre-existing quest graphs from already running.
The shipped `PlayScene(scene,input)` API offers no proven spectator/no-effects
mode, so this adapter never invokes it for listeners. Scoped coordinator leases
are useful authority and ordering primitives; they do not prove one shared NPC
scene, one graph execution, scene seeking, cross-region graph ownership, or a
seamless full campaign.
