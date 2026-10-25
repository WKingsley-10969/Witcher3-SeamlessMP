# Experimental campaign bootstrap. Credentials are local protected state, not source artifacts.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'W3Lan.psm1')
Import-Module (Join-Path $PSScriptRoot 'W3LanProfile.psm1')
if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) { Add-Type -AssemblyName System.Security }
if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData }

function Assert-W3SeamlessBuild {
    param([Parameter(Mandatory)][string]$GameDir, [string]$ServerJar)
    $root = (Resolve-Path -LiteralPath $GameDir).Path.TrimEnd('\')
    $markerPath = Join-Path $root '.w3lan-seamless.json'
    Assert-W3CampaignPath $root $markerPath
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { throw 'The experimental seamless build marker is missing. Build/stage the new sources into the verified test copy first.' }
    try { $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json }
    catch { throw 'Experimental seamless marker is malformed.' }
    if ($marker.api -ne 1 -or $marker.protocol -ne 1) { throw 'Unsupported experimental seamless marker/protocol.' }
    $expected = @('bin/x64_dx12/WitcherOnlineClient.asi','bin/x64_dx12/WitcherNativeBridge.asi',
        'mods/modWitcherOnline/content/scripts/local/seamlessCampaign.ws','mods/modWitcherOnline/content/scripts/local/seamlessEffects.ws',
        'mods/modWitcherOnline/content/scripts/local/client.ws','mods/modWitcherOnline/content/scripts/local/anno.ws','mods/modWitcherOnline/content/scripts/local/coopEnemies.ws',
        'mods/modWitcherOnline/content/scripts/local/sceneFactCapture.ws')
    $properties = @($marker.files.PSObject.Properties)
    if ($properties.Count -ne $expected.Count) { throw 'Experimental marker file set differs from this launcher.' }
    foreach ($relative in $expected) {
        $property = @($properties | Where-Object { $_.Name -ceq $relative })
        if ($property.Count -ne 1 -or $property[0].Value -cnotmatch '\A[a-f0-9]{64}\z') { throw 'Experimental marker contains an invalid file/hash.' }
        $path = Join-Path $root $relative
        Assert-W3CampaignPath $root $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $property[0].Value) { throw "Experimental build file changed or is missing: $relative" }
    }
    $exe = Join-Path $root 'bin/x64_dx12/witcher3.exe'
    if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -cne $marker.exeSha256) { throw 'Experimental marker targets a different game executable.' }
    if ($ServerJar) {
        if (-not (Test-Path -LiteralPath $ServerJar -PathType Leaf) -or (Get-FileHash -LiteralPath $ServerJar -Algorithm SHA256).Hash.ToLowerInvariant() -cne $marker.serverJarSha256) { throw 'The server JAR differs from the staged experimental build.' }
    }
}

function Assert-W3CampaignPath {
    param([string]$Root, [string]$Path)
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $target = [IO.Path]::GetFullPath($Path)
    if ($target -ine $base -and -not $target.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Campaign path escapes the verified game copy.' }
    $part = $target
    while ($part) {
        if ((Test-Path -LiteralPath $part) -and ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Campaign paths must not contain links or junctions.' }
        if ($part -ieq $base) { break }
        $part = Split-Path -Parent $part
    }
}

function New-W3CampaignSecret {
    param([int]$Bytes)
    $buffer = New-Object byte[] $Bytes
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buffer); return ([BitConverter]::ToString($buffer)).Replace('-', '').ToLowerInvariant() }
    finally { $rng.Dispose() }
}

function Protect-W3CampaignValue {
    param([string]$Value, [string]$Purpose)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $entropy = [Text.Encoding]::UTF8.GetBytes('W3LanCampaign-v1:' + $Purpose)
    [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($bytes, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser))
}

function Unprotect-W3CampaignValue {
    param([string]$Value, [string]$Purpose, [int]$Length)
    try {
        $bytes = [Convert]::FromBase64String($Value)
        $entropy = [Text.Encoding]::UTF8.GetBytes('W3LanCampaign-v1:' + $Purpose)
        $plain = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($bytes, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser))
        if ($plain.Length -ne $Length -or $plain -cnotmatch '\A[a-f0-9]+\z') { throw 'Invalid credential shape' }
        return $plain
    } catch { throw 'Campaign credential is corrupt, belongs to another Windows user, or its identity binding changed. Restore the existing state; it will not be silently replaced.' }
}

function Write-W3CampaignState {
    param([string]$Path, [object]$State)
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $bytes = [Text.Encoding]::UTF8.GetBytes(($State | ConvertTo-Json -Depth 6))
    try {
        $file = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
        if (Test-Path -LiteralPath $Path) {
            # Windows PowerShell 5.1 binds a null backup filename as an invalid
            # empty path. Keep the prior protected state as a recovery artifact.
            $backup = $Path + '.previous'
            if ((Test-Path -LiteralPath $backup) -and ((Get-Item -LiteralPath $backup -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Campaign backup must not be a link.' }
            [IO.File]::Replace($temporary, $Path, $backup)
        }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Read-W3CampaignState {
    param([string]$Path, [string]$CampaignName, [string]$HostName, [bool]$Voting, [bool]$SharedXp)
    try {
        if ((Get-Item -LiteralPath $Path).Length -gt 1048576) { throw 'Oversize state' }
        $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($state.Format -ne 1 -or $state.CampaignName -cne $CampaignName -or $state.HostName -ine $HostName -or
            $state.Voting -isnot [bool] -or $state.SharedXp -isnot [bool] -or $state.Voting -ne $Voting -or $state.SharedXp -ne $SharedXp -or
            $state.TieBreak -cne 'initiator' -or $state.UniqueRewards -cne 'completer' -or @($state.Players).Count -gt 64) { throw 'State identity or policy changed' }
        if ($state.HostProof -isnot [string]) { throw 'Missing proof field' }
        if ($state.HostProof -ne '') { [void][Convert]::FromBase64String($state.HostProof) }
        $seen = @{}
        foreach ($player in @($state.Players)) {
            Assert-W3LanName $player.Name
            if ($seen.ContainsKey($player.Name.ToLowerInvariant()) -or $player.Role -notin @('host','guest') -or $player.Session -isnot [string]) { throw 'Invalid player identity' }
            if (($player.Role -eq 'host') -ne ($player.Name -ieq $HostName)) { throw 'Role mismatch' }
            [void][Convert]::FromBase64String($player.Session)
            $seen[$player.Name.ToLowerInvariant()] = $true
        }
        return $state
    } catch { throw 'Campaign state is malformed or its host/policy identity differs. Restore it or choose a different campaign name; existing state will not be reset.' }
}

function Get-W3CampaignContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GameDir,
        [Parameter(Mandatory)][ValidateSet('Host','Join')][string]$Mode,
        [Parameter(Mandatory)][ValidatePattern('\A[a-z0-9][a-z0-9_-]{1,31}\z')][string]$CampaignName,
        [Parameter(Mandatory)][string]$PlayerName,
        [Parameter(Mandatory)][string]$HostName,
        [bool]$Voting = $true,
        [bool]$SharedXp = $true,
        [switch]$Plan
    )
    Assert-W3LanName $PlayerName
    Assert-W3LanName $HostName
    if (($Mode -eq 'Host') -ne ($PlayerName -ieq $HostName)) { throw 'Host mode must use the configured host name; guests must use a different name.' }
    $root = (Resolve-Path -LiteralPath $GameDir).Path.TrimEnd('\')
    # Validate the real copy/hash/hook before creating campaign files; Plan never seeds saves.
    [void](New-W3LanProfileStartInfo -GameDir $root -PlayerName $PlayerName -Address '127.0.0.1' -CampaignName $CampaignName -Plan)
    Assert-W3SeamlessBuild -GameDir $root
    $directory = Join-Path $root ('.w3lan-campaigns\' + $CampaignName)
    $path = Join-Path $directory 'campaign.json'
    $serverPath = Join-Path $directory 'state'
    Assert-W3CampaignPath $root $path
    Assert-W3CampaignPath $root $serverPath
    $state = $null
    if (Test-Path -LiteralPath $path) { $state = Read-W3CampaignState $path $CampaignName $HostName $Voting $SharedXp }
    elseif (Test-Path -LiteralPath (Join-Path $serverPath 'campaign.bin')) { throw 'Campaign credential state is missing beside an existing server ledger. Restore it; do not create replacement identities.' }
    $role = if ($Mode -eq 'Host') { 'host' } else { 'guest' }
    $purpose = $CampaignName + ':' + $HostName.ToLowerInvariant()
    $identityPurpose = $purpose + ':' + $PlayerName.ToLowerInvariant() + ':' + $role
    $session = ''
    $proof = $null
    $fileLock = $null
    try {
        if (-not $Plan) {
            [void][IO.Directory]::CreateDirectory($directory)
            $lockPath = Join-Path $directory 'bootstrap.lock'
            Assert-W3CampaignPath $root $lockPath
            try { $fileLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
            catch { throw 'Another launcher is updating this campaign. Wait for it to finish.' }
            # Re-read under lock: another launcher may have created an identity since the preview.
            if (Test-Path -LiteralPath $path) { $state = Read-W3CampaignState $path $CampaignName $HostName $Voting $SharedXp }
        }
        $changed = $false
        if (-not $state) {
            $state = [pscustomobject]@{Format=1; CampaignName=$CampaignName; HostName=$HostName; Voting=$Voting; SharedXp=$SharedXp; TieBreak='initiator'; UniqueRewards='completer'; HostProof=''; Players=@()}
            if (-not $Plan -and $Mode -eq 'Host') { $state.HostProof = Protect-W3CampaignValue (New-W3CampaignSecret 32) ($purpose + ':host-proof') }
            $changed = $true
        }
        if ($Mode -eq 'Host' -and $state.HostProof -eq '' -and -not ($Plan -and $changed)) { throw 'This local campaign has no host credential. A join-only campaign cannot silently become the host.' }
        $player = @($state.Players | Where-Object { $_.Name -ieq $PlayerName })
        if ($player.Count -gt 1) { throw 'Duplicate campaign identity' }
        if ($player.Count -eq 1) {
            if ($player[0].Role -cne $role) { throw 'Campaign player role changed.' }
            $session = Unprotect-W3CampaignValue $player[0].Session $identityPurpose 32
        } elseif (-not $Plan) {
            if (@($state.Players).Count -ge 64) { throw 'Campaign participant limit reached.' }
            $session = New-W3CampaignSecret 16
            $state.Players = @($state.Players) + [pscustomobject]@{Name=$PlayerName; Role=$role; Session=(Protect-W3CampaignValue $session $identityPurpose)}
            $changed = $true
        }
        if ($Mode -eq 'Host' -and $state.HostProof -ne '') {
            $plainProof = Unprotect-W3CampaignValue $state.HostProof ($purpose + ':host-proof') 64
            $proof = ConvertTo-SecureString -String $plainProof -AsPlainText -Force
            $plainProof = $null
        }
        if ($changed -and -not $Plan) { Write-W3CampaignState $path $state }
        [pscustomobject]@{CampaignName=$CampaignName; HostName=$HostName; PlayerName=$PlayerName; Role=$role; GameDir=$root; CampaignDirectory=$directory; ServerStateDirectory=$serverPath; StatePath=$path; SessionId=$session; HostToken=$proof; Voting=$Voting; SharedXp=$SharedXp; IsPlan=[bool]$Plan; WouldCreate=$changed}
    } finally { if ($fileLock) { $fileLock.Dispose() } }
}

function Set-W3CampaignClientEnvironment {
    param([Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$StartInfo, [Parameter(Mandatory)][object]$Context)
    if ($Context.IsPlan -or $Context.SessionId -cnotmatch '\A[a-f0-9]{32}\z') { throw 'Initialize a real campaign context before assigning child credentials.' }
    foreach ($key in @($StartInfo.EnvironmentVariables.Keys)) {
        if ($key.StartsWith('WO_SC_', [StringComparison]::OrdinalIgnoreCase) -or $key.StartsWith('W3T_', [StringComparison]::OrdinalIgnoreCase) -or $key -ieq 'WO_CAMPAIGN_HOST_TOKEN') { $StartInfo.EnvironmentVariables.Remove($key) }
    }
    $StartInfo.EnvironmentVariables['WO_SC_ENABLED'] = '1'
    $StartInfo.EnvironmentVariables['WO_SC_EFFECTS'] = '0'
    $StartInfo.EnvironmentVariables['WO_SC_ROLE'] = $Context.Role
    $StartInfo.EnvironmentVariables['WO_SC_SESSION'] = $Context.SessionId
    if ($Context.Role -eq 'host') {
        if (-not $Context.HostToken) { throw 'Host proof is missing.' }
        $StartInfo.EnvironmentVariables['WO_SC_HOST_TOKEN'] = ([Net.NetworkCredential]::new('', $Context.HostToken)).Password
    }
    # The profile constructor supplies this verified path; keep only the native
    # isolation log from the W3T namespace, never inherited bot controls.
    $documents = $StartInfo.EnvironmentVariables['W3LAN_DOCUMENTS']
    if (-not $documents) { throw 'Verified isolated Documents path missing from game start info.' }
    Assert-W3CampaignPath $Context.GameDir $documents
    $StartInfo.EnvironmentVariables['W3T_LOG'] = Join-Path $documents 'native.log'
}

function Invoke-W3CampaignGameSlot {
    param(
        [Parameter(Mandatory)][ValidateSet('acquire','register-pid','release')][string]$Operation,
        [Parameter(Mandatory)][ValidatePattern('\A[a-z0-9-]{1,64}\z')][string]$Owner,
        [int]$GameProcessId,
        [string]$PythonPath
    )
    if (-not $PythonPath) { $PythonPath = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' }
    if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) { throw 'Pass -PythonPath to an existing Python interpreter for the required game lease. No runtime is installed automatically.' }
    $source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\coop-playbook\tools\gameslot\gameslot.py'))
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -cne '7a939829c6a782c774226a5c72f4137c1b94af60730d02c75b6251bfd2ceaf3d') { throw 'Required pinned gameslot source is missing or changed.' }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Resolve-Path -LiteralPath $PythonPath).Path
    $info.Arguments = '-I "' + $source + '" ' + $Operation + ' --owner ' + $Owner
    if ($Operation -eq 'acquire') { $info.Arguments += ' --slots 1 --ttl 900 --wait 0' }
    if ($Operation -eq 'register-pid') {
        if ($GameProcessId -le 0) { throw 'A launched game PID is required.' }
        $info.Arguments += ' --pid ' + $GameProcessId
    }
    $info.EnvironmentVariables['GAMESLOT_DIR'] = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\local\gameslot'))
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Game lease helper failed to start.' }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Game lease helper timed out.' }
        if ($process.ExitCode -ne 0) { throw ('Game lease rejected: ' + ($stdout + $stderr).Trim()) }
    } finally { $process.Dispose() }
}

function Wait-W3CampaignGame {
    param([Parameter(Mandatory)][Diagnostics.Process]$Game, [Diagnostics.Process]$Server, [scriptblock]$RenewLease)
    $renewAt = [DateTime]::UtcNow.AddMinutes(5)
    while (-not $Game.WaitForExit(500)) {
        if ($Server -and $Server.HasExited) { throw "The host server stopped (code $($Server.ExitCode)); the owned game session is being closed to prevent unsynchronized play." }
        if ($RenewLease -and [DateTime]::UtcNow -ge $renewAt) { & $RenewLease; $renewAt = [DateTime]::UtcNow.AddMinutes(5) }
    }
    if ($Server -and $Server.HasExited) { throw "The host server stopped (code $($Server.ExitCode))." }
    return $Game.ExitCode
}

Export-ModuleMember -Function Get-W3CampaignContext, Set-W3CampaignClientEnvironment, Assert-W3SeamlessBuild, Invoke-W3CampaignGameSlot, Wait-W3CampaignGame
