#requires -Version 5.1
[CmdletBinding()]
param([string]$JavaPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'W3Lan.psm1') -Force
$script:checks = 0
$script:failures = @()

function Check([string]$Label, [scriptblock]$Body) {
    $script:checks++
    try { & $Body; Write-Host "PASS $Label" }
    catch { $script:failures += "${Label}: $_"; Write-Host "FAIL ${Label}: $_" }
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Throws([scriptblock]$Body) {
    $didThrow = $false
    try { & $Body | Out-Null } catch { $didThrow = $true }
    Assert $didThrow 'Expected rejection.'
}
function FreePort {
    $s = [Net.Sockets.UdpClient]::new(0)
    try { $s.Client.LocalEndPoint.Port } finally { $s.Dispose() }
}
function Client([int]$Port) {
    $s = [Net.Sockets.UdpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
    $s.Connect('127.0.0.1', $Port)
    $s.Client.ReceiveTimeout = 150
    $s
}
function Send([Net.Sockets.UdpClient]$Client, [string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    [void]$Client.Send($bytes, $bytes.Length)
}
function WaitPacket([Net.Sockets.UdpClient]$Client, [string]$Expected) {
    $until = [DateTime]::UtcNow.AddSeconds(2)
    while ([DateTime]::UtcNow -lt $until) {
        try {
            $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Any,0)
            $text = [Text.Encoding]::UTF8.GetString($Client.Receive([ref]$remote))
            if ($text -ceq $Expected) { return }
        } catch [Net.Sockets.SocketException] { }
    }
    throw "Expected packet not received: $($Expected.Replace("`t", '|'))"
}

Check 'PowerShell files parse' {
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in '.ps1','.psm1' }) {
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        Assert ($errors.Count -eq 0) "$($file.Name): $errors"
    }
}
Check 'private address and loopback validation' {
    foreach ($address in @('10.0.0.2','172.16.0.2','172.31.255.254','192.168.1.20','127.0.0.1','100.64.0.1','100.101.102.103','100.127.255.254')) {
        Assert ((Resolve-W3LanAddress $address) -ceq $address) 'Address changed.'
    }
    foreach ($address in @('8.8.8.8','172.15.0.1','172.32.0.1','100.63.255.255','100.128.0.1','0.0.0.0','255.255.255.255','169.254.1.2','::1','127.1','192.168.001.2','192.168.999.1','localhost','192.168.1.2;whoami')) {
        Throws { Resolve-W3LanAddress $address }
    }
}
Check 'names cannot silently collapse to another identity' {
    Assert-W3LanName 'Host_Witcher1'
    foreach ($name in @('a','none','NONE','Bad Name',"two`tfields",'01234567890123456','A&B',"Alice`n", "Alice`r`n")) { Throws { Assert-W3LanName $name } }
}
Check 'client override plan does not change the current process' {
    $before = [Environment]::GetEnvironmentVariable('WO_SERVER_IP','Process')
    $plan = New-W3LanClientEnvironment -PlayerName GuestWitcher -Address 192.168.1.20 -Port 40123
    Assert ($plan.WO_SERVER_IP -ceq '192.168.1.20' -and $plan.WO_SERVER_PORT -ceq '40123' -and $plan.WO_USERNAME -ceq 'GuestWitcher') 'Wrong client endpoint.'
    Assert ([Environment]::GetEnvironmentVariable('WO_SERVER_IP','Process') -ceq $before) 'Environment was changed.'
    Throws { New-W3LanClientEnvironment -PlayerName GuestWitcher -Address 192.168.1.20 -Port 65536 }
}
Check 'missing Java and JAR fail clearly' {
    Throws { Find-W3LanJava (Join-Path $root 'missing-java.exe') }
    Throws { Start-W3LanServer -JarPath (Join-Path $root 'missing.jar') -Port (FreePort) }
}
Check 'an unused UDP endpoint is not reported as connected' {
    $result = Test-W3LanEndpoint -Address 127.0.0.1 -Port (FreePort) -TimeoutMs 150
    Assert (-not $result.Reachable) 'False positive connection.'
    $result = Test-W3LanEndpoint -Address 127.0.0.1 -Port (FreePort) -TimeoutMs 150 -Attempts 2
    Assert (-not $result.Reachable) 'False positive connection after a retry.'
}
Check 'an unreachable host gets a ZeroTier or Tailscale hint' {
    Assert ((Get-W3LanUnreachableHint '10.147.17.5') -match 'same ZeroTier network') 'No ZeroTier hint.'
    Assert ((Get-W3LanUnreachableHint '100.101.102.103') -match 'same Tailscale tailnet') 'No Tailscale hint.'
}

$server = $null; $alice = $null; $bob = $null; $late = $null
try {
    $java = Find-W3LanJava $JavaPath
    $port = FreePort
    $jar = Join-Path $root 'server\WitcherServer.jar'
    $server = Start-W3LanServer -JarPath $jar -JavaPath $java -Port $port
    Check 'real Java server answers the non-player UDP probe' {
        $result = Test-W3LanEndpoint -Address 127.0.0.1 -Port $port
        Assert $result.Reachable 'No compatible server reply.'
        Assert ($result.Reply -ceq "ERROR`tINVALID_USERNAME") 'Wrong probe response.'
    }
    Check 'occupied port is rejected without stopping the first server' {
        Throws { Start-W3LanServer -JarPath $jar -JavaPath $java -Port $port }
        Assert (-not $server.HasExited) 'Existing server was stopped.'
    }
    Check 'join launcher reports the compatible server through its real CLI' {
        $shell = (Get-Process -Id $PID).Path
        $output = & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Lan.ps1') -Mode Join -Address 127.0.0.1 -Port $port 2>&1
        Assert ($LASTEXITCODE -eq 0) "Join CLI failed: $output"
        Assert (($output -join "`n") -match 'confirms UDP transport only') 'CLI did not distinguish transport from gameplay.'
    }
    $alice = Client $port; $bob = Client $port
    Send $alice "COOP`tAlice`ten`t7`t1`t0"
    Send $bob "COOP`tBob`thit`tAlice`t7`t1"
    Check 'two simulated players receive each others co-op state' {
        WaitPacket $bob "COOP`t1`tAlice`ten`t7`t1`t0"
        WaitPacket $alice "COOP`t2`tBob`thit`tAlice`t7`t1"
    }
    Check 'new state replaces an older snapshot' {
        Send $alice "COOP`tAlice`ten`t7`t2`t0"
        WaitPacket $bob "COOP`t1`tAlice`ten`t7`t2`t0"
    }
    Check 'late simulated joiner receives the latest state' {
        $script:late = Client $port
        Send $script:late "COOP`tLateJoin`thit`tAlice`t7`t1"
        WaitPacket $script:late "COOP`t1`tAlice`ten`t7`t2`t0"
    }
    Check 'movement packets still work alongside co-op packets' {
        Send $alice "MOVE`tAlice`t1`t0`t0`t0`t1`t0`t0`t0"
        WaitPacket $bob "MOVE`t1`tAlice`t1`t0`t0`t0`t1`t0`t0`t0"
    }
    Check 'server stops gracefully and releases its UDP port' {
        Stop-W3LanServer $server
        Assert $server.HasExited 'Java process still running.'
        Assert ($server.ExitCode -eq 0) "Unclean exit $($server.ExitCode)."
        $socket = [Net.Sockets.UdpClient]::new($port)
        $socket.Dispose()
    }
    Check 'host launcher starts and stops its own server through its real CLI' {
        $cliPort = FreePort
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = (Get-Process -Id $PID).Path
        $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'Lan.ps1') + '" -Mode Host -JavaPath "' + $java + '" -Port ' + $cliPort
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $cli = [Diagnostics.Process]::new()
        $cli.StartInfo = $info
        try {
            [void]$cli.Start()
            $stdout = $cli.StandardOutput.ReadToEndAsync()
            $stderr = $cli.StandardError.ReadToEndAsync()
            $cli.StandardInput.WriteLine('')
            $cli.StandardInput.Flush()
            Assert ($cli.WaitForExit(15000)) 'Host CLI did not exit after Enter.'
            Assert ($cli.ExitCode -eq 0) "Host CLI failed: $($stderr.Result)"
            Assert ($stdout.Result -match 'LAN server ready') 'Host never reached protocol readiness.'
            Assert (-not (Test-W3LanEndpoint -Address 127.0.0.1 -Port $cliPort -TimeoutMs 150).Reachable) 'Host left a server running.'
        } finally {
            if (-not $cli.HasExited) { $cli.Kill(); [void]$cli.WaitForExit(3000) }
            $cli.Dispose()
        }
    }
} catch {
    $script:failures += "Server integration setup: $_"
    Write-Host "FAIL server integration: $_"
} finally {
    foreach ($socket in @($alice,$bob,$late)) { if ($socket) { $socket.Dispose() } }
    if ($server) { Stop-W3LanServer $server; $server.Dispose() }
}
Write-Host "RESULT: $($script:checks - $script:failures.Count)/$script:checks checks passed"
if ($script:failures.Count) { $script:failures | ForEach-Object { Write-Host $_ }; exit 1 }
exit 0
