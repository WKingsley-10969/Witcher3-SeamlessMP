# Verification — 2026-10-24

**15/15 checks passed under Windows PowerShell 5.1.**

**15/15 checks passed under PowerShell 7.6.5.**

Both runs used the included, compiled Java server with the approved portable Eclipse Temurin JDK 21.0.12.1. Actual server/client sockets ran on localhost in a permitted unsandboxed command. An earlier sandboxed attempt could start Java but its UDP probe timed out; it is not counted as a passing network run.

| Check | Result on both shells |
|---|---|
| All PowerShell scripts/module parse | PASS |
| Private IPv4 and loopback accepted; public/malformed addresses rejected | PASS |
| Invalid player names rejected, including trailing LF/CRLF | PASS |
| Client endpoint plan is correct and leaves the process environment unchanged | PASS |
| Missing Java/JAR fail without pretending to start a server | PASS |
| An unused UDP endpoint is not reported as connected | PASS |
| Real Java server answers a compatible probe without creating a player | PASS |
| Occupied port rejected; original server remains running | PASS |
| Actual join CLI reports compatible server reachability | PASS |
| Two simulated players receive each other's co-op state | PASS |
| New snapshots replace older state | PASS |
| A late simulated joiner receives the latest state | PASS |
| Movement messages work alongside co-op messages | PASS |
| Graceful server shutdown returns exit code 0 and releases the port | PASS |
| Actual host CLI reaches readiness, exits on Enter and leaves no listener | PASS |

The simulated clients send protocol data; they do not run Witcher 3. The late-join check briefly adds a third simulated client to validate retained state, not to claim supported three-player gameplay.

The two-client packet exchange checks transport and server storage/rebroadcast. It does not model authoritative combat, damage correctness or quest execution. Neither a localhost run nor two shell versions is a two-PC LAN test.

## Not performed

- No Witcher 3 installation is available: engine detection, executable identity, native client compilation, mod installation and game launch were not performed.
- No gameplay, save isolation, combat, quests, bosses, cutscenes, travel, death or reconnect recovery tested.
- No second PC, physical LAN/Wi-Fi route, firewall traversal, or internet connection tested.
- No game-version compatibility confirmed against an installed executable.
- No firewall, router, system PATH or Steam account changes made.

The starter uses the unchanged upstream server. It adds local launch/probe tooling, validates a future game-client configuration, and includes source/licenses. It is not a complete multiplayer mod installer.

## Next verification gate

Install the game when ready; identify the exact build; stage an isolated test copy and save profile. Build and validate the native client and save-isolation hook there. Only then run two real game clients and establish the first gameplay baseline.
