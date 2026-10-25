# Install, update or remove the LAN mod

You can use your existing Witcher 3 folder. No second 70 GB game copy is required.

1. Close Witcher 3 and the host console.
2. Extract the complete package outside the game folder, keeping its folders together.
3. Run **Manage Mod.cmd** (or **Setup LAN.cmd**).
4. Select your existing Witcher 3 folder.
5. Choose **1** to install/update, **2** to remove/revert, or **3** for status.

Install saves original contents of any files it replaces. Updates keep those original backups, replace only changed mod files, and restore/remove old mod files no longer included. Remove restores those originals and deletes files the installer added. Your game executable is checked but never patched. The supported executable is still Steam build 25773555; an unsupported game build is refused.

Keep the game's **.w3lan-install** folder. It contains your restore record and original backups. Removing this folder loses your automatic revert history. An installation with already-overwritten files from an older/manual mod can only back up what is present now; it cannot recreate missing vanilla originals.

If files were changed by another mod, Steam or manual editing, the installer stops. The Manage menu can preserve those versions before continuing. Preserved files live under **.w3lan-install/preserved**. Missing/corrupt originals stop restoration rather than guessing. Backups and co-op saves are retained after removal.

Managed installations launched through **Play Host LAN.cmd** or **Play Join LAN.cmd** keep co-op saves under **%LOCALAPPDATA%\W3LAN\profiles**. Existing isolated game copies retain their current co-op profile paths. Reinstalling in the same folder keeps the save identity. Removal does not undo quest progress stored in a save.

For future updates, extract the newer package, select the same game folder and choose **1**. The backup record is in the game folder, so it survives replacing/moving the extracted package. If using an update-only ZIP, extract its contents into your existing package folder containing **mod-manifest.json** and **mod**; it does not contain the full mod payload itself.

Use the **Play** launchers for separate co-op saves. While mod files are installed, they are also present for Steam/direct launches. Remove the mod first to return to an unmodded solo game. Protected game folders may need **Run as administrator** for installation/removal; normal play need not be elevated.

Install/remove failures roll back the file changes when possible. If the installer is interrupted, run Manage again to recover before launching. Unknown changes made after interruption stop automatic recovery and retain its journal/backups for repair.

PowerShell equivalents, from the extracted package folder:

```powershell
.\Install-LAN.ps1 -GameDir 'D:\SteamLibrary\steamapps\common\The Witcher 3'
.\Remove-LAN.ps1 -GameDir 'D:\SteamLibrary\steamapps\common\The Witcher 3'
```

A separate full game copy remains available with **-Mode Copy** for development. It is optional for normal managed installation.

This installer update uses the existing LAN game payload. It does not include the separate cleared-flag/recovery PRs or enable their experimental campaign effects. Installer restoration is tested with temporary fixture game files; running a managed install in an actual Witcher session and on two physical PCs remains unverified.
