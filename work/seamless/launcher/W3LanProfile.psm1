# Human-play profile preparation. This never stages mods into the original game.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'W3Lan.psm1')

function New-W3LanProfileStartInfo {
    param(
        [Parameter(Mandatory)][string]$GameDir,
        [Parameter(Mandatory)][string]$PlayerName,
        [Parameter(Mandatory)][string]$Address,
        [ValidateRange(1,65535)][int]$Port = 40000,
        [string]$SeedDirectory,
        [ValidatePattern('\A[a-z0-9][a-z0-9_-]{1,31}\z')][string]$CampaignName,
        [switch]$Plan
    )
    Assert-W3LanName $PlayerName
    $ip = Resolve-W3LanAddress $Address
    $root = (Resolve-Path -LiteralPath $GameDir).Path.TrimEnd('\')
    $markerPath = Join-Path $root '.w3lan-test-copy.json'
    $nativePath = Join-Path $root '.w3lan-native.json'
    if (-not (Test-Path -LiteralPath $markerPath) -or -not (Test-Path -LiteralPath $nativePath)) {
        throw 'Use the verified isolated game copy with the LAN profile hook. This launcher does not install the mod into your normal game.'
    }
    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    $native = Get-Content -LiteralPath $nativePath -Raw | ConvertFrom-Json
    if ($marker.TestCopy -ne $true -or [IO.Path]::GetFullPath($marker.OriginalPath).TrimEnd('\') -ieq $root) { throw 'Invalid test-copy marker.' }
    $exe = Join-Path $root 'bin\x64_dx12\witcher3.exe'
    $hook = Join-Path $root 'bin\x64_dx12\w3test.asi'
    if ($native.profileApi -ne 1) { throw 'Unsupported LAN profile-hook version.' }
    if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $marker.ExeSha256) { throw 'Game executable changed; identify the build again before launching.' }
    if ((Get-FileHash -LiteralPath $hook -Algorithm SHA256).Hash.ToLowerInvariant() -ne $native.profileDllSha256) { throw 'Save-isolation hook changed; rebuild/stage it before launching.' }
    foreach ($relative in @('bin\x64_dx12\dinput8.dll','bin\x64_dx12\WitcherNativeBridge.asi','bin\x64_dx12\WitcherOnlineClient.asi','mods\modWitcherOnline','mods\modWitcherOnlineCompat','dlc\dlcWitcherOnline')) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $relative))) { throw "Missing mod component: $relative" }
    }
    $documents = Join-Path $root ('.w3lan-profiles\' + $PlayerName)
    if ($CampaignName) { $documents = Join-Path $documents ('campaigns\' + $CampaignName) }
    if ($documents.Length -ge 240) { throw 'Use a shorter test-game folder so the isolated profile remains below MAX_PATH.' }
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
    if (-not $Plan -and -not (Test-Path -LiteralPath $initialized)) {
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
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $exe
    $info.WorkingDirectory = Split-Path -Parent $exe
    $info.UseShellExecute = $false
    $info.Arguments = '-windowed -width 960 -height 540 -noraytracing'
    foreach ($key in @($info.EnvironmentVariables.Keys)) {
        if ($key.StartsWith('W3T_', [StringComparison]::OrdinalIgnoreCase) -or $key.StartsWith('WO_SC_', [StringComparison]::OrdinalIgnoreCase) -or $key -ieq 'WO_CAMPAIGN_HOST_TOKEN') { $info.EnvironmentVariables.Remove($key) }
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
