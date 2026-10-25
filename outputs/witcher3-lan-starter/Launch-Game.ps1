#requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Host','Join')][string]$Mode='Host')
$ErrorActionPreference='Stop'
$settings=Join-Path $PSScriptRoot 'launcher.settings.json'
if(Test-Path -LiteralPath $settings){
    $gameDir=(Get-Content -LiteralPath $settings -Raw|ConvertFrom-Json).GameDir
}else{
    $gameDir=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\work\test-game'))
    if(-not(Test-Path -LiteralPath (Join-Path $gameDir '.w3lan-native.json'))){
        throw 'Run Install-LAN.ps1 first to prepare the isolated modded copy.'
    }
}
$name=Read-Host 'Your player name (letters, digits or underscores; different on each PC)'
& (Join-Path $PSScriptRoot 'Play-LAN.ps1') -Mode $Mode -GameDir $gameDir -PlayerName $name
exit $LASTEXITCODE
