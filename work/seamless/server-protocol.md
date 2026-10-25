# Seamless campaign coordinator, protocol 1

This is an experimental ordered campaign-intent ledger, separate from the existing enemy/quest channels. It does not prove that a remote Witcher engine executes arbitrary quest graphs, scene side effects, rewards, world changes, or rollback. Engine adapters advertise only the effect kinds they can actually apply; the initial integration should leave these capabilities disabled until tested against an isolated game copy.

## Starting the existing server with the coordinator

The original first positional UDP port still applies. Campaign mode is opt-in:

```powershell
$env:WO_CAMPAIGN_HOST_TOKEN = '<random shared host secret at least 16 characters>'
java -jar WitcherServer.jar 40000 --campaign-host HostName --campaign-dir '<dedicated campaign directory>' --campaign-voting true --campaign-shared-xp true
```

The launcher should set this environment variable only on the server/host child processes, not persist it globally or distribute it to guests. `--campaign-host-token <secret>` is also supported for test harnesses. Host and directory must be explicit; the first connecting player is never elected host. Voting and shared XP policy default to true; a saved campaign refuses a changed host or changed policy. Shared XP policy does not activate an XP adapter.

The server retains legacy UDP binding on every local interface. No router configuration, firewall changes, external traffic, or game launching is performed by the coordinator. HTTP status stays disabled unless explicitly enabled through the existing server properties.

The state directory contains `campaign.bin`, an atomic-replacement temporary file, and `campaign.lock`. A process lock prevents two servers writing the same campaign. Durable commits fsync the temporary file before atomic replacement. A corrupt/unrecognized state or unsupported atomic filesystem causes failure instead of silently resetting progress. Disk format 3 adds dialogue instance state. Format 2 is read without resetting epoch/history/receipts; old active scopes are released on startup as before, and the next write upgrades the file to format 3. This remains a development format, not a general future migration promise. No existing game save is read or modified.

## Transport and request ordering

Fields use the existing tab-separated COOP encoding, including existing backslash escaping. Requests:

```
COOP  <username>  sc  1  <clientSession>  <requestSeq>  <operation>  <arguments...>
```

The legacy optional numeric player id can precede username. A clientSession is a persistent random token matching `[A-Za-z0-9_-]{16,64}`. Keep it in the launcher profile across launches. The host name is ASCII letters/digits/underscore, 2–16 characters, case insensitive for identity, excluding `none` and `SCServer`.

One request is outstanding per session. Sequence starts at 1; retry identical fields with the same sequence until acknowledged. A successful/semantic-error sequenced response consumes that sequence. Malformed packets, authentication failures, `STALE_EPOCH`, `HELLO_REQUIRED`, `BAD_SEQUENCE`, and endpoint ownership failures do not. A duplicate most-recent committed request replays its durable result with a new response tick; a different request using the same number returns `REQUEST_CONFLICT`. Older requests return `ALREADY_APPLIED` and the last accepted sequence. Future requests return `BAD_SEQUENCE` and the expected sequence.

There is no global campaign broadcast or broadcast-cache insertion. Every request receives one unicast reply:

```
COOP  2147483647  SCServer  sc  1  <worldEpoch>  <responseTick>  <clientSession>  <requestSeq>  <status>  <arguments...>
```

The reserved player id and `SCServer` name cannot be registered by legacy clients. Epoch and tick are **64-bit decimal strings**; keep them as strings in WitcherScript. Response tick changes even for cached replies, so the existing native COOP duplicate filter can deliver retries. Clients must match session + sequence before processing replies. The epoch identifies the persisted campaign and remains stable across server restart. All post-HELLO requests must echo it; a different epoch is rejected.

`HELLO` has arguments `role proof capabilityCsv`, without an epoch. `role` is `host` or `guest`. Host must match the configured host name and supply the configured secret. Guest uses `-` for proof. Capability CSV contains a subset of `fact,journal,item,xp`, or `-` for no capabilities. Use nonempty `-` placeholders because the native script sender tokenizes on whitespace.

`WELCOME` arguments are `epoch latestEventId`. After restart, the client must HELLO again. For a persisted session, use the next request number; `BAD_SEQUENCE expectedSeq` supports recovery when the client lost the previous reply. If the old pending mutation was already committed, reconnect then replay the ledger rather than issuing a second independent mutation. In-flight leases/pending transactions are released on restart with ordered `CLOSE ... SERVER_RESTART` events; committed transactions remain.

Session transport is bound to the exact endpoint separately from legacy name/session handling. Moving a live session to another endpoint is rejected for 15 seconds. The host secret protects host-role claims. This is a trusted home-LAN protocol; it provides no encryption or protection against an attacker observing/altering LAN traffic. Guest random session identifiers are bearer identities, not passwords.

## Polling and replay

Every operation below begins with `worldEpoch` in its argument list:

| Operation | Remaining arguments | Result |
|---|---|---|
| `GET_STATE` | `lastAppliedEventId conversationIdOr-` | `STATE` as below |
| `ACK` | `lastAppliedEventId` | `OK cursor`; stores monotonic delivery acknowledgement |
| `OPEN` | `conversationId scopeKind scopeId` | `OK conversationId leaseId`, or `BUSY existingConversation owner` |
| `LISTEN` | `conversationId` | `OK conversationId owner` |
| `UNLISTEN` | `conversationId` | `OK conversationId`; owner must CLOSE |
| `RENEW` | `conversationId` | `OK 15000` |
| `CHOICE` | `conversationId choiceId` | `OK choiceId`, or vote/ownership error |
| `CLOSE` | `conversationId` | `OK` |
| `VOTE_OPEN` | `conversationId choicesCsv` | `OK voteId choicesCsv` |
| `VOTE_CAST` | `voteId choiceId` | `OK voteId resultOrEmpty` |
| `EFFECT` | `transactionId conversationId kind target value` | one-member transaction shortcut |
| `TX_BEGIN` | `transactionId conversationId baseRevision expectedMemberCount` | `OK transactionId` |
| `TX_EFFECT` | `transactionId memberId kind target value expectedValueOr-` | `OK transactionId memberId` |
| `TX_COMMIT` | `transactionId` | `OK transactionId` or conflict/incomplete result |

The original CHOICE/VOTE forms above are legacy development operations. Once a scope publishes a registered choice instance, missing instance context returns `CHOICE_INSTANCE_REQUIRED`. The instance-aware operations below are required by the updated adapter. `GET_STATE` retains its original field positions and event cursor behavior.

`STATE` arguments:

```
latestEventId sharedXp conversationId ownerUsername leaseRemainingMs voteId choicesCsv voteResult eventPresent
[eventId eventType actorUsername eventPayload...]
```

The selected conversation fields can be empty. `eventPresent` is `0` or `1`; at most one event strictly after the supplied cursor is returned. Every committed event is replayable from cursor 0. A cursor ahead of latest is rejected; ACK does not prune events. Process events in order and advance cursor only after the adapter has applied/verified them. ACK is a delivery receipt, **not proof that a game save contains the effects**. Save reload and receipt persistence must be coordinated by the engine integration; do not skip effects merely because an older process ACKed them.

No event compaction is implemented. The ledger bounds events to roughly 20,000 (capacity reserved for orderly release), sessions to 64, committed transactions to 10,000, simultaneous scopes to 16 and pending transactions to 16. Capacity exhaustion explicitly rejects new mutations. Each sequenced request currently rewrites a bounded snapshot; optimize to a journal/checkpoint scheme before claiming long-campaign performance.

## Independent scoped ownership and voting

Scope kind is `npc` or `quest`. Conversation id, scope id, choices, transaction ids, members, and effect targets use ASCII tokens matching `[A-Za-z0-9_.:/%-]{1,96}`. Prefer explicit stable aliases for scenes/quests; URL-encoded paths can fit this grammar. `OPEN conversationId` without explicit scope remains a development compatibility shorthand for an NPC scope with the same id.

Each scope has one lease owner. A different conversation on the same scope is BUSY; unrelated scopes can proceed simultaneously. Host and guest can each own independent quests. Any listener can observe/poll; only the owner can RENEW, choose, close, or submit effects for that scope. Host status does not override another player's lease. Renew before 15 seconds; any next request observes and durably releases expired/disconnected ownership. No progress depends on an offline client acknowledging an event.

Vote choices are 2–8 distinct tokens. Listener membership is frozen when a vote opens. Each voter casts once; all current voters must cast before resolution. Explicit UNLISTEN or transport expiry removes unresolved voters. The owner's choice wins a tied top count; otherwise the first tied option in the declared order is deterministic. Once resolved, the result is binding: CHOICE rejects a different choice. The engine must enforce a pending CHOICE result before advancing the local scene; the ledger alone cannot stop an unmodified client.

## Dialogue choice instances

Each successful OPEN creates a new server-issued `leaseId` (`lease-<OPEN event id>`). Closing and reopening the same conversation ID never reuses that lease. Every registered prompt has a caller-supplied `instanceId`; the pair `(leaseId, instanceId)` identifies one exact prompt, including prompts with identical displayed text/options. At most 256 distinct instances can be declared per lease in this prototype.

All operations still begin with `worldEpoch`:

| Operation | Remaining arguments | Result |
|---|---|---|
| `GET_DIALOGUE` | `conversationId` | `DIALOGUE` snapshot, or `NO_CONVERSATION` |
| `CHOICES` | `conversationId leaseId instanceId choicesCsv mainStoryBool` | `OK conversationId leaseId instanceId` |
| `CHOICE` | `conversationId leaseId instanceId choiceId` | `OK choiceId leaseId instanceId canonicalEventId duplicateBool` |
| `VOTE_OPEN` | `conversationId leaseId instanceId` | `OK voteId choicesCsv leaseId instanceId` |
| `VOTE_CAST` | `voteId leaseId instanceId choiceId` | `OK voteId resultOrEmpty leaseId instanceId` |

`GET_DIALOGUE` returns status `DIALOGUE` followed by:

```
conversationId leaseId instanceId choicesCsv mainStoryBool acceptedChoice canonicalChoiceEventId voteId voteChoicesCsv voteResult leaseRemainingMs ownerUsername
```

For the script's `WO_Str` indexing, status is field 6; these snapshot fields are indices 7 through 18 respectively. A scope with no registered prompt has empty instance/choice strings and choice event id `0`. This snapshot describes coordinator state, not whether an engine graph has actually executed it.

CHOICES is owner-only and accepts 1–8 distinct choice tokens (2–8 for main story). The boolean must be exactly `true` or `false`. Repeating the same current instance and exact options/main flag is idempotent and appends no event. Changing those fields under the same ID returns `CHOICE_INSTANCE_CONFLICT`. A different prompt cannot replace an unaccepted current prompt (`CHOICE_PENDING`); accept or close the interaction first. Reusing a past instance within a lease returns `STALE_CHOICE_INSTANCE`. Wrong lease IDs return `STALE_LEASE`.

An accepted choice is stored with one canonical event id. A rapid second click using a **new request sequence** but the same current lease/instance/choice returns that same receipt with `duplicateBool=true`, and appends no second event. An exact request retransmission returns its original cached reply. A different choice after acceptance returns `CHOICE_ALREADY_ACCEPTED`. Requests for an earlier prompt after a new one is published return `STALE_CHOICE_INSTANCE`, even if the earlier choice was accepted; old canonical events remain available through ledger replay.

For `mainStoryBool=true`, CHOICE cannot bypass voting before a vote is opened (`VOTE_REQUIRED`) or while it is pending (`VOTE_PENDING`). VOTE_OPEN derives its options exclusively from the registered prompt and rejects side prompts (`NOT_MAIN_STORY`). Reopening the same prompt's vote returns the existing vote id without another event. After resolution, a conflicting choice returns `VOTE_BINDING`. Voting disabled by campaign policy returns `VOTING_DISABLED` for a registered main-story prompt rather than silently accepting an unvoted answer.

Votes include lease and prompt instance in requests and events. Delayed votes from an earlier prompt cannot affect a new prompt. A duplicate identical cast is idempotent even after resolution; changing a voter's existing selection returns `VOTE_ALREADY_CAST`. This still votes among the frozen listener membership, not an unimplemented global party UI.

Registered prompts append these new event types, leaving legacy event payloads unchanged:

| Type | Payload |
|---|---|
| `CHOICES` | `conversationId leaseId instanceId choicesCsv mainStoryBool` |
| `DIALOG_CHOICE` | `conversationId leaseId instanceId choiceId` |
| `DIALOG_VOTE_OPEN` | `conversationId leaseId instanceId voteId choicesCsv` |
| `DIALOG_VOTE_RESULT` | `conversationId leaseId instanceId voteId result` |

Adapters must match current lease+instance before driving one owner graph. Listeners may display an outcome but must never independently execute the same graph. On server restart active scopes are durably released and historical events are replayable; neither a snapshot nor a canonical receipt authorizes replaying a historical engine choice after loading/joining.

Event payloads:

| Type | Payload |
|---|---|
| `OPEN` | `conversationId scopeKind scopeId` |
| `CHOICE` | `conversationId choiceId` |
| `CLOSE` | `conversationId reason` |
| `VOTE_OPEN` | `conversationId voteId choicesCsv` |
| `VOTE_RESULT` | `conversationId voteId result` |
| `TRANSACTION` | `transactionId conversationId scopeKind scopeId memberCount (memberId kind target value)*` |

## Scoped effect transactions

Single EFFECT is a one-member transaction named `single`. Multi-effect transactions declare 1–4 members at BEGIN; no incomplete transaction commits. Duplicate member id with identical contents is accepted; changed membership or duplicate target is rejected. Effect kinds are explicitly allowlisted. `fact` is an absolute signed 32-bit desired total, optionally suffixed `@validFor` (a canonical positive 32-bit engine duration, as captured from `FactsSet(id, value, validFor)`; no suffix means permanent). An `expected` value compares the whole stored string, suffix included, `journal` an absolute numeric desired status (currently bounded 0–4; the adapter must also match the engine's actual enum), and `item`/`xp` are extension points whose engine adapters are not currently proven. Never advertise unsupported kinds.

Every active adapter must advertise a member's kind before the server accepts it. Disconnected peers do not block a commit and can replay later. Each reconnecting adapter must stop replay on an unsupported effect rather than falsely ACK it. Targets must additionally pass an engine-side allowlist and resolve to the intended quest/NPC before applying. Global journal/fact snapshots are not a substitute for scoped quest side effects.

BEGIN's baseRevision is the observed latestEventId. At COMMIT all members validate first. A target changed after baseRevision returns `REVISION_CONFLICT`; a specified expected value different from the ledger returns `VALUE_CONFLICT`. Unrelated target updates do not conflict. The server appends one ordered, durable TRANSACTION event containing all members and then updates target revisions. Retrying a committed transaction id cannot apply it again; changed single-effect contents return `TRANSACTION_CONFLICT`. Transaction ownership persists across restart for receipt checks.

This is atomic **ledger membership**, not atomic engine execution: the adapter can preflight all members but cannot promise rollback of arbitrary engine/script effects if a later application fails. Reapplying absolute fact/journal values can repair state, but does not establish that remote quest graphs, scene triggers, rewards or irreversible side effects ran correctly. Item/XP additive semantics need a receipt tied to the exact campaign save before enabling.

## Verification without a game

Compile source/tests with the existing portable JDK (`--release 17`; existing ClientEndpoint uses instanceof patterns). `SeamlessCampaignTest` exercises authentication, strict ordering, durable dedupe/restart, lock/corruption handling, simultaneous scopes, ownership, voting/listener release, membership validation, revision/value conflicts, largest transaction replay, choice-instance ordering/canonical receipts, guest-owned tie resolution/host-listener disconnect and format-2 migration. `SeamlessUdpIntegrationTest` starts actual WitcherServer subprocesses on loopback UDP, exercises lost-response retry, duplication and out-of-order requests, forged host/owner/reserved identities, separate scopes, abrupt kill/restart/replay and the instance-aware dialogue operations. Latest server-only run: 236 pure assertions and 376 real UDP assertions passed. These tests do not validate WitcherScript compilation or game behavior.

## Captured fact replication (adapter)

### Explicit removal extension (25 October 2026)

`EFFECT <epoch> <transaction> <scope> fact <target> absent` removes a fact. The literal `absent` is a retained tombstone in the **same fact target/revision namespace** as SET; it is not the existing numeric value `0`, and it is not a new effect kind. It has no duration. `TX_EFFECT` accepts `absent` as the desired or expected fact state. Expected `absent` matches a committed tombstone, not an unknown target that has never been recorded. Expected `-` still means no precondition. Dedupe, ownership, atomic ledger membership and revision conflicts apply unchanged.

All active clients must advertise both `fact` and the extension capability `fact_remove` before a removal can commit, including at TX_COMMIT. Once any removal is in retained history, HELLO without `fact_remove` returns `CAPABILITY_REQUIRED fact_remove` without consuming the request sequence. This also applies after restart and after a later SET restored the flag: loading a save replays historical removals. Existing campaigns without removals still accept old capability advertisements. No disk format change is required; values/events were already strings.

The updated adapter advertises `fact_remove` when effects are enabled. Snapshot capture maps `exists=0` to `absent`, retaining the native record until the ledger acknowledges the commit. Remote application removes the flag inside the existing snapshot and operation-journal echo guards. Preflight validates every member first; same-process captured echoes are skipped, and a fresh process/load replays the tombstone. `RequestFactRemoval` provides the explicit scoped request path.

**Engine scope:** only `sc_test_` targets may be removed. SET support for `mh306_job_taken` does not vet its removal; capture of that removal stops with `SNAPSHOT_REMOVAL_NOT_VETTED` and leaves the record unacknowledged. This is snapshot observation, not a global hook for all native FactsRemove calls, and does not recover intermediate changes between snapshots or fact timestamps.

Verification on the separate Codex branch: 255 existing pure assertions + 54 removal assertions + 448 UDP assertions passed; 5/5 deliberately broken server variants were caught. The `seamless_removals` bot is written but **not compiled/run in the game** while Claude uses the original checkout. It checks existing zero → absent → existing zero with host receipts between transitions, exact commit/application counts and empty echo queues. Neither real quest removal nor save/load removal replay in the game has been proved.

The owner of a scope drains the native FactsSet journal (`WNB_FactOps*`) one FactsSet at a time. Each FactsSet is recorded as a `remove`/`add` pair for one target; the adapter acknowledges the `remove` locally, turns the `add` into `EFFECT fx_<processNonce>_<generation>_<revision> <scope> fact <target> <value[@validFor]>`, and acknowledges the `add` only after `OK` (or `OK ... DUPLICATE` on a resend). Only operations captured under the scope id the client currently owns are sent; others wait. Any other reply halts the adapter (`CAPTURE_COMMIT_<status>`) with the operation still queued.

Applying a `TRANSACTION` brackets each fact write in both remote-echo guards (`WO_SCBeginRemoteFact` and, when capture is active, `WNB_FactOpsBeginRemote`), so a replicated write is never recaptured. The capturing process skips its own `fx_<processNonce>_` transactions because the engine already holds them; a later process (new nonce) replays them like any remote write. A positive duration re-arms expiry from the applying game's current time. Capture remains restricted to `sc_test_` scopes and targets.
