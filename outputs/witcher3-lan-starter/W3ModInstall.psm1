# In-place mod transactions. Only manifest-owned files are changed; game data and saves are not copied.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:W3ExpectedExeHash = '2df765398a3d1f165db418271be7200178320a4466817379f2fa0dc0001fb101'
$script:W3Metadata = @('.w3lan-managed.json', '.w3lan-native.json')
$script:W3AtomicDirectory = $null

function Get-W3FileHash([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Expected a file: $Path" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-W3PlainPath([string]$Path) {
    $part = [IO.Path]::GetFullPath($Path)
    while ($part) {
        if (Test-Path -LiteralPath $part) {
            $item = Get-Item -LiteralPath $part -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Links/junctions are not supported: $part" }
            if ($part -ine [IO.Path]::GetFullPath($Path) -and -not $item.PSIsContainer) { throw "Parent is not a directory: $part" }
        }
        $next = Split-Path -Parent $part
        if ($next -eq $part) { break }
        $part = $next
    }
}

function Resolve-W3ModRoot([string]$GameDir) {
    $root = (Resolve-Path -LiteralPath $GameDir -ErrorAction Stop).Path.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $root -PathType Container) -or $root.Length -lt 4) { throw 'Choose the Witcher 3 installation folder.' }
    if ($root.Length -gt 130) { throw 'The game folder path exceeds 130 characters; choose a shorter installation path so backups work with Windows PowerShell.' }
    Assert-W3PlainPath $root
    return $root
}

function Assert-W3ModRelative([string]$Relative, [bool]$Metadata = $false) {
    if ($Metadata -and $Relative -cin $script:W3Metadata) { return }
    if ($Relative -cnotmatch '\A(?:bin|mods|dlc|W3Coop)/[^\\:<>"|?*\x00-\x1f]+\z') { throw "Invalid mod path: $Relative" }
    foreach ($part in $Relative.Split('/')) {
        if (-not $part -or $part -in @('.', '..') -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw "Invalid mod path: $Relative" }
    }
    if ([IO.Path]::GetFileName($Relative) -ieq 'witcher3.exe') { throw 'A mod payload must not replace the game executable.' }
}

function Get-W3ModPath([string]$Root, [string]$Relative, [bool]$Metadata = $false) {
    Assert-W3ModRelative $Relative $Metadata
    $target = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $target.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Mod path escapes the game folder.' }
    Assert-W3PlainPath $target
    return $target
}

function Assert-W3GameClosed {
    if (@(Get-Process -Name witcher3 -ErrorAction SilentlyContinue).Count) { throw 'Close Witcher 3 before installing, updating or removing the mod.' }
}

function Write-W3AtomicFile([string]$Source, [string]$Target) {
    Assert-W3PlainPath $Target
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Target))
    if (-not $script:W3AtomicDirectory) { throw 'Atomic writes require the installation lock.' }
    Assert-W3PlainPath $script:W3AtomicDirectory
    [void][IO.Directory]::CreateDirectory($script:W3AtomicDirectory)
    # Same-volume staging stays in restore metadata, so a killed copy cannot
    # leave half-copied DLLs or untracked temporary files in the game directories.
    $temp = Join-Path $script:W3AtomicDirectory ([Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::Copy($Source, $temp, $false)
        $stream = [IO.File]::Open($temp, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { $stream.Flush($true) } finally { $stream.Dispose() }
        if (Test-Path -LiteralPath $Target) { [IO.File]::Replace($temp, $Target, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Target) }
    } finally {
        if (Test-Path -LiteralPath $temp) { [IO.File]::Delete($temp) }
    }
}

function Write-W3Json([object]$Value, [string]$Target) {
    $temp = $Target + '.' + [Guid]::NewGuid().ToString('N') + '.json'
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
        Write-W3AtomicFile $temp $Target
    } finally { if (Test-Path -LiteralPath $temp) { [IO.File]::Delete($temp) } }
}

function Get-W3TreeFiles([string]$Root) {
    $queue = [Collections.Generic.Queue[string]]::new(); $queue.Enqueue($Root)
    while ($queue.Count) {
        $dir = $queue.Dequeue(); Assert-W3PlainPath $dir
        foreach ($item in Get-ChildItem -LiteralPath $dir -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Payload must not contain links or junctions.' }
            if ($item.PSIsContainer) { $queue.Enqueue($item.FullName) } else { $item.FullName }
        }
    }
}

function Read-W3ModState([string]$Root) {
    $path = Join-Path $Root '.w3lan-install/state.json'; Assert-W3PlainPath $path
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($state.api -ne 1 -or $state.gameRoot -ine $Root -or $state.installationId -cnotmatch '\A[a-f0-9]{32}\z' -or $state.installed -isnot [bool]) { throw 'Invalid installation identity.' }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($file in $state.files) {
            [void](Get-W3ModPath $Root $file.path $true)
            if (-not $seen.Add($file.path) -or $file.installedHash -cnotmatch '\A[a-f0-9]{64}\z') { throw 'Invalid installed file entry.' }
            if ($null -ne $file.originalHash) {
                if ($file.originalHash -cnotmatch '\A[a-f0-9]{64}\z' -or $file.backup -cnotmatch ('\Aoriginals/' + $state.installationId + '/[a-f0-9]{32}\.bin\z')) { throw 'Invalid backup entry.' }
                Assert-W3PlainPath (Join-Path $Root ('.w3lan-install/' + $file.backup))
            } elseif ($null -ne $file.backup) { throw 'Unexpected backup entry.' }
        }
        if (-not $state.installed -and @($state.files).Count) { throw 'Removed installation still owns files.' }
        return $state
    } catch { throw "Installation record is invalid; keep its backups and repair the record before proceeding. $($_.Exception.Message)" }
}

function Get-W3ModStatus {
    param([Parameter(Mandatory)][string]$GameDir)
    $root = Resolve-W3ModRoot $GameDir
    $state = Read-W3ModState $root
    $pending = Join-Path $root '.w3lan-install/pending.json'; Assert-W3PlainPath $pending
    [pscustomobject]@{ GameDir=$root; Installed=($null -ne $state -and $state.installed); NeedsRecovery=(Test-Path -LiteralPath $pending); Record=$state }
}

function Copy-W3Verified([string]$Source, [string]$Target, [string]$Hash) {
    Assert-W3PlainPath $Source; Assert-W3PlainPath $Target
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Target))
    [IO.File]::Copy($Source, $Target, $false)
    if ((Get-W3FileHash $Target) -cne $Hash) { throw 'File changed during preparation or backup.' }
}

function Clear-W3TransactionStaging([string]$Root, [string]$Id) {
    if ($Id -cnotmatch '\A[a-f0-9]{32}\z') { throw 'Invalid staging identity.' }
    $base = [IO.Path]::GetFullPath((Join-Path $Root '.w3lan-install/transactions')).TrimEnd('\')
    $dir = [IO.Path]::GetFullPath((Join-Path $base $Id))
    if (-not $dir.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid staging folder.' }
    Assert-W3PlainPath $dir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $dir -File -Force) {
        Assert-W3PlainPath $file.FullName
        if ($file.Name -cmatch '\A(?:[a-f0-9]{32}\.(?:before|after|metadata)|next-state\.json)\z') { [IO.File]::Delete($file.FullName) }
    }
    if (@(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0) { [IO.Directory]::Delete($dir, $false) }
}

function Clear-W3AtomicStaging {
    if (-not $script:W3AtomicDirectory) { return }
    Assert-W3PlainPath $script:W3AtomicDirectory
    if (-not (Test-Path -LiteralPath $script:W3AtomicDirectory -PathType Container)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $script:W3AtomicDirectory -File -Force) {
        Assert-W3PlainPath $file.FullName
        if ($file.Name -cmatch '\A[a-f0-9]{32}\.tmp\z') { [IO.File]::Delete($file.FullName) }
    }
}

function Restore-W3Pending([string]$Root) {
    $dir = Join-Path $Root '.w3lan-install'; $pendingPath = Join-Path $dir 'pending.json'; Assert-W3PlainPath $pendingPath
    if (-not (Test-Path -LiteralPath $pendingPath)) { return }
    $journal = Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json
    if ($journal.api -ne 1 -or $journal.gameRoot -ine $Root -or $journal.transactionId -cnotmatch '\A[a-f0-9]{32}\z' -or $journal.nextStateHash -cnotmatch '\A[a-f0-9]{64}\z') { throw 'Invalid interrupted transaction record.' }
    $stateHash = Get-W3FileHash (Join-Path $dir 'state.json')
    if ($stateHash -ceq $journal.nextStateHash) {
        [IO.File]::Delete($pendingPath)
        try { Clear-W3TransactionStaging $Root $journal.transactionId } catch { Write-Warning 'Completed transaction staging could not be cleaned up; original backups were retained.' }
        return
    }
    if ($stateHash -cne $journal.oldStateHash) { throw 'Installation record changed during an interrupted operation; backups were retained.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    # Verify the whole rollback before changing any target.
    foreach ($entry in $journal.files) {
        $target = Get-W3ModPath $Root $entry.path $true
        if (-not $seen.Add($entry.path) -or ($null -ne $entry.beforeHash -and $entry.beforeHash -cnotmatch '\A[a-f0-9]{64}\z') -or ($null -ne $entry.afterHash -and $entry.afterHash -cnotmatch '\A[a-f0-9]{64}\z')) { throw 'Invalid rollback file entry.' }
        $current = Get-W3FileHash $target
        if ($current -cne $entry.beforeHash -and $current -cne $entry.afterHash) { throw "File changed after an interrupted operation: $($entry.path). Backups retained; refusing to overwrite it." }
        if ($null -ne $entry.beforeHash) {
            if ($entry.snapshot -cnotmatch ('\Atransactions/' + $journal.transactionId + '/[a-f0-9]{32}\.before\z')) { throw 'Invalid rollback snapshot.' }
            $snapshot = Join-Path $dir $entry.snapshot; Assert-W3PlainPath $snapshot
            if ((Get-W3FileHash $snapshot) -cne $entry.beforeHash) { throw 'Rollback snapshot is missing or corrupt.' }
        }
    }
    foreach ($entry in $journal.files) {
        $target = Get-W3ModPath $Root $entry.path $true
        if ((Get-W3FileHash $target) -ceq $entry.beforeHash) { continue }
        if ($null -eq $entry.beforeHash) { [IO.File]::Delete($target) }
        else { Write-W3AtomicFile (Join-Path $dir $entry.snapshot) $target }
        if ((Get-W3FileHash $target) -cne $entry.beforeHash) { throw 'Rollback readback failed; retry the operation after repairing storage.' }
    }
    [IO.File]::Delete($pendingPath)
    try { Clear-W3TransactionStaging $Root $journal.transactionId } catch { Write-Warning 'Rollback succeeded; temporary staging was retained.' }
}

# Custom Player Characters (nikich340), installed by the player: its mod and DLC folders. Our
# stand-in for it (mods/modWitcherOnlineCompatCPC) declares the same classes, so it stays out then.
function Test-W3CpcInstalled([string]$Root) {
    (Test-Path -LiteralPath (Join-Path $Root 'mods/modCustomPlayerCharacters') -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $Root 'dlc/dlcCustomPlayerCharacters') -PathType Container)
}

function Invoke-W3ModTransaction {
    param([string]$GameDir, [string]$PackageDir, [switch]$Remove, [switch]$PreserveChanges)
    $root = Resolve-W3ModRoot $GameDir
    Assert-W3GameClosed
    $dir = Join-Path $root '.w3lan-install'; Assert-W3PlainPath $dir
    [void][IO.Directory]::CreateDirectory($dir)
    $lockPath = Join-Path $dir 'install.lock'; Assert-W3PlainPath $lockPath
    try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'Another mod operation is running, or the game folder is not writable. Close it or run this installer as administrator if required.' }
    try {
        $script:W3AtomicDirectory = Join-Path $dir 'atomic'
        Clear-W3AtomicStaging
        Restore-W3Pending $root
        $old = Read-W3ModState $root
        $active = $null -ne $old -and $old.installed
        if ($Remove -and -not $active) {
            if ($null -eq $old -and (Test-Path -LiteralPath (Join-Path $root 'bin/x64_dx12/WitcherOnlineClient.asi'))) { throw 'This older/manual mod install has no restore record. Its original files cannot be reconstructed by this installer.' }
            return [pscustomobject]@{Action='Remove';ChangedFiles=0;AlreadyRemoved=$true;GameDir=$root}
        }
        $installationId = [Guid]::NewGuid().ToString('N')
        # Keep the save-profile identity after uninstall/reinstall. New ownership
        # still receives fresh backup file IDs, so the new baseline is independent.
        if ($null -ne $old) { $installationId = $old.installationId }
        $transactionId = [Guid]::NewGuid().ToString('N')
        $transaction = Join-Path $dir ('transactions/' + $transactionId)
        [void][IO.Directory]::CreateDirectory($transaction)
        $desired = @{}; $version = ''
        if (-not $Remove) {
            $exeHash = Get-W3FileHash (Join-Path $root 'bin/x64_dx12/witcher3.exe')
            if ($exeHash -cne $script:W3ExpectedExeHash) { throw 'This package requires the verified Steam game build 25773555. The game executable will not be patched.' }
            $package = (Resolve-Path -LiteralPath $PackageDir).Path.TrimEnd('\'); Assert-W3PlainPath $package
            if ($package -ieq $root -or $package.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or $root.StartsWith($package + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Keep the extracted package separate from the game folder.' }
            $manifestPath = Join-Path $package 'mod-manifest.json'; Assert-W3PlainPath $manifestPath
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $version = [string]$manifest.version
            if (-not $version -or $version.Length -gt 96 -or @($manifest.files).Count -eq 0) { throw 'Invalid package manifest.' }
            $payload = Join-Path $package 'mod'; Assert-W3PlainPath $payload
            foreach ($entry in $manifest.files) {
                $source = Get-W3ModPath $payload $entry.path
                if ($desired.ContainsKey($entry.path) -or $entry.sha256 -cnotmatch '\A[a-f0-9]{64}\z') { throw 'Invalid or duplicate manifest entry.' }
                if ((Get-W3FileHash $source) -cne $entry.sha256) { throw "Package checksum mismatch: $($entry.path)" }
                $desired[$entry.path] = @{Hash=$entry.sha256;Source=$source}
            }
            if (@(Get-W3TreeFiles $payload).Count -ne $desired.Count) { throw 'Payload contains files not listed in its manifest.' }
            if (-not $desired.ContainsKey('bin/x64_dx12/w3test.asi')) { throw 'Package is missing its save-profile helper.' }
            if (Test-W3CpcInstalled $root) {
                foreach ($path in @($desired.Keys | Where-Object { $_.StartsWith('mods/modWitcherOnlineCompatCPC/', [StringComparison]::OrdinalIgnoreCase) })) { $desired.Remove($path) }
            }
            $metadata = @{
                '.w3lan-native.json' = [ordered]@{profileApi=1;profileDllSha256=$desired['bin/x64_dx12/w3test.asi'].Hash}
                '.w3lan-managed.json' = [ordered]@{api=1;mode='InPlace';gameRoot=$root;exeSha256=$exeHash;installationId=$installationId}
            }
            foreach ($relative in $metadata.Keys) {
                $source = Join-Path $transaction ([Guid]::NewGuid().ToString('N') + '.metadata')
                [IO.File]::WriteAllText($source, ($metadata[$relative] | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
                $desired[$relative] = @{Hash=(Get-W3FileHash $source);Source=$source}
            }
        }
        $owned = @{}
        if ($active) { foreach ($entry in $old.files) { $owned[$entry.path] = $entry } }
        $paths = @(@($owned.Keys) + @($desired.Keys) | Sort-Object -Unique)
        $entries = @(); $changes = @(); $preserved = @()
        # Preflight every target and original backup before making any game change.
        foreach ($relative in $paths) {
            $target = Get-W3ModPath $root $relative $true
            $current = Get-W3FileHash $target
            if ($owned.ContainsKey($relative)) {
                $entry = $owned[$relative]
                if ($null -ne $entry.originalHash) {
                    $backup = Join-Path $dir $entry.backup
                    if ((Get-W3FileHash $backup) -cne $entry.originalHash) { throw "Original backup is missing or corrupt: $relative" }
                }
                if ($current -cne $entry.installedHash) {
                    if (-not $PreserveChanges) { throw "File changed outside this installer: $relative. Keep a copy and rerun with -PreserveChanges to continue." }
                    if ($null -ne $current) {
                        $saved = Join-Path $dir ('preserved/' + $transactionId + '/' + $relative)
                        Copy-W3Verified $target $saved $current; $preserved += $relative
                    }
                }
            } else {
                $backupRelative = $null
                if ($null -ne $current) {
                    $backupRelative = 'originals/' + $installationId + '/' + [Guid]::NewGuid().ToString('N') + '.bin'
                    Copy-W3Verified $target (Join-Path $dir $backupRelative) $current
                }
                $entry = [pscustomobject]@{path=$relative;originalHash=$current;backup=$backupRelative;installedHash=$null}
            }
            if ($desired.ContainsKey($relative)) {
                $nextHash = $desired[$relative].Hash; $source = $desired[$relative].Source
                $entries += [ordered]@{path=$relative;originalHash=$entry.originalHash;backup=$entry.backup;installedHash=$nextHash}
            } else {
                $nextHash = $entry.originalHash; $source = $null
                if ($null -ne $nextHash) { $source = Join-Path $dir $entry.backup }
            }
            if ($current -ceq $nextHash) { continue }
            $snapshotRelative = $null
            if ($null -ne $current) {
                $snapshotRelative = 'transactions/' + $transactionId + '/' + [Guid]::NewGuid().ToString('N') + '.before'
                Copy-W3Verified $target (Join-Path $dir $snapshotRelative) $current
            }
            $staged = $null
            if ($null -ne $nextHash) {
                $staged = Join-Path $transaction ([Guid]::NewGuid().ToString('N') + '.after')
                Copy-W3Verified $source $staged $nextHash
            }
            $changes += [ordered]@{path=$relative;beforeHash=$current;afterHash=$nextHash;snapshot=$snapshotRelative;staged=$staged}
        }
        $newState = [ordered]@{api=1;gameRoot=$root;installationId=$installationId;installed=(-not $Remove);version=$version;files=@($entries)}
        $nextState = Join-Path $transaction 'next-state.json'
        [IO.File]::WriteAllText($nextState, ($newState | ConvertTo-Json -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
        $journal = [ordered]@{api=1;gameRoot=$root;transactionId=$transactionId;oldStateHash=(Get-W3FileHash (Join-Path $dir 'state.json'));nextStateHash=(Get-W3FileHash $nextState);files=@($changes | ForEach-Object {[ordered]@{path=$_.path;beforeHash=$_.beforeHash;afterHash=$_.afterHash;snapshot=$_.snapshot}})}
        $pendingPath = Join-Path $dir 'pending.json'
        Write-W3Json $journal $pendingPath
        try {
            Assert-W3GameClosed
            foreach ($change in $changes) {
                $target = Get-W3ModPath $root $change.path $true
                if ((Get-W3FileHash $target) -cne $change.beforeHash) { throw "File changed during preparation: $($change.path)" }
                if ($null -eq $change.afterHash) { [IO.File]::Delete($target) }
                else { Write-W3AtomicFile $change.staged $target }
                if ((Get-W3FileHash $target) -cne $change.afterHash) { throw 'Installed file readback failed.' }
            }
            Write-W3AtomicFile $nextState (Join-Path $dir 'state.json')
            [IO.File]::Delete($pendingPath)
        } catch {
            $failure = $_.Exception.Message
            try { Restore-W3Pending $root } catch { throw "Operation stopped: $failure. Automatic rollback needs attention: $($_.Exception.Message). Backups and journal retained." }
            throw "Operation failed and its file changes were rolled back: $failure"
        }
        try { Clear-W3TransactionStaging $root $transactionId } catch { Write-Warning 'Install state is complete; temporary staging was retained.' }
        [pscustomobject]@{Action=$(if($Remove){'Remove'}elseif($active){'Update'}else{'Install'});GameDir=$root;ChangedFiles=$changes.Count;PreservedFiles=$preserved.Count;Backups=$dir;InstallationId=$installationId}
    } finally {
        try { Clear-W3AtomicStaging } catch { Write-Warning 'Temporary atomic-write staging was retained for later cleanup.' }
        $script:W3AtomicDirectory = $null
        $lock.Dispose()
    }
}

function Install-W3LanMod {
    param([Parameter(Mandatory)][string]$GameDir, [Parameter(Mandatory)][string]$PackageDir, [switch]$PreserveChanges)
    Invoke-W3ModTransaction -GameDir $GameDir -PackageDir $PackageDir -PreserveChanges:$PreserveChanges
}

function Remove-W3LanMod {
    param([Parameter(Mandatory)][string]$GameDir, [switch]$PreserveChanges)
    Invoke-W3ModTransaction -GameDir $GameDir -Remove -PreserveChanges:$PreserveChanges
}

Export-ModuleMember -Function Install-W3LanMod, Remove-W3LanMod, Get-W3ModStatus, Test-W3CpcInstalled
