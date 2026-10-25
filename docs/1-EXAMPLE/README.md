# Witcher 3 co-op: what we are building

This document explains the intended experience for you and the player on the second PC. **It is a plan for the finished mod, not a list of features that already work.** The current development build is an early prototype.

## The basic idea

You host a shared Witcher 3 campaign on your PC. A second PC joins over your home network, also called LAN.

You can explore and fight together, or split up to do different side quests. You each control your own character. Neither player should need to stay next to the host all the time.

Think of it as **one shared adventure with two players making progress in different places**.

## Example 1: you both play together

You enter a village together and accept a monster contract. You find the monster, fight it together and finish the contract.

The intended result:

- Both players see the same monster and the same outcome.
- The contract is completed once in your shared campaign.
- Quest XP is shared.
- An ordinary unique item reward belongs to the player who completes the quest. It is not automatically copied into both inventories.

## Example 2: the second PC does a side quest far away

You stay in Novigrad. The player on the second PC travels to Skellige and starts a different side quest.

You should be able to continue your own quest while they play theirs. The second PC draws the part of the world that player is visiting; your PC does not need to draw Skellige on your screen.

When they complete their quest, the second PC's game sends the result to your host. Your host records that result as part of the shared campaign.

If the quest changed an NPC, opened a door, awarded an item or changed another quest, those consequences must be recorded too. **Changing the quest log to say “complete” is not enough.**

When you later visit that place, you should find the world in the state the second PC's actions left it. That progress should still be there after you save and come back another day.

This is one of the largest pieces still to build and prove in the actual game.

## Example 3: the second PC starts a conversation

The player on the second PC speaks to an NPC first. They own that conversation and choose the replies.

You being the host does not give you control of their answers. They should not need your permission for ordinary side-quest choices.

If you walk nearby, the plan is to show a **Listen** action. You could press a key, such as X, to watch and hear the conversation. The exact key is not decided yet.

Listening should let you follow what is happening without choosing replies or making the game run the same quest twice. If you stop listening, the second PC's player should be able to continue.

Safe cinematic listening is not implemented yet. Simply starting the same conversation on both PCs could repeat quest effects or rewards, so it needs proper support.

## Example 4: an important main-story decision

For designated important main-story choices, the plan is to ask the connected party to vote before the conversation continues.

For example:

1. The player on the second PC starts a main-story conversation.
2. An important choice appears.
3. Each eligible player votes.
4. The winning answer becomes the shared campaign's decision.

**If the vote is tied, the player who started the conversation breaks the tie.** With two players voting differently, that player's selected answer wins.

These are the rules you selected:

| Situation | Intended rule |
|---|---|
| Ordinary side-quest conversation | The player who starts it controls the replies |
| Important main-story choice | Party vote |
| Tied vote | Conversation initiator breaks the tie |
| Quest XP | Shared |
| Ordinary unique item reward | Kept by the player who completes the quest |

The plan is to make these rules configurable. The server already has voting logic, but normal story scenes are not connected to a finished voting interface yet. XP and item distribution still need game integration.

## What if you both approach the same NPC?

Two unrelated side quests should be able to run at the same time. Two players trying to control the same NPC or make conflicting changes need an order.

The intended rule is that the first accepted interaction owns that conversation. The other player can listen or wait. Neither player should overwrite the other's choice just because their PC sent a message slightly later.

Some side quests affect the same people or events. The mod must treat those consequences as part of one shared world, rather than assuming every side quest is completely separate.

## Does your PC act as the server?

**Yes.** Your PC runs both your game and a small server that coordinates the shared campaign.

The second PC runs its own game and connects to your PC using its home-network address. It still handles its own graphics and controls.

For this LAN version, a separate rented server is not needed. Your PC must stay running and hosting while the second PC plays in that campaign. If you close the host, the session ends; the second PC cannot keep advancing that shared campaign on its own.

## Saves and disconnects

The goal is to keep one host-owned campaign record, with each player's personal character state handled consistently alongside it. Co-op uses separate profiles so it does not overwrite your normal solo progress.

If a guest disconnects, the intended behaviour is to keep changes that the host has already accepted and let the guest reconnect. An unfinished conversation must release or recover its ownership so nobody gets stuck.

Loading an older save is harder: the game save and the shared campaign record must agree. That recovery is not finished. A server remembering an event does not by itself prove the game saved every consequence.

## What “seamless” should mean here

You should be able to separate, explore, enter conversations and complete supported quests without repeatedly ending the multiplayer session or gathering beside the host.

It does not mean removing Witcher 3's own loading screens. Travel, sleeping, points of no return and scenes that move the whole party still need clear rules. Quest-critical items also need a shared-access rule so an item in one inventory cannot block the other player.

## What works today, and what is left?

The existing prototype has LAN hosting, separate save profiles, player presence and some shared combat and leader-to-member quest/dialogue behaviour. Earlier automated checks exercised those mechanisms with two game clients on one PC. That is not proof of a complete campaign or two physical PCs playing together.

The new work adds a server foundation for independent quest ownership, conversation ownership, votes, ordered changes and progress replay after a server restart. An automated test with two real game clients has also passed: each player changed separate test values and both games received the changes, including changes sent by the guest to the host. That proves part of the connection between the games and the server; it does not prove real quest completion.

**The finished experience described above is still not ready.** The main remaining work is:

- Capture and apply all consequences of a real guest side quest while the host is elsewhere.
- Keep quest logic, NPCs, doors, items and rewards consistent across both games.
- Connect actual story conversations to ownership and voting controls.
- Add safe Listen playback without repeating quest actions.
- Make saving, loading and reconnecting preserve the same shared world.
- Test real quests, conflicting choices and long sessions on two PCs.

The next useful milestone is a small, proven example: the second PC completes one real side quest in another region, you receive all its consequences, and that result survives a host save and reload. Until that works, we should describe this as a development prototype rather than finished seamless co-op.
