#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Host','Join')][string]$Mode = 'Host',
    [Parameter(Mandatory)][string]$GameDir,
    [Parameter(Mandatory)][string]$PlayerName,
    [Parameter(Mandatory)][string]$HostName,
    [ValidatePattern('\A[a-z0-9][a-z0-9_-]{1,31}\z')][string]$CampaignName = 'lan-coop',
    [string]$Address,
    [ValidateRange(1,65535)][int]$Port = 40000,
    [string]$JavaPath,
    [string]$PythonPath,
    [string]$ServerJar = (Join-Path $PSScriptRoot '..\..\WitcherOnline\server\build\WitcherServer.jar'),
    [bool]$Voting = $true,
    [bool]$SharedXp = $true,
    [switch]$Plan
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'W3Campaign.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'W3LanProfile.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'W3Lan.psm1') -Force
$server = $null
$game = $null
$profileLock = $null
$slotOwner = 'human-' + [Guid]::NewGuid().ToString('N')
$slotHeld = $false
try {
    if ($Mode -eq 'Host') { $Address = '127.0.0.1' }
    elseif (-not $Address) { throw 'Join mode requires -Address with the host PC private IPv4 address.' }
    if ($Mode -eq 'Host') { Assert-W3SeamlessBuild -GameDir $GameDir -ServerJar $ServerJar }
    $context = Get-W3CampaignContext -GameDir $GameDir -Mode $Mode -CampaignName $CampaignName -PlayerName $PlayerName -HostName $HostName -Voting $Voting -SharedXp $SharedXp -Plan:$Plan
    $info = New-W3LanProfileStartInfo -GameDir $GameDir -PlayerName $PlayerName -Address $Address -Port $Port -CampaignName $CampaignName -Plan:$Plan
    if ($Plan) {
        # Deliberately list public routing/paths only: not credentials or child env.
        [pscustomobject]@{Mode=$Mode; Campaign=$CampaignName; HostName=$HostName; PlayerName=$PlayerName; Executable=$info.FileName; Address=$Address; Port=$Port; Documents=$info.EnvironmentVariables['W3LAN_DOCUMENTS']; State=$context.StatePath; WouldCreate=$context.WouldCreate; Launch=$false; EffectsEnabled=$false} | ConvertTo-Json
        exit 0
    }
    $profileLockPath = Join-Path $info.EnvironmentVariables['W3LAN_DOCUMENTS'] 'launch.lock'
    try { $profileLock = [IO.File]::Open($profileLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'This player/campaign profile is already in use.' }
    Set-W3CampaignClientEnvironment -StartInfo $info -Context $context
    Invoke-W3CampaignGameSlot -Operation acquire -Owner $slotOwner -PythonPath $PythonPath
    $slotHeld = $true
    if ($Mode -eq 'Host') {
        $server = Start-W3LanServer -JarPath $ServerJar -JavaPath $JavaPath -Port $Port -CampaignHost $context.HostName -CampaignDirectory $context.ServerStateDirectory -CampaignHostToken $context.HostToken -Voting $context.Voting -SharedXp $context.SharedXp
        Write-Host 'Experimental campaign server ready. Home-network addresses:'
        Get-W3LanAddresses | Format-Table Adapter,Address | Out-Host
    } else {
        $probe = Test-W3LanEndpoint -Address $Address -Port $Port
        if (-not $probe.Reachable) { throw "Host did not answer the UDP check: $($probe.Reply)." }
    }
    Write-Host 'Launching the experimental build with a persistent campaign identity and a separate save profile.'
    Write-Host 'Full independent quests, cinematic Listen and save reconciliation remain unfinished. Engine effect adapters are disabled.'
    $game = [Diagnostics.Process]::Start($info)
    Invoke-W3CampaignGameSlot -Operation register-pid -Owner $slotOwner -GameProcessId $game.Id -PythonPath $PythonPath
    $renew = { Invoke-W3CampaignGameSlot -Operation acquire -Owner $slotOwner -PythonPath $PythonPath }.GetNewClosure()
    $exitCode = Wait-W3CampaignGame -Game $game -Server $server -RenewLease $renew
    if ($exitCode -ne 0) { throw "Game exited with code $exitCode. Check the isolated profile logs." }
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
} finally {
    if ($game) {
        if (-not $game.HasExited) { $game.Kill(); [void]$game.WaitForExit(5000) }
        $game.Dispose()
    }
    if ($server) { Stop-W3LanServer $server; $server.Dispose() }
    if ($profileLock) { $profileLock.Dispose() }
    if ($slotHeld) {
        try { Invoke-W3CampaignGameSlot -Operation release -Owner $slotOwner -PythonPath $PythonPath }
        catch { Write-Warning 'Game stopped, but its lease could not be released; it expires automatically.' }
    }
}
