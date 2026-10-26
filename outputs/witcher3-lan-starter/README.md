# Witcher 3 LAN — development build

Two Windows PCs on one home network: one hosts, the other joins by private IPv4 address. Built on **W3Coop v0.2.0**, a fork of **Witcher Online**. This is an experimental LAN adaptation, not a verified seamless campaign.

**Version:** the `VERSION` file in this package (for example `0.3.0-alpha`) is this build's version. The package folder, its zip and its GitHub release carry the same number.

The full development ZIP contains the native mod, its DLC/templates, Java server, LAN launchers, source and licenses. It contains no Witcher 3 installation or Java runtime. Each player needs a matching game. Target: Steam build **25773555**, executable resource version **5.0.0.1048522**; other builds are rejected until checked.

## On this development PC

Run **Manage Mod.cmd** and choose your existing game folder, then **1 — Install or update**. You can also select an existing isolated development copy. The installer backs up only files it replaces; it does not copy the whole game. Close all Witcher 3 instances and host consoles before changing the installation. Use **Play Host LAN.cmd** afterwards. The existing portable JDK is found in this workspace's `work/tooling` directory while the package stays in its current location; an extracted package elsewhere can use `JAVA_HOME`.

## Prepare the other PC

1. Extract the complete LAN development ZIP into a short, writable path. Keep its folders together.
2. With the matching Steam game installed and closed, run **Setup LAN.cmd** or **Manage Mod.cmd**. Select the existing Steam game folder and choose **1 — Install or update**. The original game executable is checked but never replaced. Extra space is needed only for the mod, touched-file backups and temporary staging, rather than another 70 GB game copy.
3. For installation or updates from PowerShell:

```powershell
.\Install-LAN.ps1 -GameDir 'D:\SteamLibrary\steamapps\common\The Witcher 3'
```

The payload is hash-checked before installation. First backups remain unchanged across updates. An update replaces changed mod files and restores/removes files dropped by the new version. Setup writes `launcher.settings.json` locally. Keep the package separate from the game folder. Do not publish local settings, the game's `.w3lan-install` restore data or personal saves.

## Update or remove the mod

For updates, extract the newer complete package, run **Manage Mod.cmd**, choose the same game folder and select **1**. The restore record lives in that game folder, so updates keep the first backups even when you use a different extracted package directory. For **older/manual installations**, the first managed install treats the files currently present as its baseline; it cannot reconstruct vanilla files that were already overwritten before these backups existed.

To remove, run **Remove Mod.cmd**, or choose **2 — Remove** in **Manage Mod.cmd**. Original file contents are restored, and files newly added by this installer are removed. Co-op saves, original backups and any preserved outside edits are retained. Uninstall does not undo quest progress in a save. Reinstalling in the same folder reuses the co-op save identity and creates fresh original-backup entries.

If another mod, Steam or a manual edit changed a managed file, the operation stops before modifying game files. Manage Mod can offer to keep those changed files under `.w3lan-install/preserved` and continue. It does not merge competing mods. Corrupt/missing originals stop restoration. Keep `.w3lan-install` until you are finished with rollback; deleting it loses the restore history.

Failed writes roll back the operation. An interrupted operation retains its journal and verified pre-operation snapshots; the next install/remove recovers it before proceeding. Launchers refuse a pending transaction. If interrupted files were changed again externally, automatic recovery stops and retains the evidence instead of overwriting those changes. Temporary transaction data is cleaned after success; original/preserved backups stay.

Folders that require elevated write access may need **Run as administrator** for installation/removal. Game launch itself need not run as administrator. Use the supplied **Play** launchers for isolated co-op saves. While installed, the mod files also exist for Steam/direct launches; remove the mod before launching an unmodded solo game.

A separate full copy remains optional for development:

```powershell
.\Install-LAN.ps1 -Mode Copy -SourceGameDir 'D:\SteamLibrary\steamapps\common\The Witcher 3' -Destination 'D:\W3LAN\game-copy'
```

## Play over LAN

1. **Host:** run **Play Host LAN.cmd** with a name such as `HostWitcher`.
   - Keep the console open. It runs the server: UDP 40000 for the game, and TCP 40001, which shares your co-op saves with joining players.
   - Load or start your game and **save**. Joining players get your newest co-op save.
2. **Second PC:** run **Play Join LAN.cmd** with a different name such as `GuestWitcher`, and enter the host's home-network IPv4 address shown in its console.

   The launchers remember your name and the host's address (in `%LOCALAPPDATA%\W3LAN\player.json`, so a newer package folder still knows them): next time, press Enter to keep them. Keep the same name: it picks your co-op saves and character. The game starts with your own graphics settings (no forced window or resolution).
3. **The co-op session takes over.** The launcher downloads the host's newest co-op save, and the game then:
   - loads that save from the main menu by itself;
   - joins the host's party;
   - steps in beside the host;
   - follows the host's difficulty, also when the host changes it mid-session.

   Both players then play the same game: the same story point, choices and place. Your own solo saves are untouched; the host's save goes into your co-op profile only.
4. **If the host has no save yet,** your game waits in the co-op lobby (below) until the host starts a new game. **If the download fails,** the launcher says so and you play as before:
   - load a save yourself;
   - meet the host;
   - interact with the host character and choose **Join party**.

   If you leave the host's party (interact with the host → Leave party), your game stops joining it again by itself until you join it yourself.

   To keep your own co-op save instead of the host's, start with `.\Play-LAN.ps1 -Mode Join -GameDir '<game folder>' -NoSessionSave`.

**Co-op lobby (new).** The game starts in a **Co-op lobby** popup in the main menu (also the first main-menu entry).
- The host's lobby lists the players waiting. **OK** starts with the host's newest co-op save: the host's game loads it, and everyone waiting downloads it if needed and loads it too. To start fresh instead, close the popup and choose **New Game**: everyone waiting starts the same new game.
- A joining player waits in the lobby until the host starts. **OK** stops waiting, to play on your own.
- If the host's lobby does not answer within 8 s, a joining player's game loads the save the launcher downloaded, as in step 3.
- **Back to the main menu** (or after leaving the game world): the Co-op lobby opens again by itself, downloads the host's newest save and brings you back into the host's game and party. No need to restart the game.

**Your own character (new).** The host's save brings the world: quests, choices and places. A joining player then plays their own Geralt, with their own level, XP, skills, mutations, money, recipes, gear, stash, horse gear and Gwent cards.
- The first time you join a host, your character starts as a copy of the host's Geralt; from then on it is yours.
- Your game records it every 20 s in your co-op profile (`The Witcher 3\coop-characters\<host>.txt`) and brings it back after every load of the host's game.
- Your character is only recorded and restored in the host's world: not in a save of your own, not in the prologue's Kaer Morhen dream. A stored character without any weapon or armour is never applied over your gear, and before your character is replaced the old record is backed up in `coop-characters\backups`.
- Quest items stay with the world. Gwent decks are the save's: your cards are yours, but which of them are in a deck comes with the host's save.

**Create your own character (new, optional).** With the mod **Custom Player Characters** (by nikich340) installed, a joining player can play a witcher, witcheress or sorceress of their own look instead of Geralt. It is not included in this package (its permissions do not allow that); without it everyone plays Geralt.
- **Install on both PCs**, into the game folder, before running **Manage Mod.cmd** (choose **1** again if the LAN mod is already installed):
  1. [Custom Player Characters 3.1.2](https://www.nexusmods.com/witcher3/mods/5940): extract its `mods` and `dlc` folders and `add_to_input.settings.txt` into the game folder.
  2. [CPC Remaster Compatibility Fix](https://www.nexusmods.com/witcher3/mods/13735): extract its `mods` and `dlc` folders into the game folder. CPC 3.1.2 needs it on this game version.
  3. Remove `mods\modSharedImports` (Community Patch – Shared Imports) if you have it: the fix does not work alongside it.
- **Manage Mod** says whether it found CPC and its fix. With CPC installed it leaves out this package's CPC stand-in (`modWitcherOnlineCompatCPC`); remove CPC later and choose **1** again to put the stand-in back.
- **The Play launchers** add CPC's key bindings to your co-op profile once.
- **The first time you join a host**, CPC's character creator opens by itself, once you are in the host's world and not fighting or in a cutscene. Later, hold **E** and press **P** to change your look.
- **Your look is part of your character**: the character type, face and outfit are recorded with the rest of your character and come back after every load of the host's game. The other player sees your character as you made it.
- CPC's own tips (first time, hotkeys) show once per save as fullscreen popups that pause your game: close them with the accept button.

**Nearby NPCs (new, experimental).** While in a party, the townsfolk, guards and characters such as Ciri within about 45 m of either player are shared. The host's game runs them, except that when the second PC walks up to one (within about 4 m and closer than the host), the second PC's game takes it over, so it reacts to that player at once; it goes back once they walk off. Whichever PC does not run an NPC shows a look-alike stand-in in its place that follows the other screen. You can't talk to a stand-in directly: walk up to it and the real NPC is handed to you first. Stand-ins walk and stand but do not play work animations, gestures or chatter. Stand-ins now move smoothly: they play slightly behind the other screen (about 0.15 s) instead of jumping between updates.

**Shared quest progress (new).** In a party, quest progress made on either PC reaches the other: the quest facts and quest-log updates each PC makes are sent to the other, which applies the ones that move it forward, so the other PC's own quests start and advance too (for example, taking a notice from a board). Story choices are shared the same way; a romance outcome is shared, the romance scene itself only plays on the PC that played it. Tutorial progress stays per player. Progress only moves forward: nothing is undone on the other PC.

**Talk together (new).** In a party, when one player talks to an NPC, the other player (within about 40 m, not fighting or riding) joins the same conversation: their Geralt is moved beside the speaker and their own game plays the same scene, so they see the camera, hear the voices and read the subtitles. Either player can answer: whoever picks first decides (new). The other PC shows "name chose: answer" above its choices for a moment, then takes that answer too, also when its conversation is a line or two behind. If both pick at the same moment, each PC keeps its own answer. A shop, barber or other menu the conversation opens stays with the speaker; it is closed on the other PC.

Steam must be running for the game normally. Mod traffic goes directly over LAN: no Steam relay, VPN or router port forwarding. If Windows Firewall blocks the host's Java process, allow it on your private home network; scripts do not change firewall rules. Guest Wi-Fi can isolate PCs.

Only the host needs Java 21+. On another host, use `JAVA_HOME`, put a portable JDK under `runtime`, or pass `-JavaPath` to `Play-LAN.ps1`. Java is not installed automatically. Names are 2-16 ASCII letters, digits or underscores; choose different names, and avoid reserved `none`.

## Saves, settings and controls

Managed in-place installations use `%LOCALAPPDATA%\W3LAN\profiles\<installation-id>\<name>\The Witcher 3`. Existing isolated-copy installations keep `<game-copy>/.w3lan-profiles/<name>/The Witcher 3`. First use copies existing solo saves/settings; later launches preserve co-op progress. Originals are read for seeding and are not the supplied launcher's save destination. Removing the mod retains these profiles.

The native helper redirects three imported Documents APIs and stops on invalid/missing hooks or paths resolving to the original Documents/save folder. Human mode does not activate bots, choose dialogue, mute audio or change focus/input. Launch arguments request 960×540. Normal menu/startup prompts remain yours to answer.

This is application-level redirection, not an OS sandbox for every file access. It is tested on the pinned executable, not unrelated mods or future patches.

```powershell
.\Play-LAN.ps1 -Mode Host -GameDir 'D:\W3LAN\game-copy' -PlayerName HostWitcher
.\Play-LAN.ps1 -Mode Join -GameDir 'D:\W3LAN\game-copy' -PlayerName GuestWitcher -Address 192.168.1.20
```

## Checks and limits

The older **Host LAN.cmd** and **Join LAN.cmd** are server/probe tools; they do not launch or join Witcher 3. A probe proves UDP reachability only.

```powershell
.\Lan.ps1 -Mode Probe -Address 192.168.1.20
.\tests\Test-Lan.ps1 -JavaPath 'C:\path\to\jdk-21\bin\java.exe'
.\Build-Server.ps1 -JdkPath 'C:\path\to\jdk-21'
```

See **TEST-RESULTS.md** for actual checks. Real game tests use two clients on one PC. A second-PC LAN session, full quest playthrough, travel/death/rejoin recovery and expansion coverage are not yet established.

Nearby-NPC limits: at most 24 shared NPCs and 12 stand-ins at a time (any beyond that are left on each game's own routine); only in a party and within about 45 m; a quest character's own script may still move or teleport it right after it is handed back. Tested with two clients on one PC on one Novigrad street, not yet on two physical PCs.

Talk-together limits: only conversations started with the Talk button are shared; cutscenes a quest starts on its own still play on one PC only; the joining player is moved next to the speaker; if the host stands closer to an NPC than the second PC, the second PC must walk up to it before it can talk to it; tested with one merchant conversation, not yet with long cinematic quest dialogues or timed choices.

Shared-progress limits: only quest facts and quest-log states travel, so a quest step that waits for a scene or an interaction on one PC catches up on the other only where it is recorded as a fact; removals are not shared.

**Shared quest rewards and looted containers (new).** In a party:
- When a quest pays out on one PC, the other player gets that reward's experience too (for their own level), once. Money and items stay with the player whose game paid out. If the same quest then finishes in the second player's game, they get its money and items there, but not its experience a second time.
- A container one player loots loses the same items in the other player's game. If the looter emptied it, it is emptied in the other game too (except quest items), even where the other game's loot roll differed. A container the other game has not loaded yet is updated when it loads, for up to 10 minutes.
- **Enemy corpses (new):** the monsters and enemies you fight together leave one corpse with one loot, the same on both PCs: the party leader's game rolls it, and the other player's corpse of that enemy holds exactly that loot instead of its own roll. Whatever one player takes is gone from the other's corpse; empty it on one PC and it is empty on the other. (If the other game's enemy left no body to loot, a loot bag lies where it died.)
- Limits: containers are matched by position; corpses only for shared enemies (within the shared-enemy range of both players), so a body neither shared nor lying in the same spot on both PCs is not matched; only rewards a quest gives through the game's reward table are shared, not money or items a dialogue hands over directly; tested with one contract reward and one container, two clients on one PC.

**Flying monsters (new).** Griffins, sirens, harpies, wyverns and other flyers fly on both screens: the other player's copy takes off, flies at the same height and lands with the real one, and one killed in the air falls to the ground. A monster circling high above the fight stays in it.

**Monster phases and knockdowns (new).** When a monster turns untouchable or untargetable (a noonwraith, an alghoul, a fogling in its fog), it does so on both screens, and you cannot lock on to it on either. A monster knocked down, staggered, frozen, blinded or held by Yrden is so on both screens too.

**A leshen's roots and crows (new).** The roots a leshen sends through the ground and the crows it throws show on both screens, and its crows hurt whichever player they hit. A griffin's landing dust already shows with its flight.

**Attacks that come out of the ground (new).** What a monster's attack makes appear, such as a spriggan's roots bursting out under you, shows on both screens. Only the real one hurts: the other player's copy is just for show.

Inherited limits include the roughly 60 m shared-enemy range, independently started scenes, incomplete enemy animation/spell/summon cases and loot on corpses outside the shared-enemy range. This adaptation does not remove them. The server has no enforced two-player cap or authenticated LAN session; use it on your trusted home network.

To remove the managed mod, close the game/server and use **Remove Mod.cmd**. To discard a separate development copy instead, keep desired co-op saves first, then remove that separate folder. The installer never deletes a game installation or co-op saves.

## Credits and source

- Original Witcher Online: rejuvenate7 and contributors, https://github.com/rejuvenate7/WitcherOnline, GPL-3.0.
- W3Coop baseline: https://github.com/Emillock/witcher3-coop, v0.2.0, commit `1dea513153ecb4c8eefb2f6b4041d388971f3d09`.
- Native client/server fork: https://github.com/Emillock/WitcherOnline, commit `3823f98c3364806a4b748f1e4b429101f013bc07`. Included source: `mod/W3Coop/source` and `server/src`.
- WitcherNativeBridge: Flawkee and rejuvenate7, MIT, https://github.com/rejuvenate7/WitcherNativeBridge; built from `415e1c1e79a9d5ab78629c70cd3a76131ad98941`. Included under `source/WitcherNativeBridge`.
- Ultimate ASI Loader: ThirteenAG, MIT; license included with the baseline mod.
- LAN launchers, profile-helper changes and tests: MIT. Included under the package root, `source/witcher3-coop/w3test` and `source/native-tests`. This does not replace upstream GPL-3.0 licensing.
- Workflow: https://github.com/cranebeaker/coop-anything/blob/main/AGENTS.md.

This unofficial fan project is not affiliated with CD PROJEKT RED or Valve.
