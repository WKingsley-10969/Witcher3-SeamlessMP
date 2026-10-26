# Join password (server JoinGate.java). The password never crosses the network: the host's server
# sends a one-time nonce and this PC answers with HMAC-SHA256(password, "w3lan-join:" + nonce).
# Once answered, this PC's address may join for as long as the host's server runs.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-W3LanSecret {
    param([Security.SecureString]$Secret)
    if (-not $Secret -or $Secret.Length -eq 0) { return '' }
    [Net.NetworkCredential]::new('', $Secret).Password
}

function Get-W3LanJoinProof {
    param([Parameter(Mandatory)][string]$Password, [Parameter(Mandatory)][string]$Nonce)
    $hmac = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($Password))
    try { -join ($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("w3lan-join:$Nonce")) | ForEach-Object { $_.ToString('x2') }) }
    finally { $hmac.Dispose() }
}

# Answers the host's challenge from this PC. Returns 'OK', 'OPEN' (the host set no password),
# 'WRONG_PASSWORD' or 'TOO_MANY_ATTEMPTS'; throws when the host does not answer.
function Request-W3LanJoin {
    param(
        [Parameter(Mandatory)][string]$Address,
        [ValidateRange(1,65535)][int]$Port = 40000,
        [Parameter(Mandatory)][Security.SecureString]$Password,
        [ValidateRange(50,10000)][int]$TimeoutMs = 2000
    )
    $udp = [Net.Sockets.UdpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($Address, $Port)
        $exchange = {
            param([string]$Text)
            $data = [Text.Encoding]::UTF8.GetBytes($Text)
            [void]$udp.Send($data, $data.Length)
            $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
            [Text.Encoding]::UTF8.GetString($udp.Receive([ref]$remote))
        }
        # a lost packet over the internet: start again with a fresh nonce
        for ($attempt = 1; ; $attempt++) {
            try {
                $reply = & $exchange 'AUTH'
                if ($reply -ceq "AUTH`tOPEN") { return 'OPEN' }
                if ($reply -ceq "ERROR`tTOO_MANY_ATTEMPTS") { return 'TOO_MANY_ATTEMPTS' }
                if ($reply -cmatch "\AAUTH`tCHALLENGE`t([0-9a-f]{32})\z") { $nonce = $Matches[1] }
                else { throw "Unexpected reply from the host: $reply" }
                $reply = & $exchange ("AUTH`t$nonce`t" + (Get-W3LanJoinProof -Password (ConvertFrom-W3LanSecret $Password) -Nonce $nonce))
                if ($reply -ceq "AUTH`tOK") { return 'OK' }
                if ($reply -ceq "ERROR`tWRONG_PASSWORD") { return 'WRONG_PASSWORD' }
                throw "Unexpected reply from the host: $reply"
            } catch [Net.Sockets.SocketException] {
                if ($attempt -ge 3) { throw "The host did not answer the join password check ($($_.Exception.SocketErrorCode))." }
            }
        }
    } finally { $udp.Dispose() }
}

Export-ModuleMember -Function ConvertFrom-W3LanSecret, Get-W3LanJoinProof, Request-W3LanJoin
