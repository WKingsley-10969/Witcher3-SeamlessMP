# Verification — game integration, 2026-10-25

## In-place installer verification (25 October 2026)

The installer/profile launcher update is separate from the unchanged game payload below. `tests/Test-Install.ps1` passed 30 fixture scenarios in Windows PowerShell 5.1 and PowerShell 7: exact binary backups, no-op reinstall, updates without a game copy, superseded-file restoration, original retention across updates, full file-content revert, retained saves, reinstallation identity, outside edits, checksum/path/link/record/backup rejection, concurrent lock, failed writes and rollback, refused launch during a pending transaction, and recovery after killing an owned installer process during install and uninstall. Private fixture guards use fake executable bytes and do not operate on the actual installed game. The existing isolated-copy profile regression also passed on both shells.

Managed-install launch construction is tested with fake game files; no real managed game session or two-physical-PC run has been verified. Earlier real-game results below used isolated copies. This installer package does not include PRs #2/#3 or enable their experimental recovery adapter.

## Real game checks

Two actual Witcher 3 clients on one PC, separate copied saves/settings, direct local UDP server and automated bots. Target: Steam build 25773555, executable resource version 5.0.0.1048522. Executable SHA-256: `2df765398a3d1f165db418271be7200178320a4466817379f2fa0dc0001fb101`.

| Scenario | Result | Scope |
|---|---|---|
| see_each_other | PASS | Both instances create the expected remote-player ghost |
| movement | PASS | Observer's ghost follows the mover's scripted position changes |
| shared_enemy | PASS | Spawned monster health, member hit claims and death propagation |
| member_combat | PASS after fixing dummy exhaustion | At least three real melee hits, one sign hit and two effects sent; host receives damage/effects |
| quest_sync | PASS | Scripted journal objective update reaches the member |
| facts_sync | PASS | Scripted facts set before/after joining reach the member |
| dialog_sync | PASS | Script-driven tracking, skips and delayed dialogue-choice synchronization |
| npc_own | PASS | Party nearby-NPC sharing: the second PC walks up to Ciri, takes her over (she reacts on its own AI), the host shows a stand-in mirroring her, and she returns to the host when the second PC walks off |
| quest_share | PASS | Party quest progress both ways: the second PC takes three real notices; the host, which never touches a board, gets the facts and its own quest graphs start the same two quests; an objective update arrives; a host change reaches the second PC; nothing echoes |
| talk_share | PASS | Talk together: the second PC talks to the Novigrad general-store trader; the host 14 m away joins the same scene (13 identical lines), its click reaches the second PC as a suggestion, both answers play on the host, the shop opened on the host is closed, Farewell ends the conversation on both |

**This payload (2026-10-25).** Runs on the exact scripts, native helpers and server in this ZIP: `talk_share` `20261025-100444` PASS, `quest_share` `20261025-101314` PASS, `npc_own` `20261025-101452` PASS, `member_combat` `20261025-101817` PASS (an earlier run on the same payload failed because only two of the three sword swings connected), `shared_enemy` `20261025-102022` PASS (two earlier runs on the same payload failed: after a hit the host's drowner keeps losing about 1.5 % health a second for an unknown reason, already seen before this payload, and the test reads its health 2 s after each hit with ±0.02 tolerance). The server now relays up to 12 message channels per player instead of 4; before, a fifth channel was silently dropped.

**Smoother stand-ins.** Measured while NPCs walk: frames where a stand-in barely moves fell from 13 % to under 4 % (the same as a real NPC), and frame-to-frame jerkiness by about 40 %, though it is still above a real NPC's.

**Nearby NPCs (`npc_own`, run `20261024-221254`, an earlier payload).** On one Novigrad street with 19 shared NPCs: Ciri was shown exactly once on both screens in 64/64 one-second samples; no stand-in slid or ran in place; the one running-in-place second on each screen was the real Ciri starting to move on her own AI. While the second PC owned her, the host's stand-in stayed within 0.30 m median (0.40 m max) of her; while the host owned her, within 0.04 m median. A quest teleport by her own script right after the hand-back shows as a jump on both screens (the 10 m maximum). A previous run with the same payload failed only because the test bot could not walk away from her (a wall); ownership correctly stayed with the PC standing next to her. Not covered: two physical PCs, other regions, crowds over 24 NPCs, conversations with a shared NPC.

The earlier seven scenarios are not seven complete quests. They do not establish every quest graph, cutscene, choice, expansion or a completed campaign. The first presence run used 640×360; later runs used enlarged windows, with member combat and story tests starting at 960×540.

The original member-combat fixture failed: its immortal drowner reached roughly one hit point, and later melee did no effective damage. Only that test dummy now replenishes its health. Real-hit/effect thresholds were retained; ordinary enemies were unchanged. The successful run recorded four melee and two sign hits. An earlier ineffective diagnostic put the change in another helper; it was removed and is not counted as a pass.

## Native helper and launchers

- MSVC x64 builds succeeded for WitcherNativeBridge and the modified test/profile helper.
- **10/10 standalone process checks passed:** three Documents APIs redirect; human profile mode works without test mode; missing, relative, nonexistent and owner paths reject; owner slash/dot aliases reject; missing imports terminate; overlong wide paths cannot fall back to the original folder.
- A **35-second real-game human-profile startup smoke test passed**: process stayed running, all Documents hooks installed, no bot/focus/audio test behaviour. This verifies startup, not a human gameplay session.
- Profile fixtures passed under PowerShell 7 and Windows PowerShell 5.1: bot flags cleared, endpoint correct, seed save unchanged, co-op progress preserved, modified helper rejected.
- Packaged installer passed a disposable fixture using the verified executable: it staged an independent copy, left the source unchanged, rejected an existing destination and rejected a modified payload. This fixture was not a complete second game install or a second-PC test.
- **15/15 server/launcher checks passed again under Windows PowerShell 5.1** with this build's server, after a fix: on this PC the console input encoding is UTF-8 with a byte order mark, so the launcher's `stop` reached the server as `﻿stop` and the server was killed after 5 s instead of stopping (the old server failed the same way). The server now ignores the mark. Earlier versions also passed under PowerShell 7.6.5. Coverage includes compatible/negative UDP probes, occupied ports, real host/join CLI paths, simulated clients, latest/late-join state, movement messages and shutdown.

Redirection covers the pinned main executable's imported Documents APIs; it is not an OS sandbox for unrelated DLLs, dynamically resolved APIs or arbitrary mods.

## Compiler diagnostic

`-verifyscriptsandexit` returned code 3 without an error report for restored scripts. This standalone result remains unresolved and is not labeled PASS. A deliberately broken test-only script produced the expected compiler error and was removed. Subsequent real clients compiled and ran the mod/bot scripts and passed the scenarios above.

## Not established

- Two physical PCs over LAN/Wi-Fi, firewall traversal or real link behaviour.
- A full campaign, natural quest sequences, boss coverage or long-session stability.
- Travel, death/revive, reconnect, conflicting saves or crash-recovery correctness.
- Complete enemy animation, spell/summon/status-effect parity or arbitrary patch/mod compatibility.

The core multiplayer is upstream W3Coop/Witcher Online. This adaptation adds LAN tools, separate profiles, setup/package checks and harness fixes; inherited gameplay limits remain.
