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
Import-Module (Join-Path $PSScriptRoot 'W3Lan.psm1') -Force
# the name and the host's address from last time: Enter keeps them (the name also picks the co-op
# save profile, so the same name brings back the same saves and character)
$remembered=Get-W3LanPlayerSettings
$nameKey=if($Mode -eq 'Host'){'HostName'}else{'JoinName'}
$name=Read-W3LanValue -Prompt 'Your player name (letters, digits or underscores; different on each PC)' -Default $remembered[$nameKey] -Check {param($value) Assert-W3LanName $value}
$remembered[$nameKey]=$name
$arguments=@{Mode=$Mode; GameDir=$gameDir; PlayerName=$name}
if($Mode -eq 'Join'){
    $address=Read-W3LanValue -Prompt "Host PC's LAN IPv4 address" -Default $remembered['HostAddress'] -Check {param($value) [void](Resolve-W3LanAddress $value)}
    $remembered['HostAddress']=$address
    $arguments['Address']=$address
}
Set-W3LanPlayerSettings -Values $remembered
& (Join-Path $PSScriptRoot 'Play-LAN.ps1') @arguments
exit $LASTEXITCODE
