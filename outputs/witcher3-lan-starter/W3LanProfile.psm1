# Human-play profile preparation. Managed installs and isolated copies use separate co-op saves.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'W3Lan.psm1')

function New-W3LanProfileStartInfo {
    param(
        [Parameter(Mandatory)][string]$GameDir,
        [Parameter(Mandatory)][string]$PlayerName,
        [Parameter(Mandatory)][string]$Address,
        [ValidateRange(1,65535)][int]$Port = 40000,
        [string]$SeedDirectory
    )
    Assert-W3LanName $PlayerName
    $ip = Resolve-W3LanAddress $Address
    $root = (Resolve-Path -LiteralPath $GameDir).Path.TrimEnd('\')
    $markerPath = Join-Path $root '.w3lan-test-copy.json'
    $managedPath = Join-Path $root '.w3lan-managed.json'
    $nativePath = Join-Path $root '.w3lan-native.json'
    if (Test-Path -LiteralPath (Join-Path $root '.w3lan-install/pending.json')) { throw 'A mod operation was interrupted. Run Manage Mod.cmd to recover it before launching.' }
    if (-not (Test-Path -LiteralPath $nativePath)) {
        throw 'Install the LAN mod with Manage Mod.cmd, or use a verified isolated copy.'
    }
    $profileBase = Join-Path $root '.w3lan-profiles'
    if (Test-Path -LiteralPath $managedPath) {
        Import-Module (Join-Path $PSScriptRoot 'W3ModInstall.psm1')
        $status = Get-W3ModStatus -GameDir $root
        if (-not $status.Installed -or $status.NeedsRecovery) { throw 'Mod installation is incomplete. Run Manage Mod.cmd to finish or restore it.' }
        $managed = Get-Content -LiteralPath $managedPath -Raw | ConvertFrom-Json
        $record = @($status.Record.files | Where-Object {$_.path -ceq '.w3lan-managed.json'})
        if ($record.Count -ne 1 -or (Get-FileHash -LiteralPath $managedPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $record[0].installedHash -or
            $managed.api -ne 1 -or $managed.mode -cne 'InPlace' -or $managed.gameRoot -ine $root -or $managed.installationId -cne $status.Record.installationId) { throw 'Invalid managed-install marker.' }
        $marker = [pscustomobject]@{ExeSha256=$managed.exeSha256}
        if (Test-Path -LiteralPath $markerPath) {
            # Adopting an existing isolated copy keeps its current co-op profiles.
            $copyMarker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            if ($copyMarker.TestCopy -ne $true -or [IO.Path]::GetFullPath($copyMarker.OriginalPath).TrimEnd('\') -ieq $root -or $copyMarker.ExeSha256 -cne $managed.exeSha256) { throw 'Invalid test-copy marker.' }
        } else {
            if (-not $env:LOCALAPPDATA -or -not [IO.Path]::IsPathRooted($env:LOCALAPPDATA)) { throw 'Local application-data folder is unavailable for co-op saves.' }
            $profileBase = Join-Path $env:LOCALAPPDATA ('W3LAN\profiles\' + $managed.installationId)
        }
    } else {
        if (-not (Test-Path -LiteralPath $markerPath)) { throw 'No managed installation or verified test-copy marker. Run Manage Mod.cmd first.' }
        $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        if ($marker.TestCopy -ne $true -or [IO.Path]::GetFullPath($marker.OriginalPath).TrimEnd('\') -ieq $root) { throw 'Invalid test-copy marker.' }
    }
    $native = Get-Content -LiteralPath $nativePath -Raw | ConvertFrom-Json
    $exe = Join-Path $root 'bin\x64_dx12\witcher3.exe'
    $hook = Join-Path $root 'bin\x64_dx12\w3test.asi'
    if ($native.profileApi -ne 1) { throw 'Unsupported LAN profile-hook version.' }
    if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $marker.ExeSha256) { throw 'Game executable changed; identify the build again before launching.' }
    if ((Get-FileHash -LiteralPath $hook -Algorithm SHA256).Hash.ToLowerInvariant() -ne $native.profileDllSha256) { throw 'Save-isolation hook changed; rebuild/stage it before launching.' }
    foreach ($relative in @('bin\x64_dx12\dinput8.dll','bin\x64_dx12\WitcherNativeBridge.asi','bin\x64_dx12\WitcherOnlineClient.asi','mods\modWitcherOnline','mods\modWitcherOnlineCompat','dlc\dlcWitcherOnline')) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $relative))) { throw "Missing mod component: $relative" }
    }
    $documents = Join-Path $profileBase $PlayerName
    if ($documents.Length -ge 240) { throw 'The co-op save profile path is too long.' }
    # Existing links could redirect game writes; inspect ancestors and the profile tree.
    $parent = $documents
    while ($parent -and $parent -ine $root) {
        if ((Test-Path -LiteralPath $parent) -and ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Profile paths must not contain junctions or symbolic links.' }
        $parent = Split-Path -Parent $parent
    }
    if ((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Game-copy root must not be a link.' }
    if (Test-Path -LiteralPath $documents) {
        $links = @(Get-ChildItem -LiteralPath $documents -Force -Recurse | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint})
        if ($links.Count) { throw 'Profile contains a link; refusing to launch.' }
    }
    $w3 = Join-Path $documents 'The Witcher 3'
    $initialized = Join-Path $documents '.profile-ready.json'
    if (-not (Test-Path -LiteralPath $initialized)) {
        if (-not $SeedDirectory) { $SeedDirectory = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'The Witcher 3' }
        [void][IO.Directory]::CreateDirectory((Join-Path $w3 'gamesaves'))
        foreach ($name in @('dx12user.settings','input.settings','profile.settings','mods.settings')) {
            $source = Join-Path $SeedDirectory $name
            $target = Join-Path $w3 $name
            if ((Test-Path -LiteralPath $source -PathType Leaf) -and -not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $source -Destination $target }
        }
        $seedSaves = Join-Path $SeedDirectory 'gamesaves'
        if (Test-Path -LiteralPath $seedSaves) {
            foreach ($file in Get-ChildItem -LiteralPath $seedSaves -File | Where-Object {$_.Extension -in '.sav','.png','.json'}) {
                $target = Join-Path $w3 ('gamesaves\' + $file.Name)
                if (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $file.FullName -Destination $target }
            }
        }
        @{PlayerName=$PlayerName; ProfileOnly=$true} | ConvertTo-Json | Set-Content -LiteralPath $initialized -Encoding utf8
    }
    # Custom Player Characters' key bindings (its add_to_input.settings.txt, extracted into the game
    # folder with the mod) in this co-op profile's input.settings, once: the profile's settings are a
    # copy made when it was created, so bindings added to the normal settings later never reach it.
    $cpcBindings = Join-Path $root 'add_to_input.settings.txt'
    $profileInput = Join-Path $w3 'input.settings'
    if ((Test-Path -LiteralPath (Join-Path $root 'mods\modCustomPlayerCharacters') -PathType Container) -and (Test-Path -LiteralPath $cpcBindings -PathType Leaf)) {
        if (-not (Test-Path -LiteralPath $profileInput -PathType Leaf)) {
            Write-Warning 'This co-op profile has no input.settings yet: Custom Player Characters key bindings are added on the next launch.'
        } elseif (-not (Select-String -LiteralPath $profileInput -SimpleMatch 'Action=NRUse' -Quiet)) {
            [IO.File]::AppendAllText($profileInput, [Environment]::NewLine + [IO.File]::ReadAllText($cpcBindings))
        }
    }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $exe
    $info.WorkingDirectory = Split-Path -Parent $exe
    $info.UseShellExecute = $false
    # no window, resolution or ray-tracing options: the player's own graphics settings apply (the
    # bot harness, run_test.py, sizes its side-by-side windows itself)
    $info.Arguments = ''
    foreach ($key in @($info.EnvironmentVariables.Keys)) {
        if ($key.StartsWith('W3T_', [StringComparison]::OrdinalIgnoreCase) -or $key.StartsWith('WO_SC_', [StringComparison]::OrdinalIgnoreCase) -or $key.StartsWith('W3LAN_SESSION_', [StringComparison]::OrdinalIgnoreCase)) { $info.EnvironmentVariables.Remove($key) }
    }
    $info.EnvironmentVariables['W3LAN_DOCUMENTS'] = $documents
    $info.EnvironmentVariables['W3T_LOG'] = Join-Path $documents 'native.log'
    $info.EnvironmentVariables['WO_USERNAME'] = $PlayerName
    $info.EnvironmentVariables['WO_SERVER_IP'] = $ip
    $info.EnvironmentVariables['WO_SERVER_PORT'] = $Port.ToString()
    $info.EnvironmentVariables['SteamAppId'] = '292030'
    $info.EnvironmentVariables['SteamGameId'] = '292030'
    return $info
}
Export-ModuleMember -Function New-W3LanProfileStartInfo
