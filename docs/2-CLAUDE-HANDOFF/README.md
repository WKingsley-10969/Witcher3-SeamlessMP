# Continue this project in Claude

Handoff written 24 October 2026. This file describes the local workspace at handoff; verify current files and test logs before changing code.

## Live development status — read this first

**25 October 2026 — parallel Codex branch: server verified; game verification pending.** Claude is still active in the original checkout. This separate worktree/branch `codex/campaign-fact-removals` starts from `dd7cae0`; it must not be staged into the shared test game or merged over Claude's work while that work is active. Owned changes: campaign server/protocol tests, `seamlessCampaign.ws`/`seamlessEffects.ws`, a dedicated removal bot, and this branch's notes. Implement explicit absent fact state (distinct from existing zero), durable dedupe/conflicts, snapshot capture and guarded engine application. Test-only targets for removals; mh306 removal has not been vetted. Server/UDP verification used separate build/state paths and ephemeral ports: 255 existing pure + 54 removal + 448 UDP assertions passed, and 5/5 deliberately broken server variants were caught. Game compilation and two-client proof remain pending integration. The older bullets below predate Claude's later journal: read the entries at the end for NPC ownership, quest sharing, save/load replay and shared merchant conversations.

The owner requests that this document stay updated throughout implementation, not only at the end of a session.

### Historical status snapshot (superseded by the journal below)

- **Last verified milestone:** guest-captured FactsSet changes replicate through the campaign ledger to the host (test facts only), plus versioned dialogue/voting, capture, effects and baseline regressions — all passing with two real clients in runs `20261024-202202` to `20261024-202641`. Limits in the last journal entries.
- **Latest continuation:** Claude Code (24 October 2026) fixed the listener join race and a Windows campaign-file replace failure; see the last journal entry.
- **Current work:** none in progress. Dialogue control/vote transport and the narrow fact observer are verified within synthetic-bot limits; no real story scene, cinematic Listen or quest has been tested.
- **Still unfinished:** complete distant vanilla quests and world consequences, cinematic Listen, real story bindings/voting UI, item/XP distribution and save/load reconciliation.
- **State at this update:** all owned clients/servers stopped, UDP 41000 free, game slots released. Source in all three repositories remains modified/untracked and uncommitted; a backup of the pre-Claude state is in `work/backups/`.

### Handoff update rule for every implementation session

1. Before changing a subsystem, record the intended change, owned files and current uncertainty here.
2. After a meaningful edit or test, record the actual result, exact test/run identifier, failures and remaining work. Label work **in progress**, **implemented but unverified**, **verified within stated limits**, or **blocked by a specific finding**.
3. Update this top status when the next step changes. Keep historical entries below so failed attempts are not mistaken for passes.
4. Before ending or handing off, record modified/untracked repositories, active processes/leases, build/staging state and the next concrete command or investigation. Never call a feature complete based only on a server simulator or synthetic quest flag.

### Development journal

**24 October 2026 — continuation started; documentation workflow updated.** Rechecked the three working-tree status lists. Their modifications and untracked files match the prior handoff inventory. No new game build or launch was performed during that read-only inspection. Added this live status and update rule at the owner's request. Next: make the next subsystem changes concrete and keep their progress/results here as work proceeds.

**24 October 2026 — subsystems assigned; in progress.** Following AGENTS phase 5, separate workers own (a) `work/seamless/launcher` and launcher tests for persistent identities and host bootstrap, (b) Java server source/tests and protocol documentation for choice-instance ordering, and (c) native bridge source plus `work/seamless/engine-hooks` for verified effect capture. Root owns the WitcherScript adapter, native client exports, bot harness, stager and this shared handoff. Workers report through their own progress files; root consolidates results here. No new feature is verified yet.

The agreed dialogue extension preserves existing GET_STATE indexes. OPEN returns a fresh lease id; GET_DIALOGUE returns lease/current prompt/accepted choice/vote metadata. CHOICES registers an immutable prompt instance; versioned choice/vote requests carry both lease and instance, so a duplicate click or delayed old vote cannot advance a different prompt. Listener scene execution remains prohibited. Engine investigation found that parsing a native script frame and then calling the original would evaluate argument expressions twice; that approach is rejected. A narrow exact-argument scene-helper capture is being evaluated instead, without claiming every quest-node write is captured.

**24 October 2026 — implementations landed; mixed verification status.** Server dialogue changes are **verified server-only**: latest suite passed 236 pure assertions and 376 real UDP assertions, including guest-owned tied votes, duplicate new-sequence clicks, stale leases/prompts, lost replies, restart replay and format-2 migration. `server-protocol.md` is the final wire reference. Native client `WO_SCInstance` supplies a process-random nonce plus atomic serial; its build passed. Root's `seamlessCampaign.ws` now uses lease/prompt identities, owner-only ordered engine acceptance, prompt metadata polling and UI-refresh handling, but those edits are **not yet game-verified**.

Launcher changes are **verified within PS5.1 fixture/UDP limits**: 23 checks passed, covering protected persistent identities, write-free/redacted Plan, guest secret exclusion, real bootstrap/restart sequence recovery and owned server death detection. PS7 and actual game-launch integration are pending. Root stager writes `.w3lan-seamless.json` with native/script/JAR hashes so baseline files cannot silently enable the new launcher.

The exact effect observer is **implemented but not yet integrated in game**: native queue unit tests passed 92 checks. It records only the scripted FactsSet/AddFact_S/RemoveFact_S helper paths, with duration/telemetry/time metadata; direct native quest-node writes remain outside coverage. Helper provenance comparison passed against the pinned game's shipped scripts. No inline detour or guessed DB signature was installed. Worker progress files: `work/seamless/launcher-progress.md`, `work/seamless/dialogue-protocol-progress.md`, `work/seamless/engine-hooks/progress.md`.

**24 October 2026 — ready for integrated game verification.** Native bridge build and packed-string regression passed with the new exact-operation journal. Its 92 unit checks, 10 mutation twins and 3/3 helper-provenance checks passed. Copied the observer into active mod source as `local/sceneFactCapture.ws`, added reset at the player-load boundary, and added `seamless_capture` bot coverage. This is **implemented but not yet game-verified**; the operation queue is in memory and is not yet replicated through the campaign ledger.

Root's versioned dialogue adapter and `seamless_dialogue` bot are also **implemented but not yet game-verified**. The bot makes the guest own the conversation, the host vote A, the guest vote B, verifies the guest's tie-break, then accepts a fresh second prompt with the same option labels. It deliberately expects zero cinematic/quest-graph executions; this proves transport/control semantics only. Current server results are 236 pure + 376 UDP assertions. Launcher PS5.1 and PS7 each passed 23 checks, including real UDP restart, without launching a game. Next commands: guarded `seamless_dialogue`, then `seamless_capture` and the existing effect regression after staging the current build. Original install/saves remain untouched; test launch results will be appended here.

**24 October 2026 — first integration attempt failed compilation.** Run `20261024-192633-seamless_dialogue` failed before gameplay: `sceneFactCapture.ws(29)` rejected `storyscene` after bare `@replaceMethod`. Both owned clients were stopped by the harness. This is not a dialogue/capture pass. Root is checking plain replacement declarations against the existing storyscene definitions; the engine worker is verifying grammar/metadata. If scene-function replacement cannot be established, retain only the independently testable FactsSet observer and mark scene coverage unverified. Launcher harmless stand-in lease test passed and its owned lease was released before the game attempt.

**24 October 2026 — scope narrowed; second integration run active.** Plain scene-helper replacement declarations passed the initial compiler stage in run `20261024-192728-seamless_dialogue`, but compilation does not establish that storyscene metadata survives replacement. The worker is moving those two candidates out of staged source; only FactsSet will remain enabled for the capture proof. The active run checks the dialogue protocol, not scene-helper correctness. Next: copy the narrowed source after this run, restage and run `seamless_capture`; keep the scene-helper metadata question explicitly unresolved.

**24 October 2026 — wrap-up requested; exact outcomes and next step.** The owner reported 20% usage remaining and requested a wrap-up. No further long game runs will start. `20261024-192728-seamless_dialogue` is **FAIL overall**, not a verified feature: the guest reached stage 8 and logged PASS at t=40.7; the host reached its voting stage and observed the second accepted answer but never satisfied its final condition. The test was stopped while investigating the unmet host condition. Do not infer its cause from those logs. Root added diagnostic fields for vote status, fact receipt, cursor/latest and applied count to `w3test_seamless.ws`, but that diagnostic version has not run yet.

Final implemented scope this continuation:

- Persistent opt-in launcher: **26/26 fixture + real UDP checks passed under both PS5.1 and PS7**, plus an owned harmless gameslot acquire/register/renew/release test. No actual human launcher or second-PC gameplay was tested. Session persistence is not save/world recovery.
- Conversation lease/prompt dedupe and binding votes: **236 pure + 376 actual UDP assertions passed**, including guest initiator tie-break, old prompt/lease rejection, duplicate clicks and restart replay. Native client and bridge builds passed. Real-client adapter is **compiled/partially exercised, integration unresolved** as above; no real story/cinematic test ran.
- Exact operation journal: **92 unit checks and 10 mutation twins passed**. Active global replacement is **FactsSet only**; AddFact_S/RemoveFact_S candidates are in `work/seamless/engine-hooks/candidates/scene-helper-candidates.txt` and must not be copied into the active mod. Its dedicated `seamless_capture` real-game test is **not run**. Queue is local/in-memory, not campaign-replicated; direct native quest-node effects are not captured.
- Handoff and progress notes were updated during work. Stable LAN ZIP was not rebuilt; original game and solo saves were not intentionally modified.

Next continuation: read this entry, verify cleanup/build hashes, then run `work/run-isolated-test.py seamless_dialogue --duration 180` with the new diagnostic trace. Diagnose the unmet host condition before declaring success. Separately run `seamless_capture` against the narrowed source, then `seamless_effects` and appropriate baseline regression. Full distant quest/world persistence, safe cinematic Listen, production story bindings/vote UI, item/XP adapters and save checkpoint/recovery remain unfinished. All three source repositories still contain modified and untracked work; no implementation was pushed or published.

**Final cleanup verified:** no owned game PIDs remain from either attempted run; UDP 41000 is free; workspace game slots are released. Original executable and all 25 recorded solo save/settings hashes are unchanged. The stable LAN ZIP still matches its prior SHA-256. Narrowed FactsSet-only source and the latest diagnostic bot are staged in the independent test copy; neither the narrowed capture bot nor the new dialogue diagnostic version has been rerun. No active worker-owned server/process/lease remains. No new testing is starting during this usage-conserving wrap-up.

## For the owner

The simplest handoff is to use Claude Code locally on this same PC, with this project's folder as its working folder. That gives it the existing source, installed build tools and independent test game. A new chat does not automatically inherit this conversation, so give it the prompt below.

**Do not transfer only a GitHub link. Most new changes are still local, and several important files are untracked in Git.** There are three separate source repositories inside `work`; their changes all matter. No new implementation was pushed or published.

If using a website chat instead, attach this document and the relevant source/docs. An upload alone does not provide access to the local game or test environment. The whole workspace contains an approximately 70 GB game copy: do not upload it as a project attachment. Game files, saves, dumps, profiles, tokens and private logs are not source handoff material.

Have only one coding agent edit this working folder at a time.

### Prompt to paste

> Continue the Witcher 3 LAN co-op project in this working folder. First read docs/2-CLAUDE-HANDOFF/README.md, docs/1-EXAMPLE/README.md, work/seamless/README.md, work/seamless/server-protocol.md, work/seamless/adapter-integration.md and work/seamless/engine/ENGINE-ADAPTER.md. Follow work/coop-playbook/AGENTS.md and its applicable playbooks. Inspect all three nested source repositories and preserve modified and untracked files. The target is host-on-my-PC LAN co-op with a second PC: independent distant side quests in one shared campaign, initiator-controlled side dialogue, optional safe listening, and voting for important main-story choices. Approved rules: initiator breaks ties, quest XP shared, ordinary unique rewards stay with the completing player. The current code is only a foundation; do not claim full quests or cinematic listening work. Continue implementation from the recorded state, use the isolated test copy and guarded bot runner, and keep the plain-language docs updated. First report the actual current state and the next concrete engine milestone, then work on it. Do not modify the original game or solo saves, install new software, download large files or publish anything without the required authorization.

## Goal and current status

The owner wants a BG3-like experience, using Windows Steam Witcher 3 and two PCs on home LAN. Players may separate into different regions. Guest side-quest completion must change the host's shared world, including NPC/item/door/reward consequences, and persist after saving/loading. A journal flag alone does not satisfy this.

Current state: the server foundation and a narrow bidirectional engine-state mechanism are implemented and tested. Arbitrary remote quest execution, full effect capture, safe cinematic spectators, real story bindings, XP/item distribution and host save/ledger reconciliation remain unfinished. There is no reliable completion percentage or ETA.

Read [the plain-language feature guide](../1-EXAMPLE/README.md) and [the technical implementation summary](../../work/seamless/README.md).

## Where the code is

All three repositories use branch `game/seamless-coop`. Work is **not committed/pushed as a finished release**. Preserve their modified and untracked files before any checkout/reset/clean/update operation.

| Location | Purpose / important changes |
|---|---|
| `work/WitcherOnline` | Native client, Java server and gameplay scripts |
| `work/WitcherOnline/server/src/SeamlessCampaign.java` | Durable scoped campaign coordinator, leases, ordered intents, transactions, voting |
| `work/WitcherOnline/server/src/WitcherServer.java` | Opt-in `sc` request/reply routing, reserved control identity |
| `work/WitcherOnline/server/tests` | Pure coordinator and actual UDP integration tests; `Test-Seamless.ps1` builds/tests the JAR |
| `work/WitcherOnline/client/NativeBridge.cpp` | Bootstrap settings and native fact-observation functions |
| `work/WitcherOnline/client/dllmain.cpp` | Coordinator packet handling, control tuple excluded from rendered avatars |
| `work/WitcherOnline/client/seamless/FactDeltaTracker.h` | Allowlisted observations, ordered ACKs, load generation, remote-echo suppression |
| `work/WitcherOnline/witcher/mods/modWitcherOnline/content/scripts/local` | New `seamlessCampaign.ws` and `seamlessEffects.ws`; integration in `client.ws`, `anno.ws`, `coopEnemies.ws` |
| `work/WitcherNativeBridge` | Native registration/marshalling bridge; essential packed string result fix |
| `work/witcher3-coop` | Game bot and multi-client test harness, separate Documents/profile helper |
| `work/witcher3-coop/w3test/modW3Test/content/scripts/local/w3test_seamless.ws` | Synthetic bidirectional test bot, not a real quest test |
| `work/native-tests` | Save-isolation fixture and packed string result regression |
| `work/seamless` | Protocol, engine evidence, adapter integration and native tracker tests |
| `work/research/games/witcher-3/NOTES.md` | Development history, failed attempts and later corrections; read chronologically within each update |
| `docs` | Owner-facing documentation |

The pinned bases are WitcherOnline `3823f98c3364806a4b748f1e4b429101f013bc07`, witcher3-coop `1dea513153ecb4c8eefb2f6b4041d388971f3d09`, native bridge `415e1c1e79a9d5ab78629c70cd3a76131ad98941`. Asio is present at `bd500f0a018db9a845ebaaed5c0318343ae9f497`.

## Working boundaries and important traps

- The owner explicitly authorized implementation, the existing portable JDK download, the baseline prerelease download and C++ Build Tools installation. This is not blanket authorization for unrelated installations, large downloads, account use or publication. Read the AGENTS rules.
- Original game and solo saves must remain untouched. Use only verified independent `work/test-game`. Private build identity and original-file hashes are in `local`; inspect locally and do not publish them.
- Never start a game without the gameslot lease. Use `work/run-isolated-test.py`, which pins the tool, takes slots and registers exact game processes. Do not run the upstream harness directly or kill all processes named witcher3.exe.
- Use 960×540 windows. Two clients consume substantial RAM; run one test pair at a time.
- The old `outputs/Witcher3-LAN-0.2.0-dev.zip` remains unchanged. It does not include these new seamless foundations. Do not describe it as the completed mod.
- Do not rebuild the new client with the upstream default output path: it points at a real game location. Use `work/build-online-client.cmd`, which overrides output into the workspace.
- The stager deliberately excludes `gwintManager.ws`, `gwintGameMenu.ws` and `gwentHooks.ws`, matching upstream's 5.01 packaging. Overlaying every upstream script caused a real compile failure.
- The first enabled runs crashed because the bridge wrote C++ string padding at offset 12 into the next packed engine property. `src/ScriptStringResult.h` now stores only pointer plus uint32 length. Do not restore the old `destination->padding = 0` write. Splitting field declarations did not fix that crash.
- Fact/journal application is restricted to test targets. Fact sums do not preserve expiry/history. No ordinary scene is enabled by default; registrations must be explicit and verified.
- Only a matching conversation owner may advance a bound engine scene. A listener must never run another quest graph as a shortcut to playback. No safe cinematic Listen API was found.
- `LOAD_REQUIRES_CAMPAIGN_RECONCILE` deliberately stops the experimental coordinator after a subsequent in-process load. It is a guard, not implemented save recovery.
- Ledger transaction membership is atomic; engine effects have no general rollback. A server ACK does not mean a game save contains those effects.
- Persistent `WO_SC_SESSION` support exists in native code, but the production launcher does not yet create/store it. The coordinator has development limits, including 64 sessions and roughly 20,000 events, and rewrites a bounded snapshot per sequenced request.

## Build and test on this PC

Run from the project root. The existing Windows C++ Build Tools are used by the batch files. The portable JDK is under `work/tooling/jdk-21.0.12.1+1`; no system Java/PATH changes are needed.

```powershell
cmd /c work\build-native.cmd
cmd /c work\build-online-client.cmd
powershell -NoProfile -ExecutionPolicy Bypass -File work\WitcherOnline\server\tests\Test-Seamless.ps1
```

Use the bundled Python interpreter at `%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe`, or verify an equivalent installed interpreter. Do not assume `python` on PATH is correct. With its path assigned to `$pythonExe`:

```powershell
& $pythonExe work/stage-test-game.py
& $pythonExe work/run-isolated-test.py seamless_effects --duration 160
& $pythonExe work/run-isolated-test.py facts_sync,dialog_sync
```

These commands launch real game clients only inside the guarded isolated workflow. `-verifyscriptsandexit` previously exited 3 without a usable report; it was not counted as passing compilation. Real client runs compiled and executed the scripts.

## Historical baseline checks before the latest continuation

These are the earlier verified runs. The live journal above records newer server/launcher results and the latest failed dialogue integration; do not substitute this baseline for current gameplay verification.

| Check | Actual result / limit |
|---|---|
| Java coordinator tests | 115 assertions passed |
| Real UDP server tests | 145 assertions passed: loss, duplicates, reordering, authentication, crash/restart/replay |
| Native fact tracker | Tests passed; seven guard-breaking mutation twins caught |
| gameslot | 18 checks and 13 mutation twins passed |
| Packed string bounds fixture | Passed; adjacent property canary preserved |
| Enabled two-client `seamless_effects` | Run `20261024-185837-seamless_effects` passed: separate concurrent scopes, six fact SET/decrease/zero transactions applied in both directions; forbidden fact/missing journal refusal |
| Post-fix baseline regressions | Run `20261024-190153-session2`: facts_sync and dialog_sync passed (2/2) |
| Earlier baseline | Seven real-client mechanism scenarios passed before this feature work; see NOTES |
| Original files / stable package | 25 owner save/settings hashes and original executable unchanged; stable LAN ZIP unchanged |

Logs are local under `work/game-testing/runs` and `work/seamless/test-results`. Do not upload private game logs/dumps/saves as source. All game/server processes owned by the completed runs were stopped, the server port released and game slots released at handoff. Inspect again before starting anything new.

## Next engineering milestone

Do not restart from scratch or replace the current work with an unrelated multiplayer mod. First verify the working trees, the latest documentation and the build prerequisites.

The next gameplay proof should be **one real side quest**, completed by the guest while the host is in another region, with all required effects present once on the host and still correct after host save/reload. That requires an actual engine adapter: quest graph control or complete leased effect capture, stable world identity, unloaded-area application and a save checkpoint. Existing facts/journal primitives alone cannot provide it.

Smaller useful implementation tasks include persistent launcher session identities, save/load checkpoint design, stronger choice-instance identity/input dedupe, actual scene/choice mapping and vote UI. Keep them distinct from claiming complete quest support.

Research evidence is in `work/seamless/engine/ENGINE-ADAPTER.md`: the shipped quest graph class exposes no arbitrary suspend/cursor restore API; `PlayScene` starts another graph; facts snapshots omit entry timing/history. Investigate verified native hooks or a clearly bounded quest-specific adapter rather than inventing function signatures or enabling all quest targets.

**24 October 2026 — resumed at owner's request (14% usage remaining).** In progress: rerun versioned dialogue with diagnostic fields, fix the evidenced failure, then run FactsSet-only capture and relevant regression. Root owns adapter/bot edits and notes. No new subsystem claims; previous failed run remains historical evidence.

**24 October 2026 — Claude Code continuation: listener join race fixed; game rerun in progress.** Codex's last diagnostic run `20261024-193822-seamless_dialogue` (FAIL) showed the guest passing while the host's casts returned `NOT_VOTER`. Cause, from its log: the host's single `LISTEN` reached the server about one second before the guest's `OPEN`, received `NO_CONVERSATION`, and was never retried; a later `GET_STATE` snapshot then copied the conversation id into the adapter's `conversation` field, so the host looked joined without being a registered listener/voter. Codex had diagnosed this but had not written a fix (no source file was newer than that run).

Changes (all uncommitted, on `game/seamless-coop`; a diff/untracked backup is in `work/backups/pre-claude-*`):

- `seamlessCampaign.ws`: `GET_STATE` now records `observedConversation`/`observedOwner` and never grants membership; only `OPEN OK`/`LISTEN OK` set `conversation`. A requested listen (`listenRequested`) is retried, throttled to once per second, whenever a snapshot shows the requested conversation and the client is not yet joined. `ListenConversation` is idempotent; `LeaveConversation` cancels an unregistered listen; `OpenConversation` refuses while a listen is pending.
- `w3test_seamless.ws`: DIALOGUE log adds `joined=` and `observed=`.
- `SeamlessCampaign.java`: the same run also ended in `STORAGE_ERROR` — Windows `AccessDeniedException` replacing `campaign.bin` (another process briefly held it open). The atomic replace is now retried up to 10 times with 5–45 ms backoff; a persistently held file still returns `STORAGE_ERROR` and commits nothing. New `transientStateFileLock` test (Windows only) covers both cases; a mutation twin with no retry fails it. **Verified server-only: 239 pure + 376 real UDP assertions passed.**

Results after staging with `work/stage-test-game.py` (real clients, guarded runner, isolated test copy):

| Run | Result |
|---|---|
| `20261024-194522-seamless_dialogue` | **PASS both clients.** Host observed the conversation at 19:46:23, joined via retried LISTEN at 19:46:24, vote returned `OK`; guest tie-break B accepted, second prompt A accepted, zero engine/scene executions. No STORAGE_ERROR. |
| `20261024-194656-seamless_capture` | **PASS** (first real run). Six ordered FactsSet remove/add operations with durations, ordered ACK, remote-echo suppression; direct `FactsRemove` deliberately not captured. |
| `20261024-194800-seamless_effects` | **PASS** regression. |
| `20261024-194909-session2` | `facts_sync` and `dialog_sync` **PASS 2/2** regression. |

Verified within stated limits: listener registration/voting transport with synthetic bots. Still not covered: real story scene binding, cinematic Listen, distant quest effects, campaign replication of captured fact operations, save/load reconciliation, item/XP distribution. Captured fact operations remain local/in-memory.

Next concrete milestone: replicate the captured FactsSet operation queue through the campaign ledger (guest scope → host apply, with ACK only after ledger commit), then pick one small real side quest whose effects are FactsSet-only to attempt the first real distant-quest proof. Separately, persisting only mutating requests would cut snapshot rewrites (GET_STATE/GET_DIALOGUE currently rewrite `campaign.bin` several times per second per client), but changes restart sequence semantics and needs its own UDP tests.

**24 October 2026 — Claude Code: captured FactsSet replication through the ledger (guest → host).** Owned files: `seamlessCampaign.ws`, `seamlessEffects.ws`, `SeamlessCampaign.java` + test, `w3test_seamless.ws`, `w3test_wo.ws`, `run_test.py`, `server-protocol.md`.

- Server: a `fact` value may be `value@validFor` (canonical positive duration); everything else unchanged. **255 pure + 376 UDP assertions passed.**
- Adapter: the scope owner drains the native journal one FactsSet (remove/add pair) at a time into `EFFECT fx_<processNonce>_<gen>_<rev> <scope> fact <target> <value[@validFor]>`; the journal entry is ACKed only after the ledger's `OK`/`DUPLICATE`. Operations captured under another scope wait. Applying a transaction brackets fact writes in both echo guards; the capturing process skips its own `fx_<nonce>_` transactions. Details in `server-protocol.md` → "Captured fact replication".
- New bot `seamless_replicate` (run_test sets `WO_SC_CAPTURE=1` for it): guest owns quest scope `sc_test_replicate` and calls FactsSet a=7@120, a=3, b=0, c=5@3600; host watches the same targets. Run `20261024-201056-seamless_replicate` **PASS both clients**: guest 4 commits, applied 0, queue empty; host a=3, b exists=0, c=5, applied 4, own queue empty (no recapture). Ledger file holds `7@120` and `5@3600`.
- **Regression found and fixed:** the follow-up `seamless_effects` run `20261024-201226` halted both clients with `CAPTURE_BAD_RECORD` — without `WO_SC_CAPTURE=1` the native peek returns `DISABLED`, not empty. PumpCapture now ignores `DISABLED` and halts with `CAPTURE_RECONCILE_REQUIRED` on `ERROR <reason>` (journal overflow). After restaging the fix, **all passed with real clients**: `20261024-202202-seamless_effects`, `20261024-202310-seamless_dialogue`, `20261024-202430-seamless_capture`, `20261024-202534-seamless_replicate`, and `20261024-202641-session2` (`facts_sync`, `dialog_sync` 2/2). No owned game processes remain; UDP 41000 free.

Limits: test facts only (`sc_test_` scope and targets); players stood together; timed facts re-arm their clock on the host; FactsSet helper only; no reconnect-during-commit game test (server dedupe covers it in UDP tests); no save/load reconciliation. Next real milestone: allow capture for a vetted list of one real side quest's facts and attempt the first guest-completes-while-host-is-elsewhere proof.

**24 October 2026 — owner observation: NPCs are not shared.** Watching two bot windows, the owner saw Ciri (an NPC; both bots' players stood still at the same spot) at different points of her walk on each screen, offset by the ~5 s launch stagger. Expected with the current code: each PC simulates the whole world independently; only player avatars, nearby combat enemies (leader-area, ~60 m) and the seamless campaign ledger are shared. A BG3-like experience needs **remote-area/NPC ownership**: one machine owns each nearby non-combat NPC and its scripted movement/scene state, the other renders it (see `outputs/SEAMLESS-COOP-TARGET.md`, "Remote areas"). Not started. Separate milestone from fact replication; likely builds on the coopEnemies.ws ownership/puppet pattern.

**24 October 2026 — Claude Code: "brother" wording removed at the owner's request.** Docs say "second PC". Identifiers renamed: test username `Brother` → `SecondPC` (Java tests; ids `second/talk`, `second_fact`), default/test player `BrotherWitcher` → `GuestWitcher`, default/test campaign `brothers` → `lan-coop` (`Play-Seamless.ps1`, `Test-Campaign.ps1`), and the host console line now reads "The second PC uses the home-network address below" (`Play-LAN.ps1` in both output folders). Stale launcher fixture folders from earlier runs were deleted. Reruns: server **255 pure + 376 UDP passed**; `Test-Campaign.ps1` **26/26** (Windows PowerShell 5.1; PowerShell 7 is no longer installed here, so not rerun); `Test-Lan.ps1` **15/15** for both output folders; edited launch scripts parse. **The packaged `outputs/Witcher3-LAN-0.2.0-dev.zip` was not rebuilt** and still holds the old default name and console text; `work/build-lan-package.py` rebuilds it (it copies the starter's README/PROVENANCE over the package folder and rewrites the ZIP checksum).

**24 October 2026 — Claude Code: first real side quest replicated, second PC → host ("Novigrad Hunt: Da'o", mh306).**

*Research probe* (`seamless_quest_probe`, run `20261024-203748`): the test save is in Novigrad (`levels\novigrad\novigrad.w2w`, `AN_NMLandNovigrad`); 18 notice boards are within 3 km. The second PC took the nearest usable note, `item_name_mh306_contract`, by calling `W3NoticeBoard.AcceptNewQuest` exactly as `NoticeBoardMenu.OnTakeQuest` does (minus a tutorial fact and a sound). Whole-DB diff over 15 s: **exactly one fact, `mh306_job_taken=1`**, then the quest graph activated journal quest `AF164E2C-41CC196D-1AB4BFB6-1DAA9A91` ("Novigrad Hunt: Da'o"). **The FactsSet helper saw 0 writes** — `board.ws:724` uses native `FactsAdd`. A 10 s control window showed only 4 load-time facts (`REWARD_RABBLE_ROUSER_HAIR`, `RemasterSkillResetAndRefund`, `game_is_loaded`, `tutorial_interaction_talk`). The note also adds item `mh306_contract` to the taker's inventory (stays with them, per the unique-item rule).

*Capture point:* the whole-DB snapshot tracker (`FactDeltaTracker`, `WO_SCWatchFact`/`WO_SCReadFactChange`/`WO_SCAckFactChange`), which sees native and quest-graph writes. Changes:
- `FactDeltaTracker.h`: `IsVettedQuestFact` — exactly `mh306_job_taken`; `seamlessEffects.ws` `SC_IsVettedQuestFact` mirrors it for apply. Unit test extended (lookalikes refused); new mutation twin `widen_vetted_quest_facts`; **8/8 twins caught**. Native client rebuilt (`work/build-online-client.cmd`).
- `seamlessCampaign.ws`: `WatchSnapshotFact(target)`; `PumpSnapshot` (throttled 0.5 s; each read copies the whole DB) sends `EFFECT fs_<nonce>_<gen>_<rev> <scope> fact <target> <value>`, ACKed natively only after the ledger OK; own `fs_` echoes skipped. A removal halts with `SNAPSHOT_REMOVAL_UNSUPPORTED` (the ledger has no removal effect yet).
- Development probe `SC_ProbeFactsSet` in the replaced FactsSet (observation only); `engine-hooks/sceneFactCapture.ws` synced and `check_provenance.py` excludes it — still PASS, and an injected extra engine call is caught.

*Real-client result* (`seamless_quest_mh306`, run `20261024-204230`): **PASS both clients.** Host teleported 592 m away first; the second PC owned scope `quest_mh306`, watched the fact and took the notice. Second PC: 1 commit, applied 0. Host: `mh306_job_taken=1` applied from the ledger and **its own quest graph activated the "Novigrad Hunt: Da'o" journal entry**; host fact diff otherwise only the local `farmsvillage_2_noticeboard_empty` (board near where it was parked) and `tutorial_interaction_talk` noise.

What this proves and doesn't: the quest **start** replicates through a real native write and drives the host's own quest graph; replicating the cause (the fact) rather than every effect is how the host's journal followed. Not done: the rest of the contract (investigation, the fight, reward/XP), the notice item, save/load on the host, players on different quest states, removals, any other quest. Replicating facts inherently lets the host's graphs react — fine for state, but a graph that plays a scene or gives a reward would do so on the host too; each vetted fact needs that check.

**24 October 2026 — Claude Code: save/load reconciliation (loading no longer halts co-op).** The owner stopped the post-mh306 regression batch to move on; before stopping, `seamless_effects` (`20261024-204347`) had passed on the mh306 build; the rest did not run. Leftover processes were checked (none) and the run's gameslot lease was released through `gameslot.release`.

Design (`seamlessCampaign.ws`): `OnSessionStart` after the first spawn now calls `ReconcileAfterLoad` instead of halting with `LOAD_REQUIRES_CAMPAIGN_RECONCILE` (removed). Every ledger effect is an absolute value, so replaying all transactions from event 1 onto whatever the loaded save contains is idempotent and ends at the latest committed value. On load: clear scene/prompt state; CLOSE/UNLISTEN any conversation (its NPC is gone); drop snapshot watches (natively reset; callers re-watch); keep an in-flight capture commit but skip its native ACK (`captureOrphan`); new capture nonce so this process's own earlier writes replay too; `cursor = 0`, `liveFloor = latest` so dialogue choices never re-execute. The pending request is kept — its sequence number is used, so dropping it would `REQUEST_CONFLICT`. Two fixes this needed: ACKs only go out for events above `ackedThrough` (the server rejects a lower ACK with `BAD_CURSOR`, which would otherwise loop forever), and a replayed historical `CLOSE` no longer clears a current conversation with the same id.

Bot: `W3T_StartBot` re-enters `W3T_Running` when the bot already exists (a scenario loaded a save; entry functions replace any surviving loop). New `seamless_reload_mh306`: second PC starts mh306 as before; once the host has it, the host loads the run's save again via `LoadGameInit`.

Result, run `20261024-205232-seamless_reload_mh306`: **PASS both clients.** Host log: replicated (`applied=1`) → load → **at spawn, before any replay: `fact=false/0 journal=false`** (the save's own state) → after replay `loads=1 fact=true/1 journal=true applied=2 cursor=2/2`, adapter not halted. The earlier run `20261024-205005` also passed without the at-load log line.

Limits: replay re-applies every transaction one per poll (~0.1 s each), so a long ledger replays slowly; a fact the quest later changes *locally without capture* would be reset to the ledger value on load; only fact/journal effects exist (no removals, items, XP); a newer save than the ledger is not a case here because the ledger is authoritative; only the host loading the same save was tested (not the guest, not a different save, not quitting and relaunching). Regression after this change: `seamless_dialogue` (`20261024-205432`) and `seamless_effects` (`20261024-205552`) **PASS**; capture, replicate and baseline sync were not rerun on this build.

**24 October 2026 — Claude Code: nearby NPC sync, research probe and first prototype.** Started at the owner's request after they saw Ciri at different points of her walk on the two screens.

*Probe* (`npc_probe`, run `20261024-205830`; analysis `work/seamless/npc_probe_report.py <run dir>`): both games listed every living NPC within 60 m every 5 s, paired by wall clock (≈0.8 s apart). About 20 NPCs at the Novigrad save spot; 176/179 NPC samples. Matching: 89 % by a voicetag unique in both worlds, 11 % by template + appearance; ~8 % of the host's NPCs had no copy on the second PC and ~9 % of the second PC's had none on the host. Standing/working NPCs (guards, Redanian soldiers, witch hunters, Ciri there) were identical (median 0 m, same action and work state). The divergence is the wandering torch-carriers (`novigrad_citizen_man_torch`, `novigrad_eternal_fire_priest_torch`): matched copies 7–46 m apart, and some exist on only one PC. Note voicetags contain spaces; generic voicetags (`ETERNAL FIRE GUARD 01`) can repeat.

*Prototype* (`WitcherOnline/.../local/coopNpcs.ws`, hooked into `client.ws` Tick/OnMessage next to coopEnemies; channel `np`): in a formed party, the leader's game owns non-hostile, non-horse, non-combat NPCs within 45 m of the leader or any member in the same area (≤24, 5 snapshots/s: netId voicetag template appearance position yaw speed atWork). The member matches each to its own copy (unique voicetag, else template + appearance nearest within 15 m). Copies that agree (≤2 m, leader's NPC not walking) keep their own AI, so work/idle animations stay; disagreeing or walking ones are taken over (AI forced idle, slide + locomotion like enemy puppets) and handed back after settling 3 s at the leader's work spot. A missing NPC gets a stand-in spawned from the template with all tags stripped (`w3coop_npc_copy`, ≤8); a member-only NPC is hidden only when the leader has an NPC of the same template nearby (a duplicate townsperson).

*Results* (`npc_sync`): v0 run `20261024-210300` — 7–10 synced, all by voicetag, offset mean 0.03 m, but every puppet lost its work state and 2 leader NPCs had no copy. v1 run `20261024-210743` — **PASS**: 15 leader NPCs → 11 by voicetag, 2 by template, 2 stand-ins, 2 second-PC extras hidden; 12 kept their own AI with `work=true` preserved, 3 controlled (1 takeover, 0 handbacks); offset mean 0.01–0.03 m, worst 0.17 m after the first second. A first compile failed on `handle != NULL` as a value (`coopnpcs.ws:331`); fixed.

*Limitations (measured or by design)*:
- Party mode only, same area, NPCs within 45 m of a party member and within 60 m of the leader. Players far apart each keep their own world — intended for independent regions.
- Controlled NPCs only walk/run/slide/turn: their work, idle and gesture animations, one-liners, chatter, scenes and cutscenes are **not** mirrored. A walking NPC's animation quality was not measured.
- Stand-ins are tagless look-alikes: they cannot be talked to or used by quests. A quest NPC missing on the second PC stays missing for its quests.
- Unique member-only NPCs are never hidden, so the second PC can still see NPCs the host does not (e.g. its own quest NPCs).
- The leader's world wins: if the two players are in different quest states, the second PC's copy of a shared NPC (e.g. Ciri following a quest) is driven to the leader's position, which can fight that PC's own quest logic. Ownership per NPC (e.g. the player whose quest owns it) is not implemented.
- NPC reactions to the other player's Geralt, combat transitions and deaths are not synced here (hostiles stay with coopEnemies).
- Tested only at one Novigrad street spot with both players standing, about one minute; no interiors, crowds, horses, boats or different areas. Bandwidth ≈ 5 × ~2 KB/s, fine on LAN, not measured.
- Party regression (`shared_enemy`, `facts_sync`, `dialog_sync`) with NPC sync active: see the next entry.

**24 October 2026 — Claude Code: NPC sync follow-ups (owner observations).**

- Party regression with NPC sync v1 active: `shared_enemy` (`20261024-210946`) **PASS**; `facts_sync` + `dialog_sync` (`20261024-211106-session2`) **PASS 2/2**. Not rerun on the later rubber-band build below.
- "Ciri still unsynced" in the regression windows: those scenarios only form the party ~30 s after load (and leave/rejoin between scenarios); NPC sync is off until then, and Ciri's scripted walk happens right after load. Also v1 left "agreeing" copies alone within 2 m without a facing check, and the probe measured Ciri's copies 1.4 m apart. Agree threshold tightened to 0.5 m and 25°; per-second `CIRI host/member` logging added to `npc_sync`.
- "NPC moves, then is back where he was 2–3 s later": real, caused by the prototype. A copy left on its own AI started its own routine walk, drifted past the tolerance, was taken over and slid back in 0.25 s (run `20261024-211332`: 3 takeovers). Fix: only copies at work on both sides keep their own AI; all others are controlled from adoption; a working copy whose own speed exceeds 0.3 m/s while the leader's stands is taken over at once; drift is corrected by walking (slide time = distance / 1.5 m/s, 0.25–1 s); at most one handback per NPC. New metric `worstSnapBack`. Run `20261024-211614`: **PASS, 0 takeovers, worstSnapBack 0**, offset mean 0.01–0.06 m, worst 0.35 m; 15 NPCs (12 voicetag, 2 template, 1 stand-in), 11 on own AI at work.
- New limitation: **controlled Ciri drifted 0.5 m on the second PC after ~25 s at 1 cm** while the leader's Ciri stood still. Something local (most likely her quest behaviour, which may outrank `ForceAIBehavior(..., BTAP_AboveCombat)`) moves her and the movement adjustor does not fully hold her. Next: try a higher behaviour priority or teleport-pin for stationary controlled quest characters, and measure.

**24 October 2026 — Claude Code: NPC ownership and display stand-ins (immersion layers 2 and 3).** Requested by the owner after the second PC saw Ciri "running in place" when walking up to her.

- Cause of the treadmill and the 0.5 m drift: two drivers on one body. The second PC's real Ciri kept her quest AI (which reacted to the local Geralt), while sync forced her idle at `BTAP_AboveCombat` and pinned her to the leader's position with the movement adjustor.
- Design now in `coopNpcs.ws`:
  - **Ownership (layer 2):** each listed NPC has one owner whose world runs it on its own AI. The leader owns all by default. A member that has its own copy and comes within 4 m (and 1 m closer than the leader) takes it over. It goes back beyond 7 m or when the leader is 1 m closer within 4 m, at most every 2 s. The leader decides, from positions, and sends `owner` in each `np` entry. The member streams owned NPCs and lists the netIds it has copies of on the new `nq` channel (5 Hz).
  - **Replace, don't hijack (layer 3):** a non-owning world never steers its real NPC. It hides it (visibility, gameplay visibility and collisions off) and leaves its own AI running, so quests still see it act. It shows an AI-free stand-in instead: template spawn, tags stripped, talk component disabled, invulnerable. Taking ownership teleports the real NPC to the stand-in's pose and destroys the stand-in. A member copy that already agrees (at work on the same spot, leader's not walking) stays shown on its own AI until it disagrees, then is swapped for a stand-in. One handback is allowed when the hidden copy goes back to work at the leader's spot. The cap is 12 stand-ins; NPCs beyond it are left unsynced on their own AI, never steered.
  - **Stable ids:** the leader keeps an NPC's netId if it drops off the list and comes back (`retiredNpcs`). A member that gets a voice-unique NPC under a new id re-keys the existing puppet instead of adopting it twice.
- Test `npc_own` (new; BotA = leader steps 14 m back from Ciri; BotB = second PC walks up to the Ciri on its screen, stays 25 s, runs off), analysed by `work/seamless/npc_own_report.py`:
  - Run `20261024-213603`: **PASS**, ownership BotB took and returned Ciri, 0 running-in-place steps on either screen. But it showed a **duplicate Ciri**: the leader re-listed her under a new netId, the member adopted a second stand-in, and the old puppet's timeout revealed the real one. Fixed with the stable ids above, and a per-second `visible=` count was added to the log and report.
  - Run `20261024-214024`: **PASS** — Ciri visible exactly once in 64/64 (leader) and 63/63 (second PC) samples; running in place 0/63 and 0/62; swap pop 0.01 m. Mirror error 0.02 m median while the leader owns her and 0.41 m median (max 0.66 m) while the second PC owns her and walks with its Geralt (5 Hz stream, ≈ 0.25 s behind at walking speed). Three ownership hand-overs and three returns in total (Ciri plus two NPCs passed on the way).
- Known effects: after a hand-back the leader's real Ciri is teleported to where the second PC had her, and her own quest AI may then move or teleport her (run 1: 23 m at 30 m from the leader). Hidden real NPCs may still be audible if their AI speaks (not checked).

**24 October 2026 — Claude Code: layer 4 (stand-ins move like the NPC they show).**

- **Work animations on stand-ins: tried, does not work, removed.**
  - `CNewNPC.FindActionPoint` called from mod script **crashes the game** (access violation, BotA rc=3221225477 as soon as it became leader; runs `20261024-214457`, `20261024-214651`). Do not call it.
  - The safe read is `GetActiveActionPoint()` + `theGame.GetAPManager().GetFriendlyAPName(apID)`. It reads `CLayer_"<layer path>"::::<job>`, e.g. `ap_guarding`, `ap_spyglass`, `ap_arms_crossed` (kept as diagnostic `NpcJob()`, logged as `NPCHOSTED`).
  - A stand-in forced into `CAINpcWork` with a `CSimpleActionPointSelector` whose category was the full name (run `20261024-214828`) or the `<job>` suffix (run `20261024-215108`) never reached work (4 started, 0 reached). It just stood on the spot. Either `<job>` is not the AP category or a forced work tree does nothing outside the community system.
  - Work poses are covered instead by the second PC's own copies: in this street 12 of 19 NPCs stayed shown on their own AI at the same job, and two more were handed back after their hidden copy went to work at the leader's spot.
- **Foot sliding fixed.** Stand-ins switched the walk off whenever they caught up between updates, so they slid with idle legs: 19 of 62 seconds on the leader's screen in run `20261024-215108`. The gait now stays on while the owner's NPC moves, and when caught up it faces the owner's NPC's heading. Run `20261024-215447`: 0 of 63.
- **Owned NPCs streamed at 10 Hz** (was 5 Hz). Mirror error while the second PC owns Ciri and walks: median 0.42 → 0.24–0.26 m. `npc_own_report.py` now interpolates the second PC's position to the leader's sample time, because the bots log about 0.5 s apart. The earlier 1.09 m figure was that artifact.
- **Sprinting on the spot after a hand-back fixed.** The leader's teleport of its real NPC to the hand-back spot (25 m) was counted as walking speed, and the second PC's new stand-in ran in place for about 2 s (run `20261024-215447`, anim 3.0, moved 0.01 m/s). Teleports and swaps no longer count as speed (`CoopNpcSpeed`).
- **Latest run `20261024-215722`: PASS.** Running in place 0/62 on both screens; sliding 0/62 on both; Ciri visible exactly once in 63/63 on both; swap pop 0.00 m; mirror error 0.04 m median while the leader owns her and 0.26 m median (max 0.36 m) while the second PC owns her.
- **Remaining effect seen in two runs:** after the hand-back, Ciri's own quest AI on the leader teleports her about 22 m to the same spot (533.68, 2145.33). Both screens show the jump about 1 s apart and agree afterwards. The second PC can see the pop if it is watching her.
- **Not mirrored:** gestures, greetings and one-liners. They run in native behaviour trees that script cannot see; only `CBTTaskPlayAnimationEventDecorator` animations reach script, and those are combat ones.

**24 October 2026 — Claude Code: LAN package rebuilt with NPC ownership.** `outputs/Witcher3-LAN-0.2.0-dev.zip` (SHA-256 `937cd379f686fd16a41d5c06a0b8dcd8567eee176002c7e7367d0399437bf792`).

- `work/build-lan-package.py` previously shipped only `baseline-package` plus two native helpers. It now applies the same overlays as `stage-test-game.py`: current Witcher Online scripts (minus the Gwent overrides), `WitcherOnlineClient.asi`, and the built server jar (in both `mod/bin/w3coop/server` and the launcher's `server/`). It also rebuilds `mod/` from scratch each time, and includes the modified client source (`source/WitcherOnline/client`, git-listed files; the `asio` submodule is referenced, not copied) and the current server source. All 65 payload files match the tested `work/test-game` byte for byte.
- Server: console commands now ignore a UTF-8 byte order mark. On this PC `[Console]::InputEncoding` is UTF-8 with a preamble, so the launcher's `stop` arrived as `\uFEFFstop` and `Test-Lan` failed "server stops gracefully" 14/15, with the old jar too. `Test-Seamless.ps1` 255 + 376 assertions pass. Package `Test-Lan.ps1` 15/15, `Test-Profile.ps1` pass.
- `npc_own` on the final payload: run `20261024-220740` FAILED because the member bot's walk-away target was behind a wall (stuck 4.2 m from Ciri; ownership correctly stayed with it). The bot now picks a navmesh-reachable spot and retries (`W3T_ReachableAway`). Run `20261024-221254`: **PASS**, visible once 64/64 on both screens, no stand-in sliding or running in place, mirror 0.30 m median while the second PC owns her.
- `Install-LAN.ps1` still refuses an existing destination, so a second PC with an older install needs a fresh Setup into a new folder.

**24 October 2026 — Claude Code: shared quest progress in party mode (both directions).** Owner's decision for romance: share the outcome like any story choice; the romance scene itself stays on the PC that played it.

- Before: the inherited W3Coop party sync sent the leader's changed facts (`fx`, `WO_FactsPage` pages of 40 every 0.5 s, all facts changed since its load) and journal statuses (`jr`) to members only, forward-only. Nothing went from a member to the leader. Campaign mode disables both and uses the ledger with its hand-approved list.
- Now (`coopEnemies.ws`): members also send `fx` and `jr`. The leader applies a party member's facts (`OnFacts`, forward-only: raise to the sender's sum, never lower) and journal statuses (`ApplyJournalStatuses`, forward-only). It ignores a member's tracking and scene-skip fields, which stay leader → member. Echoes are no-ops because both rules only move forward. `CoopFactShared()` keeps `game_is_loaded`, `tutorial*`/`Tutorial*` and `RemasterSkillResetAndRefund` per player in both directions. Everything else is shared, romance included.
- Test `quest_share` (new): both bots pick the first three usable notices by key. The second PC takes them with `W3NoticeBoard.AcceptNewQuest` (native `FactsAdd`; returns false but sets the fact), activates an inactive objective and reports its new-quest count. The host never touches a board.
  - Run `20261024-223200` failed only on the test's assumption of 3 new quests: the notices were card-game notices (`cg_baron_discovered`, `cg_stjepan_discovered`, `cg_vimme_vivaldi_discovered`), and only two start quests, on both PCs.
  - Run `20261024-223717`: **PASS**. The host got all three facts, and its own quest graphs activated the same two quests as the second PC ("CG: Novigrad", "CG: No Man's Land"). The objective ("Win unique card from crossroads innkeeper") arrived via `jr`, and the host's `w3t_share_host=7` reached the second PC. Applied counters stayed constant for 8 s on both sides, so no echo loop. Both fact diffs held only the quest facts plus identical load-time facts (`REWARD_RABBLE_ROUSER_HAIR`, `W3ED-8292`, `RemasterSkillResetAndRefund`, `game_is_loaded`, `tutorial_interaction_talk`).
- Limits: only facts and journal statuses travel. A quest step driven by a scene or interaction on one PC does not run the other PC's quest graph; it only catches up where its graph waits on a fact. Decreases and removals are not shared. Rewards or scenes that a graph triggers when reacting to a shared fact would happen on both PCs (not yet observed or checked). Page cycling slows as a session accumulates changed facts (all of them every `pages × 0.5 s`). Campaign mode is unchanged.
- Regression on this build (leader → member path, refactored `OnJournal`): `quest_sync` (`20261024-223923`) **PASS**, `facts_sync` (`20261024-224036`) **PASS**. The LAN package has not been rebuilt with this change.

**24 October 2026 — Claude Code: smoother stand-in movement (owner observation: "a bit stuttery").**

- Metric (new, `MeasureGlide`): per frame, while the NPC a stand-in shows walks (owner pace ≥ 0.5 m/s). A stall is a frame covering under a third of the owner's pace; jerk is the mean |pace change between frames| / owner pace; jumps are frames faster than 8 m/s (teleports). The reference measures the leader's own NPCs walking on their AI the same way.
- Baseline (run `20261024-224432`, old 5 Hz chase): second PC stalls 13.1 %, jerk 1.05; leader 8.3 %, 0.59.
- Changes in `coopNpcs.ws`:
  - The leader sends `np` at 10 Hz (collection and ownership stay at 5 Hz). `np` and `nq` carry the sender's clock (`sentAt`, after the area code).
  - `r_CoopNpcTrack` keeps the last four samples. Playback runs 0.15 s behind on the sender's clock. The clock offset is the least-delayed sample, creeping up by 1 % of elapsed time, so it never jumps.
  - `Glide()` slides each frame, over 0.1 s, to where the NPC will be 0.1 s ahead, with gait hysteresis (`CoopNpcGait`). It catches up at about 3 m/s and teleports beyond 12 m. A teleport or a gap over 1 s restarts the track; a hand-back clears it.
- Bug found on the way: matching by voicetag only checked uniqueness on the member's side. Two leader guards share `ETERNAL FIRE GUARD 01`, so both matched one local guard, and the re-key logic flipped that puppet between the two netIds every snapshot. Its stand-in got positions from two guards alternately (run `20261024-224733`: second-PC jerk 19.5). Voice matching now requires the voicetag to be unique in the leader's list too (`CoopCount`).
- Results:
  - Run `20261024-225112`: second PC stalls 3.9 %, jerk 0.63; leader 1.0 %, 0.33; mirror 0.18 m while the second PC owns Ciri.
  - Run `20261024-225440` (4-sample history, creeping offset): second PC stalls 3.7 %, jerk 0.66, 12 jumps (teleports); leader 3.3 %, 0.37. **Native reference: stalls 3.7 %, jerk 0.21.** Stalls are now at the natural level. Jerk is still about 1.8× natural on the leader and about 3× on the second PC (was about 5×). Whether that is visible is for the owner to judge.
  - All npc_own checks pass: Ciri shown once 64/64 and 63/63, no running in place or sliding beyond 1 sample.
- Next ideas if it still looks stuttery: issue the slide less often than every frame (each frame cancels and recreates the adjustor request, which may fight root motion), and match the walk animation's own speed.

**25 October 2026 — Claude Code: shared conversations (party).** Owner request: when one player talks to someone, the other should watch, listen and vote instead of seeing the NPC stand there.

- Approach (`local/coopTalk.ws`, new): the other PC does not stream the scene. Its own game starts the same conversation, the way the Talk button does (`npc.OnInteraction("Talk", thePlayer)`). A probe (`talk_probe`) showed both games then load the identical `.w2scene` with the same lines and choices, so the joiner gets its own camera, voices and subtitles, and its own quest graph runs the scene.
- Flow:
  - The starter's Talk is captured by `@wrapMethod` on `CNewNPC.OnInteraction` and `W3MerchantNPC.OnInteraction` (merchants override it). When the blocking scene starts within 3 s, the starter sends `coop cv open id scene voice tpl app npc-pos starter-pos`.
  - A party member within 40 m, not in combat or on a horse, finds its copy of the NPC (`coopNpcs.HoldForScene`: unique voicetag, else template + appearance nearest within 10 m). It swaps any stand-in back to the real NPC, keeps NPC sync off it, and moves its Geralt 1.2 m beside the starter facing the NPC (`NavigationFindSafeSpot`). It presses Talk 0.5 s later and reports `cv joined` (or a mismatch if a different scene loads). The join fails if no scene starts within 4 s.
  - The starter chooses. A joiner's click is intercepted in the `OnDialogOptionAccepted` wrapper and sent as `cv vote`; the starter sees "name > choice text" in the dialog alert. The starter's pick goes out as `cv pick id list index text`. The joiner applies it when the same choice list (matched by text at that index) is up there: it highlights the choice, waits 0.6 s and accepts it. Picks for a list that never matches are logged `PICK_UNMATCHED`.
  - Menus the conversation opens (shop, barber, crafting) are closed in the joiner's game; trading is for the one who asked. The scene's `OpenGUIPanelForScene` waits for `GetLastOpenedCommonMenuName() != 'None'`, so the joiner sets that name before `CloseMenu()`. Otherwise its scene waits forever.
  - When the starter's scene ends it sends `cv close`; a joiner still in it leaves, and the NPC goes back to normal sync (`ReleaseScene`).
- Fixes found on the way:
  - **Server channel limit.** `WitcherServer` kept at most 4 coop channels per player (latest message each). Once the leader used `en`/`hurt`/`jr`/`fx`/`np`, a fifth channel (`cv`) was silently dropped. Raised to 12 (`MAX_COOP_CHANNELS`). The same limit could have dropped combat `hurt`/`hit` messages before. The jar was rebuilt; `Test-Seamless.ps1` passes 255 + 376 assertions.
  - Mid-scene `fx`/`jr` changed the joiner's choices: the starter's facts arrived during the scene and gave it a different list. Shared facts and journal statuses, and the inherited leader scene-skip mirror, now wait while this PC is in a shared conversation (`IsSyncing()`). The inherited dialogue-choice sync stays out of shared conversations.
  - The scene accepts the *highlighted* line: `OnDialogOptionAccepted(i)` alone can play a different choice. Applies now call `OnDialogOptionSelected(i)` first, as the older sync did.
- Test `talk_share` (new): the second PC talks to the Novigrad general-store trader; the host stands 10-15 m away. The host clicks "Care to play cards?" (must stay a suggestion). The second PC picks "Tell me about Aeramas' artefacts" (its lines end by opening the shop), closes its own shop, then picks Farewell.
  - Earlier runs: `20261025-094314` (both scenes hung after the shop; panel-name fix), then Farewell playing choice 0 (highlight fix). Runs `-094837`, `-095409` and `-095954` were not staged; `run-isolated-test.py` does not stage, so run `stage-test-game.py` first.
  - Run `20261025-100444`: **PASS**. The host joined (same scene, 13 lines on both), its vote reached the second PC, both picks were applied on the host, the shop the scene opened on the host was closed, and Farewell ended the conversation on both PCs. No mismatches or join failures.
- Limits:
  - Only conversations started with Talk are shared. Quest-triggered scenes (a cutscene that starts on its own, a scene from a trigger area) are not.
  - The joiner is teleported beside the starter.
  - If the host stands closer to an NPC than the second PC, the second PC sees a stand-in, which can't be talked to; it must walk up first.
  - Tested with one merchant conversation, two players, bots. Not tested: a long quest dialogue with cinematic cameras, a choice that starts combat or a cutscene, Gwent, or a joiner whose facts differ before the scene starts. Choice timers are not handled.
  - The server keeps only the latest message per channel. A pick and a close sent in the same tick could lose the pick; the close also ends the joiner's scene.
- Regressions on this build (channel limit, fact deferral, member `fx`/`jr`):
  - `quest_share` (`20261025-101314`) **PASS**; `npc_own` (`20261025-101452`) **PASS**.
  - `member_combat`: `20261025-100837` failed (only 2 of the 3 sword hits connected in 240 s; swings miss often in the passing runs too); rerun `20261025-101817` **PASS**.
  - `shared_enemy`: `20261025-100729` and `-101705` failed; `-102022` **PASS**. Cause: after a hit the leader's drowner keeps losing about 1.5 % health a second with no further hits, and the second PC checks the leader's reading 2 s after each hit with ±0.02 tolerance. The same drain shows in the last passing run before this work (`20261024-210946`, hit 2 read 0.904 instead of 0.92), so it predates these changes. It is not bleeding, poison or burning: a check for those buffs never fired in `-102022`. The source of the drain is still unknown, and the test stays timing-dependent until it is found.
- The project is now one git repo, pushed at the owner's request to `https://github.com/WKingsley-10969/Witcher3-SeamlessMP` (`main`).
  - A whitelist `.gitignore` keeps out the game copy, saves, `local/` identities, test runs, toolchains and binaries.
  - The vendored projects' original `.git` folders moved to `work/upstream-git/<name>.git` (with `core.worktree`), so `git --git-dir=work/upstream-git/WitcherOnline.git status` still diffs against upstream.
  - `client/asio` is a submodule.
  - `run-isolated-test.py` does not stage: run `stage-test-game.py` first.


**25 October 2026 — Codex parallel feature branch, ready for draft PR.** The owner confirmed Claude is active and requested separate work; then requested a PR for each new feature. Branch `codex/campaign-fact-removals` is based on `dd7cae0`. No changes were made to the original checkout or its game processes/staging/package. Implemented an explicit `fact ... absent` ledger value, shared SET/removal conflict key, capability gating for active players and historical replay, snapshot removal submission/commit ACK, guarded removal application, a test-only target allowlist and a dedicated `seamless_removals` bot. The dispatcher adds one scenario case; preserve Claude's newer cases during integration.

Verification actually run: `Test-Seamless.ps1` passed **255 existing pure + 54 new removal + 448 UDP assertions**. Expected STORAGE_ERROR logging comes from the deliberate held-file regression. `Test-FactRemovalMutations.ps1` caught **5/5** mutants (reject removal, skip active capability, skip replay capability, persist absence as zero, bypass removal receipt lookup). All test subprocesses were owned and stopped by these suites. No game process or game-slot lease was started here. Logs/builds remain ignored in this checkout. The new WitcherScript adapter and bot are **implemented but unverified in game**. No removal-specific save/load game test ran; real quest removals remain forbidden, including mh306.

Next: review/merge the feature PR with Claude's current changes, build the merged server, stage once the shared test installation is idle, then run `work/run-isolated-test.py seamless_removals --duration 180` and the effects/replicate/reload/dialogue regressions. Details and plain-language description: `docs/4-FACT-REMOVAL/README.md`. Do not run the guarded game runner in this branch's checkout: it has no isolated test-game installation. Keep the ZIP unchanged until merged game verification passes.

Branch rebased onto `8c920f9` before publication, preserving Claude's additional conversation/combat regression notes. That base update changed documentation only; the tested source is unchanged.

**Publication:** draft [PR #2](https://github.com/WKingsley-10969/Witcher3-SeamlessMP/pull/2) is open against main; implementation commit `a60304d`. Not merged. Owner preference going forward: create a separate feature branch and pull request for each new feature. Draft status reflects pending game verification, not a failed server test. This checkout has no active test processes or game leases.

**25 October 2026 — Claude Code: shared story scenes (scenes a quest starts by itself).** Branch `feature/shared-cutscenes`. Talk together only covered conversations started with the Talk button; the scenes a quest starts on its own still played on one PC.

- Research: quest scenes are started by the engine's quest graph (`CStorySceneSystem.PlayScene(scene, input)` from native quest blocks); scripts cannot see the scene's input name or the graph. Probes `scene_probe` and `ciri_follow` (new) listed the test save's quests: the tracked main quest is "Payback" (Q310), "Go with Ciri to see Whoreson Junior" and "Wait for daylight", at 22:00. Ciri follows Geralt rather than leading; moving the clock to 08:00 with `SetGameTime` did not advance the quest (it waits for real meditation), so no quest scene was reachable in a short test.
- Approach (`coopTalk.ws`): a blocking scene that starts with no Talk pressed is offered to the party like a conversation (`cv open` with empty voice and template). A party member within 60 m (`COOP_SCENE_RANGE`), not fighting, riding or in a scene, is moved 1.5 m from the starter and waits up to 10 s (`COOP_SCENE_WAIT`) for its own game to start the same scene; its quest graph is at the same step through shared quest progress, and is where the scene really comes from, so the scene's own effects run in both games. It then listens exactly like talk together (suggestions, the starter's picks applied, menus closed). If no scene starts, it is put back where it stood (`AUTO_MISSED`). If both games start the same scene on their own, the leader chooses and the other becomes a listener (`HANDOVER`).
- NPC sync during scenes (`coopNpcs.ws`): `HoldAround` holds every synced NPC within 25 m of a scene playing here, as itself (stand-ins swapped back, hidden copies shown) and out of sync until the scene ends (`ReleaseScene`). Before, only the one NPC of a Talk join was held, so a quest scene on the second PC could play with the real NPC hidden behind a stand-in.
- Test `scene_share` (new). Stand-in for a quest's area trigger: each bot starts the general-store trader's scene with `PlayDialog()` (what Talk calls, without Talk) once its Geralt is within 6 m. The host stands at the trader, the second PC 20 m away. Then the second PC walks off with its trigger spent and the host starts the scene again.
  - Run `20261025-103958` and earlier: `StartEmbeddedScene()` is not how this trader starts his scene (returned false). Run `-110328`: the mechanism worked; the host bot stalled in its own shop (its shop closer only covered talk_share). Run `-110932`: everything passed except the return check: the second PC had been nudged 2.7 m before the offer arrived (the host's scene starting; no mod code moves the player), and was put back exactly where it stood when offered; the check now allows 5 m.
  - Run `20261025-111600`: **PASS**. The host's scene was offered; the second PC was brought from 20 m to beside the host, where its own trigger started the same scene; its suggestion reached the host; both host picks played on the second PC; the shop was closed there; the trader was himself (not a stand-in) during its scene; the second, missed scene put it back 0.2 m from where it stood.
- Limits: not yet tried with a real quest graph (the test emulates the quest's trigger); scenes the quest starts only when the player stands in one exact spot may not start for the joiner placed 1.5 m away; a joiner whose quest is at a different step than the starter's is put back after 10 s and does not see the scene; no prompt yet: joining is automatic (the owner asked about an option to watch; a Watch / Skip prompt is queued); the joiner is moved without a fade.
- Regressions on this branch: `talk_share` (`20261025-111934`) **PASS**, `npc_own` (`20261025-112208`) **PASS**.

**25 October 2026 — Claude Code: travel together.** Branch `feature/travel-together` (from `main`).

- Before: in a party, the inherited sync copies the leader's clock and weather while both are in the same region; the console `mpghosts_teleport` could move a player to another. A fast travel left the other player behind.
- Now (`coopTravel.ws`, new; wrappers on `CCommonMapManager.PerformLocalFastTravelTeleport` / `PerformGlobalFastTravelTeleport`, the script functions the map menu calls): a fast travel sends `coop tr ft seq area pin x y z fromArea` (area 0: same region). A party member who stood within 60 m (`COOP_TRAVEL_RANGE`) of where the traveller stood, in the same region, not fighting or in a scene, runs the same fast travel in its own game 1 s later (its own loading screen, autosave and arrival), then steps 1.5 m aside from the signpost spot. Signpost tags are matched by text among the destination's map pins (scripts cannot make a name from a string). Players who were elsewhere stay where they are (`FT_IGNORED`), so the party can still split up.
- Region changes that are not fast travel (a quest moving a player, a boat): if a party member who was within 60 m changes region without having announced a fast travel in the last 60 s, this game follows them there with `ScheduleWorldChangeToPosition` (`REGION_FOLLOW`). Not tested yet.
- Test `travel_together` (new): both stand together at board 0; the host fast-travels to the nearest discovered signpost at least 300 m away; the second PC walks 150 m off and the host travels again.
  - Run `20261025-114311`: the follow worked (the second PC landed on the host's signpost), but the scenario stopped once the players stood 150 m apart: past that range the other player's figure is not shown, and the dispatch required one. Now it requires a known player.
  - Run `20261025-114924`: **PASS**. The second PC followed the trip to `novigrad_southeast_gate_1` and arrived where the host stood; after walking 150 m off it ignored the host's trip to `seven_cats_inn` and stayed put (442 m from the host afterwards).
  - Run `20261025-115152` (follower steps 1.5 m aside after arriving): **PASS**, arrived 1.5 m from the host.
- Test `travel_region` (new), run `20261025-115438`: **PASS**. The host fast-travelled from Novigrad to `an_skellig_harbor` on Ard Skellig (another world, a full load; 348 map pins were listed for the unloaded world, so signposts can be looked up there); the second PC followed with its own load and arrived beside it.
- Limits: the region-change follow (quest or boat, no fast travel) is implemented but not tested yet; after a trip to another region the two players stand on the same spot (the step aside only runs within a region); there is no prompt (it follows whoever was with you, after a notification); a boat trip is not a fast travel and only the region-change rule covers it; both players' clocks jump on their own trip and the leader's clock wins afterwards (inherited time sync).

**25 October 2026 — Claude Code: party death and revive.** Branch `feature/party-revive` (from `main`).

- Before: a party member who died got the normal death screen and reloaded their last save, leaving the other player's game behind. The mod had no death handling of its own.
- Now (`coopRevive.ws`, new): while a party member is alive in the same region, a blow that would kill this player is capped at 1 health point where the game lowers health (`CActor.DrainVitality`, wrapped). The player is knocked down instead (new player state `CoopDowned`: the game's knock-out animation, all actions blocked, `OnCheckUnconscious` true so the game's damage code leaves them alone, a no-save lock).
  - The game's saved immortality flags are not used. They are saved with the game, and all eight channels already have owners (Mutation 11, the god-mode cheat and others).
  - A downed player reports itself as not alive in the movement update, so its figure on the other screens plays the existing death animation and lies on the ground.
- Revive: a party member within 2.5 m who holds Interact for 3 s revives them. The reviver kneels facing the downed player: the game's examine-ground action, which the other screen already shows through the player-action sync. The reviver's state message carries a kneeling flag. When it goes off, the other screens stand the reviver's figure up at once (`r_RemotePlayer.EndKneel`), instead of letting the player-action sync finish its whole 8.6 s examine-ground sequence, which outlasted the 3 s hold. Interact on a downed figure no longer opens the party menu. The revived player gets up with 30% health.
- Respawn: after 30 s without a revive, the screen fades out and the downed player gets up 1.5 m beside a party member, on the first side the navmesh has room on, with 30% health.
- Normal death in these cases:
  - alone, or with every party member down, dead or in another region (after 3 s, so lagging updates do not end it early);
  - in water, on a horse or boat, in a fist fight, in a scene;
  - when the game kills the player outright (`Kill`: quest deaths, kill triggers, falls into the abyss);
  - when the game already protects the player (its own immortality or knock-out rules).
- Messages: `coop dn state downSeq x y z target targetSeq` carries the player's up/down state and its count of knock-downs, plus the last party member this player revived and that member's knock-down count. The client passes a channel's message to scripts only when it changes, so each state reaches the others once.
- Bugs found while testing:
  - `r_RemotePlayer.inGame` is never set for other players.
  - `isAlive` is only kept up to date in the nearby players' list (`getPlayers()`), not in the global list. The helper check now reads it from the nearby list.
  - The first runs therefore found "no party member can help" and the host died normally.
- `stage-test-game.py` now removes files an earlier deploy placed that the current sources no longer have (another branch's scripts, such as `coopTravel.ws` without its client wiring), restoring a backed-up original where there is one, and only if unchanged since deployed. Before, switching branches left them in the test copy and broke the script compile.
- Test `party_revive` (new, `w3test_revive.ws`), run `20261025-125416`: **PASS**.
  - The host took a lethal blow beside the second PC and was knocked down instead of dying.
  - The second PC knelt beside it, held Interact, and revived it (33% health, back in the exploration state).
  - The second PC walked 40 m off and the host took another lethal blow. Nobody came, so after 35.5 s the host got up 1.5 m beside the second PC (33% health).
  - No real deaths.
- Limits:
  - Hold-to-revive uses the real Interact input, but the test simulates holding it.
  - The knock-down and get-up animations, and the kneel as seen on the other screen, were not checked by eye.
  - Enemies may keep attacking a downed player (no damage is taken).
  - A party member who truly dies (the normal death screen) is not noticed by a downed player until their figure reports it.
  - Not tested on two physical PCs.

**25 October 2026 — Claude Code: co-op session (the host's game for everyone).** Branch `feature/coop-session` (from `main`). Step 1 of the co-op lobby; step 2 is a Co-op entry in the main menu.

- **Before:** each PC played its own game. Players loaded their own saves, met in the world and joined a party by hand. Difficulty was each PC's own.
- **Server** (`SaveShare.java`, new): with `--save-dir DIR --host-name NAME`, the server shares the host's co-op save folder read-only over HTTP on TCP port `--save-port`, by default the game port + 1.
  - `GET /session` describes the newest `.sav`.
  - `GET /session/save/FILE` serves one `.sav`/`.png` of that folder by plain name; nothing else is served.
- **Launcher:**
  - `Play-LAN.ps1 -Mode Host` starts the server sharing the host profile's `gamesaves`.
  - `-Mode Join` downloads the host's newest save and its thumbnail into the joining player's co-op `gamesaves` (`Copy-W3LanSessionSave` in `W3Lan.psm1`: size checked, written through a `.download` file). It then starts the game with `W3LAN_SESSION_ROLE=join`, `W3LAN_SESSION_SAVE` and `W3LAN_SESSION_HOST`.
  - `-NoSessionSave` keeps the old way. If the host has no save or the download fails, the launcher warns and plays the old way.
  - Inherited `W3LAN_SESSION_*` variables are removed before launch.
- **Native:** `WO_SessionConfig(key)` (`NativeBridge.cpp`) reads `role`, `save` and `host` from those variables, validated (role `host`/`join`, save and host names from a fixed character set and length). Anything else reads as empty.
- **Game** (`coopSession.ws`, new):
  - a joining player's game loads the host's save from the main menu (`CR4CommonMainMenuBase.OnConfigUI`, wrapped), once per game start;
  - it joins the host's party (retried every 5 s until in it);
  - it steps in 1.5 m beside the host once per load, also when the same save put both on one spot;
  - it applies the host's difficulty (`coop ss diff level`, sent by the host at start and on every change) with the same calls as the options menu (`SetDifficultyLevel`, `OnDifficultyChanged`).
- **Test bot:** the bot's own main-menu save loader leaves the load to the session when `WO_SessionConfig("save")` is set.
- **Harness:** `run_test.py` gives the second PC the join variables for `session_join`.
- **Tests:**
  - `SaveShareTest` (server, 12 assertions): newest save, byte-for-byte files, refusals.
  - `tests/Test-SessionSave.ps1` (launcher with the real server and fixture saves, 8 checks, PowerShell 5.1 and 7).
  - `Test-Lan` 15/15.
  - Game test `session_join` (new): the second PC's game loaded the host's save from the main menu by itself, joined the host's party on the first attempt, stepped in beside the host, and after walking 60 m off stepped in again 1.5 m from it. When the host changed difficulty 2 -> 3, the second PC's game followed within 2 s.
  - Runs `20261025-143129` (PASS; both players still stood on one spot right after loading, now fixed) and `20261025-143445` (PASS: the second PC stepped 1.5 m aside right after loading, and in again after walking off).
- **Limits:**
  - The host shares its newest co-op save, so it should save before others join.
  - The launcher downloads the save before the game starts. Picking a save, or starting together from a menu, is step 2 (the Co-op lobby).
  - A joining player's own co-op progress is replaced by the host's save in that session (their older co-op saves stay in the folder).
  - Not tested on two physical PCs.

**25 October 2026 — Claude Code: co-op lobby in the main menu.** Branch `feature/coop-lobby` (from `feature/coop-session`). Step 2 of the co-op lobby.

- **Before:** the launcher downloaded the host's newest save before the game started, and a joining player's game loaded it at once. Starting together, or starting a new game together, was not possible.
- **Server** (`CoopLobby.java`, new; attached to `SaveShare` on the game port + 1):
  - `GET /lobby?name=NAME` checks a waiting player in, and describes the lobby: host, state (`open`/`started`), start number, mode (`save`/`new`), save, new-game options, seconds since the start, the host's newest save, and the players seen in the last 6 s.
  - `GET /lobby/start?mode=save[&save=NAME]` or `?mode=new&options=N` starts the session; `GET /lobby/open` reopens the lobby. Both are refused (403) unless they come from the host's own PC (loopback).
- **Native** (`NativeBridge.cpp`):
  - `WO_LobbyRequest(path)` / `WO_LobbyResult()`: lobby requests over WinHTTP on one worker thread, so a slow or missing host never stalls the game. Replies come back with lines joined by `|` (scripts have no newline escape).
  - `WO_LobbyFetchSave(name)` / `WO_LobbyFetchState()`: downloads one of the host's saves (and its thumbnail) into this player's co-op `gamesaves` through a `.download` file.
  - `WO_SessionConfig("player")`: this player's name from `WO_USERNAME`. The client only learns its name once in game, and the lobby runs before that.
- **Game** (`coopLobby.ws`, new):
  - In the main menu, a host or joining player gets a **Co-op lobby** popup, and a **Co-op lobby** entry first in the main menu reopens it.
  - The host's popup lists the players waiting. OK starts with the host's newest save: the host loads it and every waiting player follows. New Game in the main menu starts a new game for everyone waiting, with the host's options.
  - A joining player waits in the lobby. When the host starts, their game downloads the host's save if it lacks it, loads it, and the co-op session then joins the party beside the host. On a new-game start it starts the same new game. OK stops waiting.
  - With no lobby on the host's server within 8 s, a joining player's game loads the save the launcher downloaded, as before.
  - A host who loads or continues a game some other way starts the session with its newest save, so waiting players follow.
- **Launcher:** `Play-LAN.ps1 -Mode Join` now marks the game as joining whenever the host's save server answers, also when the host has no save yet, so the game waits in the lobby for a new game. Before, a host without a save meant playing the old way.
- **The main menu pauses the game.** The lobby's clock is real time (`GetLocalTimeAsMilliseconds`): engine time stands still in the menu, which first stopped the polling after two requests. The lobby popup is a progress dialog whose progress requests also drive the lobby.
- **Saves the game did not list at start:** after a download the game lists the new save only after `RefreshCrossProgressionSavesList()` (what the Load menu calls). The lobby calls it and waits up to 10 s for the save (3.7 s in the test).
- **Tests:**
  - `CoopLobbyTest` (server, 14 assertions, including the 403 from a LAN address). `SaveShareTest` now clears its folder, so it passes twice in a row.
  - Game test `lobby_save` (new): the second PC started with no save. The host's lobby listed it, and the host started with its save. The second PC downloaded the save, loaded it, joined the host's party and stood 1.5 m from the host.
  - Game test `lobby_new` (new): neither PC had a save. The host started a new game from the lobby, and the second PC started the same new game.
  - On the final code, merged with `main` (#10, party menu): `lobby_save` (run `20261025-163647`), `session_join` (`20261025-163839`) and `party_revive` (`20261025-164013`) passed.
- **Limits:**
  - The **Co-op lobby** main-menu entry is not covered by the bots, which open the lobby directly.
  - In `lobby_new` both games start the prologue; joining the party then depends on the session's auto-party, which this test does not check.
  - Not tested on two physical PCs.

**25 October 2026 — Claude Code: per-player characters.** Branch `feature/player-characters` (from `main`).

- **Before:** a joining player's game loads the host's save, and a Witcher 3 save holds both the world and Geralt. So the second PC played the host's Geralt: the host's level, skills, gear and money. What it earned was replaced by the host's Geralt again at the next session.
- **Now:** the host's save still brings the world (quests, choices, places), and the second PC then gets its own character back.
- **Game** (`coopCharacter.ws`, new; joining players only):
  - every 20 s it records the character: level and total XP, skill points, learned skills with their levels and skill slots, money, alchemy recipes, crafting schematics, and every item of the character with quantity, durability, equipment slot, enchantment, runes, rune slots, item-level (`autogen`) abilities and bomb/oil charges;
  - 5 s after a load, it replaces the loaded (host's) Geralt with that record: unequips and removes the host's items, resets skills (`ResetCharacterDev`), sets level and XP, gives back all skill points and learns the skills again (so they cost points as in the game), sets the recorded free/used points, equips skills, recipes, money and items;
  - the first time with a host there is no record: the character starts as a copy of the host's Geralt and is the player's own from then on;
  - a record it cannot read is kept, not overwritten; that session plays the host's Geralt.
- **What belongs to the world, not the character:** items tagged quest or notice-board note, the game's hidden items (body parts, hair, fists, scabbards, recipe and schematic items, Gwent cards) and horse gear. These are neither recorded nor removed.
- **Level down and up without the level-up flow:** `W3LevelManager.CoopSetLevel` (added) moves the level and adds or removes the level-up abilities (`Lvl2`...), the way the game's own Blood and Wine standalone start shrinks a level.
- **Restore details found in testing:**
  - Items from finished quests have lost their quest tag in the save, but a re-added item gets it back from its definition. A restored item drops it again, otherwise it would count as a world item.
  - Bombs and oils are single items with charges; the game's `AddAnItem` forces their quantity to 1. They are added with the recorded quantity (`CInventoryComponent.CoopAddItem`), and their charges set.
  - An enchantment fills the rune slots and lists itself as their runes: an enchanted item records only the enchantment.
- **Native** (`NativeBridge.cpp`): `WO_CharacterStore` / `WO_CharacterLoad` keep the record in `The Witcher 3\coop-characters\<host>.txt` in the player's co-op profile, replaced only by a complete new file. `WO_ToName` turns record text into game names (scripts cannot).
- **Tests:** game test `player_character` (new), passed (run `20261025-170728`). The second PC started fresh as a copy of the host's level-31 Geralt. It went to level 29, learned three skills (one in a skill slot), and added a sword with a rune, an enchanted sword, equipped gloves and 777 crowns. It stored the character and loaded the host's save again. After the reload the restored character matched the stored one line for line: 671 items, 3 skills, 4696 crowns, no problems. The world's 32 quest items were unchanged, and the host's character was never touched.
  Regressions passed with this branch: `session_join` (`20261025-171006`), `lobby_save` (`20261025-171141`), `party_revive` (`20261025-171253`).
- **Limits:**
  - Not covered yet: Blood and Wine mutations (the host's stay), the stash, horse gear and the Gwent collection.
  - Durability is recorded and restored, but the test could not wear an item down, so restoring a worn item is not verified.
  - Loot is per player. A container the second PC emptied is full again in the host's next save, and quest items the second PC picked up are the world's (the host's save decides).
  - Only joining players have own characters; the host's Geralt is the save's.
  - Not tested on two physical PCs.

**25 October 2026 — Claude Code: leaving the party sticks on LAN.** Branch `fix/leave-party` (from `main`).

- **Before:** the co-op session joined a joining player to the host's party every 5 s while they were not in it. "Leave party" in the party menu was therefore undone within 5 s.
- **Now** (`coopSession.ws`):
  - A leave the player asks for (`r_MultiplayerClient.leaveParty`, wrapped: the party menu, the old item menu, the `leave` console command) stops the automatic joining, with a notification on how to join again.
  - Any join the player asks for (interact with the host → Join party) turns automatic joining back on. The session's own join calls do not count as the player's.
- **Test:** `party_leave` (new), passed (run `20261025-172746`). The second PC was joined by the session, left the party itself, and stayed out for 15 s with no join attempt. It then joined by itself, and automatic joining was on again.

