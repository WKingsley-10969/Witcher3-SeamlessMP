# Disconnect and rejoin recovery

This extends the experimental campaign ledger from the cleared-flag feature (PR #2).

For example, one player leaves while a test quest flag exists with value zero. The other player continues, changes another flag and removes the first flag. When the first player returns, their adapter applies the missed events in order. The flag is absent, rather than an existing zero flag. A second rejoin at the same cursor applies no transaction again and does not restart an old conversation.

## Implementation

- `SeamlessCampaign.java`: authenticated `RESUME` restores an expired or restarted transport without consuming a request sequence or replacing its cached result. The client can retry the exact outstanding request, including an effect whose success reply was lost. Existing host proof, session/name ownership, endpoint lease and removal capability checks apply. Expired listeners are removed from future vote membership.
- `seamlessCampaign.ws`: long outages retry automatically. Recovery preserves the pending wire request, sequence and native capture receipt. New campaign actions wait until ordered catch-up reaches the resume boundary. A cached polling response cannot lower that boundary. The event cursor stays intact during an in-process network rejoin.
- Conversation bindings, queued unsent actions and deferred votes/choices are abandoned on recovery. Cached pre-outage OPEN/prompt replies cannot restore them. Historical choice events cannot execute a graph. A bound engine scene already running when recovery starts blocks further local acceptance until that scene exits; this feature does not implement safe arbitrary cinematic restoration or cancellation.
- Fresh processes still use the existing persistent session HELLO sequence negotiation and replay from event zero onto the loaded world. Delivery ACKs never substitute for a save checkpoint.

The server does not depend on an offline player's ACK to continue. Expired owners release scopes through the existing 15-second lease. RESUME itself does not open, renew or reacquire a scope, nor does it append a conversation or transaction event. An expired listener must explicitly LISTEN again before joining future vote membership.

## Verification actually run

- `Test-Seamless.ps1`: **255 existing campaign + 54 removal + 148 recovery + 690 real UDP assertions passed**.
- The recovery tests cover host and guest outages, continuing-peer changes/removals, endpoint migration, duplicate RESUME, exact lost-response retries, an unused request sequence, restart, persistent transaction dedupe, historical conversation receipts and removal capability refusal.
- The UDP scenario closes the guest socket, renews the continuing host for more than the real 15-second timeout, changes/clears flags, returns on another socket, replays and ACKs in order, rejoins again with an empty tail, then kills/restarts its own server and retrieves an unchanged pending polling receipt.
- `node work/seamless/test-rejoin-adapter.cjs`: **74 assertions passed**. This executes recovery methods extracted from production WitcherScript with adapted syntax/defaults and stubbed engine/native APIs. It checks pending request retention, stale polling replies, tombstone and numeric application, capture acknowledgement, historical choice suppression, abandoned scene gating, repeated rejoin and connection retry pacing. It is not a WitcherScript compiler or real engine test.
- `Test-RejoinMutations.ps1`: **5/5** broken server variants caught. Adapter `--mutations`: **7/7** caught.
- `git diff --check` passed.

The deliberate held-file regression emits a campaign persistence error; its test passes by checking recovery from that expected failure. Test suites use owned loopback servers and private temporary campaigns. They do not start the game or edit game saves.

## Game integration for Claude

Branch `codex/disconnect-rejoin-recovery` is based on `codex/campaign-fact-removals` at `ffc2de2`. Integrate PR #2 first, then this feature. Preserve newer dispatcher cases and scene work; do not overwrite whole files from this branch. The new dispatch case is `seamless_rejoin`, with its own `w3test_rejoin.ws`.

The new two-player bot is written but **has not compiled or run in Witcher 3**. It pauses campaign Tick and inbound delivery for 24 seconds in the test mod, twice. The first outage spans host flag changes/removal; the second requires unchanged application/transaction counts. The production adapter has no test disconnect switch. Ordinary party traffic remains running in this scenario, so it is a coordinator outage test, not a cable-pull test. Conversation history/no duplicate graph invocation is covered by the server/source harness; the new game bot does not play a real cinematic.

After integration, using the original checkout's installed JDK, guarded runner and verified isolated game copy, once that shared test setup is idle:

1. Build the merged server with `work/WitcherOnline/server/tests/Test-Seamless.ps1`.
2. Run `node work/seamless/test-rejoin-adapter.cjs`.
3. Run `work/stage-test-game.py` before launching tests.
4. Run `work/run-isolated-test.py seamless_removals --duration 180`, then `work/run-isolated-test.py seamless_rejoin --duration 240`; require both clients to pass each scenario.
5. Run `seamless_effects`, `seamless_replicate`, `seamless_reload_mh306` and `seamless_dialogue` regressions on the merged build. Verify a natural conversation interrupted by disconnect separately before claiming that path works.

Do not use the guarded runner from this checkout: it has no independent test installation, build dependencies or game-slot setup. The other agent's scripts, processes, staging area and package were left untouched. The existing ZIP has not been rebuilt.

## Limits

This is campaign recovery infrastructure, not finished seamless co-op. Removal still permits test flags only. It does not add inventory/XP rewards, arbitrary quest graph restoration, safe cinematic resumption, save-bound reward receipts or network recovery for the ordinary party conversation channel (`coopTalk.ws`). A captured engine write that never committed before its scope expired fails explicitly with the existing capture commit error; recovery does not silently discard or reissue it under a new scope. A replaced campaign, unsupported removal history, invalid credentials, storage failure or inconsistent request sequence stops rather than guessing.

Build/adapter checks passed; game verification and integration remain pending. No merge or player package release is implied.
