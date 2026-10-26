# Changelog

What changed for players in each release of the Witcher 3 LAN co-op mod, newest first. Every release is an early alpha test build. Both PCs must run the same build: to update, extract the new package and run **Manage Mod.cmd** → **1** on both PCs.

From v0.3.0-alpha on, each release is named by its version and ships as `Witcher3-LAN-<version>.zip`. The builds before it all shipped as `Witcher3-LAN-0.2.0-dev.zip`; each one is named here by its GitHub release tag.

## Unreleased

- **This changelog** is now part of the package.

## v0.3.0-alpha (26 October 2026)

- **Flying monsters fly on both screens.** Griffins, sirens and other flyers take off, fly at the same height and land on the second PC too. One killed in the air falls to the ground.
- **Monster phases and knockdowns on both screens.** A monster that turns untouchable or untargetable (a noonwraith, an alghoul, a fogling in its fog) does so on both PCs, and neither player can lock on to it. A monster knocked down, staggered, frozen, blinded or held by Yrden is so on both screens.
- **A leshen's roots on both screens.** The roots a leshen sends through the ground show on the second PC too.
- **Attacks that come out of the ground.** A spriggan's roots and similar things a monster's attack makes appear show on both screens. Only the real ones hurt: the second PC's copies are just for show.

## lan-dev-2026-10-25-5 (25 October 2026)

- **Shared corpse loot.** Enemies you fight together leave one corpse with the same loot on both PCs. What one player takes is gone for the other.
- **Create your own character (optional).** With the mod Custom Player Characters and its Remaster fix installed, the second PC can play a witcher, witcheress or sorceress of its own look. The creator opens the first time you join a host.
- **The host's save, every time.** The second PC always loads the host's actual save, even when both PCs have saves with the same name.
- **Your character is kept safe.** It is only recorded in the host's world and is backed up before it is replaced. Fixes the second PC starting in early Kaer Morhen and losing all its gear.
- **Back from the main menu.** After quitting to the main menu, the Co-op lobby opens again by itself and brings you back into the host's game. The host's lobby popup opens by itself too.
- **The launchers remember you.** Play Host LAN and Play Join LAN offer your last name and the host's address (Enter keeps them). The game keeps your own graphics settings.
- **Fixes:** a host feature could silently stop working because the server allowed too few co-op message types; the host server's settings file is back in the package.

## lan-dev-2026-10-25-4 (25 October 2026)

- **Shared quest XP.** When a quest pays out for one player, the other gets its XP too, once. Money and items go to whoever finished it.
- **Shared chests.** A chest one player loots loses the same items for the other; empty it on one PC and it is empty on the other.
- **Your own character, part 2.** The second PC also keeps its own mutations, stash, horse gear and Gwent cards.
- **Watch / Skip is back.** When your partner starts a conversation you are asked to watch it or skip it. Choose Ask, Always or Never in the mod's settings menu.
- **Leaving the party sticks.** After you leave the host's party, your game no longer joins it again by itself.
- **No name labels in cutscenes.** Other players' name labels no longer show over the subtitles.

## lan-dev-2026-10-25-3 (25 October 2026)

- **Co-op lobby in the main menu.** The host starts with its newest save, which the second PC downloads and loads by itself, or starts a new game that the second PC starts too.
- **Play in the host's game.** The second PC loads the host's world (same story point, choices and place), joins the host's party by itself, steps in beside the host and follows the host's difficulty.
- **Your own character.** The second PC keeps its own Geralt: level, XP, skills, money, recipes and gear.
- **Fix:** the empty player menu; joining and leaving the party now ask to confirm.
- This build left out the Watch / Skip prompt: the other player joined conversations automatically.

## lan-dev-2026-10-25-2 (25 October 2026)

- **Death and revive.** In a party, a lethal blow knocks you down instead of killing you. A party member who holds Interact beside you for 3 s revives you; after 30 s without help you get up beside a party member.

## lan-dev-2026-10-25 (25 October 2026)

The first build meant for two real PCs.

- **LAN co-op for two PCs.** Play Host LAN on one PC, Play Join LAN on the second PC, then join the host's party in game. Co-op saves are kept apart from your solo saves.
- **Installs into your game folder.** Manage Mod installs and updates the mod in your existing Witcher 3 folder, backing up what it replaces; Remove Mod restores the original files.
- **Shared world in a party.** Enemies, quest progress, story choices and nearby NPCs are shared.
- **Talk together.** When one player talks to an NPC, the other is asked to watch the same conversation. The player who started it chooses the answers; the other's picks show up as suggestions.
- **Shared quest scenes.** Scenes a quest starts by itself are shared the same way.
- **Travel together.** Anyone within 60 m of a player who fast-travels goes along; players elsewhere stay put.
