#requires -Version 5.1
[CmdletBinding()]
param([string]$GameDir, [switch]$PreserveChanges)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'W3ModInstall.psm1') -Force
if (-not $GameDir) {
    $settings = Join-Path $PSScriptRoot 'launcher.settings.json'
    if (-not (Test-Path -LiteralPath $settings)) { throw 'Pass -GameDir with the installation folder, or use Manage Mod.cmd.' }
    $GameDir = (Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json).GameDir
}
$result = Remove-W3LanMod -GameDir $GameDir -PreserveChanges:$PreserveChanges
Write-Host "Mod removal complete: $($result.ChangedFiles) files restored or removed. Co-op saves and original backups were kept."
