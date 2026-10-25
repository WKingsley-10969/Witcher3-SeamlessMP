# Local contribution draft — not submitted

## Directory correction

The current directory entry predates W3Coop v0.2.0. Update its reported feature scope to acknowledge the release's shared enemies, journal/fact progression, party dialogue and sign visuals. Keep the alpha/prerelease designation. Qualify maintainer reports as one-PC tests, not a verified campaign or separate-PC test. Reconcile older passing enemy-move test tables with the current known failing playback check.

Source: https://github.com/Emillock/witcher3-coop/releases/tag/v0.2.0

## New verified LAN tooling findings

Pinned upstream server commit: 3823f98c3364806a4b748f1e4b429101f013bc07.

The Java UDP server can run separately from the Steam relay. It binds all IPv4 interfaces when started with java.net.preferIPv4Stack=true. An empty-username MOVE packet receives ERROR INVALID_USERNAME before player-session creation and can serve as a readiness/reachability probe. Unrecognized PING packets are ignored.

Server stdin EOF does not stop it: retain stdin, send stop, wait, and bound cleanup. Client environment overrides can avoid editing config.xml; set all three WO_USERNAME, WO_SERVER_IP and WO_SERVER_PORT because the native client otherwise has a public default endpoint.

New standalone PowerShell LAN tooling and the unchanged server were verified with 15 checks each under Windows PowerShell 5.1 and PowerShell 7.6.5. These tests used simulated clients and localhost, not the game. They cannot promote the game mod's gameplay QA level.

No public project URL exists for this local starter, so do not add a directory entry claiming it is a released mod. No PR, issue, fork or account action was performed.
