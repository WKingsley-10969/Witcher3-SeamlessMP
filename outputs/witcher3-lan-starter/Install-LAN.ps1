#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$GameDir,
    [ValidateSet('InPlace','Copy')][string]$Mode = 'InPlace',
    [string]$SourceGameDir = 'C:\Program Files (x86)\Steam\steamapps\common\The Witcher 3',
    [string]$Destination,
    [switch]$PreserveChanges
)
$ErrorActionPreference = 'Stop'
if ($PSBoundParameters.ContainsKey('Destination') -and -not $PSBoundParameters.ContainsKey('Mode')) { $Mode = 'Copy' }
if ($Mode -eq 'InPlace' -and $PSBoundParameters.ContainsKey('Destination')) { throw '-Destination is for -Mode Copy. Use -GameDir to patch an existing installation.' }
if ($Mode -eq 'Copy') {
    if (-not $Destination) { $Destination = Join-Path $PSScriptRoot 'game-copy' }
    & (Join-Path $PSScriptRoot 'Install-Copy.ps1') -SourceGameDir $SourceGameDir -Destination $Destination
    exit
}
Import-Module (Join-Path $PSScriptRoot 'W3ModInstall.psm1') -Force
if (-not $GameDir) {
    $settings = Join-Path $PSScriptRoot 'launcher.settings.json'
    if (Test-Path -LiteralPath $settings) { $GameDir = (Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json).GameDir }
    else { $GameDir = $SourceGameDir }
}
$result = Install-W3LanMod -GameDir $GameDir -PackageDir $PSScriptRoot -PreserveChanges:$PreserveChanges
@{GameDir=$result.GameDir} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'launcher.settings.json') -Encoding utf8
Write-Host "$($result.Action) complete: $($result.ChangedFiles) files changed. Original backups: $($result.Backups)"
Write-Host 'Use Play Host LAN.cmd or Play Join LAN.cmd. Remove Mod.cmd restores your pre-install files and keeps your co-op saves.'
