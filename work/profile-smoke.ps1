param([string]$PlayerName='HostWitcher')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'outputs\witcher3-lan-starter\W3Lan.psm1') -Force
Import-Module (Join-Path $root 'outputs\witcher3-lan-starter\W3LanProfile.psm1') -Force
$info=New-W3LanProfileStartInfo -GameDir (Join-Path $PSScriptRoot 'test-game') -PlayerName $PlayerName -Address 127.0.0.1 -Port 41003
$nativeLog=$info.EnvironmentVariables['W3T_LOG']
if(Test-Path -LiteralPath $nativeLog){throw 'Smoke log already exists; use a fresh profile or archive the prior log first.'}
$server=$null
$game=$null
try {
    $server=Start-W3LanServer -JarPath (Join-Path $root 'outputs\witcher3-lan-starter\server\WitcherServer.jar') -Port 41003
    $game=[Diagnostics.Process]::Start($info)
    Write-Output "PROFILE_SMOKE_GAME_PID $($game.Id)"
    $deadline=[DateTime]::UtcNow.AddSeconds(35)
    while([DateTime]::UtcNow -lt $deadline){
        if($game.HasExited){throw "Interactive game exited early: $($game.ExitCode)"}
        Start-Sleep -Seconds 1
    }
    $text=Get-Content -LiteralPath $nativeLog -Raw
    if($text -notmatch 'loaded in LAN profile mode'){throw 'Interactive profile mode did not load'}
    foreach($api in @('SHGetKnownFolderPath','SHGetFolderPathW','SHGetFolderPathA')){
        if($text -notmatch "HOOK $api installed"){throw "Missing hook: $api"}
    }
    if($text -match 'HOOK GetAsyncKeyState|AUDIO muted|BOT start'){throw 'Automated test behavior leaked into human mode'}
    Write-Output 'PROFILE_SMOKE_PASS: game remained running; all Documents hooks installed; no test input/audio hooks'
} finally {
    if($game){if(-not $game.HasExited){$game.Kill();[void]$game.WaitForExit(5000)};$game.Dispose()}
    if($server){Stop-W3LanServer $server;$server.Dispose()}
}
