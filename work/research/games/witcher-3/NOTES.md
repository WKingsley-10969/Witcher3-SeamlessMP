# Witcher 3 co-op research — 2026-10-24

## Latest continuation — wrap-up and live handoff

Owner requested further implementation, continuous updates to docs/2-CLAUDE-HANDOFF/README.md, then a wrap-up with 20% usage remaining. New opt-in campaign launcher passed 26 fixture/actual-UDP checks in both PS5.1 and PS7, plus a harmless owned-process gameslot lifecycle test. Versioned dialogue server passed 236 pure assertions and 376 actual UDP assertions. Native bridge/client builds passed. Exact-operation journal passed 92 native checks and 10 mutation twins. This remains development source, not a new released LAN package.

Root integrated lease/prompt identities, metadata polling, fresh nonce/serial prompt ids, owner-only ordered choice application and bot coverage. Actual game run 20261024-192633-seamless_dialogue failed compilation: storyscene qualifier after bare @replaceMethod was rejected. Plain candidates compiled during 20261024-192728-seamless_dialogue, but metadata preservation was unproven; both scene helper replacements were removed from active source and kept as non-staged research candidates. Active exact capture is FactsSet only, not native DB/quest-node interception. It records local operations but does not replicate them yet.

Run 20261024-192728-seamless_dialogue is FAIL overall: guest reached stage8 and PASS at t40.7; host saw the second accepted answer but did not meet its final test condition. Stopped both exact owned game PIDs and server. New trace fields (vote status/fact/cursor/applied count) were added but not rerun. No dedicated seamless_capture game run was performed. Narrowed source was copied and restaged into the verified isolated copy for continuation. Staging is not verification. Shared-world quest execution, cinematic Listen and save checkpoint recovery remain unfinished.

The live handoff and docs/3-DEVELOPMENT-STATUS/README.md record the current code, test limits, failures, next command and cleanup state. Original install/saves and existing stable ZIP are to be rechecked unchanged at final cleanup; no publishing/account action occurred.

Final cleanup checks passed: original executable, 25 solo save/settings hashes and stable ZIP unchanged; no owned game PIDs remained, UDP41000 free and gameslot files released. Narrowed source and diagnostic bot staged but not rerun. All worker-owned processes/leases stopped. No further game testing began after the owner's wrap-up request.

## Implementation update — seamless foundations

The owner explicitly requested implementation and approved initiator tie-breaks, shared quest XP and unique item rewards staying with the completing player. Created game/seamless-coop branches in both source checkouts. As AGENTS phase 5 requests, subsystem workers implemented the server coordinator, script adapter and engine primitives independently; root integrated the native transport, callbacks, guarded runner and tests. Nothing published or written into the original game/save folders.

Implemented experimental scoped conversation/quest leases, exact request retries/dedupe, persistent ordered transaction membership, explicit host authentication, vote outcomes, reconnect replay and capability gates. Native bootstrap reads only allowlisted child settings, uses a random/persistent session id, reserves SCServer as a control endpoint and excludes it from avatar rendering. The script adapter uses explicit scene/choice bindings; no ordinary story scenes are enabled by default. Listening does not run a second scene graph. Absolute fact/journal primitives are limited to test targets, not arbitrary quest data.

Server tests actually ran: 115 pure assertions and 145 real UDP assertions (loss/duplication/reordering/authentication/crash/replay). Native FactDeltaTracker tests and seven mutation twins passed. Root rebuilt the native client successfully. Adopted pinned gameslot tool commit 5b86e5bb10ce864ab9872f2589651f73ffcae5db; SHA-256 7a939829c6a782c774226a5c72f4137c1b94af60730d02c75b6251bfd2ceaf3d. Its 18 checks/13 twins passed. Future test games take leases and register exact process identities.

Real compiler caught a reserved identifier, unavailable member/global helper calls, unsupported handle comparison and a bare return in a wrapped event; fixed those. Source staging initially included three legacy Gwent files intentionally excluded by upstream's 5.01 deploy script. Corrected the stager to apply the documented exclusion and removed only the exact manifest-tracked staged files. Two real clients then compiled/loaded and passed smoke with campaign mode disabled. First enabled seamless_effects run crashed both games with access violations during save loading; not a PASS. Diagnostics and another run are underway. The stable LAN ZIP remains unchanged.

Engine evidence: shipped CQuestGraphBlock exposes no arbitrary graph suspend/cursor restore API. Scene PlayScene starts another graph; no safe no-effects spectator API was found. Fact snapshots lose entry expiry/history. Therefore distant vanilla quest execution, full effect capture, shared item/XP awards, cinematic Listen and host save/checkpoint reconciliation remain unfinished. An in-process load currently blocks the experimental coordinator rather than continuing with stale engine receipts.

Created docs/1-EXAMPLE/README.md with plain-language examples, the user's selected rules and explicit prototype limits.

Subsequent enabled runs isolated a native bridge memory corruption bug. Its 16-byte C++ ScriptString representation wrote padding at byte 12 into an adjacent packed engine property. Role assignment then session assignment zeroed the low pointer bytes of role; crash dumps showed a five-byte copy from a pointer with zero low 32 bits. Splitting script field declarations did not repair it. Replaced the bridge result write with pointer+uint32 length only, added a neighbouring-property canary regression fixture and rebuilt successfully. Two real clients then loaded with the feature enabled and passed seamless_effects at run 20261024-185837-seamless_effects: concurrent separate test scopes, both directions of six accepted fact SET/decrease/zero transactions, forbidden fact/missing journal refusal. No party leader required. All owned game/server processes stopped. This is not a natural quest/different-region/save-reload/listening proof. Owner executable and 25 saved settings/save hashes were checked unchanged.

Post-fix baseline regression session 20261024-190153-session2 passed facts_sync and dialog_sync (2/2) in two real clients with campaign mode disabled. Both clients exited normally and server cleanup completed. The plain-language document now includes the enabled test's narrow scope instead of the earlier loading-failure status.

## Clarified target: independent quests and dialogue ownership

The owner clarified that the goal is one shared campaign with independent side quests in different areas, initiator-owned dialogue, optional nearby listen-in, and main-story voting. This supersedes the earlier suggested stay-near-host scope as the intended final behaviour. The 0.2.0-dev package remains a limited prototype; its passing host-to-member tests do not satisfy this clarified target.

Rechecked source directionality, distance/area checks and dialogue hooks; read the effect-capture-story-sync design guidance. Saved outputs/SEAMLESS-COOP-TARGET.md with requirements, proposed boundaries, unresolved policies and an end-to-end proof plan. Remote quest execution and spectator scene playback are unproven engine capabilities. No new seamless-coop implementation is claimed in this update.

## Game integration update — LAN development package

The owner installed the Steam game and explicitly approved the 163 MB W3Coop package and Microsoft C++ Build Tools installation. Recorded private identity in local/identity.json: Steam build 25773555, exe resource version 5.0.0.1048522, SHA-256 2df765398a3d1f165db418271be7200178320a4466817379f2fa0dc0001fb101. The engine signature scanner returned unknown; REDengine 3 remains supported by documented engine identity and the shipped WitcherScript/bundle layout, not that scanner result.

Copied and verified 1,926 files (about 69.76 GB) into an independent test game. Only that copy was staged. Source executable and 25 original save/settings hashes were rechecked unchanged after tests. No owner saves were included in deliverables.

Downloaded W3Coop v0.2.0 from its official release; SHA-256 matched 4fdf767c7f4208c86fde3e5321169b3ffb22b1cf3bb571ee0e12a8b437ccaed3. Installed Microsoft-signed VS 2022 C++ Build Tools with the Windows SDK after owner approval. Built WitcherNativeBridge from 415e1c1e79a9d5ab78629c70cd3a76131ad98941 and modified w3test.asi.

### Observed issues and fixes

- Upstream save isolation could log success despite a missing required hook, and its wide-path hook could fall back to real Documents on a long path. Fixed hook-install validation, missing/invalid-path termination, canonical-directory owner/alias checks and VirtualProtect error handling. All three Documents imports were confirmed on the pinned executable.
- Added W3LAN_DOCUMENTS human profile mode: save/settings redirects only, with no test bots, audio muting or focus/input hooks. PowerShell prepares persistent co-op profiles using copies of solo saves/settings and clears inherited W3T bot flags.
- Compiler-only flag exits code 3 without a report on this build; treated as unresolved, not PASS. A deliberately broken script produced a compiler error and was removed. Real clients subsequently compiled and executed the mod/test scripts.
- member_combat originally failed with melee count 1 and an immortal dummy near one HP. Vanilla damage clamps immortal damage at one HP; the test dummy now replenishes itself. Required real-hit/effect thresholds were unchanged. A first diagnostic placed the change in another helper; it was ineffective, removed, and not counted as passing. Corrected member_combat passed with 4 melee and 2 sign hits.
- An automatic approval review previously hit an account usage limit, preventing a combined rebuild/action from running. The owner requested continuation; retry succeeded. No approval restriction was bypassed.

### Checks actually run

- Native helper standalone processes: 10/10 passed, including human mode, missing hooks, invalid paths and owner slash/dot aliases.
- Server/launcher suite: 15/15 passed again in Windows PowerShell 5.1; earlier PowerShell 7 suite also passed.
- Profile fixture: passed in PowerShell 5.1 and 7 (seed unchanged, progress preserved, no inherited bots, altered helper rejected).
- Human profile startup: 35-second real-game smoke passed; required hooks installed, no test input/audio behaviour.
- Two real game clients on one PC: see_each_other, movement, shared_enemy, member_combat, quest_sync, facts_sync and dialog_sync PASS. The latter story cases are scripted mechanism checks, not completed natural quests.
- Packaged installer disposable fixture: copied/staged independently, source unchanged, existing destination and changed payload rejected. Not a second full game installation or second PC.

The owner requested larger windows; active test windows were resized to 960x540 and subsequent tests use that size. Game and server processes started by the runs were stopped.

### Deliverable and limits

Prepared outputs/Witcher3-LAN-0.2.0-dev.zip: baseline native mod with source/licenses, direct-LAN launchers/server, separate-profile helper and isolated-copy setup. The ZIP was checked for corruption, payload hashes, and absence of game executables, saves, profiles and private local paths. No public release, PR, issue or social/account messaging was performed.

Final package: 163,230,161 bytes, SHA-256 65dab144bc598f67a02e2140988d66e6747221cdadadb06c7d6b58a09d0e7f36. Archive verification covered 139 files and 61 payload hashes. Final read-only review found no blocker in documented setup/host/join flow. Nonblocking limits: Play-LAN -Plan can prepare/seed a profile; unexpected server exit is not actively reported while the game runs. These are not claimed as crash/recovery support.

A second 35-second human startup smoke passed with modW3Test temporarily removed from the isolated copy, matching the human payload (no automation scripts). The scripts were restored afterward for future bot tests. Owner save/settings hashes remained unchanged. All owned game/server processes were stopped at completion.

Not proven: two physical PCs/LAN link, natural campaign and expansion coverage, travel/death/rejoin recovery, long sessions or full seamless behaviour. Core shared gameplay remains upstream W3Coop/Witcher Online. This milestone adds LAN integration, isolation and targeted verification.

## Development update — LAN milestone 1

The owner subsequently authorized development for two PCs over home LAN and confirmed the game is not installed. They explicitly approved a 205 MB portable JDK download. It was downloaded into this workspace, SHA-256 verified against official Eclipse Adoptium metadata, and extracted without system installation or PATH changes.

Pinned public sources downloaded with Git credential helpers disabled: W3Coop v0.2.0 at 1dea513153ecb4c8eefb2f6b4041d388971f3d09 and its exact WitcherOnline submodule commit 3823f98c3364806a4b748f1e4b429101f013bc07. Native client, scripts and server were fetched sparsely; large DLC assets and the 163 MB player release were not downloaded. A public API search found closed coop-anything PR 15, documenting the earlier 5.01 port. No owner account used.

Applied coop-revive, coop-networking and coop-contribute. Two read-only audit agents checked upstream subsystems as requested by coop-revive. A subsequent read-only review caught a final-newline username regex bug, fixed with absolute regex anchors and regression coverage. New launcher files live in outputs/witcher3-lan-starter; only the unchanged Java server is compiled so far.

Verified 15/15 transport/launcher checks under Windows PowerShell 5.1 and PowerShell 7.6.5. Tests used actual Java server processes and simulated localhost UDP clients, plus real CLI host/join paths. A sandboxed UDP attempt timed out; subsequent permitted unsandboxed runs passed. Server processes were stopped and listener release checked. Not tested: any Witcher 3 game client, second PC or actual LAN link. Game identity and engine-detection tools cannot run without an install.

Local contribution draft prepared; nothing published. The previous analysis below remains dated research context, not a statement of current development authorization.

Scope: analysis only. Owner uses the latest Steam edition; player count unspecified. No game inspected, installed, launched, modified or tested. No account used and nothing published.

## Observations from public sources

- Read coop-anything AGENTS, coop-triage, coop-research, directory search and Witcher 3 write-up using its MCP.
- Official patch announcement identifies 5.01 as released on Steam on October 8. The owner's exact executable/build/hash remains unknown.
- The MCP directory/write-up dated October 18 says shared enemies and quests are absent. Current W3Coop release v0.2.0, published October 21, claims both. Stopped treating the older entry as current evidence.
- W3Coop documents two clients on one PC, including two Steam accounts; different-PC internet play remains untested by the maintainer. These are reported results, not tests performed here.
- Current README documents missing enemy moves and an enemy_moves failure; the older design verification table has a PASS. Use the newer qualification.

## Derived assessment

Evaluate and extend W3Coop before considering a new implementation. Its claims establish a candidate foundation, not proof of a reliable campaign. Acceptance should require real internet sessions, ordinary encounters, branch-sensitive quest completion, reconnects, saves and area changes.

## Working proposal

Start with two players, one host-owned campaign and a separate co-op save. Resolve combat and campaign-state correctness before expanding player count. No duration estimate is justified before reproducing the baseline.

## Unknowns

Exact local build, DLC/mod set, desired player count; campaign and DLC coverage; recovery from disconnect/death/load; compatibility with divergent saves; performance on separate PCs; current complete test results and full implementation correctness.

## Searched and limits

Searched directory for Witcher; checked listed original and current fork; English and Russian multiplayer/co-op searches; attempted issue/PR filters and GitHub API. Public issue/PR index pages opened, but filtered queries/API were unavailable, so the search is incomplete. Shell network lookup failed; gh is unavailable. No authenticated fallback was used. Full source audit and binary/release hash verification were not performed.

## Proposed upstream correction (not submitted)

Update the October 18 directory/write-up to mention v0.2.0's claimed shared combat and quest features, with explicit one-PC validation limits and current known failures. Replace categorical absence claims with dated, qualified status; reconcile stale test-table PASS claims.

## Sources

- https://github.com/cranebeaker/coop-anything/blob/main/AGENTS.md
- https://github.com/cranebeaker/coop-anything/tree/main/games/witcher-3
- https://github.com/rejuvenate7/WitcherOnline
- https://github.com/Emillock/witcher3-coop
- https://github.com/Emillock/witcher3-coop/releases/tag/v0.2.0
- https://github.com/Emillock/witcher3-coop/blob/main/docs/true-coop-design.md
- https://www.thewitcher.com/us/en/news/52085/patch-5-01-for-the-witcher-3-wild-hunt-remastered-is-live


## 25 October 2026 — parallel campaign fact-removal implementation

Owner confirmed Claude is active; isolated branch `codex/campaign-fact-removals`, base `dd7cae0`. Observed source limitation: PumpSnapshot halted on exists=0 although a local removal primitive already existed. Added literal `absent` under the existing fact key, active and historical-replay capability gates, snapshot-to-ledger removal and echo-guarded application. Removals remain test-target-only; mh306 SET approval does not authorize its removal. Protocol and integration notes are in `work/seamless/server-protocol.md` and `docs/4-FACT-REMOVAL/README.md`.

Verified without the game: 255 existing pure + 54 removal + 448 real UDP assertions; 5/5 mutation twins caught. The negative controls prove the tests reject zero/absence conflation, missing capability checks and broken restart receipt behavior. Unknown: WitcherScript compilation, real-client application, removal-specific game save/load and actual quest effects. The new bot awaits integration and isolated game testing; no shared active game setup was used. Owner requested a feature PR; publication is authorized, merging is left for review.
