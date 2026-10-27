#requires -Version 5.1
# Co-op logs from the second PC, end to end on this PC with fixture logs only: the real server
# (Start-W3LanServer with a save folder) takes a joining player's logs on TCP Port+1, and the join
# launcher's functions queue and send them: the last session's at launch, this session's after the
# game, nothing twice, nothing outside the player's own logs, the opt-out, and a missing host.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$JavaPath,
    [string]$JarPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'server\WitcherServer.jar'),
    [ValidateRange(1,65534)][int]$Port = 41720
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'W3Lan.psm1') -Force
$root = Join-Path ([IO.Path]::GetTempPath()) ('w3lan-logs-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$passed = 0
function Check([bool]$condition, [string]$what) {
    if (-not $condition) { throw "FAIL $what" }
    $script:passed += 1
    Write-Output "PASS $what"
}
function FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { $listener.LocalEndpoint.Port } finally { $listener.Stop() }
}
# the logs the host has from a player, by kind (native, scripts, mod), with their bytes
function Received([string]$Name) {
    $folder = Join-Path $root "server\player-logs\$Name"
    @(Get-ChildItem -LiteralPath $folder -Filter '*.log' -File -ErrorAction SilentlyContinue | Sort-Object Name)
}
function SameBytes([string]$A, [string]$B) {
    (Get-FileHash -LiteralPath $A -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $B -Algorithm SHA256).Hash
}

$server = $null
$player = $null
try {
    # the host: the server JAR in a folder of its own, so its player-logs folder is this test's
    $serverDir = Join-Path $root 'server'
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'host\gamesaves'))
    [void][IO.Directory]::CreateDirectory($serverDir)
    Copy-Item -LiteralPath $JarPath -Destination (Join-Path $serverDir 'WitcherServer.jar')
    $server = Start-W3LanServer -JarPath (Join-Path $serverDir 'WitcherServer.jar') -JavaPath $JavaPath -Port $Port -SaveDirectory (Join-Path $root 'host\gamesaves') -HostName 'HostWitcher'
    $sharePort = $Port + 1

    # the second PC: a co-op profile and a game folder with the mod's log, plus files that are not this player's
    $name = 'Guest_1'
    $documents = Join-Path $root "join\profiles\$name"
    $game = Join-Path $root 'join\game'
    [void][IO.Directory]::CreateDirectory((Join-Path $documents 'The Witcher 3\gamesaves'))
    [void][IO.Directory]::CreateDirectory((Join-Path $game 'bin\WitcherOnline'))
    $native = Join-Path $documents 'native.log'
    $scripts = Join-Path $documents 'The Witcher 3\scriptslog.txt'
    $modLog = Join-Path $game "bin\WitcherOnline\WitcherOnline_$name.log"
    [IO.File]::WriteAllText($native, "native: last session, crashed`r`n")
    [IO.File]::WriteAllText($scripts, "scripts: last session`r`n")
    [IO.File]::WriteAllText($modLog, "WO_Log: last session`r`n")
    [IO.File]::WriteAllText((Join-Path $documents 'The Witcher 3\gamesaves\QuickSave.sav'), 'a save, never sent')
    [IO.File]::WriteAllText((Join-Path $documents 'other.log'), 'not a co-op log, never sent')
    [IO.File]::WriteAllText((Join-Path $game 'bin\WitcherOnline\WitcherOnline_Someone.log'), 'another player''s log, never sent')
    $settings = Join-Path $root 'join\player.json'

    # opt-out
    Check (Test-W3LanLogUploadWanted -SettingsPath $settings) 'logs are sent by default'
    Check (-not (Test-W3LanLogUploadWanted -NoLogUpload -SettingsPath $settings)) '-NoLogUpload turns it off'
    Set-W3LanPlayerSettings -Path $settings -Values @{ HostName = ''; JoinName = $name; HostAddress = '127.0.0.1'; SendLogs = $false }
    Check (-not (Test-W3LanLogUploadWanted -SettingsPath $settings)) '"SendLogs": false in player.json turns it off'
    $remembered = Get-W3LanPlayerSettings -Path $settings
    Check ($remembered['SendLogs'] -eq $false -and $remembered['JoinName'] -ceq $name) 'the setting is remembered with the name'
    Set-W3LanPlayerSettings -Path $settings -Values $remembered
    Check (-not (Get-W3LanPlayerSettings -Path $settings)['SendLogs']) 'the launcher keeps the opt-out when it saves player.json'

    # launch: the last session's logs are queued; a PC that never played on this host is refused
    Check ((Add-W3LanLogsToOutbox -Documents $documents -GameDir $game -PlayerName $name) -eq 3) 'the last session''s three logs are queued at launch'
    Check ((Add-W3LanLogsToOutbox -Documents $documents -GameDir $game -PlayerName $name) -eq 0) 'a log is queued only once'
    $refused = Send-W3LanLogOutbox -Address 127.0.0.1 -Port $sharePort -PlayerName $name -Documents $documents
    Check ($refused.Sent -eq 0 -and $refused.Left -eq 3 -and $refused.Error -match '403') "the host refuses a PC that is not a connected player: $($refused.Error)"
    Check ((Received $name).Count -eq 0) 'nothing is written for a refused PC'

    # the second PC joins the game (a player packet from this address)
    $player = [Net.Sockets.UdpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
    $player.Connect('127.0.0.1', $Port)
    $packet = [Text.Encoding]::UTF8.GetBytes("COOP`t$name`ten`t7`t1`t0")
    [void]$player.Send($packet, $packet.Length)
    Start-Sleep -Milliseconds 300

    # the background upload at launch delivers the last session's logs
    $background = Start-W3LanLogUpload -Address 127.0.0.1 -Port $sharePort -PlayerName $name -Documents $documents
    $early = @($background.Shell.EndInvoke($background.Handle))[0]
    $background.Shell.Dispose()
    Check ($early.Sent -eq 3 -and $early.Left -eq 0) "the background upload at launch sends the last session's logs: $($early.Error)"
    $got = Received $name
    Check ($got.Count -eq 3) 'the host has three logs'
    Check (@($got | Where-Object { $_.Name -match '-native\.log$' -and (SameBytes $_.FullName $native) }).Count -eq 1) 'native.log arrives byte for byte'
    Check (@($got | Where-Object { $_.Name -match '-scripts\.log$' -and (SameBytes $_.FullName $scripts) }).Count -eq 1) 'scriptslog.txt arrives byte for byte'
    Check (@($got | Where-Object { $_.Name -match '-mod\.log$' -and (SameBytes $_.FullName $modLog) }).Count -eq 1) 'the mod''s WitcherOnline log arrives byte for byte'
    Check (@(Get-ChildItem -LiteralPath (Get-W3LanLogOutbox $documents) -File).Count -eq 0) 'the outbox is empty once the host has them'

    # the game ran and exited: native.log and the mod's log are new, scriptslog.txt is unchanged;
    # native.log is over the 8 MB cap, so its last 8 MB are sent
    $big = [byte[]]::new(9MB)
    [Random]::new(3).NextBytes($big)
    [IO.File]::WriteAllBytes($native, $big)
    [IO.File]::WriteAllText($modLog, "WO_Log: this session`r`n")
    $line = Send-W3LanSessionLogs -Address 127.0.0.1 -Port $sharePort -PlayerName $name -Documents $documents -GameDir $game
    Check ($line -eq 'Sent your co-op log to the host at 127.0.0.1.') "after the game: one line: $line"
    $got = Received $name
    Check ($got.Count -eq 5) "the changed logs only: $($got.Count) logs at the host"
    $newest = @($got | Where-Object { $_.Name -match '-native\.log$' } | Sort-Object Length -Descending)[0]
    $tail = [IO.File]::ReadAllBytes($newest.FullName)
    $sha = [Security.Cryptography.SHA256]::Create()
    $sameTail = [Convert]::ToBase64String($sha.ComputeHash($tail)) -eq [Convert]::ToBase64String($sha.ComputeHash($big, 1MB, 8MB))
    $sha.Dispose()
    Check ($tail.Length -eq 8MB -and $sameTail) 'a log over 8 MB sends its last 8 MB'
    Check ((Send-W3LanSessionLogs -Address 127.0.0.1 -Port $sharePort -PlayerName $name -Documents $documents -GameDir $game) -eq '') 'nothing is sent twice'
    $all = @(Get-ChildItem -LiteralPath (Join-Path $root 'server\player-logs') -Recurse -File)
    Check (@($all | Where-Object { $_.DirectoryName -notlike "*\player-logs\$name" }).Count -eq 0) 'every log lands in the player''s folder'
    Check (@($all | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue) -match 'never sent' }).Count -eq 0) 'saves, other files and other players'' logs are never sent'

    # a missing host: a quick failure, and the logs wait for the next time
    [IO.File]::WriteAllText($modLog, "WO_Log: a session with the host gone`r`n")
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $line = Send-W3LanSessionLogs -Address 127.0.0.1 -Port (FreeTcpPort) -PlayerName $name -Documents $documents -GameDir $game
    Check ($timer.ElapsedMilliseconds -lt 6000 -and $line -like 'Could not send your co-op log: *') "a closed host port fails at once ($($timer.ElapsedMilliseconds) ms): $line"
    $timer.Restart()
    $line = Send-W3LanSessionLogs -Address 10.255.255.1 -Port $sharePort -PlayerName $name -Documents $documents -GameDir $game -ConnectTimeoutMs 2000
    Check ($timer.ElapsedMilliseconds -lt 4000 -and $line -like 'Could not send your co-op log: *') "a host that does not answer fails within the connect timeout ($($timer.ElapsedMilliseconds) ms): $line"
    Check (@(Get-ChildItem -LiteralPath (Get-W3LanLogOutbox $documents) -File).Count -eq 1) 'the unsent log waits in the outbox'
    $line = Send-W3LanSessionLogs -Address 127.0.0.1 -Port $sharePort -PlayerName $name -Documents $documents -GameDir $game
    Check ($line -eq 'Sent your co-op log to the host at 127.0.0.1.' -and (Received $name).Count -eq 6) 'it is sent the next time the host answers'
} finally {
    if ($player) { $player.Dispose() }
    if ($server) { Stop-W3LanServer $server; $server.Dispose() }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "LOG_UPLOAD_PASS: $passed checks. Fixture logs only; no game launched."
