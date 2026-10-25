# Exact fact operation observer progress

24 October 2026 — **FactsSet-only implementation; real-game verification owned by root**.

## Latest correction — scene helper annotation rejected

The real compiler rejected `@replaceMethod` followed by the `storyscene` modifier at line 29. This syntax was not a passing integration. A later plain-function candidate passed compilation in root's test, but that does **not** prove that original storyscene metadata remains intact or that scenes invoke the replacement correctly. Therefore the active `sceneFactCapture.ws` is now narrowed to **FactsSet only**. AddFact_S/RemoveFact_S candidates were moved to `candidates/scene-helper-candidates.txt`, an intentionally non-staged file. Do not claim scene-helper coverage.

`check_provenance.py` still checks all three equivalent helper bodies for research, but the generated manifest explicitly labels only FactsSet active and the two scene helpers unstaged research. Body equivalence does not establish annotation metadata. Root will copy the narrowed file after the current test and run actual capture/effect regression. No native import/header changes were required for this correction.

The history below describes the initial broader candidate and must be read with this correction.

Owned changes: bridge `src/FactOperationJournal.h`, built-in imports in `src/NativeImports.cpp`, and the experimental `sceneFactCapture.ws` source here. The source has not been copied into the active mod by this worker; root owns that integration and all game launches.

The active slice records exact Add/Remove calls made by scripted `FactsSet`, including effective validity duration and observed engine timestamp. FactsSet passes no telemetry flag, so its records correctly have telemetry=false. The journal can retain telemetry metadata for future verified adapters, but no active scene adapter supplies it. Direct native FactsAdd/Remove calls, AddFact_S/RemoveFact_S and native quest graph nodes bypass active capture. It does not replicate the operations or establish full quest support.

No inline detour was installed: parsing the native frame then replaying it can evaluate argument expressions twice, and no verified native DB member signature was available. Bare `@replaceMethod` for global functions is explicitly documented by CDPR. The exact shipped helper bodies are preserved with observation calls inserted after their existing primitives. Other global replacements conflict; this is opt-in experimental code.

Native capture requires WO_SC_CAPTURE=1, an explicit test scope and explicit watched sc_test_ targets. Its bounded queue retains immutable ordered operations, rejects stale generation/revision ACKs, suppresses only a synchronous remote bracket and latches overflow as requiring reconciliation. Reset is required on every load. No production quest target can be watched. Every active FactsSet call produces a remove/add pair; its remove call is recorded even when the target was initially absent, matching the original helper's unconditional native call.

Checks actually run: the real native journal header compiled with MSVC C++17 `/W4 /WX` and passed **92 checks**. All **10 guard-breaking mutation twins** were caught (target allowlist, explicit watch, expiry preservation, ACK generation/order, remote echo, prior local retention, overflow retention/stickiness and load generation). The first mutation run stopped because an intentionally constant condition triggered a compiler warning under `/WX`; that mutant-only warning was suppressed and all ten then built and were caught. Native helper-body provenance check passed for all three functions after excluding the guarded observation calls; exact executable/script hashes are in `provenance.json`. Production `NativeImports.cpp` also compiled independently with `/W4 /WX`; the first compile caught an incorrect ReturnString overload and it was corrected to the actual four-argument API before the passing compile. No DLL was linked or staged by this worker. Root must still build the DLL, compile scripts and run real clients before claiming script or engine integration.

The extra `WNB_FactOpsActive():bool` import makes disabled observation skip string marshalling in the wrappers. Queue wire output uses classic locale and nine significant digits for the engine float timestamp. No opcode frame is evaluated twice, and no machine-code hook is installed.

Important limits: the queue is in-memory and is not yet connected to the campaign coordinator. Records represent completed helper primitive calls, not an atomic engine/save transaction. Direct `FactsAdd`/`FactsRemove` outside these helpers still bypass capture. Root owns reset on load and remote-apply lifecycle integration. A direct final FactsRemove in a bot must not be mistaken for an observed operation.

Final integration-ready state: active source frozen at FactsSet only after the scene-annotation correction. Built-in imports are declared at the top of `sceneFactCapture.ws`. Root may copy that source into the actual mod, rebuild the bridge and stage only the verified isolated game. The .txt candidates must not be copied as active scripts. No game/server processes or leases were started by this worker. New `src/FactOperationJournal.h` is untracked and must be preserved and included in any future source archive.

Primary reference for global replacement syntax: https://cdprojektred.atlassian.net/wiki/spaces/W3REDkit/pages/36241598/WS%253A%2BScript%2BCompilation%2BErrors%2Boverrides . Current native wrapping notes: https://cdprojektred.atlassian.net/wiki/spaces/W3REDkit/pages/12058625/Changelog . Local executable includes native-wrapper restriction text for modio mods; no such flag was guessed or enabled.
