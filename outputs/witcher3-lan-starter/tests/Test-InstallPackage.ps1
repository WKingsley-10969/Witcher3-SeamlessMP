#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fixture = Join-Path ([IO.Path]::GetFullPath($TestRoot)) ([Guid]::NewGuid().ToString('N').Substring(0,8))
$extract = Join-Path $fixture 'package'; [void][IO.Directory]::CreateDirectory($extract)
$zip=[IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Archive).Path)
try {
    foreach($entry in $zip.Entries) {
        $prefix='Witcher3-LAN-0.2.0-dev/'
        if(-not $entry.FullName.StartsWith($prefix) -or $entry.FullName.Contains('\') -or $entry.FullName.Split('/') -contains '..') {throw 'Unexpected archive path'}
        $relative=$entry.FullName.Substring($prefix.Length)
        if(-not $relative -or $relative.EndsWith('/')) {continue}
        $target=[IO.Path]::GetFullPath((Join-Path $extract $relative))
        if(-not $target.StartsWith($extract+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'Archive escapes fixture'}
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        $inputStream=$entry.Open(); $outputStream=[IO.File]::Create($target)
        try {$inputStream.CopyTo($outputStream)} finally {$inputStream.Dispose(); $outputStream.Dispose()}
    }
} finally {$zip.Dispose()}
$package = $extract
$game = Join-Path $fixture 'game'; [void][IO.Directory]::CreateDirectory((Join-Path $game 'bin/x64_dx12'))
[IO.File]::WriteAllText((Join-Path $game 'bin/x64_dx12/witcher3.exe'),'fake executable bytes for package smoke only; never run')
[IO.File]::WriteAllBytes((Join-Path $game 'bin/x64_dx12/dinput8.dll'),[byte[]]@(0,255,2,128))
[IO.File]::WriteAllText((Join-Path $game 'keep.txt'),'unrelated content')
$fakeHash = (Get-FileHash -LiteralPath (Join-Path $game 'bin/x64_dx12/witcher3.exe')).Hash.ToLowerInvariant()
# Modify ONLY this throwaway extracted module's private fixture guards. The
# deliverable archive and production scripts retain their pinned game checks.
$modulePath = Join-Path $package 'W3ModInstall.psm1'
$moduleText = [IO.File]::ReadAllText($modulePath)
$moduleText = $moduleText.Replace('2df765398a3d1f165db418271be7200178320a4466817379f2fa0dc0001fb101',$fakeHash)
$guard = '    if (@(Get-Process -Name witcher3 -ErrorAction SilentlyContinue).Count) { throw ''Close Witcher 3 before installing, updating or removing the mod.'' }'
if (-not $moduleText.Contains($guard)) { throw 'Fixture guard anchor changed.' }
[IO.File]::WriteAllText($modulePath,$moduleText.Replace($guard,''))
function Snapshot {
    return (@(Get-ChildItem -LiteralPath $game -Recurse -Force -File | Where-Object {$_.FullName -notlike '*\.w3lan-install\*'} | Sort-Object FullName | ForEach-Object {$_.FullName.Substring($game.Length)+':'+(Get-FileHash -LiteralPath $_.FullName).Hash}) -join '|')
}
function Run([string]$Script,[string[]]$Words,[bool]$ShouldFail=$false) {
    $info=[Diagnostics.ProcessStartInfo]::new(); $info.FileName=(Get-Command powershell.exe).Source
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $all=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $package $Script)) + $Words
    $info.Arguments=(@($all | ForEach-Object {'"'+$_+'"'}) -join ' ')
    $p=[Diagnostics.Process]::Start($info)
    try {
        $stdout=$p.StandardOutput.ReadToEndAsync(); $stderr=$p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(120000)) {$p.Kill(); [void]$p.WaitForExit(5000); throw 'Owned package fixture timed out'}
        $text=$stdout.Result+$stderr.Result
        if (($p.ExitCode -ne 0) -ne $ShouldFail) { throw "Unexpected package fixture exit $($p.ExitCode): $text" }
        return $text
    } finally { if (-not $p.HasExited) {$p.Kill(); [void]$p.WaitForExit(5000)}; $p.Dispose() }
}
$before=Snapshot
$output=Run 'Install-LAN.ps1' @('-GameDir',$game)
if ($output -notmatch 'Install complete') {throw 'Public install script did not complete'}
Write-Output 'PASS packaged public install script (fixture game only)'
$settings=Get-Content -LiteralPath (Join-Path $package 'launcher.settings.json') -Raw | ConvertFrom-Json
if ($settings.GameDir -ine $game) {throw 'Launcher settings point to another game'}
$output=Run 'Install-LAN.ps1' @('-GameDir',$game)
if ($output -notmatch 'Update complete: 0 files changed') {throw "No-op update across fresh processes rewrote files: $output"}
Write-Output 'PASS packaged update across fresh PowerShell processes is a no-op'
$changed=Join-Path $game 'mods/modWitcherOnline/content/scripts/local/coopTalk.ws'
[IO.File]::WriteAllText($changed,'external fixture edit')
$output=Run 'Remove-LAN.ps1' @('-GameDir',$game) $true
if ($output -notmatch 'changed outside') {throw 'Public removal failed for an unexpected reason'}
Write-Output 'PASS packaged removal protects outside edits'
[void](Run 'Remove-LAN.ps1' @('-GameDir',$game,'-PreserveChanges'))
if ((Snapshot) -cne $before) {throw 'Packaged install/update/remove did not restore original bytes and file set'}
Write-Output 'PASS packaged removal restores the exact pre-install file set and bytes'
$copyScript=Join-Path $package 'Install-Copy.ps1'
[IO.File]::WriteAllText($copyScript,[IO.File]::ReadAllText($copyScript).Replace('2df765398a3d1f165db418271be7200178320a4466817379f2fa0dc0001fb101',$fakeHash))
$copy=Join-Path $fixture 'legacy-copy'
[void](Run 'Install-LAN.ps1' @('-SourceGameDir',$game,'-Destination',$copy))
if (-not (Test-Path -LiteralPath (Join-Path $copy '.w3lan-test-copy.json')) -or (Test-Path -LiteralPath (Join-Path $copy '.w3lan-managed.json'))) {throw 'Legacy Destination command did not use copy mode'}
if ((Snapshot) -cne $before) {throw 'Legacy copy modified the source fixture game'}
Write-Output 'PASS old Destination command still creates a copy instead of patching its source'
Write-Output "INSTALL_PACKAGE_PASS: 5 subprocess workflow checks. Evidence: $fixture"
