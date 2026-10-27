#requires -Version 5.1
# Save download over a bad connection, on this PC with fixture saves only: a scripted host (a TCP
# listener speaking the save share's HTTP) drops connections mid-file, sends damaged bytes, ignores
# Range or refuses, and Copy-W3LanSessionSave must resume, retry, verify the SHA-256 and leave
# nothing half-written in the second PC's save folder. Needs no Java (Test-SessionSave.ps1 covers
# the real server).
[CmdletBinding()]
param([ValidateRange(1024,65535)][int]$Port = 41790)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'W3Lan.psm1') -Force
$root = Join-Path ([IO.Path]::GetTempPath()) ('w3lan-download-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$saves = Join-Path $root 'join\gamesaves'
$passed = 0
function Check([bool]$condition, [string]$what) {
    if (-not $condition) { throw "FAIL $what" }
    $script:passed += 1
    Write-Output "PASS $what"
}
function Sha([byte[]]$bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('X2') }) } finally { $sha.Dispose() }
}
function FileSha([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }

# The scripted host. Files: name -> bytes. Per file, queues of what the next requests get:
# Drop (send that many body bytes, then close), Corrupt (a damaged byte). NoRange: answer every
# Range with the whole file. Refuse: 403 for everything. Next: the host's next save (Files, Listing),
# taken once the current request is answered. Log: "path|range" per request.
$hostState = [hashtable]::Synchronized(@{
    Files = @{}; Listing = ''; Drop = @{}; Corrupt = @{}; NoRange = $false; Refuse = $false; Next = $null
    Log = [Collections.ArrayList]::Synchronized([Collections.ArrayList]::new())
    Listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
})
$serve = {
    param($state)
    function Answer($stream, [int]$status, [string]$reason, [hashtable]$headers, [byte[]]$body, [long]$send) {
        $head = "HTTP/1.1 $status $reason`r`nConnection: close`r`nContent-Length: $($body.Length)`r`n"
        foreach ($key in $headers.Keys) { $head += "${key}: $($headers[$key])`r`n" }
        $bytes = [Text.Encoding]::ASCII.GetBytes($head + "`r`n")
        $stream.Write($bytes, 0, $bytes.Length)
        if ($send -gt 0) { $stream.Write($body, 0, [int][Math]::Min($send, $body.Length)) }
        $stream.Flush()
    }
    for (;;) {
        try { $client = $state.Listener.AcceptTcpClient() } catch { return }
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 5000
            $head = [Text.StringBuilder]::new()
            $one = [byte[]]::new(1)
            while ($head.Length -lt 8192 -and -not $head.ToString().EndsWith("`r`n`r`n")) {
                if ($stream.Read($one, 0, 1) -le 0) { break }
                [void]$head.Append([char]$one[0])
            }
            $lines = $head.ToString() -split "`r`n"
            $path = ($lines[0] -split ' ')[1]
            $from = ''
            foreach ($line in $lines) { if ($line -match '^Range:\s*bytes=(\d+)-$') { $from = $Matches[1] } }
            [void]$state.Log.Add("$path|$from")
            $text = @{ 'Content-Type' = 'text/plain' }
            if ($state.Refuse) { Answer $stream 403 'Forbidden' $text ([Text.Encoding]::ASCII.GetBytes("join password required`n")) 99; continue }
            if ($path -eq '/session') { $body = [Text.Encoding]::ASCII.GetBytes($state.Listing); Answer $stream 200 'OK' $text $body $body.Length; continue }
            $name = $path.Substring('/session/save/'.Length)
            if (-not $state.Files.ContainsKey($name)) { Answer $stream 404 'Not Found' $text ([Text.Encoding]::ASCII.GetBytes("not found`n")) 99; continue }
            $file = [byte[]]$state.Files[$name]
            $sha = [Security.Cryptography.SHA256]::Create()
            $headers = @{ 'Content-Type' = 'application/octet-stream'; 'X-Content-SHA256' = (-join ($sha.ComputeHash($file) | ForEach-Object { $_.ToString('x2') })) }
            $sha.Dispose()
            $status = 200; $reason = 'OK'; $body = $file
            if (-not $state.NoRange) {
                $headers['Accept-Ranges'] = 'bytes'
                if ($from) {
                    $start = [long]$from
                    if ($start -ge $file.Length) { $headers['Content-Range'] = "bytes */$($file.Length)"; Answer $stream 416 'Range Not Satisfiable' $headers ([byte[]]::new(0)) 0; continue }
                    $body = [byte[]]::new($file.Length - $start)
                    [Array]::Copy($file, $start, $body, 0, $body.Length)
                    $status = 206; $reason = 'Partial Content'
                    $headers['Content-Range'] = "bytes $start-$($file.Length - 1)/$($file.Length)"
                }
            }
            $send = [long]$body.Length
            $drops = $state.Drop[$name]
            if ($drops -and $drops.Count) { $send = [long]$drops.Dequeue() }
            $corrupt = $state.Corrupt[$name]
            if ($corrupt -and $corrupt.Count -and $corrupt.Dequeue()) { $body = [byte[]]$body.Clone(); $body[$body.Length - 1] = $body[$body.Length - 1] -bxor 0xFF }
            Answer $stream $status $reason $headers $body $send
            if ($state.Next) { $state.Files = $state.Next.Files; $state.Listing = $state.Next.Listing; $state.Next = $null }
        } catch {
        } finally {
            $client.Close()
        }
    }
}
function Set-Save([string]$save, [byte[]]$bytes, [byte[]]$thumb) {
    $hostState.Files = @{ "$save.sav" = $bytes }
    if ($thumb) { $hostState.Files["$save.png"] = $thumb }
    $hostState.Listing = "host=HostWitcher`nsave=$save`nsize=$($bytes.Length)`nsha256=$((Sha $bytes).ToLowerInvariant())`nmodified=1`n"
    $hostState.Drop = @{}; $hostState.Corrupt = @{}; $hostState.NoRange = $false; $hostState.Refuse = $false; $hostState.Next = $null
    $hostState.Log.Clear()
}
function Queue([object[]]$values) { $queue = [Collections.Queue]::new(); foreach ($value in $values) { $queue.Enqueue($value) }; ,$queue }
function Leftovers { @(Get-ChildItem -LiteralPath $saves -Filter '*.download' -ErrorAction SilentlyContinue).Count }
function Download {
    $script:warned = @()
    $result = Copy-W3LanSessionSave -Address 127.0.0.1 -Port $Port -SaveDirectory $saves -RetryDelaySeconds 0 -WarningVariable caught -WarningAction SilentlyContinue
    $script:warned = @($caught)
    $result
}

$runspace = $null
try {
    $hostState.Listener.Start()
    $runspace = [PowerShell]::Create()
    [void]$runspace.AddScript($serve).AddArgument($hostState)
    $running = $runspace.BeginInvoke()

    $random = [Random]::new(11)
    $save1 = [byte[]]::new(1536000); $random.NextBytes($save1)
    $thumb = [byte[]]::new(40000); $random.NextBytes($thumb)
    $saveTarget = Join-Path $saves 'QuickSave_7c1d.sav'

    # clean: the save and its thumbnail, verified, nothing left over
    Set-Save 'QuickSave_7c1d' $save1 $thumb
    $session = Download
    Check ($session.Host -eq 'HostWitcher' -and $session.Save -eq 'QuickSave_7c1d') 'the host save is offered'
    Check ((FileSha $saveTarget) -eq (Sha $save1) -and (FileSha (Join-Path $saves 'QuickSave_7c1d.png')) -eq (Sha $thumb)) 'save and thumbnail arrive byte for byte'
    Check ((Leftovers) -eq 0 -and $warned.Count -eq 0) 'no retry, no .download left'

    # the same save again: nothing to download
    Set-Save 'QuickSave_7c1d' $save1 $thumb
    $session = Download
    Check (@($hostState.Log | Where-Object { $_ -like '/session/save/*.sav|*' }).Count -eq 0) 'a save this PC already has is not downloaded again'

    # a connection dropped mid-file: the next try resumes with Range
    $save2 = [byte[]]::new(1536000); $random.NextBytes($save2)
    Set-Save 'QuickSave_7c1d' $save2 $thumb
    $hostState.Drop['QuickSave_7c1d.sav'] = Queue @(600000)
    $session = Download
    $requests = @($hostState.Log | Where-Object { $_ -like '/session/save/QuickSave_7c1d.sav|*' })
    Check ($requests.Count -eq 2 -and $requests[0] -like '*|' -and $requests[1] -like '*|600000') "a dropped download resumes at the byte it reached ($($requests -join ', '))"
    Check ((FileSha $saveTarget) -eq (Sha $save2) -and (Leftovers) -eq 0) 'the resumed save is the host''s, byte for byte'
    Check ($warned.Count -eq 1 -and "$($warned[0])" -match 'failed: the connection dropped at 0\.6 of 1\.5 MB') "the player is told the download broke off and is retried ($($warned[0]))"

    # dropped twice, then a host that ignores Range: the whole file again, still verified
    $save3 = [byte[]]::new(1536000); $random.NextBytes($save3)
    Set-Save 'QuickSave_7c1d' $save3 $thumb
    $hostState.NoRange = $true
    $hostState.Drop['QuickSave_7c1d.sav'] = Queue @(300000, 900000)
    $session = Download
    Check ((FileSha $saveTarget) -eq (Sha $save3) -and (Leftovers) -eq 0) 'without Range support the third try downloads it whole'

    # damaged bytes of the right size: refused, downloaded again from the start
    $save4 = [byte[]]::new(800000); $random.NextBytes($save4)
    Set-Save 'QuickSave_7c1d' $save4 $thumb
    $hostState.Corrupt['QuickSave_7c1d.sav'] = Queue @($true)
    $session = Download
    $requests = @($hostState.Log | Where-Object { $_ -like '/session/save/QuickSave_7c1d.sav|*' })
    Check ($requests.Count -eq 2 -and $requests[1] -like '*|') 'a damaged save is refused and downloaded again from the start'
    Check ((FileSha $saveTarget) -eq (Sha $save4) -and "$($warned[0])" -match 'SHA-256') "the second try's save is intact ($($warned[0]))"

    # damaged every time: a clear failure, the earlier save untouched, nothing half-written
    $before = FileSha $saveTarget
    $save5 = [byte[]]::new(800000); $random.NextBytes($save5)
    Set-Save 'QuickSave_7c1d' $save5 $thumb
    $hostState.Corrupt['QuickSave_7c1d.sav'] = Queue @($true, $true, $true)
    $failure = $null
    try { Download | Out-Null } catch { $failure = $_.Exception }
    Check ($failure -is [IO.IOException] -and $failure.Message -match 'did not arrive after 3 tries' -and $failure.Message -match 'SHA-256') "after 3 damaged tries it fails with a message ($($failure.Message))"
    Check ((FileSha $saveTarget) -eq $before -and (Leftovers) -eq 0) 'a failed download leaves the save folder as it was'

    # dropped every time, a new save name: no .sav, no .download
    $save6 = [byte[]]::new(1200000); $random.NextBytes($save6)
    Set-Save 'ManualSave_9e2f' $save6 $thumb
    $hostState.Drop['ManualSave_9e2f.sav'] = Queue @(100000, 100000, 100000)
    $failure = $null
    try { Download | Out-Null } catch { $failure = $_.Exception }
    $requests = @($hostState.Log | Where-Object { $_ -like '/session/save/ManualSave_9e2f.sav|*' })
    Check ($failure -and $failure.Message -match 'connection dropped' -and $requests.Count -eq 3) "3 dropped tries, then it gives up ($($failure.Message))"
    Check (-not (Test-Path -LiteralPath (Join-Path $saves 'ManualSave_9e2f.sav')) -and -not (Test-Path -LiteralPath (Join-Path $saves 'ManualSave_9e2f.png')) -and (Leftovers) -eq 0) 'nothing of a failed save is left in the save folder'

    # the host saved again (same name and size) between two tries: the new save, not a mix of both
    $save7 = [byte[]]::new(1100000); $random.NextBytes($save7)
    $save8 = [byte[]]::new(1100000); $random.NextBytes($save8)
    Set-Save 'QuickSave_7c1d' $save7 $thumb
    $hostState.Drop['QuickSave_7c1d.sav'] = Queue @(500000)
    $hostState.Next = @{ Files = @{ 'QuickSave_7c1d.sav' = $save8; 'QuickSave_7c1d.png' = $thumb }; Listing = "host=HostWitcher`nsave=QuickSave_7c1d`nsize=$($save8.Length)`nsha256=$(Sha $save8)`nmodified=2`n" }
    $session = Download
    Check ((FileSha $saveTarget) -eq (Sha $save8) -and (Leftovers) -eq 0) 'a host that saves again mid-download gives its new save, not a mix'

    # no thumbnail on the host: the save alone
    $save9 = [byte[]]::new(5000); $random.NextBytes($save9)
    Set-Save 'AutoSave_1b2c' $save9 $null
    $session = Download
    Check ($session.Save -eq 'AutoSave_1b2c' -and (FileSha (Join-Path $saves 'AutoSave_1b2c.sav')) -eq (Sha $save9) -and -not (Test-Path -LiteralPath (Join-Path $saves 'AutoSave_1b2c.png'))) 'a save without a thumbnail'

    # a refusal (the join password's 403) is not retried and keeps its status code
    $hostState.Refuse = $true
    $hostState.Log.Clear()
    $refused = $false
    try { Download | Out-Null } catch { $refused = $_.Exception -is [Net.WebException] -and $_.Exception.Response.StatusCode.value__ -eq 403 }
    Check ($refused -and $hostState.Log.Count -eq 1) 'a 403 is reported at once, as a WebException with its status code'

    # no host at all: retried, then a clear failure
    $hostState.Listener.Stop()
    $failure = $null
    try { Copy-W3LanSessionSave -Address 127.0.0.1 -Port $Port -SaveDirectory $saves -RetryDelaySeconds 0 -WarningAction SilentlyContinue | Out-Null } catch { $failure = $_.Exception }
    Check ($failure -is [IO.IOException] -and $failure.Message -match 'after 3 tries') "an unreachable host fails after 3 tries ($($failure.Message))"
} finally {
    try { $hostState.Listener.Stop() } catch { }
    if ($runspace) { $runspace.Stop(); $runspace.Dispose() }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "SAVE_DOWNLOAD_PASS: $passed checks. Fixture saves only; no game launched."
