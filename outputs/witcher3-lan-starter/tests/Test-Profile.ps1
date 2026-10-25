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
    $profile=$info.EnvironmentVariables['W3LAN_DOCUMENTS']
    $copied=Join-Path $profile 'The Witcher 3\gamesaves\test.sav'
    if((Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash -ne $seedHash){throw 'Seed copy differs'}
    'co-op-progress'|Set-Content -LiteralPath $copied
    [void](New-W3LanProfileStartInfo -GameDir $game -PlayerName HostWitcher -Address 127.0.0.1 -SeedDirectory $seed)
    if((Get-Content -LiteralPath $copied -Raw).Trim() -ne 'co-op-progress'){throw 'Existing co-op save overwritten'}
    if((Get-FileHash -LiteralPath (Join-Path $seed 'gamesaves\test.sav') -Algorithm SHA256).Hash -ne $seedHash){throw 'Seed save changed'}
    # Custom Player Characters' key bindings are added to the profile's input.settings, once
    [void][IO.Directory]::CreateDirectory((Join-Path $game 'mods\modCustomPlayerCharacters'))
    "[Exploration]`r`nIK_E=(Action=NRUse)"|Set-Content -LiteralPath (Join-Path $game 'add_to_input.settings.txt')
    $profileInput=Join-Path $profile 'The Witcher 3\input.settings'
    "[Exploration]`r`nIK_W=(Action=MoveForward)"|Set-Content -LiteralPath $profileInput
    [void](New-W3LanProfileStartInfo -GameDir $game -PlayerName HostWitcher -Address 127.0.0.1 -SeedDirectory $seed)
    [void](New-W3LanProfileStartInfo -GameDir $game -PlayerName HostWitcher -Address 127.0.0.1 -SeedDirectory $seed)
    $inputText=Get-Content -LiteralPath $profileInput -Raw
    if(([regex]::Matches($inputText,'Action=NRUse')).Count -ne 1 -or $inputText -notmatch 'Action=MoveForward'){throw 'CPC key bindings not added exactly once to the profile input.settings'}
    'changed-hook'|Set-Content -LiteralPath (Join-Path $game 'bin\x64_dx12\w3test.asi')
    $rejected=$false
    try{[void](New-W3LanProfileStartInfo -GameDir $game -PlayerName HostWitcher -Address 127.0.0.1 -SeedDirectory $seed)}catch{$rejected=$true}
    if(-not $rejected){throw 'Altered isolation hook accepted'}
    Write-Output 'PROFILE_FIXTURE_PASS: no bot flags; correct endpoint; seed unchanged; profile progress preserved; CPC bindings added once; altered hook rejected'
}finally{
    $env:W3T_SCENARIO=$oldScenario
}


