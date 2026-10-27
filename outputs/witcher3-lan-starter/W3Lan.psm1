# LAN launcher helpers. No game files, persistent environment or firewall changes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-W3LanName {
    param([Parameter(Mandatory)][string]$PlayerName)
    if ($PlayerName -cnotmatch '\A[A-Za-z0-9_]{2,16}\z' -or $PlayerName -ieq 'none') {
        throw 'Use a distinct player name of 2-16 ASCII letters, digits or underscores; none is reserved.'
    }
}

function Resolve-W3LanAddress {
    param([Parameter(Mandatory)][string]$Address)
    if ($Address -notmatch '\A(\d{1,3}\.){3}\d{1,3}\z') { throw 'Enter a private IPv4 address, such as 192.168.1.20.' }
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$parsed)) { throw 'Invalid IPv4 address.' }
    $b = $parsed.GetAddressBytes()
    if ($b.Count -ne 4 -or $parsed.ToString() -cne $Address) { throw 'Use the full IPv4 address without leading zeroes.' }
    $private = $b[0] -eq 10 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168)
    if (-not $private -and $Address -ne '127.0.0.1') { throw 'This launcher accepts private LAN IPv4 addresses or 127.0.0.1 only.' }
    $parsed.ToString()
}

function Get-W3LanAddresses {
    [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq 'Up' } |
        ForEach-Object {
            $adapter = $_
            foreach ($entry in $adapter.GetIPProperties().UnicastAddresses) {
                try {
                    $ip = Resolve-W3LanAddress $entry.Address.ToString()
                    if ($ip -ne '127.0.0.1') { [pscustomobject]@{ Adapter = $adapter.Name; Address = $ip } }
                } catch { }
            }
        }
}

function Find-W3LanJava {
    param([string]$JavaPath)
    $candidates = @()
    if ($JavaPath) { $candidates += $JavaPath }
    else {
        if ($env:W3LAN_JAVA) { $candidates += $env:W3LAN_JAVA }
        $candidates += Join-Path $PSScriptRoot 'runtime\bin\java.exe'
        if ($env:JAVA_HOME) { $candidates += Join-Path $env:JAVA_HOME 'bin\java.exe' }
        $command = Get-Command java.exe -ErrorAction SilentlyContinue
        if ($command) { $candidates += $command.Source }
        # Optional local development tool; absent when the standalone starter is moved.
        $tooling = Join-Path $PSScriptRoot '..\..\work\tooling'
        if (Test-Path -LiteralPath $tooling) {
            $candidates += @(Get-ChildItem -LiteralPath $tooling -Directory | ForEach-Object { Join-Path $_.FullName 'bin\java.exe' })
        }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    throw 'Java not found. Supply -JavaPath <java.exe>, set JAVA_HOME, or put a portable JDK in runtime. No software is installed automatically.'
}

function Test-W3LanEndpoint {
    param(
        [Parameter(Mandatory)][string]$Address,
        [ValidateRange(1,65535)][int]$Port = 40000,
        [ValidateRange(50,10000)][int]$TimeoutMs = 1000
    )
    $ip = Resolve-W3LanAddress $Address
    $udp = [Net.Sockets.UdpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($ip, $Port)
        # A blank username produces an explicit reply without creating a player session.
        $data = [Text.Encoding]::UTF8.GetBytes("MOVE`t ")
        [void]$udp.Send($data, $data.Length)
        $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
        $reply = [Text.Encoding]::UTF8.GetString($udp.Receive([ref]$remote))
        $ok = $reply -ceq "ERROR`tINVALID_USERNAME"
        [pscustomobject]@{ Reachable = $ok; Address = $ip; Port = $Port; Reply = $reply; ElapsedMs = $timer.ElapsedMilliseconds }
    } catch [Net.Sockets.SocketException] {
        [pscustomobject]@{ Reachable = $false; Address = $ip; Port = $Port; Reply = $_.Exception.SocketErrorCode.ToString(); ElapsedMs = $timer.ElapsedMilliseconds }
    } finally { $udp.Dispose() }
}

function Stop-W3LanServer {
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)
    if (-not $Process.HasExited) {
        try {
            $Process.StandardInput.WriteLine('stop')
            $Process.StandardInput.Flush()
        } catch { }
        if (-not $Process.WaitForExit(5000)) { $Process.Kill(); [void]$Process.WaitForExit(3000) }
    }
}

function Start-W3LanServer {
    param(
        [Parameter(Mandatory)][string]$JarPath,
        [string]$JavaPath,
        [ValidateRange(1,65535)][int]$Port = 40000,
        # Co-op session: joining players download the host's newest save from this folder (TCP Port+1)
        [string]$SaveDirectory,
        [string]$HostName
    )
    if (-not (Test-Path -LiteralPath $JarPath -PathType Leaf)) { throw 'Server JAR missing. Run Build-Server.ps1 first.' }
    $jar = (Resolve-Path -LiteralPath $JarPath).Path
    $java = Find-W3LanJava $JavaPath
    $sessionArguments = ''
    if ($SaveDirectory) {
        if (-not (Test-Path -LiteralPath $SaveDirectory -PathType Container)) { throw "Save folder missing: $SaveDirectory" }
        Assert-W3LanName $HostName
        $sessionArguments = ' --save-dir "' + (Resolve-Path -LiteralPath $SaveDirectory).Path + '" --host-name ' + $HostName
    }
    # Fail before starting a second server, including when another compatible server owns this port.
    $reservation = [Net.Sockets.Socket]::new([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Dgram, [Net.Sockets.ProtocolType]::Udp)
    try {
        $reservation.ExclusiveAddressUse = $true
        $reservation.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Any, $Port))
    } catch { throw "UDP port $Port is already in use or unavailable. Choose another port on both PCs." }
    finally { $reservation.Dispose() }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $java
    $info.Arguments = '-Djava.net.preferIPv4Stack=true -jar "' + $jar + '" ' + $Port + $sessionArguments
    $info.WorkingDirectory = Split-Path -Parent $jar
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    try {
        if (-not $process.Start()) { throw 'Java server did not start.' }
        $started = $true
        $ready = $false
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($process.HasExited) { throw "Server exited during startup (code $($process.ExitCode)). Check Java 21+ and the console output." }
            $probe = Test-W3LanEndpoint -Address '127.0.0.1' -Port $Port -TimeoutMs 200
            if ($probe.Reachable) {
                Start-Sleep -Milliseconds 100
                if ($process.HasExited) { throw 'The new server exited during startup.' }
                $ready = $true
                break
            }
        }
        if (-not $ready) { throw 'Server did not answer a compatible UDP probe within 10 seconds.' }
        $process
    } catch {
        if ($started) { Stop-W3LanServer $process }
        $process.Dispose()
        throw
    }
}

function New-W3LanClientEnvironment {
    param(
        [Parameter(Mandatory)][string]$PlayerName,
        [Parameter(Mandatory)][string]$Address,
        [ValidateRange(1,65535)][int]$Port = 40000
    )
    Assert-W3LanName $PlayerName
    $ip = Resolve-W3LanAddress $Address
    # Values only: callers must put these on the isolated game's child process later.
    # Never persist these in the user's environment or silently use the upstream public server.
    @{ WO_USERNAME = $PlayerName; WO_SERVER_IP = $ip; WO_SERVER_PORT = $Port.ToString() }
}

# Co-op session: download the host's newest save (and its thumbnail) into this player's co-op
# save folder. Returns @{ Host; Save } (Save empty when the host has no save yet).
function Copy-W3LanSessionSave {
    param(
        [Parameter(Mandatory)][string]$Address,
        [ValidateRange(1,65535)][int]$Port = 40001,
        [Parameter(Mandatory)][string]$SaveDirectory
    )
    $ip = Resolve-W3LanAddress $Address
    $base = "http://${ip}:$Port/session"
    $fields = @{}
    foreach ($line in ((Invoke-WebRequest -Uri $base -UseBasicParsing -TimeoutSec 5).Content -split "`n")) {
        $at = $line.IndexOf('=')
        if ($at -gt 0) { $fields[$line.Substring(0, $at)] = $line.Substring($at + 1).Trim() }
    }
    $hostName = [string]$fields['host']
    $save = [string]$fields['save']
    if ($hostName) { Assert-W3LanName $hostName }
    if (-not $save) { return @{ Host = $hostName; Save = '' } }
    if ($save -notmatch '^[A-Za-z0-9_.-]{1,120}$') { throw "The host offered an invalid save name." }
    [void][IO.Directory]::CreateDirectory($SaveDirectory)
    foreach ($extension in @('.sav', '.png')) {
        $target = Join-Path $SaveDirectory ($save + $extension)
        $partial = $target + '.download'
        try {
            Invoke-WebRequest -Uri "$base/save/$save$extension" -UseBasicParsing -TimeoutSec 60 -OutFile $partial
        } catch {
            if ($extension -eq '.png') { continue }   # the thumbnail is optional
            throw
        }
        if ($extension -eq '.sav' -and (Get-Item -LiteralPath $partial).Length -ne [long]$fields['size']) {
            Remove-Item -LiteralPath $partial
            throw 'The host save download was incomplete.'
        }
        Move-Item -LiteralPath $partial -Destination $target -Force
    }
    @{ Host = $hostName; Save = $save }
}

# What a player typed last time (names per mode, the host's address), kept per Windows user so a
# new package folder still knows them: %LOCALAPPDATA%\W3LAN\player.json.
function Get-W3LanPlayerSettingsPath {
    if (-not $env:LOCALAPPDATA -or -not [IO.Path]::IsPathRooted($env:LOCALAPPDATA)) { return $null }
    Join-Path $env:LOCALAPPDATA 'W3LAN\player.json'
}

function Get-W3LanPlayerSettings {
    param([string]$Path = (Get-W3LanPlayerSettingsPath))
    # SendLogs: false stops the join launcher sending this PC's co-op logs to the host
    $values = @{ HostName = ''; JoinName = ''; HostAddress = ''; SendLogs = $true }
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        try {
            $stored = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            foreach ($key in @('HostName', 'JoinName', 'HostAddress')) {
                if ($stored.PSObject.Properties.Name -contains $key) { $values[$key] = [string]$stored.$key }
            }
            if ($stored.PSObject.Properties.Name -contains 'SendLogs') { $values['SendLogs'] = [string]$stored.SendLogs -notin @('False', 'false', '0', 'no', 'off') }
        } catch {
            Write-Warning "Ignoring unreadable $Path"
        }
    }
    $values
}

function Set-W3LanPlayerSettings {
    param([string]$Path = (Get-W3LanPlayerSettingsPath), [Parameter(Mandatory)][hashtable]$Values)
    if (-not $Path) { return }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    $Values | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding utf8
}

# Ask, offering the remembered answer (Enter keeps it); again until -Check accepts the answer.
function Read-W3LanValue {
    param([Parameter(Mandatory)][string]$Prompt, [string]$Default, [scriptblock]$Check)
    for (;;) {
        $text = if ($Default) { "$Prompt [$Default] (Enter keeps it)" } else { $Prompt }
        $answer = (Read-Host $text).Trim()
        if (-not $answer) { $answer = $Default }
        if (-not $answer) { continue }
        if (-not $Check) { return $answer }
        try { & $Check $answer; return $answer } catch { Write-Warning $_.Exception.Message }
    }
}

# Co-op logs of the second PC: the join launcher sends this player's game logs to the host's
# server (POST /log on TCP Port+1, LogInbox.java), so the host has them without going to the
# second PC. A log is copied once into <profile>\log-upload\outbox (sent.json keeps the SHA-256 of
# each log queued, so nothing is sent twice) and leaves the outbox when the host has it.
$script:W3LanLogMaxBytes = 8MB
$script:W3LanLogOutboxKeep = 9

# This player's own logs: the profile's native.log and scriptslog.txt, and the mod's log in the game
# folder (bin\WitcherOnline\WitcherOnline_<name>.log, written by WO_Log). Nothing else is sent.
function Get-W3LanLogSources {
    param([Parameter(Mandatory)][string]$Documents, [Parameter(Mandatory)][string]$GameDir, [Parameter(Mandatory)][string]$PlayerName)
    Assert-W3LanName $PlayerName
    @(
        [pscustomobject]@{ Kind = 'native'; Path = (Join-Path $Documents 'native.log') }
        [pscustomobject]@{ Kind = 'scripts'; Path = (Join-Path $Documents 'The Witcher 3\scriptslog.txt') }
        [pscustomobject]@{ Kind = 'mod'; Path = (Join-Path $GameDir "bin\WitcherOnline\WitcherOnline_$PlayerName.log") }
    )
}

function Get-W3LanLogOutbox {
    param([Parameter(Mandatory)][string]$Documents)
    Join-Path $Documents 'log-upload\outbox'
}

# Whether the join launcher sends the logs: not with -NoLogUpload, nor with "SendLogs": false in
# player.json.
function Test-W3LanLogUploadWanted {
    param([switch]$NoLogUpload, [string]$SettingsPath = (Get-W3LanPlayerSettingsPath))
    if ($NoLogUpload) { return $false }
    [bool](Get-W3LanPlayerSettings -Path $SettingsPath)['SendLogs']
}

# Copies each of this player's logs that changed since it was last queued into the outbox (the last
# 8 MB of a larger log). Returns how many were queued.
function Add-W3LanLogsToOutbox {
    param([Parameter(Mandatory)][string]$Documents, [Parameter(Mandatory)][string]$GameDir, [Parameter(Mandatory)][string]$PlayerName)
    $box = Join-Path $Documents 'log-upload'
    $outbox = Get-W3LanLogOutbox $Documents
    $markerPath = Join-Path $box 'sent.json'
    $marker = @{}
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        try { foreach ($entry in (Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json).PSObject.Properties) { $marker[$entry.Name] = [string]$entry.Value } } catch { }
    }
    $queued = 0
    foreach ($source in Get-W3LanLogSources -Documents $Documents -GameDir $GameDir -PlayerName $PlayerName) {
        $item = Get-Item -LiteralPath $source.Path -Force -ErrorAction SilentlyContinue
        if (-not $item -or $item.PSIsContainer -or $item.Length -eq 0) { continue }
        # never follow a link out of the profile or the mod's log folder
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ((Get-Item -LiteralPath $item.DirectoryName -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        $stream = [IO.File]::Open($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $start = [Math]::Max([long]0, $stream.Length - $script:W3LanLogMaxBytes)
            [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
            $bytes = [byte[]]::new($stream.Length - $start)
            $read = 0
            while ($read -lt $bytes.Length) {
                $n = $stream.Read($bytes, $read, $bytes.Length - $read)
                if ($n -le 0) { break }
                $read += $n
            }
            if ($read -lt $bytes.Length) { $bytes = [byte[]]($bytes | Select-Object -First $read) }
        } finally { $stream.Dispose() }
        if ($bytes.Length -eq 0) { continue }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') } finally { $sha.Dispose() }
        if ($marker.ContainsKey($source.Kind) -and $marker[$source.Kind] -ceq $hash) { continue }
        [void][IO.Directory]::CreateDirectory($outbox)
        $target = Join-Path $outbox ($item.LastWriteTime.ToString('yyyyMMdd-HHmmss') + '-' + $source.Kind + '.log')
        [IO.File]::WriteAllBytes($target, $bytes)
        $marker[$source.Kind] = $hash
        $queued++
    }
    if ($queued) {
        $marker | ConvertTo-Json | Set-Content -LiteralPath $markerPath -Encoding utf8
        # a host that never takes them: keep only the newest few
        Get-ChildItem -LiteralPath $outbox -Filter '*.log' -File | Sort-Object Name -Descending | Select-Object -Skip $script:W3LanLogOutboxKeep | Remove-Item -Force
    }
    $queued
}

# Sends the outbox to the host, oldest first; a log leaves the outbox once the host has it.
# Returns Sent, Left (still in the outbox) and Error (why the rest was not sent).
function Send-W3LanLogOutbox {
    param(
        [Parameter(Mandatory)][string]$Address,
        [ValidateRange(1,65535)][int]$Port = 40001,
        [Parameter(Mandatory)][string]$PlayerName,
        [Parameter(Mandatory)][string]$Documents,
        [ValidateRange(100,60000)][int]$ConnectTimeoutMs = 5000
    )
    Assert-W3LanName $PlayerName
    $ip = Resolve-W3LanAddress $Address
    $outbox = Get-W3LanLogOutbox $Documents
    $files = @(Get-ChildItem -LiteralPath $outbox -Filter '*.log' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    $result = [pscustomobject]@{ Sent = 0; Left = $files.Count; Error = '' }
    if (-not $files.Count) { return $result }
    # a missing host fails here, within the connect timeout
    $tcp = [Net.Sockets.TcpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
    try {
        if (-not $tcp.ConnectAsync($ip, $Port).Wait($ConnectTimeoutMs)) {
            $result.Error = "the host $ip did not answer on TCP port $Port within $([Math]::Round($ConnectTimeoutMs / 1000.0, 1)) s"
            return $result
        }
    } catch {
        $result.Error = "the host $ip did not accept a connection on TCP port $Port"
        return $result
    } finally { $tcp.Dispose() }
    foreach ($file in $files) {
        $session = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ($session -cnotmatch '\A[A-Za-z0-9_-]{1,64}\z' -or $file.Length -eq 0 -or $file.Length -gt $script:W3LanLogMaxBytes) {
            Remove-Item -LiteralPath $file.FullName -Force
            $result.Left--
            continue
        }
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $request = [Net.HttpWebRequest]::Create("http://${ip}:$Port/log?name=$PlayerName&session=$session")
        $request.Method = 'POST'
        $request.Proxy = $null
        $request.KeepAlive = $false
        $request.ServicePoint.Expect100Continue = $false
        $request.Timeout = 15000
        $request.ReadWriteTimeout = 30000
        $request.ContentType = 'text/plain'
        $request.ContentLength = $bytes.Length
        try {
            $body = $request.GetRequestStream()
            try { $body.Write($bytes, 0, $bytes.Length) } finally { $body.Dispose() }
            $request.GetResponse().Dispose()
        } catch [Net.WebException] {
            $response = $_.Exception.Response
            if ($response) {
                $status = [int]$response.StatusCode
                $reader = [IO.StreamReader]::new($response.GetResponseStream())
                try { $reply = $reader.ReadToEnd().Trim() } finally { $reader.Dispose(); $response.Dispose() }
                $result.Error = "the host refused it ($status $reply)"
            } else {
                $result.Error = $_.Exception.Message
            }
            return $result
        }
        Remove-Item -LiteralPath $file.FullName -Force
        $result.Sent++
        $result.Left--
    }
    $result
}

# Sends the outbox in the background (a PowerShell runspace), so the game starts at once.
function Start-W3LanLogUpload {
    param([Parameter(Mandatory)][string]$Address, [int]$Port = 40001, [Parameter(Mandatory)][string]$PlayerName, [Parameter(Mandatory)][string]$Documents)
    $shell = [PowerShell]::Create()
    [void]$shell.AddScript({
        param($Module, $Address, $Port, $PlayerName, $Documents)
        Import-Module $Module
        Send-W3LanLogOutbox -Address $Address -Port $Port -PlayerName $PlayerName -Documents $Documents
    }).AddArgument((Join-Path $PSScriptRoot 'W3Lan.psm1')).AddArgument($Address).AddArgument($Port).AddArgument($PlayerName).AddArgument($Documents)
    [pscustomobject]@{ Shell = $shell; Handle = $shell.BeginInvoke() }
}

# After the game: waits for the background upload, queues this session's logs, sends the outbox and
# returns the one line to print ('' when there was nothing to send).
function Send-W3LanSessionLogs {
    param(
        [Parameter(Mandatory)][string]$Address,
        [int]$Port = 40001,
        [Parameter(Mandatory)][string]$PlayerName,
        [Parameter(Mandatory)][string]$Documents,
        [Parameter(Mandatory)][string]$GameDir,
        $Background,
        [int]$ConnectTimeoutMs = 5000
    )
    $sent = 0
    try {
        if ($Background) {
            try {
                foreach ($early in $Background.Shell.EndInvoke($Background.Handle)) { if ($early) { $sent += $early.Sent } }
            } catch { } finally { $Background.Shell.Dispose() }
        }
        [void](Add-W3LanLogsToOutbox -Documents $Documents -GameDir $GameDir -PlayerName $PlayerName)
        $result = Send-W3LanLogOutbox -Address $Address -Port $Port -PlayerName $PlayerName -Documents $Documents -ConnectTimeoutMs $ConnectTimeoutMs
        $sent += $result.Sent
        if ($result.Left -gt 0) { return "Could not send your co-op log: $($result.Error). It is sent next time." }
    } catch {
        return "Could not send your co-op log: $($_.Exception.Message)"
    }
    if ($sent -gt 0) { return "Sent your co-op log to the host at $Address." }
    ''
}

Export-ModuleMember -Function Assert-W3LanName, Resolve-W3LanAddress, Get-W3LanAddresses, Find-W3LanJava, Test-W3LanEndpoint, Start-W3LanServer, Stop-W3LanServer, New-W3LanClientEnvironment, Copy-W3LanSessionSave, Get-W3LanPlayerSettingsPath, Get-W3LanPlayerSettings, Set-W3LanPlayerSettings, Read-W3LanValue, Get-W3LanLogSources, Get-W3LanLogOutbox, Test-W3LanLogUploadWanted, Add-W3LanLogsToOutbox, Send-W3LanLogOutbox, Start-W3LanLogUpload, Send-W3LanSessionLogs
