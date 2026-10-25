[CmdletBinding()]
param(
    [string]$JavaHome,
    [string]$TestRoot
)
$ErrorActionPreference = 'Stop'
$serverRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $serverRoot
$workRoot = Split-Path -Parent $repoRoot
if (-not $JavaHome) {
    $bundled = @(Get-ChildItem -LiteralPath (Join-Path $workRoot 'tooling') -Directory -Filter 'jdk-*' | Sort-Object Name -Descending)
    if ($bundled.Count -eq 0) { throw 'Pass -JavaHome pointing to an existing JDK 17 or newer. This script never downloads a JDK.' }
    $JavaHome = $bundled[0].FullName
}
if (-not $TestRoot) { $TestRoot = Join-Path $workRoot 'seamless\test-results' }
$java = Join-Path $JavaHome 'bin\java.exe'
$javac = Join-Path $JavaHome 'bin\javac.exe'
$jar = Join-Path $JavaHome 'bin\jar.exe'
foreach ($tool in @($java, $javac, $jar)) { if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "JDK tool missing: $tool" } }
$classes = Join-Path $serverRoot 'build\seamless-production'
$testClasses = Join-Path $serverRoot 'build\seamless-test-classes'
$jarFile = Join-Path $serverRoot 'build\WitcherServer.jar'
New-Item -ItemType Directory -Force -Path $classes, $testClasses, $TestRoot | Out-Null
$sources = @(Get-ChildItem -LiteralPath (Join-Path $serverRoot 'src') -Filter '*.java' -File | ForEach-Object FullName)
$tests = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.java' -File | ForEach-Object FullName)
& $javac --release 17 -encoding UTF-8 -d $classes @sources
if ($LASTEXITCODE -ne 0) { throw 'Production Java compilation failed' }
& $jar --create --file $jarFile --main-class WitcherServer -C $classes .
if ($LASTEXITCODE -ne 0) { throw 'Server JAR packaging failed' }
& $javac --release 17 -encoding UTF-8 -cp $classes -d $testClasses @tests
if ($LASTEXITCODE -ne 0) { throw 'Test Java compilation failed' }
$classPath = $classes + [IO.Path]::PathSeparator + $testClasses
& $java -cp $classPath SeamlessCampaignTest $TestRoot | Tee-Object -FilePath (Join-Path $TestRoot 'pure-latest.log')
if ($LASTEXITCODE -ne 0) { throw 'Campaign unit tests failed' }
& $java -cp $classPath FactRemovalTest $TestRoot | Tee-Object -FilePath (Join-Path $TestRoot 'fact-removal-latest.log')
if ($LASTEXITCODE -ne 0) { throw 'Fact removal tests failed' }
& $java -cp $classPath RejoinRecoveryTest $TestRoot | Tee-Object -FilePath (Join-Path $TestRoot 'rejoin-latest.log')
if ($LASTEXITCODE -ne 0) { throw 'Rejoin recovery tests failed' }
& $java -cp $classPath SeamlessUdpIntegrationTest $java $classes $TestRoot | Tee-Object -FilePath (Join-Path $TestRoot 'udp-latest.log')
if ($LASTEXITCODE -ne 0) { throw 'Real UDP integration tests failed' }
Write-Output "Built tested server: $jarFile"
