# Install/update/revert without copying Witcher 3

The owner requested automatic backup, mod-only updates in an existing game folder and an option to revert/remove the mod. Branch `codex/in-place-installer` is separate from the recovery branch and is based on main `5ddedc1`. The original checkout, installed game, its test staging and game processes were not changed.

## User workflow

**Manage Mod.cmd** (also reached by Setup LAN.cmd) asks for a game folder and offers install/update, remove/restore, or status. It can target the existing Steam installation or an existing isolated copy. Only the manifest's mod files are copied; the 70 GB game copy is optional through `Install-LAN.ps1 -Mode Copy`. Existing legacy commands that supply `-Destination` still select copy mode unless a mode was explicitly given.

The first install backs up the bytes of existing files it replaces. Updates keep those original backups, change only differing files, and restore/remove paths that leave the payload. Remove restores pre-install contents and deletes newly added files. Untouched mods, game data and saves are not deleted. Original backups and outside edits retained on request remain under `.w3lan-install` after uninstall.

The baseline is the file contents present at the first managed installation. An older/manual mod may already have overwritten vanilla bytes; the installer cannot reconstruct originals which no longer exist. Removing a managed update to an older mod restores that earlier baseline, which may itself contain mod files. A manual installation with no restore record is never falsely reported as reverted.

Normal managed game launches use a separate `%LOCALAPPDATA%/W3LAN/profiles/<installation-id>/<player>` save profile. Adopting an isolated copy retains its current `.w3lan-profiles` path. Removing/reinstalling preserves the profile identity and saved progress while making fresh original-backup entries for the new managed lifetime. A direct Steam launch still sees installed mods and does not get the supplied launcher's save redirection; remove the mod before an unmodded solo launch.

## Transaction behavior

`W3ModInstall.psm1` validates the executable against the existing supported hash, checks every payload file/hash and rejects unlisted files, traversal, alternate streams, duplicate/case paths, device aliases, executable replacement and linked paths. Game roots over 130 characters are refused for Windows PowerShell path compatibility. It requires the game closed and takes an exclusive installation lock. The package and game must be separate folders.

All affected paths and original backup hashes are preflighted. Replacement originals and per-operation snapshots are copied and hash-checked before the first target write. A durable pending journal precedes atomic same-volume file replacement. Atomic staging lives under restore metadata, so an interrupted copy cannot leave a half-written DLL in a game directory. State commit is last; its hash distinguishes a completed transaction from one requiring rollback. A failed write rolls back. A process kill retains its pending journal for the next install/remove to recover. A failed rollback retains the evidence and stops. Unknown post-interruption edits stop automatic recovery instead of being overwritten. Launchers refuse any pending journal, including mid-uninstall after the managed marker has gone.

Game files changed outside the installer block the operation before target writes. The menu can keep copies in `.w3lan-install/preserved` and retry with `-PreserveChanges`. It does not merge mods or silently replace missing/corrupt backups. Files no longer owned after an update can be changed by other tools without the uninstaller touching them. Successful transaction staging is pruned; original/preserved backups remain. Saves are never deleted by removal, nor does rollback revert quest progress inside a save.

## Validation and delivery

`tests/Test-Install.ps1`: **30 scenarios passed under Windows PowerShell 5.1 and PowerShell 7** using temporary fake game directories. Includes actual owned subprocess kills during install and uninstall, whole-file/hash comparisons, binary original content, partial-write/rollback injection, a changed-file conflict after interruption, and preservation of original and co-op saves. The test changes private expected-executable/process guards only inside its fixture processes; public installers have no build-hash bypass switch. `tests/Test-Profile.ps1` passed on both shells for the existing copied-game path.

No real game was installed, updated, removed or launched by these tests. Native mod binaries are unchanged. An actual in-place Witcher session and two-PC play remain unverified.

`tools/Build-InstallerOverlay.py` builds a small installer-only update ZIP and a complete package from the pinned existing LAN ZIP (`2cc7700e...6ef5`). It checks that every `mod/` payload byte and manifest remain identical. The small ZIP is extracted into the existing package folder containing `mod-manifest.json` and `mod`, not directly into the game. The complete ZIP contains the existing game payload with the new installer/launcher scripts. Neither includes the separate removal/recovery PRs.

For integration, preserve newer native/game changes and add the installer files to package assembly (already updated in `work/build-lan-package.py`). Review the default install mode change and per-user profile selection. The experimental seamless launcher remains on its separate development-copy workflow; its effect adapters are still disabled. Details for players: `outputs/witcher3-lan-starter/INSTALL-UPDATE-REMOVE.md`.
