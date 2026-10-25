#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$settings = Join-Path $PSScriptRoot 'launcher.settings.json'
$suggested = 'C:\Program Files (x86)\Steam\steamapps\common\The Witcher 3'
if (Test-Path -LiteralPath $settings) { $suggested = (Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json).GameDir }
Write-Host "Game folder: $suggested"
$entered = Read-Host 'Press Enter to use this folder, or enter a different Witcher 3 folder'
$gameFolder = $suggested
if ($entered.Trim()) { $gameFolder = $entered.Trim().Trim('"') }
Write-Host '1 - Install or update mod (back up replaced files automatically)'
Write-Host '2 - Remove mod and restore pre-install files'
Write-Host '3 - Show installation status'
$choice = Read-Host 'Choose 1, 2 or 3'
try {
    switch ($choice) {
        '1' { & (Join-Path $PSScriptRoot 'Install-LAN.ps1') -GameDir $gameFolder }
        '2' { & (Join-Path $PSScriptRoot 'Remove-LAN.ps1') -GameDir $gameFolder }
        '3' {
            Import-Module (Join-Path $PSScriptRoot 'W3ModInstall.psm1') -Force
            $status = Get-W3ModStatus -GameDir $gameFolder
            Write-Host "Installed: $($status.Installed). Interrupted operation pending recovery: $($status.NeedsRecovery)."
        }
        default { throw 'Choose 1, 2 or 3.' }
    }
} catch {
    if ($_.Exception.Message -notlike 'File changed outside this installer:*') { throw }
    Write-Host $_.Exception.Message
    $answer = Read-Host 'Keep copies of these changed files and continue? Type YES to continue'
    if ($answer -cne 'YES') { throw 'Stopped. Your installed files were not changed.' }
    if ($choice -eq '1') { & (Join-Path $PSScriptRoot 'Install-LAN.ps1') -GameDir $gameFolder -PreserveChanges }
    else { & (Join-Path $PSScriptRoot 'Remove-LAN.ps1') -GameDir $gameFolder -PreserveChanges }
}
