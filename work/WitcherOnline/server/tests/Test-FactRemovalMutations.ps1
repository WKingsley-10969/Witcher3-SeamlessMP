[CmdletBinding()]
param([Parameter(Mandatory)][string]$JavaHome)
$ErrorActionPreference = 'Stop'
$serverRoot = Split-Path -Parent $PSScriptRoot
$java = Join-Path $JavaHome 'bin\java.exe'
$javac = Join-Path $JavaHome 'bin\javac.exe'
$root = Join-Path $serverRoot ('build\removal-mutations-' + [Guid]::NewGuid().ToString('N'))
$source = Get-Content -LiteralPath (Join-Path $serverRoot 'src\SeamlessCampaign.java') -Raw
$mutants = @(
    @{Name='reject-removal'; Before='if (text.equals("absent")) return true;'; After='if (text.equals("absent")) return false;'},
    @{Name='skip-live-capability'; Before='if (member.value.equals("absent"))'; After='if (false)'},
    @{Name='skip-replay-capability'; Before='!capabilities.contains("fact_remove") && hasFactRemoval(state)'; After='false'},
    @{Name='store-zero-for-absence'; Before='new Value(m.value, s.nextEvent)'; After='new Value(m.value.equals("absent") ? "0" : m.value, s.nextEvent)'},
    @{Name='repeat-removal'; Before='if (s.effects.containsKey(a.get(0))) {'; After='if (s.effects.containsKey(a.get(0)) && !a.get(4).equals("absent")) {'}
)
$utf8 = New-Object Text.UTF8Encoding($false)
foreach ($mutant in $mutants) {
    if (-not $source.Contains($mutant.Before)) { throw "Mutation anchor absent: $($mutant.Name)" }
    $dir = Join-Path $root $mutant.Name
    $classes = Join-Path $dir 'classes'
    New-Item -ItemType Directory -Force -Path $classes | Out-Null
    $file = Join-Path $dir 'SeamlessCampaign.java'
    [IO.File]::WriteAllText($file, $source.Replace($mutant.Before, $mutant.After), $utf8)
    & $javac --release 17 -encoding UTF-8 -d $classes $file (Join-Path $PSScriptRoot 'FactRemovalTest.java')
    if ($LASTEXITCODE -ne 0) { throw "Mutant did not compile (not a caught defect): $($mutant.Name)" }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $java
    $info.Arguments = '-cp "' + $classes + '" FactRemovalTest "' + (Join-Path $dir 'state') + '"'
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
Write-Output "Fact removal mutation checks passed: $($mutants.Count)/$($mutants.Count). Evidence: $root"
