# Witcher 3 seamless co-op target

Status: requested design. Experimental coordinator/native/script foundations are being implemented on game/seamless-coop; full gameplay remains unfinished. The existing 0.2.0-dev LAN package does not implement this target.

## User requirements

- One shared persistent campaign, hosted on one player's PC.
- Players can separate, load different areas and complete different side quests independently.
- Completing a side quest changes the authoritative shared world and persists on the host even when the host is elsewhere.
- The player who initiates a side-quest conversation controls its choices. Being the machine host does not grant control over another player's conversation.
- Nearby players can choose a Listen action/key to join as spectators without taking over or executing quest effects again.
- Main-story play is cooperative, with party voting on major story decisions.
- Ordinary separation, conversations, combat and quest completion do not end the multiplayer session.

## Proposed system boundaries

| System | Proposed responsibility |
|---|---|
| Campaign authority | Host records accepted world changes and owns the campaign save |
| Player agency | Each player controls their avatar and conversations they initiate |
| Remote areas | A designated owner simulates loaded NPCs/combat around distant players; rendering stays local |
| Quest execution | One writer for a quest interaction; changes are committed through the host rather than merging arbitrary single-player saves |
| Dialogue session | Stable NPC/scene identity, controller, spectators, line/choice state and ordered outcomes |
| Story votes | Vote session for designated main-story choices, separate from dialogue ownership |
| Persistence/reconnect | Numbered committed events, snapshots, per-player data and explicit save/load epochs |

The host remains the authority for committed progress, but it does not need to render the guest's location. Actual execution of a distant quest is an open engine question: either the host must execute its logic with an appropriate remote-player context, or a controlled execution lease must allow the guest to produce effects that the host validates and commits. Neither route is proven for this Witcher build. Do not pretend the existing native API already supports either.

## Important behaviours

- A guest completing side quest B while the host does side quest A must produce one completion of B in the shared campaign, with its NPC, item, journal, fact and reward changes—not only a journal flag.
- NPCs cannot be controlled by two conflicting conversations simultaneously. First accepted interaction owns the conversation; others can listen or wait. Disconnects release or recover ownership predictably.
- A listener must see/hear the conversation without independently advancing their own quest graph, choosing answers, duplicating rewards or taking over the controller.
- Shared NPCs and cross-quest dependencies remain shared even when quests are called side quests. Conflicting actions must be ordered against current world state.
- User-approved policy: the conversation initiator breaks tied main-story votes; quest XP is shared; ordinary unique item rewards stay with the player who completes the quest. These rules should be configurable. The engine adapters and interface for them are not complete.
- Points of no return, sleep, global travel, quest-critical item access, eligible voters and vote timeouts still need explicit rules.

## Existing prototype gap

The current source sends journal/fact changes from party leader to members. Facts only increase toward the leader's values. Enemy sharing depends on being in the leader's area and roughly 60 metres away or less. Party dialogue follows the leader's matching choices. This does not implement independent remote quest completion, conversation ownership, voting or spectator scene playback.

Useful reusable pieces: native bridge, script annotations, player presence, UDP transport, parts of combat replication, separate test profiles and the real-client bot harness.

Major new work: remote-area ownership, quest-side-effect capture/application, guest intents, ordered campaign commits, conversation ownership/spectators, story voting and robust campaign persistence. Read the engine state and hook paths before committing to an implementation.

## First end-to-end proof

1. Two real clients occupy different areas.
2. Each advances a different side quest using actual interactions.
3. Guest completion and all required world effects reach the host once.
4. Host saves; both reconnect/reload and still agree.
5. A conversation initiated by the guest stays guest-controlled when the host listens.
6. A designated main-story choice gathers votes and commits one outcome.
7. Repeat under reconnect, delayed/duplicate packets and conflicting NPC interactions.

Do not count a fake-world simulator, forwarded quest flag, existing leader-to-member test, or UI mock as proof of these behaviours.

## References

- Current baseline: https://github.com/Emillock/WitcherOnline, commit 3823f98c3364806a4b748f1e4b429101f013bc07, especially coopEnemies.ws and the party/dialogue logic.
- Design guidance, not evidence of a Witcher implementation: https://github.com/cranebeaker/coop-anything/blob/main/playbook/effect-capture-story-sync.md.
