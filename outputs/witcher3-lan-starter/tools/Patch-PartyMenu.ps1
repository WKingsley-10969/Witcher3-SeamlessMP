#requires -Version 5.1
# Run from the extracted LAN package, never directly from the game folder.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$manifestPath=Join-Path $root 'mod-manifest.json'
$target=Join-Path $root 'mod/mods/modWitcherOnline/content/scripts/local/coopPartyMenu.ws'
$source=Join-Path $root 'party-menu-fix/coopPartyMenu.ws'
$expected='61149dc33d6636f1fad4d5b27c0e55013fe8311ce7ac6f728869be6c8a53a7ba'
$relative='mods/modWitcherOnline/content/scripts/local/coopPartyMenu.ws'
function PlainPath([string]$Path) {
    $part=[IO.Path]::GetFullPath($Path)
    if(-not $part.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Patch path escapes the package.'}
    while($part){
        if((Test-Path -LiteralPath $part) -and ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The package must not contain links or junctions.'}
        $part=Split-Path -Parent $part
    }
}
foreach($path in @($manifestPath,$target,$source,(Join-Path $root '.party-menu-patch.lock'))){PlainPath $path}
if(-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $root 'mod/mods/modWitcherOnline/content/scripts/local/client.ws')) -or -not (Test-Path -LiteralPath (Join-Path $root 'Manage-Mod.ps1'))){throw 'Extract the fix into the LAN launcher package folder containing mod-manifest.json and mod, rather than into the game folder.'}
if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected){throw 'Party-menu fix checksum mismatch.'}
$lock=[IO.File]::Open((Join-Path $root '.party-menu-patch.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
    $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $entries=@($manifest.files | Where-Object {$_.path -ieq $relative})
    if($entries.Count -gt 1){throw 'Duplicate party-menu file in manifest.'}
    $current=$null
    if(Test-Path -LiteralPath $target){$current=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()}
    if($entries.Count -eq 1 -and $null -ne $current -and $current -cne $entries[0].sha256){throw 'Party-menu source was changed outside this package. Keep that edit before applying the update.'}
    if($current -ceq $expected -and $entries.Count -eq 1 -and $entries[0].sha256 -ceq $expected){Write-Output 'Party-menu fix is already in this package.'; return}
    $backup=Join-Path $root ('.party-menu-package-backup/'+[Guid]::NewGuid().ToString('N')); PlainPath $backup
    [void][IO.Directory]::CreateDirectory($backup)
    [IO.File]::Copy($manifestPath,(Join-Path $backup 'mod-manifest.json'),$false)
    $oldManifestHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    if($null -ne $current){[IO.File]::Copy($target,(Join-Path $backup 'coopPartyMenu.ws'),$false)}
    $manifest.files=@($manifest.files | Where-Object {$_.path -ine $relative}) + @([ordered]@{path=$relative;sha256=$expected})
    $next=Join-Path $backup 'next-manifest.json'
    [IO.File]::WriteAllText($next,($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $staged=Join-Path $backup 'new.ws'; [IO.File]::Copy($source,$staged,$false)
    try{
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        if(Test-Path -LiteralPath $target){[IO.File]::Replace($staged,$target,[NullString]::Value)}else{[IO.File]::Move($staged,$target)}
        if((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -cne $oldManifestHash){throw 'Package manifest changed during the patch.'}
        [IO.File]::Replace($next,$manifestPath,[NullString]::Value)
    }catch{
        if($null -eq $current){if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $expected){[IO.File]::Delete($target)}}
        else{[IO.File]::Copy((Join-Path $backup 'coopPartyMenu.ws'),$target,$true)}
        throw
    }
    Write-Output 'Party-menu fix added to the package. In Manage Mod, select the existing game folder and choose 1 to install/update it.'
    Write-Output 'The normal mod installer backs up game files and records the new script so Remove Mod can undo it.'
}finally{$lock.Dispose()}
