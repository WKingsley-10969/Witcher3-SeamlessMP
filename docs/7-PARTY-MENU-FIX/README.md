# Empty player menu: party confirmation fallback

The reported interaction popup was black and had no Join Party entry. Reproduced in two real clients: the popup target inventory contained zero entries, `wo_joinParty` had no item category/localization definition, while a vanilla Bread control item could be created. The legacy DLC's item-backed actions were unavailable. Loose XML and a duplicate DLC-folder probe did not register them and are not included in this fix.

`coopPartyMenu.ws` wraps the existing player-menu entry point. When the legacy party item definition is absent, interaction opens the game's standard Join Party/Leave Party Yes/No dialog. When definitions exist, the original menu is used. No native rebuild, item injection into the player's inventory, auto-join or networking change is required. Other missing legacy actions (trade/emotes/Gwent) are not repaired by this fallback.

Prompt IDs are unique within the client process. Cancel, expired prompts, stale/repeated callbacks, changed party state and departed targets do not perform an action. State is cleared before the accepted action. Existing party membership and routing are handled by the established joinParty/leaveParty methods.

Verification: real two-client run `20261025-144911-party_menu` **PASS**. The bot exercised join cancellation, a stale callback against a newer prompt, accepted join and repeated callback, leader/member propagation over actual UDP, leave cancellation and accepted leave. Both clients passed. Earlier attempts did not pass: the baseline had zero actions; two compilation diagnostics were corrected; an initial dialog probe paused the bot and was replaced by callback-driven UI testing. Only owned fixture processes were stopped and the shared isolated test files were restored after the run.

The small user patch adds one script to an existing extracted LAN package and updates its manifest. Run `Patch Party Menu.cmd`, select the existing game folder in Manage Mod, then choose 1 to update. It uses the installer from PR #7 so backups and removal tracking remain intact. The package patch was exercised twice through Windows PowerShell: first application and an idempotent second application passed. It does not copy the game or replace the existing client script.

This is tested with two clients on one PC, not two physical PCs. No original Steam installation or personal saves were modified. Source patcher: `outputs/witcher3-lan-starter/tools/Patch-PartyMenu.ps1`; game scenario: `w3test_party_menu.ws`. The normal package builder already includes new script files automatically.
