$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'W3LanProfile.psm1') -Force
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('w3lan-profile-fixture-' + [Guid]::NewGuid().ToString('N'))
$seed=Join-Path $fixture 'seed'
$game=Join-Path $fixture 'game'
[void][IO.Directory]::CreateDirectory((Join-Path $seed 'gamesaves'))
'original-save'|Set-Content -LiteralPath (Join-Path $seed 'gamesaves\test.sav')
'original-settings'|Set-Content -LiteralPath (Join-Path $seed 'dx12user.settings')
foreach($rel in @('bin\x64_dx12','mods\modWitcherOnline','mods\modWitcherOnlineCompat','dlc\dlcWitcherOnline')){[void][IO.Directory]::CreateDirectory((Join-Path $game $rel))}
foreach($file in @('witcher3.exe','w3test.asi','dinput8.dll','WitcherNativeBridge.asi','WitcherOnlineClient.asi')){'fixture-data'|Set-Content -LiteralPath (Join-Path $game ('bin\x64_dx12\'+$file))}
$exeHash=(Get-FileHash -LiteralPath (Join-Path $game 'bin\x64_dx12\witcher3.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
$hookHash=(Get-FileHash -LiteralPath (Join-Path $game 'bin\x64_dx12\w3test.asi') -Algorithm SHA256).Hash.ToLowerInvariant()
@{TestCopy=$true;OriginalPath=$seed;ExeSha256=$exeHash}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $game '.w3lan-test-copy.json')
@{profileApi=1;profileDllSha256=$hookHash}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $game '.w3lan-native.json')
$seedHash=(Get-FileHash -LiteralPath (Join-Path $seed 'gamesaves\test.sav') -Algorithm SHA256).Hash
$oldScenario=$env:W3T_SCENARIO
try{
    $env:W3T_SCENARIO='must-not-leak'
    $info=New-W3LanProfileStartInfo -GameDir $game -PlayerName HostWitcher -Address 127.0.0.1 -SeedDirectory $seed
    if($info.EnvironmentVariables['W3T_SCENARIO']){throw 'Bot flag leaked'}
    if($info.EnvironmentVariables['WO_SERVER_IP'] -ne '127.0.0.1'){throw 'Wrong host endpoint'}
    if($info.Arguments){throw "The game is started with forced options ($($info.Arguments)): the player's graphics settings would not apply"}
    $profile=$info.EnvironmentVariables['W3LAN_DOCUMENTS']
    $copied=Join-Path $profile 'The Witcher 3\gamesaves\test.sav'
    if((Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash -ne $seedHash){throw 'Seed copy differs'}
    'co-op-progress'|Set-Content -LiteralPath $copied
    [void](New-W3LanProfileStartInfo -GameDir $game -PlayerName HostWitcher -Address 127.0.0.1 -SeedDirectory $seed)
    if((Get-Content -LiteralPath $copied -Raw).Trim() -ne 'co-op-progress'){throw 'Existing co-op save overwritten'}
    if((Get-FileHash -LiteralPath (Join-Path $seed 'gamesaves\test.sav') -Algorithm SHA256).Hash -ne $seedHash){throw 'Seed save changed'}
    'changed-hook'|Set-Content -LiteralPath (Join-Path $game 'bin\x64_dx12\w3test.asi')
    $rejected=$false
    try{[void](New-W3LanProfileStartInfo -GameDir $game -PlayerName HostWitcher -Address 127.0.0.1 -SeedDirectory $seed)}catch{$rejected=$true}
    if(-not $rejected){throw 'Altered isolation hook accepted'}
    Import-Module (Join-Path $root 'W3Lan.psm1') -Force
    $remembered=Join-Path $fixture 'player.json'
    $empty=Get-W3LanPlayerSettings -Path $remembered
    if($empty['JoinName'] -or $empty['HostAddress']){throw 'Settings without a file are not empty'}
    Set-W3LanPlayerSettings -Path $remembered -Values @{HostName='HostWitcher';JoinName='GuestWitcher';HostAddress='192.168.1.20'}
    $back=Get-W3LanPlayerSettings -Path $remembered
    if($back['JoinName'] -cne 'GuestWitcher' -or $back['HostAddress'] -cne '192.168.1.20' -or $back['HostName'] -cne 'HostWitcher'){throw 'Remembered name/address not read back'}
    'not json'|Set-Content -LiteralPath $remembered
    if((Get-W3LanPlayerSettings -Path $remembered 3>$null)['JoinName']){throw 'A broken settings file was not ignored'}
    Write-Output 'PROFILE_FIXTURE_PASS: no bot flags; correct endpoint; no forced game options; seed unchanged; profile progress preserved; altered hook rejected; name and address remembered'
}finally{
    $env:W3T_SCENARIO=$oldScenario
}



# The prompts: Enter keeps the remembered answer; a name the game refuses is asked for again.
Import-Module (Join-Path $root 'W3Lan.psm1') -Force
$global:W3LanTestAnswers=[Collections.Generic.Queue[string]]::new()
function global:Read-Host([string]$Prompt){$global:W3LanTestAnswers.Dequeue()}
try{
    $global:W3LanTestAnswers.Enqueue('')
    if((Read-W3LanValue -Prompt 'Name' -Default 'GuestWitcher' -Check {param($v) Assert-W3LanName $v}) -cne 'GuestWitcher'){throw 'Enter did not keep the remembered name'}
    foreach($answer in @('a b','x','NewName')){$global:W3LanTestAnswers.Enqueue($answer)}
    if((Read-W3LanValue -Prompt 'Name' -Default '' -Check {param($v) Assert-W3LanName $v} 3>$null) -cne 'NewName'){throw 'Refused names were accepted'}
    if($global:W3LanTestAnswers.Count){throw 'Unused answers left'}
    Write-Output 'PROMPT_PASS: Enter keeps the remembered answer; refused names are asked again'
}finally{
    Remove-Item function:global:Read-Host
    Remove-Variable W3LanTestAnswers -Scope Global
}
