# Sharing a cleared quest flag

Some quests remember a condition by creating a flag, then clear it later. A flag set to zero can still count as present. Before this change, the experimental campaign system could share a flag being set, but stopped when a watched flag disappeared.

This branch adds a separate "absent" state. The player who owns that quest scope submits the removal, the host records it, and the other player's adapter can remove its copy. Retrying the same request does not create another event. A later update can create the flag again, including with value zero.

Older clients cannot join a campaign that contains removal events. That avoids silently treating a removed flag as an existing zero flag.

## Current result

- Server tests passed: 255 existing campaign checks, 54 new removal checks and 448 UDP checks, including duplicate packets and server restart.
- Five intentionally broken versions failed the tests as expected.
- Game-side code and an automated two-player scenario are written. They have **not yet been compiled or run in Witcher 3**.
- Removal currently permits test flags only. Real quest flags need individual investigation and tests.

This does not complete independent quests, shared rewards or the dialogue voting system. It also does not change ordinary party-mode quest sync; it extends the separate experimental campaign ledger.

## Integration for Claude

Draft [PR #2](https://github.com/WKingsley-10969/Witcher3-SeamlessMP/pull/2). Branch: `codex/campaign-fact-removals`, originally based on `dd7cae0` and rebased onto the documentation update `8c920f9`. This work lives in a separate managed checkout. No files, game processes, staging directories or packages in the active original checkout were changed by this branch.

Review/cherry-pick this branch once compatible with your current work. The only bot dispatcher edit adds `seamless_removals`; preserve your newer dispatcher cases. The new bot is in `w3test_removals.ws`. Reconcile any overlapping adapter/server edits; do not copy entire old files over newer work.

After integration, using the original checkout's existing tools and isolated test installation:

1. Run `work/WitcherOnline/server/tests/Test-Seamless.ps1` to build the current merged server.
2. Run `work/stage-test-game.py` before launching any test.
3. Run `work/run-isolated-test.py seamless_removals --duration 180`. Require both real clients to pass. The scenario uses snapshot capture; it does not need `WO_SC_CAPTURE=1`.
4. Run `seamless_effects`, `seamless_replicate`, `seamless_reload_mh306` and `seamless_dialogue` regressions on the merged build.
5. Add a removal-specific game save/load test before claiming that path verified. The current new bot proves live transitions only.

Do not launch the guarded game runner from this new checkout: it has no separate test-game copy. Do not stage over another agent's active game test. The existing ZIP has not been rebuilt with this feature.
