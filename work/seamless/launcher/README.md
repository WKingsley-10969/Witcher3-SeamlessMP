# Experimental persistent campaign launcher

This is development tooling, separate from the existing LAN release ZIP. It enables the campaign coordinator with a persistent local player identity. **It does not enable full distant quests, cinematic listening, inventory/XP sharing or save/ledger reconciliation.** Engine effect adapters default off. No ordinary story scenes are bound in this prototype.

The launcher requires the verified independent game copy with the newly staged `.w3lan-seamless.json` hash marker, the built server JAR, an existing Java 17+ runtime for hosting, an existing Python interpreter and the pinned gameslot source already present in this workspace. It installs nothing, changes no persistent environment variables and does not modify the original game or solo saves.

## Preview without launching or creating files

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File work/seamless/launcher/Play-Seamless.ps1 -Mode Host -GameDir '<verified test copy>' -PlayerName HostWitcher -HostName HostWitcher -CampaignName lan-coop -Plan
```

`-Plan` validates the executable, profile helper and experimental payload, reads existing campaign metadata if present, and prints only public routing and paths. It does not seed profiles, create credentials, start Java, acquire game slots or launch a game. Existing malformed credentials fail rather than being replaced. The process-only execution-policy flag is needed for authored local scripts on this PC; it does not change the machine policy.

## Opt-in development launch

Use the same command without `-Plan` to host. To join on a second PC with the same experimental source/test environment:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File work/seamless/launcher/Play-Seamless.ps1 -Mode Join -GameDir '<verified test copy>' -PlayerName GuestWitcher -HostName HostWitcher -CampaignName lan-coop -Address 192.168.1.20
```

Use the actual private IPv4 address of the host. Player names must differ. Host mode explicitly requires PlayerName to match HostName. `-JavaPath` and `-PythonPath` can select existing runtimes; no automatic downloads occur.

Windows PowerShell's Boolean command-line arguments can be awkward; the approved default is voting on and shared quest XP policy on. When invoking the script from an existing PowerShell session, `-Voting:$false` / `-SharedXp:$false` select alternate coordinator policy only for a new campaign. Existing campaign policy cannot silently change. The policy does not activate an XP engine adapter. Tied votes use the initiator, and ordinary unique rewards are intended for the completing player; no item distribution code is claimed here.

## Local persistent state

Under the verified copy:

- `.w3lan-campaigns/<campaign>/campaign.json`: explicit host/policy and protected per-player identities. The host proof and 32-hex session identifiers use Windows DPAPI, bound to the current Windows user and campaign/player/role. Host proof is 64 random hex characters. State updates use flush plus atomic replacement and retain `.previous` protected state; a short-lived bootstrap lock prevents simultaneous updates.
- `.w3lan-campaigns/<campaign>/state`: Java's authoritative development ledger for the host.
- `.w3lan-profiles/<player>/campaigns/<campaign>`: separate persistent co-op saves/settings and native log. First creation copies seed files; later launches keep co-op progress. A profile lock prevents two launchers using that same profile simultaneously.

Treat these as private runtime state, not source or upload artifacts. Do not copy protected credentials to another Windows user/PC; DPAPI will refuse them. A guest never receives the host's plaintext proof in its child environment. The host game receives its host proof; Java receives it separately via a child environment variable, never the command line. Parent environment remains unchanged and inherited bot/credential variables are cleared.

The campaign name is a local profile alias. It is not a proof that a guest's loaded save matches the remote host world. Binding the remote epoch and event cursor to actual game saves remains unfinished. If credentials are malformed, changed or missing beside an existing host ledger, restore the intended private state rather than silently generating a replacement host.

## Process ownership

Before a game launch the launcher takes one gameslot lease, registers the exact game PID and renews its lease periodically. It stops only processes it started. It monitors its owned Java server while the game runs and closes the owned game if that server dies, avoiding continued unsynchronized host play. Normal/error cleanup waits for owned processes to stop before releasing profile/game leases. It does not kill unrelated game/server processes or change firewall settings.

## Verification

`launcher-tests/Test-Campaign.ps1` uses fake game/save bytes and actual Java UDP server processes; it never executes the fake game. Windows PowerShell 5.1 and PowerShell 7 both passed 26 checks: write-free/redacted Plan, persistent/scoped protected identities, host/guest roles, join-only authority refusal, profile seed preservation, malformed/protected-state refusal, missing credentials beside an existing ledger, junction refusal, build hash checks, child environment isolation, actual coordinator HELLO/GET_STATE, same-session sequence recovery after server restart and server-death detection using harmless stand-in processes.

`launcher-tests/Test-Lease.ps1` separately passed acquire, exact harmless stand-in PID/name/creation registration, renewal and release under Windows PowerShell 5.1. The stand-in was stopped and its lease removed before root's game tests. It used the same workspace gameslot state so it could not accidentally run alongside an incompatible lease owner. Fixture output directories are ignored and must not be shipped.

Human launcher gameplay, second-PC use and save recovery are not verified. Root's separate real-game bot results establish only their recorded mechanism scope. The stable LAN ZIP remains untouched.
