#requires -Version 5.1
[CmdletBinding()]
param([string]$JavaPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$launcher = Join-Path $PSScriptRoot '..\launcher'
Import-Module (Join-Path $launcher 'W3Campaign.psm1') -Force
Import-Module (Join-Path $launcher 'W3LanProfile.psm1') -Force
Import-Module (Join-Path $launcher 'W3Lan.psm1') -Force
$fixture = Join-Path $PSScriptRoot ('fx-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$game = Join-Path $fixture 'game'
$seed = Join-Path $fixture 'seed'
$serverJar = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\WitcherOnline\server\build\WitcherServer.jar'))
$script:checks = 0
function Check([string]$Label, [scriptblock]$Body) {
    & $Body
    $script:checks++
    Write-Output "PASS $Label"
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Throws([scriptblock]$Body) { $rejected=$false; try { & $Body | Out-Null } catch { $rejected=$true }; Assert $rejected 'Expected rejection' }
function Snapshot([string]$Path) { return (@(Get-ChildItem -LiteralPath $Path -Recurse -File | Sort-Object FullName | ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join '|') }
function Context([string]$Mode='Host', [string]$Player='HostWitcher', [string]$Campaign='lan-coop', [switch]$Plan) {
    Get-W3CampaignContext -GameDir $game -Mode $Mode -CampaignName $Campaign -PlayerName $Player -HostName HostWitcher -Plan:$Plan
}
function Plain([Security.SecureString]$Value) { ([Net.NetworkCredential]::new('', $Value)).Password }
function Peer([int]$Port) { $udp=[Net.Sockets.UdpClient]::new(); $udp.Connect('127.0.0.1',$Port); $udp.Client.ReceiveTimeout=1000; return $udp }
function Send([Net.Sockets.UdpClient]$Udp, [string]$Name, [string]$Session, [int]$Seq, [string[]]$Words) {
    $packet=(@('COOP',$Name,'sc','1',$Session,$Seq.ToString()) + $Words) -join "`t"
    $bytes=[Text.Encoding]::UTF8.GetBytes($packet); [void]$Udp.Send($bytes,$bytes.Length)
    $endpoint=[Net.IPEndPoint]::new([Net.IPAddress]::Any,0)
    return ,([Text.Encoding]::UTF8.GetString($Udp.Receive([ref]$endpoint)).Split("`t"))
}
function Start-StandIn([string]$Command) {
    $info=[Diagnostics.ProcessStartInfo]::new(); $info.FileName=(Get-Command powershell.exe).Source
    $info.Arguments='-NoProfile -NonInteractive -Command "' + $Command + '"'; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    return [Diagnostics.Process]::Start($info)
}

[void][IO.Directory]::CreateDirectory((Join-Path $seed 'gamesaves'))
[IO.File]::WriteAllText((Join-Path $seed 'gamesaves\test.sav'),'fixture solo save')
[IO.File]::WriteAllText((Join-Path $seed 'dx12user.settings'),'fixture settings')
$relativeFiles=@('bin/x64_dx12/witcher3.exe','bin/x64_dx12/w3test.asi','bin/x64_dx12/dinput8.dll','bin/x64_dx12/WitcherNativeBridge.asi','bin/x64_dx12/WitcherOnlineClient.asi',
    'mods/modWitcherOnline/content/scripts/local/seamlessCampaign.ws','mods/modWitcherOnline/content/scripts/local/seamlessEffects.ws','mods/modWitcherOnline/content/scripts/local/client.ws','mods/modWitcherOnline/content/scripts/local/anno.ws','mods/modWitcherOnline/content/scripts/local/coopEnemies.ws','mods/modWitcherOnline/content/scripts/local/sceneFactCapture.ws')
foreach ($relative in $relativeFiles) { $path=Join-Path $game $relative; [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path)); [IO.File]::WriteAllText($path,'not executable fixture: ' + $relative) }
foreach ($relative in @('mods/modWitcherOnlineCompat','dlc/dlcWitcherOnline')) { [void][IO.Directory]::CreateDirectory((Join-Path $game $relative)) }
$exeHash=(Get-FileHash -LiteralPath (Join-Path $game 'bin/x64_dx12/witcher3.exe')).Hash.ToLowerInvariant()
$hookHash=(Get-FileHash -LiteralPath (Join-Path $game 'bin/x64_dx12/w3test.asi')).Hash.ToLowerInvariant()
@{TestCopy=$true;OriginalPath=$seed;ExeSha256=$exeHash} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $game '.w3lan-test-copy.json')
@{profileApi=1;profileDllSha256=$hookHash} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $game '.w3lan-native.json')
$manifest=@{}; foreach ($relative in $relativeFiles | Select-Object -Skip 3) { $manifest[$relative]=(Get-FileHash -LiteralPath (Join-Path $game $relative)).Hash.ToLowerInvariant() }
@{api=1;protocol=1;exeSha256=$exeHash;files=$manifest;serverJarSha256=(Get-FileHash -LiteralPath $serverJar).Hash.ToLowerInvariant()} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $game '.w3lan-seamless.json')
$before=Snapshot $game
$preview=Context -Plan
Check 'fresh Plan creates no state or profile' { Assert ((Snapshot $game) -ceq $before) 'Plan wrote files'; Assert $preview.IsPlan 'Missing Plan flag'; Assert ($preview.SessionId -eq '' -and -not $preview.HostToken) 'Plan created credentials' }
$hostContext=Context
$hostSecret=Plain $hostContext.HostToken
$hostAgain=Context
Check 'persistent host session and proof survive repeated bootstrap' { Assert ($hostContext.SessionId -cmatch '\A[a-f0-9]{32}\z') 'Bad random session'; Assert ($hostContext.SessionId -ceq $hostAgain.SessionId) 'Session changed'; Assert ($hostSecret -ceq (Plain $hostAgain.HostToken)) 'Proof changed'; Assert ($hostSecret -cmatch '\A[a-f0-9]{64}\z') 'Bad proof shape' }
$stateBytes=[IO.File]::ReadAllBytes($hostContext.StatePath)
Check 'credentials protected on disk' { $text=[Text.Encoding]::UTF8.GetString($stateBytes); Assert (-not $text.Contains($hostSecret) -and -not $text.Contains($hostContext.SessionId)) 'Plaintext credential in JSON' }
$guestContext=Context Join GuestWitcher
$guestAgain=Context Join GuestWitcher
Check 'guest gets persistent separate identity with no host proof' { Assert ($guestContext.SessionId -ceq $guestAgain.SessionId) 'Guest identity changed'; Assert ($guestContext.SessionId -cne $hostContext.SessionId) 'Shared player identity'; Assert (-not $guestContext.HostToken) 'Guest received host proof' }
$secondCampaign=Context Host HostWitcher second
Check 'different campaigns isolate identities' { Assert ($secondCampaign.SessionId -cne $hostContext.SessionId) 'Session reused across campaigns'; Assert ($secondCampaign.ServerStateDirectory -ine $hostContext.ServerStateDirectory) 'Ledger path reused' }
$old=@{}; foreach ($key in @('W3T_SCENARIO','WO_SC_HOST_TOKEN','WO_SC_EFFECTS','WO_CAMPAIGN_HOST_TOKEN')) { $old[$key]=[Environment]::GetEnvironmentVariable($key,'Process') }
try {
    $env:W3T_SCENARIO='inherited-bot'; $env:WO_SC_HOST_TOKEN=$hostSecret; $env:WO_SC_EFFECTS='1'; $env:WO_CAMPAIGN_HOST_TOKEN=$hostSecret
    $guestInfo=New-W3LanProfileStartInfo -GameDir $game -PlayerName GuestWitcher -Address 127.0.0.1 -CampaignName lan-coop -SeedDirectory $seed
    Set-W3CampaignClientEnvironment $guestInfo $guestContext
    Check 'guest child strips inherited secrets and bots; effect adapters disabled' {
        Assert (-not $guestInfo.EnvironmentVariables.ContainsKey('WO_SC_HOST_TOKEN') -and -not $guestInfo.EnvironmentVariables.ContainsKey('WO_CAMPAIGN_HOST_TOKEN')) 'Guest leaked host proof'
        Assert (-not $guestInfo.EnvironmentVariables.ContainsKey('W3T_SCENARIO')) 'Inherited bot flag leaked'
        Assert ($guestInfo.EnvironmentVariables['WO_SC_EFFECTS'] -ceq '0') 'Unverified effects enabled'
        Assert ($guestInfo.EnvironmentVariables['WO_SC_SESSION'] -ceq $guestContext.SessionId -and $guestInfo.EnvironmentVariables['WO_SC_ROLE'] -ceq 'guest') 'Wrong guest bootstrap'
        Assert ($env:WO_SC_HOST_TOKEN -ceq $hostSecret -and $env:W3T_SCENARIO -ceq 'inherited-bot') 'Parent environment changed'
    }
    $hostInfo=New-W3LanProfileStartInfo -GameDir $game -PlayerName HostWitcher -Address 127.0.0.1 -CampaignName lan-coop -SeedDirectory $seed
    Set-W3CampaignClientEnvironment $hostInfo $hostContext
    Check 'host proof only assigned to host child' { Assert ($hostInfo.EnvironmentVariables['WO_SC_HOST_TOKEN'] -ceq $hostSecret) 'Host missing proof'; Assert (-not $hostInfo.EnvironmentVariables.ContainsKey('WO_CAMPAIGN_HOST_TOKEN')) 'Server proof variable leaked into game' }
    $copiedSave=Join-Path $guestInfo.EnvironmentVariables['W3LAN_DOCUMENTS'] 'The Witcher 3/gamesaves/test.sav'
    [IO.File]::WriteAllText($copiedSave,'existing co-op progress')
    [void](New-W3LanProfileStartInfo -GameDir $game -PlayerName GuestWitcher -Address 127.0.0.1 -CampaignName lan-coop -SeedDirectory $seed)
    Check 'campaign profile keeps existing progress and seed unchanged' { Assert ([IO.File]::ReadAllText($copiedSave) -ceq 'existing co-op progress') 'Progress overwritten'; Assert ([IO.File]::ReadAllText((Join-Path $seed 'gamesaves/test.sav')) -ceq 'fixture solo save') 'Seed changed' }
    $secondInfo=New-W3LanProfileStartInfo -GameDir $game -PlayerName GuestWitcher -Address 127.0.0.1 -CampaignName second -SeedDirectory $seed
    Check 'campaigns have separate save/settings directories' { Assert ($secondInfo.EnvironmentVariables['W3LAN_DOCUMENTS'] -ine $guestInfo.EnvironmentVariables['W3LAN_DOCUMENTS']) 'Campaign profiles shared' }
} finally { foreach ($key in $old.Keys) { [Environment]::SetEnvironmentVariable($key,$old[$key],'Process') } }
Check 'host and guest role cannot be silently changed' { Throws { Context Join HostWitcher }; Throws { Context Host GuestWitcher }; Throws { Context Join SCServer } }
Check 'saved policy cannot change silently' { Throws { Get-W3CampaignContext -GameDir $game -Mode Host -CampaignName lan-coop -PlayerName HostWitcher -HostName HostWitcher -SharedXp:$false }; Throws { Get-W3CampaignContext -GameDir $game -Mode Host -CampaignName lan-coop -PlayerName HostWitcher -HostName ChangedHost } }
$joinOnly=Context Join GuestWitcher guestonly
$joinBefore=[IO.File]::ReadAllText($joinOnly.StatePath)
Check 'join-only campaign cannot silently acquire host authority' { Throws { Context Host HostWitcher guestonly }; Assert ([IO.File]::ReadAllText($joinOnly.StatePath) -ceq $joinBefore) 'Join-only state modified after rejected hosting' }
$goodState=[IO.File]::ReadAllBytes($hostContext.StatePath)
try { [IO.File]::WriteAllText($hostContext.StatePath,'{broken'); Check 'malformed state fails closed without replacement' { Throws { Context }; Assert ([IO.File]::ReadAllText($hostContext.StatePath) -ceq '{broken') 'Corrupt state replaced' } } finally { [IO.File]::WriteAllBytes($hostContext.StatePath,$goodState) }
try {
    $tampered=[Text.Encoding]::UTF8.GetString($goodState) | ConvertFrom-Json
    $tampered.Players[0].Session=[Convert]::ToBase64String((New-Object byte[] 128))
    $tampered | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $hostContext.StatePath
    Check 'tampered protected session refuses identity regeneration' { Throws { Context } }
} finally { [IO.File]::WriteAllBytes($hostContext.StatePath,$goodState) }
try {
    $tampered=[Text.Encoding]::UTF8.GetString($goodState) | ConvertFrom-Json; $tampered.HostProof=[Convert]::ToBase64String((New-Object byte[] 128))
    $tampered | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $hostContext.StatePath
    Check 'tampered host proof fails closed' { Throws { Context } }
} finally { [IO.File]::WriteAllBytes($hostContext.StatePath,$goodState) }
$clientFile=Join-Path $game 'bin/x64_dx12/WitcherOnlineClient.asi'; $clientBytes=[IO.File]::ReadAllBytes($clientFile)
try { [IO.File]::WriteAllText($clientFile,'changed'); Check 'new build marker rejects altered native client' { Throws { Context -Plan } } } finally { [IO.File]::WriteAllBytes($clientFile,$clientBytes) }
$beforePlan=Snapshot $game
$planJson=& (Join-Path $launcher 'Play-Seamless.ps1') -Mode Host -GameDir $game -PlayerName HostWitcher -HostName HostWitcher -CampaignName lan-coop -ServerJar $serverJar -Plan
Check 'CLI Plan is read-only and redacts all credentials' { Assert ((Snapshot $game) -ceq $beforePlan) 'CLI Plan wrote files'; $previewText=$planJson -join "`n"; Assert (-not $previewText.Contains($hostSecret) -and -not $previewText.Contains($hostContext.SessionId)) 'Plan leaked credentials'; $previewObject=$previewText | ConvertFrom-Json; Assert (-not $previewObject.Launch -and -not $previewObject.EffectsEnabled) 'Plan launch/effects wrong' }
$free=[Net.Sockets.UdpClient]::new(0); $port=$free.Client.LocalEndPoint.Port; $free.Dispose()
$server=$null; $hostPeer=$null; $guestPeer=$null
try {
    $server=Start-W3LanServer -JarPath $serverJar -JavaPath $JavaPath -Port $port -CampaignHost $hostContext.HostName -CampaignDirectory $hostContext.ServerStateDirectory -CampaignHostToken $hostContext.HostToken
    Check 'actual coordinator starts without proof in command line' { Assert (-not $server.StartInfo.Arguments.Contains($hostSecret)) 'Proof leaked in command line'; Assert ($server.StartInfo.EnvironmentVariables['WO_CAMPAIGN_HOST_TOKEN'] -ceq $hostSecret) 'Server missing child proof' }
    $hostPeer=Peer $port; $guestPeer=Peer $port
    $welcome=Send $hostPeer HostWitcher $hostContext.SessionId 1 @('HELLO','host',$hostSecret,'-')
    $epoch=$welcome[5]
    Check 'launcher host identity authenticates on real UDP server' { Assert ($welcome[9] -ceq 'WELCOME') 'Host not authenticated' }
    $guestWelcome=Send $guestPeer GuestWitcher $guestContext.SessionId 1 @('HELLO','guest','-','-')
    Check 'launcher guest identity joins without host proof' { Assert ($guestWelcome[9] -ceq 'WELCOME') 'Guest not welcomed' }
    $hostState=Send $hostPeer HostWitcher $hostContext.SessionId 2 @('GET_STATE',$epoch,'0','-')
    Check 'real coordinator state uses persisted identity' { Assert ($hostState[9] -ceq 'STATE') 'No coordinator state' }
    Stop-W3LanServer $server; $server.Dispose(); $server=$null
    $server=Start-W3LanServer -JarPath $serverJar -JavaPath $JavaPath -Port $port -CampaignHost $hostContext.HostName -CampaignDirectory $hostContext.ServerStateDirectory -CampaignHostToken $hostContext.HostToken
    $recovered=Context
    $gap=Send $hostPeer HostWitcher $recovered.SessionId 1 @('HELLO','host',(Plain $recovered.HostToken),'-')
    Check 'restart reports expected sequence for the same persisted player' { Assert ($gap[9] -ceq 'BAD_SEQUENCE' -and $gap[10] -ceq '3') 'Missing sequence recovery' }
    $again=Send $hostPeer HostWitcher $recovered.SessionId 3 @('HELLO','host',(Plain $recovered.HostToken),'-')
    Check 'same persisted identity reconnects to restarted campaign' { Assert ($again[9] -ceq 'WELCOME' -and $again[5] -ceq $epoch) 'Campaign epoch/identity changed' }
} finally { if ($hostPeer) { $hostPeer.Dispose() }; if ($guestPeer) { $guestPeer.Dispose() }; if ($server) { Stop-W3LanServer $server; $server.Dispose() } }
$savedCredential=[IO.File]::ReadAllBytes($hostContext.StatePath)
try {
    Remove-Item -LiteralPath $hostContext.StatePath
    Check 'missing credentials beside an existing ledger refuse regeneration' { Throws { Context }; Assert (-not (Test-Path -LiteralPath $hostContext.StatePath)) 'Missing credential state silently recreated' }
} finally { [IO.File]::WriteAllBytes($hostContext.StatePath,$savedCredential) }
$linked=Join-Path $game '.w3lan-campaigns\linked'
try {
    [void](New-Item -ItemType Junction -Path $linked -Target $seed)
    Check 'campaign junction cannot redirect credential writes' { Throws { Context Host HostWitcher linked }; Assert (-not (Test-Path -LiteralPath (Join-Path $seed 'campaign.json'))) 'Credential write escaped campaign directory' }
} finally { if (Test-Path -LiteralPath $linked) { [IO.Directory]::Delete($linked) } }
$standIn=$null; $deadServer=$null
try {
    $standIn=Start-StandIn 'Start-Sleep -Seconds 8'; $deadServer=Start-StandIn 'exit 7'; [void]$deadServer.WaitForExit(5000)
    Check 'unexpected server exit interrupts game wait' { Throws { Wait-W3CampaignGame -Game $standIn -Server $deadServer } }
} finally { foreach ($process in @($standIn,$deadServer)) { if ($process) { if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }; $process.Dispose() } } }
Write-Output "CAMPAIGN_LAUNCHER_PASS: $script:checks checks; fixture/server only, no game launched."
