[CmdletBinding()]
param([Parameter(Mandatory)][string]$JavaHome)
$ErrorActionPreference = 'Stop'
$serverRoot = Split-Path -Parent $PSScriptRoot
$java = Join-Path $JavaHome 'bin\java.exe'
$javac = Join-Path $JavaHome 'bin\javac.exe'
$root = Join-Path $serverRoot ('build\rejoin-mutations-' + [Guid]::NewGuid().ToString('N'))
$source = Get-Content -LiteralPath (Join-Path $serverRoot 'src\SeamlessCampaign.java') -Raw
$mutants = @(
    @{Name='consume-outstanding-sequence'; Before='active.put(id, new Active(endpoint, clock.getAsLong(), parseCapabilities(auth.get(2))));'; After='prior.seq = seq; active.put(id, new Active(endpoint, clock.getAsLong(), parseCapabilities(auth.get(2))));'},
    @{Name='overwrite-pending-receipt'; Before='active.put(id, new Active(endpoint, clock.getAsLong(), parseCapabilities(auth.get(2))));'; After='prior.reply = list("WELCOME"); active.put(id, new Active(endpoint, clock.getAsLong(), parseCapabilities(auth.get(2))));'},
    @{Name='skip-endpoint-protection'; Before='existing != null && !existing.endpoint.equals(endpoint) && now - existing.seen < LEASE_MS'; After='false'},
    @{Name='skip-replay-capability'; Before='!capabilities.contains("fact_remove") && hasFactRemoval(state)'; After='false'},
    @{Name='retain-expired-listeners'; Before='if (scope.listeners.removeAll(disconnected)) changed = true;'; After='if (false) changed = true;'}
)
$utf8 = New-Object Text.UTF8Encoding($false)
foreach ($mutant in $mutants) {
    if (-not $source.Contains($mutant.Before)) { throw "Mutation anchor absent: $($mutant.Name)" }
    $dir = Join-Path $root $mutant.Name
    $classes = Join-Path $dir 'classes'
    New-Item -ItemType Directory -Force -Path $classes | Out-Null
    $file = Join-Path $dir 'SeamlessCampaign.java'
    [IO.File]::WriteAllText($file, $source.Replace($mutant.Before, $mutant.After), $utf8)
    & $javac --release 17 -encoding UTF-8 -d $classes $file (Join-Path $PSScriptRoot 'RejoinRecoveryTest.java')
    if ($LASTEXITCODE -ne 0) { throw "Mutant did not compile: $($mutant.Name)" }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $java
    $info.Arguments = '-cp "' + $classes + '" RejoinRecoveryTest "' + (Join-Path $dir 'state') + '"'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    [IO.File]::WriteAllText((Join-Path $dir 'result.log'), $stdout + $stderr, $utf8)
    if ($process.ExitCode -eq 0 -or $stderr -notmatch 'AssertionError') { throw "Mutation escaped or failed without an assertion: $($mutant.Name)" }
    Write-Output "CAUGHT $($mutant.Name)"
    $process.Dispose()
}
Write-Output "Rejoin server mutations caught: $($mutants.Count)/$($mutants.Count)"
