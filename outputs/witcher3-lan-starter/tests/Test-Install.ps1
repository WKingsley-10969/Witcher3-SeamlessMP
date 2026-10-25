#requires -Version 5.1
[CmdletBinding()]
param([string]$TestRoot = (Join-Path ([IO.Path]::GetTempPath()) 'w3lan-install-fixtures'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$starter = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $starter 'W3ModInstall.psm1') -Force
$module = Get-Module W3ModInstall
$fixture = Join-Path ([IO.Path]::GetFullPath($TestRoot)) ([Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($fixture)
$script:checks = 0
function Assert([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Check([string]$Name, [scriptblock]$Body) { & $Body; $script:checks++; Write-Output "PASS $Name" }
function Throws([scriptblock]$Body, [string]$Message='') {
    $failure = $null; try { & $Body | Out-Null } catch { $failure = $_ }
    Assert ($null -ne $failure) 'Expected the operation to be rejected.'
    if ($Message) { Assert ($failure.Exception.Message -like "*$Message*") ("Unexpected error: " + $failure.Exception.Message) }
}
function Put([string]$Path, [string]$Text) { [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path)); [IO.File]::WriteAllText($Path,$Text) }
function Hash([string]$Path) { if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }; return $null }
function Snapshot([string]$Root) {
    return (@(Get-ChildItem -LiteralPath $Root -Recurse -Force -File | Where-Object {$_.FullName -notlike '*\.w3lan-install\*'} | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($Root.Length) + ':' + (Hash $_.FullName) }) -join '|')
}
function New-Game([string]$Name) {
    $root = Join-Path $fixture $Name
    Put (Join-Path $root 'bin/x64_dx12/witcher3.exe') 'fake fixture bytes, never executed'
    Put (Join-Path $root 'bin/x64_dx12/dinput8.dll') 'pre-existing loader owned by the player'
    [IO.File]::WriteAllBytes((Join-Path $root 'bin/x64_dx12/dinput8.dll'),[byte[]]@(0,255,128,1,17,10,13,254))
    Put (Join-Path $root 'bin/config/r4game/user_config_matrix/pc/modWitcherOnline.xml') 'pre-existing config'
    Put (Join-Path $root 'mods/anotherMod/keep.ws') 'unrelated mod'
    Put (Join-Path $root '.w3lan-profiles/keep.sav') 'existing co-op save'
    return $root
}
function Manifest([string]$Package, [string]$Version) {
    $payload = Join-Path $Package 'mod'
    $files = @(Get-ChildItem -LiteralPath $payload -Recurse -File | Sort-Object FullName | ForEach-Object { @{path=$_.FullName.Substring($payload.Length+1).Replace('\','/');sha256=(Hash $_.FullName)} })
    @{version=$Version;files=$files} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Package 'mod-manifest.json') -Encoding utf8
}
function New-Package([string]$Name, [string]$Version) {
    $root = Join-Path $fixture $Name
    foreach ($relative in @('bin/x64_dx12/dinput8.dll','bin/x64_dx12/w3test.asi','bin/x64_dx12/WitcherNativeBridge.asi','bin/x64_dx12/WitcherOnlineClient.asi','bin/config/r4game/user_config_matrix/pc/modWitcherOnline.xml','mods/modWitcherOnline/content/scripts/one.ws','mods/modWitcherOnlineCompat/content/scripts/compat.ws','dlc/dlcWitcherOnline/content/test.txt')) {
        Put (Join-Path $root ('mod/' + $relative)) ($Version + ':' + $relative)
    }
    Manifest $root $Version
    return $root
}
function Install([string]$Game, [string]$Package, [switch]$Preserve) { Install-W3LanMod -GameDir $Game -PackageDir $Package -PreserveChanges:$Preserve }
function Remove-Mod([string]$Game, [switch]$Preserve) { Remove-W3LanMod -GameDir $Game -PreserveChanges:$Preserve }
$game = New-Game 'game'
$v1 = New-Package 'package1' '1'
$v2 = New-Package 'package2' '2'
$exeHash = Hash (Join-Path $game 'bin/x64_dx12/witcher3.exe')
# Tests alter the module's private expected-build constant only in this process.
# Production entry points expose no executable-hash bypass parameter.
& $module {param($hash) $script:W3ExpectedExeHash=$hash} $exeHash
# Real game processes may belong to another active developer. These fake game
# bytes cannot execute; bypass only the private process guard in this fixture.
& $module { function script:Assert-W3GameClosed {} }
$initial = Snapshot $game
$originalLoaderHash = Hash (Join-Path $game 'bin/x64_dx12/dinput8.dll')
$oldLocalData = $env:LOCALAPPDATA
try {
    Check 'status is read-only before installation' {
        $s = Get-W3ModStatus -GameDir $game
        Assert (-not $s.Installed -and -not $s.NeedsRecovery) 'Fresh installation reported active'
        Assert (-not (Test-Path -LiteralPath (Join-Path $game '.w3lan-install'))) 'Status wrote metadata'
    }
    Check 'install replaces only payload files and writes reversible ownership' {
        $r = Install $game $v1
        Assert ($r.Action -eq 'Install' -and $r.ChangedFiles -eq 10) 'Wrong install result'
        Assert ((Hash (Join-Path $game 'bin/x64_dx12/witcher3.exe')) -ceq $exeHash) 'Game executable changed'
        Assert ((Get-Content -LiteralPath (Join-Path $game 'mods/anotherMod/keep.ws') -Raw) -ceq 'unrelated mod') 'Unrelated mod changed'
        Assert (-not (Test-Path -LiteralPath (Join-Path $game '.w3lan-test-copy.json'))) 'Installer pretended the original was a test copy'
    }
    $firstState = (Get-W3ModStatus -GameDir $game).Record
    $loader = @($firstState.files | Where-Object {$_.path -eq 'bin/x64_dx12/dinput8.dll'})[0]
    $backup = Join-Path $game ('.w3lan-install/' + $loader.backup)
    Check 'original file is hash-verified and backed up automatically' { Assert ((Hash $backup) -ceq $originalLoaderHash) 'Original loader backup differs' }
    Check 'unchanged reinstall writes no game files and retains originals' {
        $r = Install $game $v1
        Assert ($r.ChangedFiles -eq 0) 'No-op reinstall rewrote game files'
        Assert ((Hash $backup) -ceq $originalLoaderHash) 'Original backup overwritten'
    }
    Check 'adopting an isolated copy retains its existing co-op profile' {
        $copyGame = New-Game 'copy-game'
        @{TestCopy=$true;OriginalPath=(Join-Path $fixture 'different-original');ExeSha256=$exeHash} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $copyGame '.w3lan-test-copy.json')
        $legacyProfile = Join-Path $copyGame '.w3lan-profiles/HostWitcher'
        Put (Join-Path $legacyProfile 'The Witcher 3/gamesaves/progress.sav') 'existing copied-game progress'
        Put (Join-Path $legacyProfile '.profile-ready.json') '{}'
        [void](Install $copyGame $v1)
        Import-Module (Join-Path $starter 'W3LanProfile.psm1') -Force
        $copyInfo = New-W3LanProfileStartInfo -GameDir $copyGame -PlayerName HostWitcher -Address 127.0.0.1
        Assert ($copyInfo.EnvironmentVariables['W3LAN_DOCUMENTS'] -ceq $legacyProfile) 'Adoption switched save folders'
        Assert ((Get-Content -LiteralPath (Join-Path $legacyProfile 'The Witcher 3/gamesaves/progress.sav') -Raw) -ceq 'existing copied-game progress') 'Existing co-op save changed'
        [void](Remove-Mod $copyGame)
    }
    Check 'managed original installation launches with separate per-user save path' {
        $env:LOCALAPPDATA = Join-Path $fixture 'appdata'
        Import-Module (Join-Path $starter 'W3LanProfile.psm1') -Force
        $seed = Join-Path $fixture 'seed'; Put (Join-Path $seed 'gamesaves/solo.sav') 'original solo save'
        $script:info = New-W3LanProfileStartInfo -GameDir $game -PlayerName HostWitcher -Address 127.0.0.1 -SeedDirectory $seed
        Assert ($info.FileName -ceq (Join-Path $game 'bin/x64_dx12/witcher3.exe')) 'Wrong executable'
        $profile = $info.EnvironmentVariables['W3LAN_DOCUMENTS']
        Assert ($profile.StartsWith($env:LOCALAPPDATA + '\')) 'Managed profile not in local app data'
        Assert ((Get-Content -LiteralPath (Join-Path $profile 'The Witcher 3/gamesaves/solo.sav') -Raw) -ceq 'original solo save') 'Profile seed missing'
        Put (Join-Path $profile 'The Witcher 3/gamesaves/coop.sav') 'progress to keep after uninstall'
    }
    # Update removes one newly added file, restores one superseded original, and adds another file.
    [IO.File]::Delete((Join-Path $v2 'mod/mods/modWitcherOnline/content/scripts/one.ws'))
    [IO.File]::Delete((Join-Path $v2 'mod/bin/config/r4game/user_config_matrix/pc/modWitcherOnline.xml'))
    Put (Join-Path $v2 'mod/mods/modWitcherOnline/content/scripts/two.ws') 'version 2 new file'; Manifest $v2 '2'
    Check 'update changes files without copying the game or overwriting first backups' {
        $r = Install $game $v2
        Assert ($r.Action -eq 'Update') 'Update not recognised'
        Assert ((Hash $backup) -ceq $originalLoaderHash) 'First backup replaced by modded bytes'
        Assert (-not (Test-Path -LiteralPath (Join-Path $game 'mods/modWitcherOnline/content/scripts/one.ws'))) 'Obsolete new file retained'
        Assert ((Get-Content -LiteralPath (Join-Path $game 'bin/config/r4game/user_config_matrix/pc/modWitcherOnline.xml') -Raw) -ceq 'pre-existing config') 'Obsolete overwritten original not restored'
    }
    Check 'successful operations discard staging copies and keep original backups' {
        Assert (@(Get-ChildItem -LiteralPath (Join-Path $game '.w3lan-install/transactions') -Recurse -File).Count -eq 0) 'Staged payload accumulated'
        Assert (@(Get-ChildItem -LiteralPath (Join-Path $game '.w3lan-install/atomic') -File).Count -eq 0) 'Atomic-write staging accumulated'
        Assert (Test-Path -LiteralPath $backup) 'Original backup was deleted'
    }
    Put (Join-Path $game 'mods/modWitcherOnline/content/scripts/two.ws') 'player custom edit'
    Check 'external changes stop removal before any managed file changes' {
        $before = Snapshot $game
        Throws { Remove-Mod $game } 'changed outside'
        Assert ((Snapshot $game) -ceq $before) 'Conflict caused partial removal'
    }
    Check 'corrupt original backup stops even an explicit preserve/remove' {
        $bytes = [IO.File]::ReadAllBytes($backup); Put $backup 'corrupted backup'
        try { $before = Snapshot $game; Throws { Remove-Mod $game -Preserve } 'backup'; Assert ((Snapshot $game) -ceq $before) 'Corrupt backup caused changes' }
        finally { [IO.File]::WriteAllBytes($backup,$bytes) }
    }
    Check 'remove preserves external edits and restores exact pre-install files' {
        [void](Remove-Mod $game -Preserve)
        Assert ((Snapshot $game) -ceq $initial) 'Removal did not restore initial file bytes/set'
        $saved = @(Get-ChildItem -LiteralPath (Join-Path $game '.w3lan-install/preserved') -Recurse -File | Where-Object {$_.Name -eq 'two.ws'})
        Assert ($saved.Count -eq 1 -and (Get-Content -LiteralPath $saved[0].FullName -Raw) -ceq 'player custom edit') 'External edit was not preserved'
        Assert ((Get-Content -LiteralPath (Join-Path $info.EnvironmentVariables['W3LAN_DOCUMENTS'] 'The Witcher 3/gamesaves/coop.sav') -Raw) -ceq 'progress to keep after uninstall') 'Co-op save removed'
        Assert (-not (Get-W3ModStatus -GameDir $game).Installed) 'Removed state still active'
    }
    Check 'second removal is a no-op' { $r = Remove-Mod $game; Assert ($r.ChangedFiles -eq 0) 'Repeated removal changed files' }
    Check 'reinstall keeps the save identity and starts fresh original backups' {
        [void](Install $game $v2)
        $again = (Get-W3ModStatus -GameDir $game).Record
        Assert ($again.installationId -ceq $firstState.installationId) 'Reinstall lost the co-op save profile identity'
        $againLoader = @($again.files | Where-Object {$_.path -eq 'bin/x64_dx12/dinput8.dll'})[0]
        Assert ($againLoader.backup -cne $loader.backup) 'Reinstall reused prior baseline backup entry'
        [void](Remove-Mod $game); Assert ((Snapshot $game) -ceq $initial) 'Reinstall/remove round trip differs'
    }
    Check 'hash-corrupt payload is rejected before game writes' {
        Put (Join-Path $v1 'mod/bin/x64_dx12/dinput8.dll') 'corrupt package'
        Throws { Install $game $v1 } 'checksum'
        Assert ((Snapshot $game) -ceq $initial) 'Bad payload wrote game files'
        Manifest $v1 '1'
    }
    Check 'unlisted extra payload files are rejected' {
        $extra = Join-Path $v1 'mod/bin/extra.txt'; Put $extra 'unlisted'
        try { Throws { Install $game $v1 } 'not listed' } finally { [IO.File]::Delete($extra) }
    }
    Check 'traversal, alternate streams, device aliases and executable replacement are rejected' {
        $manifestPath = Join-Path $v1 'mod-manifest.json'; $bytes = [IO.File]::ReadAllBytes($manifestPath)
        try {
            foreach ($bad in @('../outside.txt','bin/../../outside.txt','bin/file:stream','bin/CON.txt','mods/name./file.ws','bin/x64_dx12/witcher3.exe')) {
                @{version='bad';files=@(@{path=$bad;sha256=$exeHash})} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath
                Throws { Install $game $v1 }
            }
            Assert ((Snapshot $game) -ceq $initial) 'Unsafe manifest changed game files'
        } finally { [IO.File]::WriteAllBytes($manifestPath,$bytes) }
    }
    Check 'duplicate case aliases in manifest are rejected' {
        $manifestPath = Join-Path $v1 'mod-manifest.json'; $bytes = [IO.File]::ReadAllBytes($manifestPath)
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $duplicate = $manifest.files[0] | Select-Object path,sha256; $duplicate.path = $duplicate.path.ToUpperInvariant()
            $manifest.files = @($manifest.files) + @($duplicate); $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath
            Throws { Install $game $v1 }
        } finally { [IO.File]::WriteAllBytes($manifestPath,$bytes) }
    }
    Check 'exclusive installation lock blocks concurrent mutation' {
        $held = [IO.File]::Open((Join-Path $game '.w3lan-install/install.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try { Throws { Install $game $v1 } 'Another mod operation' } finally { $held.Dispose() }
    }
    Check 'tampered state paths cannot target files outside the game' {
        [void](Install $game $v1)
        $statePath = Join-Path $game '.w3lan-install/state.json'; $bytes = [IO.File]::ReadAllBytes($statePath)
        try {
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            $state.files[0].path = '../outside.txt'; $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statePath
            $before = Snapshot $game; Throws { Remove-Mod $game } 'record is invalid'; Assert ((Snapshot $game) -ceq $before) 'Tampered record changed files'
        } finally { [IO.File]::WriteAllBytes($statePath,$bytes) }
        [void](Remove-Mod $game)
    }
    Check 'directory collision rejects the whole install' {
        $collision = New-Game 'collision'; [void][IO.Directory]::CreateDirectory((Join-Path $collision 'bin/x64_dx12/w3test.asi'))
        $before = Snapshot $collision; Throws { Install $collision $v1 } 'Expected a file'; Assert ((Snapshot $collision) -ceq $before) 'Collision caused partial install'
    }
    Check 'a failed write rolls back every previously changed target' {
        $rollback = New-Game 'rollback'; $before = Snapshot $rollback
        & $module {
            $script:W3RealAtomic = (Get-Command Write-W3AtomicFile).ScriptBlock
            $script:W3Writes = 0
            function script:Write-W3AtomicFile([string]$Source,[string]$Target) {
                if ($Source.EndsWith('.after')) { $script:W3Writes++; if ($script:W3Writes -eq 3) { throw 'injected fixture write failure' } }
                & $script:W3RealAtomic $Source $Target
            }
        }
        try {
            Throws { Install $rollback $v1 } 'rolled back'
            Assert ((Snapshot $rollback) -ceq $before) 'Partial install survived rollback'
            Assert (-not (Test-Path -LiteralPath (Join-Path $rollback '.w3lan-install/pending.json'))) 'Successful rollback left pending journal'
        } finally { & $module {Set-Item Function:script:Write-W3AtomicFile $script:W3RealAtomic} }
    }
    Check 'failed rollback retains journal and next operation recovers it' {
        $interrupted = New-Game 'interrupted'; [void](Install $interrupted $v1); $before = Snapshot $interrupted
        & $module {
            $script:W3RealAtomic = (Get-Command Write-W3AtomicFile).ScriptBlock; $script:W3Writes = 0
            function script:Write-W3AtomicFile([string]$Source,[string]$Target) {
                if ($Source.EndsWith('.before')) { throw 'injected rollback failure' }
                if ($Source.EndsWith('.after')) { $script:W3Writes++; if ($script:W3Writes -eq 3) { throw 'injected update failure' } }
                & $script:W3RealAtomic $Source $Target
            }
        }
        try { Throws { Install $interrupted $v2 } 'rollback needs attention' }
        finally { & $module {Set-Item Function:script:Write-W3AtomicFile $script:W3RealAtomic} }
        Assert ((Get-W3ModStatus -GameDir $interrupted).NeedsRecovery) 'Missing recovery record'
        Throws { New-W3LanProfileStartInfo -GameDir $interrupted -PlayerName HostWitcher -Address 127.0.0.1 } 'interrupted'
        Check 'recovery refuses to overwrite a new external edit after interruption' {
            $pending = Get-Content -LiteralPath (Join-Path $interrupted '.w3lan-install/pending.json') -Raw | ConvertFrom-Json
            $changed = Join-Path $interrupted $pending.files[0].path
            $bytes = [IO.File]::ReadAllBytes($changed)
            try {
                Put $changed 'external edit after interruption'; $edited = Snapshot $interrupted
                Throws { Install $interrupted $v1 } 'changed after an interrupted'
                Assert ((Snapshot $interrupted) -ceq $edited) 'Recovery overwrote a new external edit'
            } finally { [IO.File]::WriteAllBytes($changed,$bytes) }
        }
        [void](Install $interrupted $v1)
        Assert ((Snapshot $interrupted) -ceq $before) 'Recovery did not restore prior version'
        Assert (-not (Get-W3ModStatus -GameDir $interrupted).NeedsRecovery) 'Recovery did not clear journal'
        [void](Remove-Mod $interrupted)
    }
    Check 'game root junction is rejected without following it' {
        $link = Join-Path $fixture 'linked-game'; [void](New-Item -ItemType Junction -Path $link -Target $game)
        Throws { Install $link $v1 } 'Links/junctions'
    }
    Check 'a replaced original backup cannot make uninstall silently discard it' {
        $missing = New-Game 'missing-backup'; [void](Install $missing $v1)
        $record = (Get-W3ModStatus -GameDir $missing).Record
        $entry = @($record.files | Where-Object {$null -ne $_.backup})[0]
        [IO.File]::Delete((Join-Path $missing ('.w3lan-install/' + $entry.backup)))
        $before = Snapshot $missing; Throws { Remove-Mod $missing } 'backup is missing'; Assert ((Snapshot $missing) -ceq $before) 'Missing backup caused partial removal'
    }
    Check 'older manual installs cannot falsely report a successful revert' {
        $legacy = New-Game 'legacy'; Put (Join-Path $legacy 'bin/x64_dx12/WitcherOnlineClient.asi') 'manually installed mod'
        $before = Snapshot $legacy; Throws { Remove-Mod $legacy } 'no restore record'; Assert ((Snapshot $legacy) -ceq $before) 'Manual install was changed'
    }
    Check 'closed-game guard runs before installation writes' {
        $guarded = New-Game 'guarded'; $before = Snapshot $guarded
        & $module {function script:Assert-W3GameClosed {throw 'fixture says the game is running'}}
        try { Throws { Install $guarded $v1 } 'game is running'; Assert ((Snapshot $guarded) -ceq $before) 'Running game was modified' }
        finally { & $module {function script:Assert-W3GameClosed {}} }
    }
    Check 'overlong game paths are refused before backup or file changes' {
        $longGame = New-Game ('l' * [Math]::Max(1,131-$fixture.Length)); $before = Snapshot $longGame
        Throws { Install $longGame $v1 } '130 characters'
        Assert ((Snapshot $longGame) -ceq $before) 'Overlong path caused file changes'
        Assert (-not (Test-Path -LiteralPath (Join-Path $longGame '.w3lan-install'))) 'Overlong path wrote restore state'
    }
    Check 'an actual killed installer process is recovered by the next operation' {
        $crashGame = New-Game 'killed'; $before = Snapshot $crashGame
        $childFile = Join-Path $fixture 'interrupt-child.ps1'; $signal = Join-Path $fixture 'child-wrote.txt'
        @'
param($GameDir,$PackageDir,$ModulePath,$SignalPath,$ExeHash,$Operation='Install')
$ErrorActionPreference='Stop'
Import-Module $ModulePath -Force
$m=Get-Module W3ModInstall
& $m {
    param($hash,$signal)
    $script:W3ExpectedExeHash=$hash
    $script:W3Signal=$signal
    function script:Assert-W3GameClosed {}
    $script:W3RealAtomic=(Get-Command Write-W3AtomicFile).ScriptBlock
    function script:Write-W3AtomicFile([string]$Source,[string]$Target) {
        & $script:W3RealAtomic $Source $Target
        if($Source.EndsWith('.after')) {
            [IO.File]::WriteAllText($script:W3Signal,'a game target was replaced after the durable journal')
            [Threading.Thread]::Sleep(30000)
        }
    }
} $ExeHash $SignalPath
if($Operation -eq 'Remove') { Remove-W3LanMod -GameDir $GameDir }
else { Install-W3LanMod -GameDir $GameDir -PackageDir $PackageDir }
'@ | Set-Content -LiteralPath $childFile -Encoding utf8
        $processInfo = [Diagnostics.ProcessStartInfo]::new()
        $processInfo.FileName = (Get-Process -Id $PID).Path
        $processInfo.UseShellExecute=$false; $processInfo.CreateNoWindow=$true
        $arguments = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$childFile,$crashGame,$v1,(Join-Path $starter 'W3ModInstall.psm1'),$signal,$exeHash)
        $processInfo.Arguments = (@($arguments | ForEach-Object {'"'+$_+'"'}) -join ' ')
        $child = [Diagnostics.Process]::Start($processInfo)
        try {
            $deadline=[DateTime]::UtcNow.AddSeconds(15)
            while(-not (Test-Path -LiteralPath $signal) -and -not $child.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
            Assert (Test-Path -LiteralPath $signal) 'Fixture child never reached a durable partial write'
            $child.Kill(); Assert ($child.WaitForExit(5000)) 'Owned fixture process did not exit'
            Assert ((Get-W3ModStatus -GameDir $crashGame).NeedsRecovery) 'Abrupt kill lost its journal'
            [void](Remove-Mod $crashGame)
            Assert ((Snapshot $crashGame) -ceq $before) 'Restarted operation did not undo partial install'
            Assert (-not (Get-W3ModStatus -GameDir $crashGame).NeedsRecovery) 'Recovered journal not cleared'
        } finally { if (-not $child.HasExited) { $child.Kill(); [void]$child.WaitForExit(5000) }; $child.Dispose() }
    }
    Check 'a killed uninstall restores the prior installed version before retry' {
        $removeGame = New-Game 'killed-remove'; [void](Install $removeGame $v1); $before = Snapshot $removeGame
        $signal = Join-Path $fixture 'remove-wrote.txt'
        $processInfo = [Diagnostics.ProcessStartInfo]::new()
        $processInfo.FileName = (Get-Process -Id $PID).Path; $processInfo.UseShellExecute=$false; $processInfo.CreateNoWindow=$true
        $arguments = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $fixture 'interrupt-child.ps1'),$removeGame,$v1,(Join-Path $starter 'W3ModInstall.psm1'),$signal,$exeHash,'Remove')
        $processInfo.Arguments = (@($arguments | ForEach-Object {'"'+$_+'"'}) -join ' ')
        $child = [Diagnostics.Process]::Start($processInfo)
        try {
            $deadline=[DateTime]::UtcNow.AddSeconds(15)
            while(-not (Test-Path -LiteralPath $signal) -and -not $child.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
            Assert (Test-Path -LiteralPath $signal) 'Fixture uninstall never reached a partial restore'
            $child.Kill(); Assert ($child.WaitForExit(5000)) 'Owned uninstall fixture did not exit'
            Throws { New-W3LanProfileStartInfo -GameDir $removeGame -PlayerName HostWitcher -Address 127.0.0.1 } 'interrupted'
            [void](Install $removeGame $v1)
            Assert ((Snapshot $removeGame) -ceq $before) 'Uninstall recovery did not restore installed files'
            [void](Remove-Mod $removeGame)
        } finally { if (-not $child.HasExited) { $child.Kill(); [void]$child.WaitForExit(5000) }; $child.Dispose() }
    }
    Write-Output "INSTALL_FIXTURE_PASS: $script:checks checks. Fixture-only game bytes; no installed game launched or modified."
    Write-Output "Evidence: $fixture"
} finally { $env:LOCALAPPDATA = $oldLocalData }
