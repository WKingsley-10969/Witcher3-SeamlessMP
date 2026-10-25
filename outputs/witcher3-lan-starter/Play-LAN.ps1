#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Host','Join')][string]$Mode = 'Host',
    [Parameter(Mandatory)][string]$GameDir,
    [string]$Address,
    [string]$PlayerName,
    [ValidateRange(1,65535)][int]$Port = 40000,
    [string]$JavaPath,
    [switch]$Plan
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'W3Lan.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'W3LanProfile.psm1') -Force
$server = $null
$game = $null
try {
    if (-not $PlayerName) { $PlayerName = if ($Mode -eq 'Host') {'HostWitcher'} else {'GuestWitcher'} }
    if ($Mode -eq 'Host') { $Address = '127.0.0.1' }
    elseif (-not $Address) { $Address = Read-Host "Host PC's LAN IPv4 address" }
    $info = New-W3LanProfileStartInfo -GameDir $GameDir -PlayerName $PlayerName -Address $Address -Port $Port
    if ($Plan) {
        [pscustomobject]@{Mode=$Mode; Executable=$info.FileName; Address=$Address; Port=$Port; PlayerName=$PlayerName; Documents=$info.EnvironmentVariables['W3LAN_DOCUMENTS']; Launch=$false} | ConvertTo-Json
        exit 0
    }
    if ($Mode -eq 'Host') {
        $server = Start-W3LanServer -JarPath (Join-Path $PSScriptRoot 'server\WitcherServer.jar') -JavaPath $JavaPath -Port $Port
        Write-Host 'Host server ready. The second PC uses the home-network address below:'
        Get-W3LanAddresses | Format-Table Adapter,Address | Out-Host
    } else {
        $probe = Test-W3LanEndpoint -Address $Address -Port $Port
        if (-not $probe.Reachable) { throw "Host did not answer the UDP check: $($probe.Reply)." }
    }
    Write-Host 'Launching the isolated modded copy with a separate save/settings profile.'
    Write-Host 'Load matching saves in the same region. In game, interact with the host character and join its party.'
    $game = [Diagnostics.Process]::Start($info)
    $game.WaitForExit()
    if ($game.ExitCode -ne 0) { throw "Game exited with code $($game.ExitCode). Check the profile's native.log and game logs." }
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
} finally {
    if ($game) {
        if (-not $game.HasExited) { $game.Kill(); [void]$game.WaitForExit(5000) }
        $game.Dispose()
    }
    if ($server) { Stop-W3LanServer $server; $server.Dispose() }
}
