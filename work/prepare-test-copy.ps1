[CmdletBinding()]
param(
    [string]$Source = 'C:\Program Files (x86)\Steam\steamapps\common\The Witcher 3',
    [string]$Destination = (Join-Path $PSScriptRoot 'test-game')
)
$ErrorActionPreference = 'Stop'
$sourcePath = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\')
$destinationPath = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
$workspace = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
if (-not $destinationPath.StartsWith($workspace + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Test copy must stay inside this workspace.' }
if ($destinationPath -ieq $sourcePath -or $destinationPath.StartsWith($sourcePath + '\',[StringComparison]::OrdinalIgnoreCase) -or $sourcePath.StartsWith($destinationPath + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Source and destination must be separate.' }
if (Test-Path -LiteralPath $destinationPath) { throw 'Destination must not exist; no existing folder is overwritten.' }
$sourceExe = Join-Path $sourcePath 'bin\x64_dx12\witcher3.exe'
if (-not (Test-Path -LiteralPath $sourceExe)) { throw 'Game executable missing.' }
$expected = '2df765398a3d1f165db418271be7200178320a4466817379f2fa0dc0001fb101'
if ((Get-FileHash -LiteralPath $sourceExe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'Installed game identity changed; triage again before copying.' }
[void][IO.Directory]::CreateDirectory($destinationPath)
$log = Join-Path $PSScriptRoot 'test-copy.log'
& robocopy.exe $sourcePath $destinationPath /E /COPY:DAT /DCOPY:T /XJ /R:1 /W:1 /NFL /NDL /NP "/LOG:$log"
if ($LASTEXITCODE -gt 7) { throw "Copy failed: robocopy code $LASTEXITCODE. See test-copy.log; destination is incomplete." }
$files = @(Get-ChildItem -LiteralPath $sourcePath -Recurse -File)
foreach ($file in $files) {
    $relative = $file.FullName.Substring($sourcePath.Length + 1)
    $target = Get-Item -LiteralPath (Join-Path $destinationPath $relative) -ErrorAction Stop
    if ($target.Length -ne $file.Length) { throw "Incomplete copy: $relative" }
}
if ((Get-FileHash -LiteralPath (Join-Path $destinationPath 'bin\x64_dx12\witcher3.exe') -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'Copied executable checksum mismatch.' }
@{ TestCopy=$true; OriginalPath=$sourcePath; ExeSha256=$expected; FileCount=$files.Count; Created='2026-10-24' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destinationPath '.w3lan-test-copy.json') -Encoding utf8
Write-Output "COPY_VERIFIED: $($files.Count) files"
