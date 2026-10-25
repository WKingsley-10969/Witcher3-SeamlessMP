#requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\launcher\W3Campaign.psm1') -Force
$owner='launcher-test-' + [Guid]::NewGuid().ToString('N')
$held=$false; $standIn=$null
$slots=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\local\gameslot\slots'))
try {
    Invoke-W3CampaignGameSlot -Operation acquire -Owner $owner
    $held=$true
    $info=[Diagnostics.ProcessStartInfo]::new(); $info.FileName=(Get-Command powershell.exe).Source
    $info.Arguments='-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 20"'; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $standIn=[Diagnostics.Process]::Start($info)
    Invoke-W3CampaignGameSlot -Operation register-pid -Owner $owner -GameProcessId $standIn.Id
    Invoke-W3CampaignGameSlot -Operation acquire -Owner $owner
    $owned=@(Get-ChildItem -LiteralPath $slots -Filter 'slot-*.json' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } | Where-Object owner -eq $owner)
    if ($owned.Count -ne 1 -or @($owned[0].procs).Count -ne 1 -or $owned[0].procs[0].pid -ne $standIn.Id -or $owned[0].procs[0].created -le 0 -or $owned[0].procs[0].name -cne 'powershell.exe') { throw 'Exact stand-in identity not retained across lease renewal.' }
    Write-Output 'LEASE_HELPER_PASS: acquire, exact stand-in registration and renewal; no game launched.'
} finally {
    if ($standIn) { if (-not $standIn.HasExited) { $standIn.Kill(); [void]$standIn.WaitForExit(5000) }; $standIn.Dispose() }
    if ($held) { Invoke-W3CampaignGameSlot -Operation release -Owner $owner }
}
$remaining=@(Get-ChildItem -LiteralPath $slots -Filter 'slot-*.json' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } | Where-Object owner -eq $owner)
if ($remaining.Count) { throw 'Owned lease was not released.' }
Write-Output 'LEASE_RELEASE_PASS: stand-in stopped and owned lease removed.'
