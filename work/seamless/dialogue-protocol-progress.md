# Dialogue protocol progress

24 October 2026 — in progress. Owning server source/tests and server protocol document only. Root owns script integration and the shared handoff document.

Current finding: request-sequence dedupe alone does not prevent a second UI click with a new request number from accepting the same dialogue prompt twice. Existing conversation IDs also survive caller reuse, so requests must include a server-issued lease identity and a unique choice-instance identity.

Proposed protocol sent to root before code changes: preserve existing GET_STATE/event layouts for compatibility, add GET_DIALOGUE snapshot and registered CHOICES operation; new choice/vote forms carry lease+instance IDs; legacy forms rejected once a scope enters registered mode. New event types carry instance context. Format 3 should read existing format 2 without resetting campaign history.

Implementation is now present in `server/src/SeamlessCampaign.java`: OPEN lease IDs, GET_DIALOGUE snapshot, registered CHOICES, instance-bound owner choice/votes, canonical acceptance receipts, immutable published prompts and format-3 storage with format-2 reading. Existing GET_STATE and legacy event layouts remain unchanged; missing context is rejected for registered scopes.

Verification run using the existing portable JDK through the bundled PowerShell 7 executable: **236 pure assertions and 376 real UDP assertions passed**. Tests include duplicate clicks with distinct sequences, exact lost-ACK retries, changed answers after acceptance, repeated identical-text prompts under new IDs, old prompt/vote rejection, owner forgery, close/reopen lease nonce, abrupt restart/replay and format-2 migration without resetting epoch/history. Explicit guest-initiated dialogue tests prove that the host cannot take over, guest wins a tied top vote, and a disconnected host listener no longer blocks a renewed guest owner. Existing 115/145 checks remained included. Production-only JAR rebuilt at `work/WitcherOnline/server/build/WitcherServer.jar`.

Initial invocation through Windows PowerShell 5.1 was refused by its local script execution policy; no settings were changed. The same local script ran successfully with the already bundled PowerShell 7 runtime. No game launched by this worker.

Scope limits: 256 registered prompts per lease; no replacement of an unaccepted prompt without accept/close; voting membership is the existing frozen listener set. Engine graph/application, UI and safe spectator behavior remain root integration work. A coordinator canonical receipt is not proof of an engine/save effect.
