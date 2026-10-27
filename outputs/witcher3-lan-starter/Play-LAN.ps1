#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Host','Join')][string]$Mode = 'Host',
    [Parameter(Mandatory)][string]$GameDir,
    [string]$Address,
    [string]$PlayerName,
    [ValidateRange(1,65535)][int]$Port = 40000,
    [string]$JavaPath,
    # Join with this player's own save instead of the host's newest one
    [switch]$NoSessionSave,
    # Do not send this PC's co-op logs to the host (also: "SendLogs": false in player.json)
    [switch]$NoLogUpload,
    [switch]$Plan
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'W3Lan.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'W3LanProfile.psm1') -Force
$server = $null
$game = $null
$logUpload = $null
$sendLogs = $false
try {
    if (-not $PlayerName) { $PlayerName = if ($Mode -eq 'Host') {'HostWitcher'} else {'GuestWitcher'} }
    if ($Mode -eq 'Host') { $Address = '127.0.0.1' }
    elseif (-not $Address) { $Address = Read-Host "Host PC's LAN IPv4 address" }
    $info = New-W3LanProfileStartInfo -GameDir $GameDir -PlayerName $PlayerName -Address $Address -Port $Port
    if ($Plan) {
        [pscustomobject]@{Mode=$Mode; Executable=$info.FileName; Address=$Address; Port=$Port; PlayerName=$PlayerName; Documents=$info.EnvironmentVariables['W3LAN_DOCUMENTS']; Launch=$false} | ConvertTo-Json
        exit 0
    }
    $saves = Join-Path $info.EnvironmentVariables['W3LAN_DOCUMENTS'] 'The Witcher 3\gamesaves'
    $joinsHostSave = $false
    if ($Mode -eq 'Host') {
        # Co-op session: joining players download this host's newest co-op save (TCP port Port+1)
        $server = Start-W3LanServer -JarPath (Join-Path $PSScriptRoot 'server\WitcherServer.jar') -JavaPath $JavaPath -Port $Port -SaveDirectory $saves -HostName $PlayerName
        $info.EnvironmentVariables['W3LAN_SESSION_ROLE'] = 'host'
        Write-Host 'Host server ready. The second PC uses the home-network address below:'
        Get-W3LanAddresses | Format-Table Adapter,Address | Out-Host
        Write-Host "Joining players load your newest co-op save. Save before they join to share your latest progress."
        # the host's own logs stay on this PC; the second PC's arrive in server\player-logs
        $modLog = Join-Path (Resolve-Path -LiteralPath $GameDir).Path "bin\WitcherOnline\WitcherOnline_$PlayerName.log"
        Write-Host "Your co-op logs: $($info.EnvironmentVariables['W3T_LOG']) and $modLog. The second PC's arrive in $(Join-Path $PSScriptRoot 'server\player-logs')."
    } else {
        $probe = Test-W3LanEndpoint -Address $Address -Port $Port
        if (-not $probe.Reachable) { throw "Host did not answer the UDP check: $($probe.Reply)." }
        if (-not $NoSessionSave) {
            try {
                $session = Copy-W3LanSessionSave -Address $Address -Port ($Port + 1) -SaveDirectory $saves
                # the game waits in the main menu's co-op lobby until the host starts, also without a save
                $info.EnvironmentVariables['W3LAN_SESSION_ROLE'] = 'join'
                $info.EnvironmentVariables['W3LAN_SESSION_HOST'] = $session.Host
                $joinsHostSave = $true
                if ($session.Save) {
                    $info.EnvironmentVariables['W3LAN_SESSION_SAVE'] = $session.Save
                    Write-Host "Downloaded $($session.Host)'s save $($session.Save): the game waits in the co-op lobby, then loads the save the host starts with and joins their party."
                } else {
                    Write-Host "$($session.Host) has no co-op save yet: the game waits in the co-op lobby until the host starts a new game or saves."
                }
            } catch {
                Write-Warning "Could not download the host's save ($($_.Exception.Message)): load your own save and meet in game."
            }
        }
    }
    if ($Mode -eq 'Join' -and (Test-W3LanLogUploadWanted -NoLogUpload:$NoLogUpload)) {
        # the last session's logs if they never reached the host (a crash, a closed window), in the background
        try {
            [void](Add-W3LanLogsToOutbox -Documents $info.EnvironmentVariables['W3LAN_DOCUMENTS'] -GameDir $GameDir -PlayerName $PlayerName)
            $logUpload = Start-W3LanLogUpload -Address $Address -Port ($Port + 1) -PlayerName $PlayerName -Documents $info.EnvironmentVariables['W3LAN_DOCUMENTS']
        } catch { Write-Warning "Could not queue your co-op log: $($_.Exception.Message)" }
        $sendLogs = $true
    }
    Write-Host 'Launching Witcher 3 with the LAN mod and a separate co-op save/settings profile.'
    if (-not $joinsHostSave) { Write-Host 'Load matching saves in the same region. In game, interact with the host character and join its party.' }
    $game = [Diagnostics.Process]::Start($info)
    Wait-W3LanGame -Game $game -Server $server
    if ($sendLogs) {
        # this session's logs (and any the background upload did not deliver) to the host
        $line = Send-W3LanSessionLogs -Address $Address -Port ($Port + 1) -PlayerName $PlayerName -Documents $info.EnvironmentVariables['W3LAN_DOCUMENTS'] -GameDir $GameDir -Background $logUpload
        $logUpload = $null
        if ($line) { Write-Host $line }
    }
    if ($game.ExitCode -ne 0) { throw "Game exited with code $($game.ExitCode). Check the profile's native.log and game logs." }
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
} finally {
    if ($game) {
        if (-not $game.HasExited) { $game.Kill(); [void]$game.WaitForExit(5000) }
        $game.Dispose()
    }
    if ($logUpload) { $logUpload.Shell.Dispose() }
    if ($server) { Stop-W3LanServer $server; $server.Dispose() }
}
