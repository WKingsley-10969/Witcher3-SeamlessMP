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
# Over the internet (ZeroTier, Tailscale) a connection can drop or stall, so each file goes to a
# .download file first, shows its progress, resumes where it broke off (HTTP Range) on the next of
# -Attempts tries, and only replaces the file in the save folder once its size and SHA-256 match
# what the host announced. When every try fails it throws a plain message and leaves no .download
# file behind. A refusal by the host (403, 404) is not retried and keeps its WebException, so
# callers can read its status code.
function Copy-W3LanSessionSave {
    param(
        [Parameter(Mandatory)][string]$Address,
        [ValidateRange(1,65535)][int]$Port = 40001,
        [Parameter(Mandatory)][string]$SaveDirectory,
        [ValidateRange(1,10)][int]$Attempts = 3,
        # wait before try n: (n - 1) times this
        [ValidateRange(0,60)][double]$RetryDelaySeconds = 2
    )
    $ip = Resolve-W3LanAddress $Address
    $base = "http://${ip}:$Port/session"
    $offered = $null   # the listing the .download files belong to: save|size|sha256
    $partials = @{}    # extension -> its .download file
    $expect = @{}      # extension -> @{ Length; Sha256; Fixed } the file must match
    $state = @{}       # extension -> 'ready' (verified .download) or 'skip' (nothing to move)
    $hostName = ''
    $save = ''
    $why = ''
    $last = $null
    try {
        for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
            if ($attempt -gt 1) {
                Write-Warning "Save download from the host failed: $why. Trying again ($attempt of $Attempts)..."
                Start-Sleep -Milliseconds ([int](1000 * $RetryDelaySeconds * ($attempt - 1)))
            }
            try {
                $fields = Read-W3LanSessionListing $base
                $hostName = [string]$fields['host']
                $save = [string]$fields['save']
                if ($hostName) { Assert-W3LanName $hostName }
                if (-not $save) { return @{ Host = $hostName; Save = '' } }
                if ($save -notmatch '^[A-Za-z0-9_.-]{1,120}$') { throw 'The host offered an invalid save name.' }
                if ([string]$fields['size'] -notmatch '^\d{1,15}$') { throw 'The host offered no save size.' }
                $size = [long]$fields['size']
                $sha = ([string]$fields['sha256']).ToUpperInvariant()   # empty from an older host
                if ($sha -and $sha -notmatch '^[0-9A-F]{64}$') { throw 'The host offered an invalid save checksum.' }
                if ("$save|$size|$sha" -ne $offered) {
                    # the first try, or the host saved again since: start these files over
                    Remove-W3LanPartials $partials
                    [void][IO.Directory]::CreateDirectory($SaveDirectory)
                    $partials = @{ '.sav' = (Join-Path $SaveDirectory "$save.sav.download"); '.png' = (Join-Path $SaveDirectory "$save.png.download") }
                    Remove-W3LanPartials $partials   # left by a launcher that was closed mid-download
                    $expect = @{ '.sav' = @{ Length = $size; Sha256 = $sha; Fixed = [bool]$sha }; '.png' = @{ Length = -1L; Sha256 = ''; Fixed = $false } }
                    $state = @{}
                    $offered = "$save|$size|$sha"
                    $target = Join-Path $SaveDirectory "$save.sav"
                    if ($sha -and (Test-Path -LiteralPath $target -PathType Leaf) -and (Get-Item -LiteralPath $target).Length -eq $size -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $sha) {
                        $state['.sav'] = 'skip'   # this PC has that very save already
                    }
                }
                if (-not $state['.sav']) {
                    Receive-W3LanSessionFile -Uri "$base/save/$save.sav" -Partial $partials['.sav'] -Expect $expect['.sav'] -Label "$save.sav"
                    Assert-W3LanDownload -Path $partials['.sav'] -Expect $expect['.sav'] -Label "$save.sav"
                    $state['.sav'] = 'ready'
                }
                if (-not $state['.png']) {
                    try {
                        Receive-W3LanSessionFile -Uri "$base/save/$save.png" -Partial $partials['.png'] -Expect $expect['.png'] -Label "$save.png"
                        Assert-W3LanDownload -Path $partials['.png'] -Expect $expect['.png'] -Label "$save.png"
                        $state['.png'] = 'ready'
                    } catch {
                        $cause = Get-W3LanCause $_.Exception
                        if ($cause -isnot [Net.WebException] -or $cause.Response -isnot [Net.HttpWebResponse] -or [int]$cause.Response.StatusCode -ne 404) { throw }
                        $state['.png'] = 'skip'   # the thumbnail is optional
                    }
                }
                break
            } catch {
                $last = Get-W3LanCause $_.Exception
                if (-not (Test-W3LanTransient $last)) { throw $last }
                $why = $last.Message.Trim().TrimEnd('.')
            }
        }
        if ($state['.sav'] -ne 'ready' -and $state['.sav'] -ne 'skip') {
            throw [IO.IOException]::new("The host's save did not arrive after $Attempts tries: $why. Check the network connection to the host and start the launcher again. Nothing was written to your co-op saves.", $last)
        }
        # the thumbnail first: the game lists a save by its .sav
        foreach ($extension in @('.png', '.sav')) {
            if ($state[$extension] -eq 'ready') { Move-W3LanDownload $partials[$extension] (Join-Path $SaveDirectory ($save + $extension)) }
        }
        @{ Host = $hostName; Save = $save }
    } finally {
        Remove-W3LanPartials $partials
    }
}

# Session share helpers (not exported).
function New-W3LanSessionRequest([string]$Uri) {
    $request = [Net.HttpWebRequest][Net.WebRequest]::Create($Uri)
    $request.Proxy = $null              # the host is on the LAN or a virtual network, never behind a proxy
    $request.KeepAlive = $false
    $request.Timeout = 15000            # connect and headers
    $request.ReadWriteTimeout = 30000   # a stalled transfer counts as dropped
    $request.AutomaticDecompression = [Net.DecompressionMethods]::None
    $request
}

function Read-W3LanSessionListing([string]$Uri) {
    $response = (New-W3LanSessionRequest $Uri).GetResponse()
    try {
        $reader = [IO.StreamReader]::new($response.GetResponseStream(), [Text.Encoding]::UTF8)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $response.Dispose() }
    $fields = @{}
    foreach ($line in ($text -split "`n")) {
        $at = $line.IndexOf('=')
        if ($at -gt 0) { $fields[$line.Substring(0, $at)] = $line.Substring($at + 1).Trim() }
    }
    $fields
}

# One try at one file into its .download file, resuming what an earlier try left there. Fills in
# $Expect's length and SHA-256 from the host when they are not known yet.
function Receive-W3LanSessionFile {
    param([string]$Uri, [string]$Partial, [hashtable]$Expect, [string]$Label)
    $have = 0L
    if (Test-Path -LiteralPath $Partial -PathType Leaf) { $have = (Get-Item -LiteralPath $Partial).Length }
    if ($Expect.Length -ge 0 -and $have -gt $Expect.Length) { Remove-Item -LiteralPath $Partial -Force; $have = 0L }
    if ($have -gt 0 -and $have -eq $Expect.Length) { return }   # complete: Assert-W3LanDownload checks it
    $request = New-W3LanSessionRequest $Uri
    if ($have -gt 0) { $request.AddRange([long]$have) }
    try { $response = $request.GetResponse() } catch {
        $cause = Get-W3LanCause $_.Exception
        if ($have -gt 0 -and $cause -is [Net.WebException] -and $cause.Response -is [Net.HttpWebResponse] -and [int]$cause.Response.StatusCode -eq 416) {
            Remove-Item -LiteralPath $Partial -Force
            throw [IO.IOException]::new("the host's $Label no longer matches the part already downloaded")
        }
        throw $cause
    }
    try {
        $total = -1L
        if ($have -gt 0 -and [int]$response.StatusCode -eq 206) {
            if ([string]$response.Headers['Content-Range'] -notmatch '^bytes (\d+)-(\d+)/(\d+)$' -or [long]$Matches[1] -ne $have) {
                Remove-Item -LiteralPath $Partial -Force
                throw [IO.IOException]::new("the host sent the wrong part of $Label")
            }
            $total = [long]$Matches[3]
        } else {
            $have = 0L   # a host without Range support sends the whole file again
            $total = $response.ContentLength
        }
        $hostSha = ([string]$response.Headers['X-Content-SHA256']).ToUpperInvariant()
        if ($hostSha -and $Expect.Sha256 -and $hostSha -ne $Expect.Sha256 -and ($Expect.Fixed -or $have -gt 0)) {
            Remove-Item -LiteralPath $Partial -Force -ErrorAction SilentlyContinue
            throw [IO.IOException]::new("the host's $Label changed during the download")
        }
        if ($hostSha -and -not $Expect.Fixed) { $Expect.Sha256 = $hostSha }
        if ($total -ge 0 -and $Expect.Length -ge 0 -and $total -ne $Expect.Length) {
            Remove-Item -LiteralPath $Partial -Force -ErrorAction SilentlyContinue
            throw [IO.IOException]::new("the host's $Label changed during the download")
        }
        if ($Expect.Length -lt 0) { $Expect.Length = $total }
        $mode = if ($have -gt 0) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
        $got = $have
        $show = $total -ge 1MB
        $activity = "Downloading the host's save"
        $stream = $response.GetResponseStream()
        $file = [IO.FileStream]::new($Partial, $mode, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $buffer = [byte[]]::new(65536)
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $next = 0L
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $file.Write($buffer, 0, $read)
                $got += $read
                if ($show -and $clock.ElapsedMilliseconds -ge $next) {
                    $next = $clock.ElapsedMilliseconds + 250
                    $rate = ($got - $have) / 1MB / [Math]::Max(0.001, $clock.Elapsed.TotalSeconds)
                    $status = '{0}: {1:N1} of {2:N1} MB ({3:N1} MB/s)' -f $Label, ($got / 1MB), ($total / 1MB), $rate
                    Write-Progress -Activity $activity -Status $status -PercentComplete ([int][Math]::Min(100, 100 * $got / $total))
                }
            }
        } finally {
            $file.Dispose()
            $stream.Dispose()
            if ($show) { Write-Progress -Activity $activity -Completed }
        }
        if ($total -ge 0 -and $got -lt $total) {
            throw [IO.IOException]::new(('the connection dropped at {0:N1} of {1:N1} MB of {2}' -f ($got / 1MB), ($total / 1MB), $Label))
        }
    } finally { $response.Dispose() }
}

# A complete .download that is not the host's file is deleted: the next try starts it over.
function Assert-W3LanDownload {
    param([string]$Path, [hashtable]$Expect, [string]$Label)
    $length = (Get-Item -LiteralPath $Path).Length
    if ($Expect.Length -ge 0 -and $length -lt $Expect.Length) {
        throw [IO.IOException]::new(('the connection dropped at {0:N1} of {1:N1} MB of {2}' -f ($length / 1MB), ($Expect.Length / 1MB), $Label))
    }
    if (($Expect.Length -ge 0 -and $length -ne $Expect.Length) -or ($Expect.Sha256 -and (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expect.Sha256)) {
        Remove-Item -LiteralPath $Path -Force
        throw [IO.IOException]::new("$Label arrived damaged: its SHA-256 checksum does not match the host's")
    }
}

# Replace the file in the save folder in one step: the game never sees half a save.
function Move-W3LanDownload([string]$Partial, [string]$Target) {
    if (Test-Path -LiteralPath $Target -PathType Leaf) { [IO.File]::Replace($Partial, $Target, [NullString]::Value) }
    else { [IO.File]::Move($Partial, $Target) }
}

function Remove-W3LanPartials([hashtable]$Partials) {
    foreach ($path in @($Partials.Values)) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { Remove-Item -LiteralPath $path -Force }
    }
}

# The .NET exception behind a PowerShell method-call wrapper.
function Get-W3LanCause([Exception]$Exception) {
    while ($Exception.InnerException -and $Exception -is [Management.Automation.ExtendedTypeSystemException]) { $Exception = $Exception.InnerException }
    $Exception
}

# Worth another try: a dropped, refused or stalled connection, a damaged file, a host error (5xx).
function Test-W3LanTransient([Exception]$Exception) {
    if ($Exception -is [Net.WebException]) {
        if ($Exception.Response -is [Net.HttpWebResponse]) {
            $code = [int]$Exception.Response.StatusCode
            return $code -ge 500 -or $code -eq 408
        }
        return $true
    }
    $Exception -is [IO.IOException] -or $Exception -is [TimeoutException]
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
