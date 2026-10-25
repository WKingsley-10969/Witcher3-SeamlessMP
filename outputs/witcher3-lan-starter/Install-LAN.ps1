#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourceGameDir = 'C:\Program Files (x86)\Steam\steamapps\common\The Witcher 3',
    [string]$Destination = (Join-Path $PSScriptRoot 'game-copy')
)
$ErrorActionPreference = 'Stop'
$expected = '2df765398a3d1f165db418271be7200178320a4466817379f2fa0dc0001fb101'
$source = (Resolve-Path -LiteralPath $SourceGameDir).Path.TrimEnd('\')
$target = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
$payload = Join-Path $PSScriptRoot 'mod'
if (-not (Test-Path -LiteralPath (Join-Path $payload 'bin\x64_dx12\w3test.asi'))) { throw 'Full mod payload missing. Use the complete LAN development package.' }
$manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'mod-manifest.json') -Raw|ConvertFrom-Json
$payloadRoot=(Resolve-Path -LiteralPath $payload).Path.TrimEnd('\')
foreach($entry in $manifest.files){
    $path=[IO.Path]::GetFullPath((Join-Path $payloadRoot $entry.path))
    if(-not $path.StartsWith($payloadRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid payload path'}
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.sha256){throw "Payload checksum mismatch: $($entry.path)"}
}
if(@(Get-ChildItem -LiteralPath $payloadRoot -Recurse -File).Count -ne @($manifest.files).Count){throw 'Payload contains unexpected files'}
if (Test-Path -LiteralPath $target) { throw 'Destination must be a new folder. Existing installations are never overwritten.' }
if ($source -ieq $target -or $target.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase) -or $source.StartsWith($target+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Original install and test copy must be separate.' }
if ($target.Length -gt 170) { throw 'Choose a shorter destination path for the game copy and its save profiles.' }
$ancestor=Split-Path -Parent $target
while($ancestor){
    if((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Choose a destination with no junctions or symbolic links in its path.'}
    $next=Split-Path -Parent $ancestor
    if($next -eq $ancestor){break}
    $ancestor=$next
}
$exe = Join-Path $source 'bin\x64_dx12\witcher3.exe'
if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'This package targets the verified Steam build 25773555 only. Identify other builds before installing.' }
$files = @(Get-ChildItem -LiteralPath $source -Recurse -File)
$size = ($files | Measure-Object -Property Length -Sum).Sum
$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($target))
if ($drive.AvailableFreeSpace -lt ($size + 5GB)) { throw 'Not enough free space for an independent game copy plus 5 GB headroom.' }
Write-Host 'Creating an independent game copy. This can take several minutes.'
[void][IO.Directory]::CreateDirectory($target)
& robocopy.exe $source $target /E /COPY:DAT /DCOPY:T /XJ /R:1 /W:1 /NFL /NDL /NP ("/LOG:" + (Join-Path $PSScriptRoot 'install-copy.log'))
if ($LASTEXITCODE -gt 7) { throw "Game copy failed (robocopy $LASTEXITCODE). Destination is incomplete." }
foreach ($file in $files) {
    $relative = $file.FullName.Substring($source.Length+1)
    if ((Get-Item -LiteralPath (Join-Path $target $relative)).Length -ne $file.Length) { throw "Incomplete copy: $relative" }
}
if ((Get-FileHash -LiteralPath (Join-Path $target 'bin\x64_dx12\witcher3.exe') -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'Copied executable checksum mismatch.' }
foreach ($file in Get-ChildItem -LiteralPath $payloadRoot -Recurse -File) {
    $relative = $file.FullName.Substring($payloadRoot.Length+1)
    $out = Join-Path $target $relative
    if (Test-Path -LiteralPath $out) {
        $backup = Join-Path $target ('.w3lan-backups\' + $relative)
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $backup))
        Copy-Item -LiteralPath $out -Destination $backup
    }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $out))
    Copy-Item -LiteralPath $file.FullName -Destination $out -Force
}
@{TestCopy=$true;OriginalPath=$source;ExeSha256=$expected;FileCount=$files.Count} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target '.w3lan-test-copy.json') -Encoding utf8
@{profileApi=1;profileDllSha256=(Get-FileHash -LiteralPath (Join-Path $target 'bin\x64_dx12\w3test.asi') -Algorithm SHA256).Hash.ToLowerInvariant()} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target '.w3lan-native.json') -Encoding utf8
@{GameDir=$target} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'launcher.settings.json') -Encoding utf8
Write-Host 'Isolated copy prepared. Use Play Host LAN.cmd or Play Join LAN.cmd.'
