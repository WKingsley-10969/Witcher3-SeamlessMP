$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$package=Join-Path $root 'outputs\Witcher3-LAN-0.2.0-dev'
$fixture=Join-Path $PSScriptRoot ('install-fixture-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$source=Join-Path $fixture 'source'
$target=Join-Path $fixture 'copy'
[void][IO.Directory]::CreateDirectory((Join-Path $source 'bin\x64_dx12'))
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'test-game\bin\x64_dx12\witcher3.exe') -Destination (Join-Path $source 'bin\x64_dx12\witcher3.exe')
'source-sentinel'|Set-Content -LiteralPath (Join-Path $source 'sentinel.txt')
$sourceHash=(Get-FileHash -LiteralPath (Join-Path $source 'sentinel.txt') -Algorithm SHA256).Hash
# Test fixture runs in work, using exactly the packaged installer/payload through junction-free copies.
$app=Join-Path $fixture 'app'
[void][IO.Directory]::CreateDirectory($app)
Copy-Item -LiteralPath (Join-Path $package 'Install-LAN.ps1') -Destination $app
Copy-Item -LiteralPath (Join-Path $package 'mod-manifest.json') -Destination $app
Copy-Item -LiteralPath (Join-Path $package 'mod') -Destination $app -Recurse
& (Join-Path $app 'Install-LAN.ps1') -SourceGameDir $source -Destination $target
if(-not(Test-Path -LiteralPath (Join-Path $target '.w3lan-native.json'))){throw 'Native marker missing'}
if((Get-FileHash -LiteralPath (Join-Path $source 'sentinel.txt') -Algorithm SHA256).Hash -ne $sourceHash){throw 'Source fixture changed'}
if(Test-Path -LiteralPath (Join-Path $source 'mods')){throw 'Source fixture was modded'}
$rejected=$false
try{& (Join-Path $app 'Install-LAN.ps1') -SourceGameDir $source -Destination $target}catch{$rejected=$true}
if(-not $rejected){throw 'Existing destination accepted'}
$bad=Join-Path $app 'mod\bin\x64_dx12\w3test.asi'
[IO.File]::AppendAllText($bad,'tampered')
$rejected=$false
try{& (Join-Path $app 'Install-LAN.ps1') -SourceGameDir $source -Destination (Join-Path $fixture 'rejected')}catch{$rejected=$true}
if(-not $rejected){throw 'Tampered payload accepted'}
Write-Output 'INSTALLER_FIXTURE_PASS: independent copy staged; source unchanged; existing destination and tampered payload rejected'
