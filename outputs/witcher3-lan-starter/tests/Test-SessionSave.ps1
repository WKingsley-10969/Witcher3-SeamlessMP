#requires -Version 5.1
# Co-op session save sharing, end to end on this PC with fixture saves only: the real server shares
# a host save folder (Start-W3LanServer -SaveDirectory), and Copy-W3LanSessionSave downloads the
# newest save into a joining player's folder byte for byte.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$JavaPath,
    [string]$JarPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'server\WitcherServer.jar'),
    [ValidateRange(1,65534)][int]$Port = 41700
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'W3Lan.psm1') -Force
$root = Join-Path ([IO.Path]::GetTempPath()) ('w3lan-session-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$hostSaves = Join-Path $root 'host\gamesaves'
$joinSaves = Join-Path $root 'join\gamesaves'
[void][IO.Directory]::CreateDirectory($hostSaves)
$passed = 0
function Check([bool]$condition, [string]$what) {
    if (-not $condition) { throw "FAIL $what" }
    $script:passed += 1
    Write-Output "PASS $what"
}
$server = $null
try {
    $server = Start-W3LanServer -JarPath $JarPath -JavaPath $JavaPath -Port $Port -SaveDirectory $hostSaves -HostName 'HostWitcher'

    $session = Copy-W3LanSessionSave -Address 127.0.0.1 -Port ($Port + 1) -SaveDirectory $joinSaves
    Check ($session.Host -eq 'HostWitcher' -and $session.Save -eq '') 'a host without saves offers none'

    $random = [Random]::new(7)
    $older = [byte[]]::new(80000); $random.NextBytes($older)
    $newer = [byte[]]::new(300000); $random.NextBytes($newer)
    $thumb = [byte[]]::new(2000); $random.NextBytes($thumb)
    [IO.File]::WriteAllBytes((Join-Path $hostSaves 'ManualSave_0a1b2c.sav'), $older)
    [IO.File]::WriteAllBytes((Join-Path $hostSaves 'QuickSave_3d4e5f.sav'), $newer)
    [IO.File]::WriteAllBytes((Join-Path $hostSaves 'QuickSave_3d4e5f.png'), $thumb)
    (Get-Item (Join-Path $hostSaves 'ManualSave_0a1b2c.sav')).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-2)

    $session = Copy-W3LanSessionSave -Address 127.0.0.1 -Port ($Port + 1) -SaveDirectory $joinSaves
    Check ($session.Save -eq 'QuickSave_3d4e5f') 'the newest host save is offered'
    $hash = { param($path) (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
    Check ((& $hash (Join-Path $joinSaves 'QuickSave_3d4e5f.sav')) -eq (& $hash (Join-Path $hostSaves 'QuickSave_3d4e5f.sav'))) 'the save arrives byte for byte'
    Check ((& $hash (Join-Path $joinSaves 'QuickSave_3d4e5f.png')) -eq (& $hash (Join-Path $hostSaves 'QuickSave_3d4e5f.png'))) 'its thumbnail arrives too'
    Check (-not (Test-Path -LiteralPath (Join-Path $joinSaves 'ManualSave_0a1b2c.sav'))) 'older host saves are not copied'
    Check (@(Get-ChildItem -LiteralPath $joinSaves -Filter '*.download').Count -eq 0) 'no partial download is left behind'

    # a later session: the host saved again, the joining player gets the new save
    [IO.File]::WriteAllBytes((Join-Path $hostSaves 'AutoSave_6a7b8c.sav'), $older)
    $session = Copy-W3LanSessionSave -Address 127.0.0.1 -Port ($Port + 1) -SaveDirectory $joinSaves
    Check ($session.Save -eq 'AutoSave_6a7b8c' -and (Get-Item (Join-Path $joinSaves 'AutoSave_6a7b8c.sav')).Length -eq $older.Length) 'a later session gets the host''s newest save'

    $outside = $false
    try { Invoke-WebRequest -Uri "http://127.0.0.1:$($Port + 1)/session/save/..%2Fsecret.sav" -UseBasicParsing -TimeoutSec 5 | Out-Null } catch { $outside = $_.Exception.Response.StatusCode.value__ -eq 404 }
    Check $outside 'nothing outside the host save folder is served'
} finally {
    if ($server) { Stop-W3LanServer $server; $server.Dispose() }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "SESSION_SAVE_PASS: $passed checks. Fixture saves only; no game launched."
