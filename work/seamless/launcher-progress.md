# Persistent campaign launcher work

Status: **verified within fixture, real UDP bootstrap/restart and harmless lease-helper scope**. Human gameplay/second-PC launch remain unverified. No game was launched by this worker.

Owned paths: `work/seamless/launcher`, `work/seamless/launcher-tests`, this progress file. Shared handoff remains root-owned; milestone notes are sent to root throughout work.

Design: opt-in experimental launcher, existing verified-copy/profile checks, write-free Plan, one atomic local campaign state with protected persistent player sessions and host-only proof, explicit invariant host/policy, child-only environment, owned-process cleanup and server death monitoring. Credential JSON must never be treated as public source or printed.

Implemented W3Campaign.psm1, Play-Seamless.ps1 and changes to the copied profile/server helpers. Added hash validation for root's new experimental build marker, DPAPI protected single-file campaign/identity state, invariant host/policy, per-campaign profile paths, write-free Plan, child-only credentials, server-death monitoring, owned cleanup and pinned gameslot acquire/register/renew/release.

Verification started with Test-Campaign.ps1. Initial ordinary PS5.1 invocation was blocked by this machine's script execution policy; using process-only `-ExecutionPolicy Bypass` runs local authored tests without changing the system policy. First actual run passed fresh write-free Plan, then found that PS5.1 needs its built-in System.Security assembly loaded before ProtectedData. Added explicit built-in assembly loading; rerun pending. No feature PASS claim yet.

Second PS5.1 run found File.Replace's null backup argument is bound as an invalid empty path in Windows PowerShell. Fixed by retaining `.previous` protected state during atomic replacement. The corrected Windows PowerShell 5.1 run **passed 23 checks**, including real UDP host/guest authentication, sequence recovery using the same identity after server restart, and unexpected-server-exit monitoring with harmless stand-in processes. No game was launched; server processes stopped gracefully. Fixtures remain under launcher-tests for investigation and contain only fake game/save bytes and protected test credentials.

PowerShell 7 also **passed 23 checks** after its fixture was adjusted to use ContainsKey when testing absent environment entries under StrictMode (production setter was already removing them). Added launcher README with exact limits, preview/launch commands, DPAPI/per-campaign state and process ownership. Stable outputs remain untouched.

Final verification: **26/26 checks passed in Windows PowerShell 5.1 and PowerShell 7** after adding join-only authority refusal, missing credential state beside an existing ledger and campaign-junction refusal. The expected experimental marker now includes `sceneFactCapture.ws` (eight required files) to match root's new staged build. No fixture executed its fake game bytes.

**Test-Lease.ps1 passed in Windows PowerShell 5.1**: acquired one lease in the shared workspace gameslot directory, registered one harmless owned powershell stand-in with exact PID/name/creation, renewed without losing that record, stopped it and released its lease. Root was notified before starting the real game pair; this worker will not take another lease while that pair runs.

Implemented files: launcher/Play-Seamless.ps1, launcher/W3Campaign.psm1, copied launcher/W3Lan.psm1 and W3LanProfile.psm1, launcher/README.md; tests Test-Campaign.ps1, Test-Lease.ps1 and fixture ignore rules. Fixture credentials are protected test-only data; fixture dirs are not source payloads. All worker-owned Java and stand-in processes are stopped. No game was launched and stable outputs/source were not changed.

Remaining: human launcher gameplay and two-PC use unverified; production packaging not updated. CampaignName is a local profile alias, not remote save/epoch binding. Full distant quests, cinematic Listen, item/XP engine adapters and game-save checkpoint reconciliation remain outside this launcher milestone.
