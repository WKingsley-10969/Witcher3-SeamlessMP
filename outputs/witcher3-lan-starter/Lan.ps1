#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Host','Join','Probe')][string]$Mode = 'Host',
    [string]$Address,
    [ValidateRange(1,65535)][int]$Port = 40000,
    [string]$PlayerName,
    [string]$JavaPath,
    [switch]$Plan
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'W3Lan.psm1') -Force
$server = $null
try {
    if (-not $PlayerName) { $PlayerName = if ($Mode -eq 'Host') { 'HostWitcher' } else { 'GuestWitcher' } }
    Assert-W3LanName $PlayerName
    if ($Mode -eq 'Host') { $Address = '127.0.0.1' }
    elseif (-not $Address) { $Address = Read-Host "Host PC's IPv4 address (home network, ZeroTier or Tailscale)" }
    $Address = Resolve-W3LanAddress $Address
    $clientEnvironment = New-W3LanClientEnvironment -PlayerName $PlayerName -Address $Address -Port $Port
    if ($Plan) {
        [pscustomobject]@{
            Mode = $Mode; Address = $Address; Port = $Port; PlayerName = $PlayerName
            ServerJar = (Join-Path $PSScriptRoot 'server\WitcherServer.jar')
            Transport = 'Direct UDP (no Steam relay)'; GameLaunch = $false
            ClientEnvironment = $clientEnvironment
        } | ConvertTo-Json
        exit 0
    }
    if ($Mode -eq 'Host') {
        $server = Start-W3LanServer -JarPath (Join-Path $PSScriptRoot 'server\WitcherServer.jar') -JavaPath $JavaPath -Port $Port
        Write-Host "LAN server ready on UDP $Port. This is a server transport test, not proof of working gameplay."
        $addresses = @(Get-W3LanAddresses)
        if ($addresses.Count) {
            Write-Host 'On the second PC, run Join LAN.cmd and enter your home-network address, or your ZeroTier or Tailscale address over the internet:'
            $addresses | Format-Table Adapter, Address | Out-Host
        } else { Write-Host 'No private LAN adapter detected. Local tests can use 127.0.0.1.' }
        Write-Host 'The upstream server listens on all IPv4 interfaces. No firewall settings were changed.'
    } else {
        $probe = Test-W3LanEndpoint -Address $Address -Port $Port -TimeoutMs 2000 -Attempts 3
        if (-not $probe.Reachable) { throw "No compatible server response from ${Address}:${Port}: $($probe.Reply). $(Get-W3LanUnreachableHint $Address)" }
        Write-Host "Compatible Witcher Online server reachable at ${Address}:${Port} ($($probe.ElapsedMs) ms)."
        Write-Host 'This confirms UDP transport only; it does not join a game or verify co-op gameplay.'
    }
    if ($server) {
        Write-Host 'No game launched. Keep this console open while testing from the other PC.'
        [void](Read-Host 'Press Enter to stop this server')
    }
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
} finally {
    if ($server) { Stop-W3LanServer $server; $server.Dispose() }
}
