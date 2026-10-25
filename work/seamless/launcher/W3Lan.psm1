# LAN launcher helpers. No game files, persistent environment or firewall changes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-W3LanName {
    param([Parameter(Mandatory)][string]$PlayerName)
    if ($PlayerName -cnotmatch '\A[A-Za-z0-9_]{2,16}\z' -or $PlayerName -ieq 'none' -or $PlayerName -ieq 'SCServer') {
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
        $tooling = Join-Path $PSScriptRoot '..\..\tooling'
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
        [string]$CampaignHost,
        [string]$CampaignDirectory,
        [Security.SecureString]$CampaignHostToken,
        [bool]$Voting = $true,
        [bool]$SharedXp = $true
    )
    if (-not (Test-Path -LiteralPath $JarPath -PathType Leaf)) { throw 'Server JAR missing. Run Build-Server.ps1 first.' }
    $jar = (Resolve-Path -LiteralPath $JarPath).Path
    $java = Find-W3LanJava $JavaPath
    # Fail before starting a second server, including when another compatible server owns this port.
    $reservation = [Net.Sockets.Socket]::new([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Dgram, [Net.Sockets.ProtocolType]::Udp)
    try {
        $reservation.ExclusiveAddressUse = $true
        $reservation.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Any, $Port))
    } catch { throw "UDP port $Port is already in use or unavailable. Choose another port on both PCs." }
    finally { $reservation.Dispose() }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $java
    $info.Arguments = '-Djava.net.preferIPv4Stack=true -jar "' + $jar + '" ' + $Port
    foreach ($key in @($info.EnvironmentVariables.Keys)) {
        if ($key.StartsWith('W3T_', [StringComparison]::OrdinalIgnoreCase) -or $key.StartsWith('WO_SC_', [StringComparison]::OrdinalIgnoreCase) -or $key -ieq 'WO_CAMPAIGN_HOST_TOKEN') { $info.EnvironmentVariables.Remove($key) }
    }
    if ($CampaignHost -or $CampaignDirectory -or $CampaignHostToken) {
        Assert-W3LanName $CampaignHost
        if (-not $CampaignDirectory -or -not $CampaignHostToken) { throw 'Campaign host, directory and protected token must be supplied together.' }
        $campaignPath = [IO.Path]::GetFullPath($CampaignDirectory).TrimEnd('\')
        if ($campaignPath -match '["\r\n\t]') { throw 'Invalid campaign directory.' }
        $secret = ([Net.NetworkCredential]::new('', $CampaignHostToken)).Password
        if ($secret -cnotmatch '\A[a-f0-9]{64}\z') { throw 'Invalid protected host credential.' }
        $info.Arguments += ' --campaign-host ' + $CampaignHost + ' --campaign-dir "' + $campaignPath + '" --campaign-voting ' + $Voting.ToString().ToLowerInvariant() + ' --campaign-shared-xp ' + $SharedXp.ToString().ToLowerInvariant()
        $info.EnvironmentVariables['WO_CAMPAIGN_HOST_TOKEN'] = $secret
        $secret = $null
    }
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
            if ($process.HasExited) { throw "Server exited during startup (code $($process.ExitCode)). Check Java 17+ and the console output." }
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

Export-ModuleMember -Function Assert-W3LanName, Resolve-W3LanAddress, Get-W3LanAddresses, Find-W3LanJava, Test-W3LanEndpoint, Start-W3LanServer, Stop-W3LanServer, New-W3LanClientEnvironment
