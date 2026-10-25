# Engine adapter implementation and evidence

Scope: inspected the installed 5.01 build's shipped script declarations and the pinned WitcherOnline/NativeBridge sources. No game launched by this worker; no guessed offsets or native function signatures installed. The new `seamlessEffects.ws` is awaiting the root's real-game compilation/check.

## Implemented

- `client/seamless/FactDeltaTracker.h`: explicit `sc_test_` ASCII targets only, existence distinct from sum, decreasing values and removal, immutable ordered pending changes, exact generation/revision ACK, bounded all-or-nothing observation and load reset.
- Remote application is bracketed. `BeginRemote` observes earlier local writes before applying; `EndRemote` suppresses only the applied target, retaining queued local changes and detecting unrelated writes. Both calls must execute synchronously on the script thread, without yielding. The caller supplies actual engine snapshots. This cannot distinguish a same-target quest reaction that happens inside that bracket from the committed remote write.
- `local/seamlessEffects.ws`: absolute sum SET, explicit REMOVE, exact journal status lookup/application with readback and side-effect-free preflight. Allowed facts: `sc_test_` plus ASCII letters/digits/underscore, 9–96 characters. Allowed journal tags: exactly `sc_test_journal` and `sc_test_objective`; no asset with those tags is supplied, so missing-entry failure is expected until a fixture is authored. Unknown effect kinds fail.
- Journal apply uses `ActivateEntry(..., false, false)` to avoid implicit parent activation. A future transaction must include parent changes explicitly. Preflight validates all known members but cannot make native engine callbacks transactional or roll them back after an unexpected failure.

`test.cmd` compiled the real header with MSVC C++17 `/W4 /WX` and passed. `mutation_tests.py` built and caught seven guard-breaking twins: allowlist, absent/zero, ACK ordering, retaining local writes, remote echo, stale load generation and queue overflow. The first mutation run exposed a test weakness in generation coverage; it was strengthened, and the final run caught all seven. These tests do not establish engine quest behaviour.

## Exact native bridge contract for integration

```
WO_SCResetFacts() : int
WO_SCWatchFact(target : string) : bool
WO_SCReadFactChange() : string  // generation revision target exists value
WO_SCAckFactChange(generation : int, revision : int) : bool
WO_SCBeginRemoteFact(target : string) : bool
WO_SCEndRemoteFact() : bool
```

`Watch` seeds only the chosen target from current state. Read takes a fresh full engine snapshot and offers one immutable pending change, never silently drops it. Return `ERROR reason` on snapshot/overflow errors rather than conflating error with an empty queue. End reads actual post-apply state, including after a failed helper result. A failed begin skips application; a failed readback/end must not ACK the committed event. Root owns these native integration changes.

The existing native `ReadAllFacts` returns sums per fact and does not retain per-entry timestamps/expiry. The tracker preserves existence (absent versus existing zero) but **cannot** restore `FactsQueryLatestValue`, `FactsQuerySumSince`, temporary entry lifetime, telemetry, or changes which occur and reverse between snapshots. It is not a complete fact-operation interceptor and must never auto-enable arbitrary real quest facts.

## Real script API map

Paths below are relative to `work/test-game/content/content0/scripts` (read-only evidence; game sources are not redistribution payload):

| Primitive | Actual API/callback | Remaining work |
|---|---|---|
| Facts | `game/facts.ws:14–40`: native FactsAdd/Remove/DoesExist/QuerySum, scripted FactsSet | Hook native DB mutation semantics, including quest-node callers and timed entries; snapshot max/sum merging cannot do this |
| Scene facts | `game/scenes/scene_functions.ws:397–421`: AddFact_S/RemoveFact_S include a scene player and call DbFactAdded/Removed | Useful narrow capture path; wrappers cover these script helpers only, not every quest effect |
| Journal | `game/journal.ws:213–238`: ActivateEntry, GetEntryStatus, GetEntryByTag, GetAllChildren | Associate each operation with one quest writer, capture silent updates, order all dependent entries; HUD callbacks only prove reported events |
| Reward | `game/r4Game.ws:992`: CR4Game.OnGiveReward(target,rewardName,SReward) | Wrap before execution to attach transaction context; raw reward XP is scaled by level/difficulty in this body. Replaying the named reward can duplicate randomized items and other effects |
| Exact awarded XP | `game/player/playerWitcher.ws:9330`: AddPoints(type,amount,show), GetPointsTotal | Capture only quest-context EExperiencePoint; generic AddPoints also includes other sources. Persistence checkpoint and per-player dedupe required before adding XP on replay |
| Inventory | `game/gameplayEntity.ws:320–323`: OnItemGiven(SItemChangedData), OnItemTaken(id,quantity); `game/components/inventoryComponent.ws:932,979,1017,5162`: AddAnItem, RemoveItem, RemoveItemByName, AddListener | Stable network item identity plus complete instance data (upgrades/condition/ownership), pre-removal metadata capture, quest/player inventory policy and durable dedupe. Names/counts alone do not serialize unique items |
| Doors | `game/scenes/scene_functions.ws:743`: DoorManager enumerates GetNodesByTag and invokes W3Door/CDoorComponent operations | Must persist state by stable resource identity and defer application until loaded. Empty tag lookup for an unloaded area is not success |
| NPC death | `game/quests/quest_function.ws:7725`: KillWithoutAgony gets a local NPC by tag then calls Kill | Capture stable actor identity and saved state, apply on streaming/load, prevent duplicate death/reward reactions. Never dereference an absent remote-area NPC |
| Scene start | `game/scenes/scenePlayer.ws:44`: OnBlockingSceneStarted(scene) | Notification occurs after engine start. Server ownership acquired here cannot undo already executed pre-scene graph effects |
| Choice input | `game/gui/hud/modules/hudModuleDialog.ws:115`: OnDialogOptionAccepted checks choice then SendSignal(SSST_Accept,index) | Gate before wrapped method, use stable current choice IDs and accepted ownership/vote result, release only one local graph |
| Scene playback | `game/scenes/scenePlayer.ws:272–277`: PlayScene(scene,input), SendSignal; player RestartScene/RestartSection | No exposed safe spectator playback, section/line seek, no-effects mode or replicated scene cursor was found. Starting another copy with PlayScene is not a safe Listen implementation |

## Smallest honest next proof

First verify the test allowlist set/decrease/zero/removal and refusal of a real quest target in two real clients, including replay after host save/load and packet retry. That demonstrates an engine primitive only.

For an actual side quest, first select one concrete short quest and inspect its graph/resource dependencies. Define its complete allowed fact operations, journal entries, reward/item instances, NPC/door/layer changes and branching inputs; then lease its execution to one player, capture all effects into one ordered transaction, defer unloaded entities, and checkpoint the campaign event cursor with host save. The proof must show guest interaction while the host is in another region, all world outcomes after host reload, and no duplicated rewards. No existing code here justifies advertising that result yet.
