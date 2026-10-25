#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$JdkPath)
$ErrorActionPreference = 'Stop'
$javac = Join-Path $JdkPath 'bin\javac.exe'
$jarTool = Join-Path $JdkPath 'bin\jar.exe'
if (-not (Test-Path -LiteralPath $javac) -or -not (Test-Path -LiteralPath $jarTool)) { throw 'Supply an extracted JDK directory with javac.exe and jar.exe.' }
$server = Join-Path $PSScriptRoot 'server'
$temporary = Join-Path $server '.build-tmp'
$build = Join-Path $temporary ([Guid]::NewGuid().ToString('N'))
$classes = Join-Path $build 'classes'
[void][IO.Directory]::CreateDirectory($classes)
$sources = @(Get-ChildItem -LiteralPath (Join-Path $server 'src') -Filter '*.java' -File | ForEach-Object { $_.FullName })
& $javac --release 21 -encoding UTF-8 -d $classes @sources
if ($LASTEXITCODE -ne 0) { throw 'Server compilation failed.' }
& $jarTool "-J-Djava.io.tmpdir=$temporary" --create --date=2026-10-21T08:24:32Z --file (Join-Path $server 'WitcherServer.jar') --main-class WitcherServer -C $classes .
if ($LASTEXITCODE -ne 0) { throw 'Server JAR packaging failed.' }
Get-FileHash -LiteralPath (Join-Path $server 'WitcherServer.jar') -Algorithm SHA256
