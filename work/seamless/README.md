# Experimental seamless campaign foundations

Development branches: `game/seamless-coop` in WitcherOnline, witcher3-coop and WitcherNativeBridge. The existing `outputs/Witcher3-LAN-0.2.0-dev.zip` is unchanged. This is not the finished seamless campaign and has no ordinary quest/scene adapters enabled.

## Latest continuation status

The live record is [docs/2-CLAUDE-HANDOFF](../../docs/2-CLAUDE-HANDOFF/README.md). The owner requested wrapping up to conserve usage. Persistent launcher checks passed 26/26 under both PS5.1 and PS7. Versioned dialogue server tests passed 236 pure + 376 real UDP assertions. Native builds passed. New exact operation journal tests passed 92 checks + 10 mutation twins.

Real-client run `20261024-192633-seamless_dialogue` failed compilation on scene-function replacement syntax. Run `20261024-192728-seamless_dialogue` compiled and partially exercised guest-owned voting/two prompts: the guest passed, the host's final condition remained unmet, so the overall test **failed**. Diagnostic fields were added but have not run. Active capture source is now **FactsSet only**, with scene-helper candidates moved outside the mod. `seamless_capture` has not run; it is not verified in game or replicated over the network.

No test processes/leases are intended to remain active. Check the handoff cleanup entry before resuming. Latest source is staged in the isolated game copy and the stable ZIP is unchanged; staging does not establish passing gameplay.

The user-facing explanation is [docs/1-EXAMPLE](../../docs/1-EXAMPLE/README.md). The selected policy is initiator tie-break, shared quest XP and ordinary unique items kept by the completing player. Item/XP engine application is not implemented.

## Implemented boundaries

- Java coordinator: explicitly configured host, persistent session identities, ordered exact retries, durable transaction ledger, independent quest/NPC scope leases, conversation controller/listeners, binding vote outcomes and reconnect replay. See [server-protocol.md](server-protocol.md).
- Native client: child-only bootstrap settings, reserved coordinator control tuple, safe campaign inbound channel, random session fallback, persistent `WO_SC_SESSION` and fresh choice-instance ids. The opt-in development launcher now supplies persistent identities; see `launcher/README.md` for its tested scope.
- Script adapter: transport/retry/ACK/replay, lease renewal, scoped effect proposals, explicit scene/choice bindings and choice gate. Only the lease owner can advance a matching bound scene. A listener records accepted choices without running another graph.
- Effect primitives: explicitly allowlisted test fact sums and journal tags, preflight/readback, no implicit journal parents, native observation generations and remote-echo bracket. Journal test resources are absent, so only missing-tag rejection can be tested currently.
- Load boundary: native observations reset on spawn. A subsequent in-process load blocks the experimental coordinator with `LOAD_REQUIRES_CAMPAIGN_RECONCILE`; continuing with stale save receipts is not supported.
- Versioned dialogue: server lease + prompt identities, immutable options and binding vote/choice receipts. Root script integration remains unresolved in the failed real-client test above.
- Exact operation observer: `sceneFactCapture.ws` replaces only the scripted FactsSet helper under explicit opt-in scope/watch gates. Direct native quest writes and scene helper replacements are not covered. Queue is in memory; it does not yet publish operations through the campaign coordinator.

## Build and verification

Use the already installed C++ Build Tools and portable JDK; these commands do not install anything:

```
cmd /c work\build-native.cmd
cmd /c work\build-online-client.cmd
powershell -NoProfile -File work\WitcherOnline\server\tests\Test-Seamless.ps1
```

The native client build overrides the upstream output directory and writes only into the workspace. Asio is checked out at `bd500f0a018db9a845ebaaed5c0318343ae9f497`. The native bridge base is `415e1c1e79a9d5ab78629c70cd3a76131ad98941`; its packed string result fix writes only the engine's pointer and 32-bit length, preserving the next property.

`stage-test-game.py` backs up/stages into the verified independent copy only, overlays the current scripts/native builds and keeps upstream's three legacy Gwent exclusions. It never substitutes the baseline JAR for the new server.

Run the Python scripts using the existing bundled Python interpreter:

```
python work/stage-test-game.py
python work/run-isolated-test.py seamless_effects --duration 160
```

`run-isolated-test.py` pins gameslot source and takes a lease before launch. Child game PIDs are registered; cleanup checks process identity. Game windows are 960×540. The `seamless_effects` bot is a synthetic mechanism test: both clients own different test scopes, submit test fact SET/decrease/zero operations and verify the other's state. It is not a natural quest, different-region, reward, save/reload or cinematic test.

Server checks actually passed: 115 pure assertions and 145 real UDP assertions. Native tracker tests and seven mutation twins passed. gameslot's 18 checks and 13 mutation twins passed. Two-client smoke compiled/loaded with experimental mode disabled. `20261024-185837-seamless_effects` passed in both real clients: two simultaneous independent scopes, six total fact transactions (SET/decrease/existing zero) received by both clients; nonallowlisted fact and missing journal targets refused. No party/leader role was needed. Both games and the owned server were stopped. This remains synthetic mechanism proof, not actual quest completion.

Earlier enabled runs crashed during loading and were not passes. The real-game crash identified a bridge bug: writing the 16-byte C++ string header cleared the low 32 bits of an adjacent packed 12-byte engine string property. The fix stores only pointer+length; a native regression fixture verifies a neighbouring property's canary remains intact. Splitting script field declarations did not fix the crash and is not credited as the repair.

After that bridge fix, the existing `facts_sync,dialog_sync` two-client regression session `20261024-190153-session2` passed both scenarios. These remain synthetic baseline mechanism tests. All owned clients exited and the server stopped.

## Remaining engine work

See [engine/ENGINE-ADAPTER.md](engine/ENGINE-ADAPTER.md) for exact script API evidence. Arbitrary quest graph suspension/restoration, complete effect capture, NPC/door/layer changes in unloaded areas, stable item instances, XP receipts tied to saves, safe cinematic spectators and save/ledger checkpoint reconciliation remain unfinished. Snapshotting facts or changing journal status cannot substitute for those systems.

Ledger transaction membership is atomic; engine changes have no general rollback. The format and session/event limits are for development. No public release, account action or contribution has been made.
