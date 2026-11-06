function Get-T3TrayServerConfig {
    param([int]$Port)
    $socket = New-Object Net.WebSockets.ClientWebSocket
    $timeout = New-Object Threading.CancellationTokenSource
    $timeout.CancelAfter(15000)
    $session = $null
    $runtimeExe = $null
    try {
        $baseDir = Join-Path $env:USERPROFILE '.t3'
        $state = Get-Content (Join-Path $baseDir 'runtime/service-state.json') -Raw | ConvertFrom-Json
        if ($state.activeVersion -notmatch '^[0-9][a-zA-Z0-9.+-]*$') { throw 'Invalid active runtime version.' }
        $runtimeExe = Join-Path $baseDir "runtime/versions/$($state.activeVersion)/t3.exe"
        $sessionText = & $runtimeExe auth session issue --ttl 1m --label t3tray-installer-check --json --base-dir $baseDir 2>$null | Out-String
        if ($LASTEXITCODE -ne 0) { throw 'Could not create a verification session.' }
        $session = $sessionText | ConvertFrom-Json
        $origin = "http://127.0.0.1:$Port"
        $descriptor = Invoke-RestMethod "$origin/.well-known/t3/environment" -TimeoutSec 15
        $headers = @{ Authorization = "Bearer $($session.token)" }
        $ticket = Invoke-RestMethod "$origin/api/auth/websocket-ticket" -Method Post -Headers $headers -TimeoutSec 15
        $query = 'wsTicket=' + [uri]::EscapeDataString($ticket.ticket)
        if ($descriptor.orchestrationProtocolVersion) { $query += '&orchestrationProtocol=' + $descriptor.orchestrationProtocolVersion }
        $socket.ConnectAsync([uri]"ws://127.0.0.1:$Port/ws?$query", $timeout.Token).GetAwaiter().GetResult()
        $json = '{"_tag":"Request","id":"1","tag":"server.getConfig","payload":{},"headers":[]}'
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $segment = New-Object 'ArraySegment[byte]' -ArgumentList @(,$bytes)
        $socket.SendAsync($segment, [Net.WebSockets.WebSocketMessageType]::Text, $true, $timeout.Token).GetAwaiter().GetResult()
        $buffer = New-Object byte[] 65536
        while ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
            $stream = New-Object IO.MemoryStream
            try {
                do {
                    $part = New-Object 'ArraySegment[byte]' -ArgumentList @(,$buffer)
                    $received = $socket.ReceiveAsync($part, $timeout.Token).GetAwaiter().GetResult()
                    if ($received.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw 'Server closed the verification connection.' }
                    $stream.Write($buffer, 0, $received.Count)
                    if ($stream.Length -gt 4MB) { throw 'Server config response exceeded 4 MB.' }
                } while (-not $received.EndOfMessage)
                $message = [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
                foreach ($item in @($message)) {
                    if ($item.requestId -eq '1' -and $item._tag -eq 'Exit') {
                        if ($item.exit._tag -ne 'Success') { throw 'server.getConfig failed.' }
                        return $item.exit.value
                    }
                }
            } finally { $stream.Dispose() }
        }
        throw 'No server.getConfig response.'
    } catch {
        throw 'server.getConfig verification failed. Check the running runtime, local authentication and ~/.t3tray/logs, then rerun.'
    } finally {
        $socket.Dispose(); $timeout.Dispose()
        if ($session -and $runtimeExe) {
            $null = & $runtimeExe auth session revoke $session.sessionId --base-dir $baseDir 2>$null | Out-String
            if ($LASTEXITCODE -ne 0) { Write-Warning 'Verification session cleanup failed. It expires after one minute.' }
        }
    }
}

function Invoke-T3TrayVerification {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Config is captured by verification scriptblocks.')]
    param($Config)
    $exe = Join-Path $env:USERPROFILE '.t3tray\t3tray.exe'
    Invoke-T3TrayStep 'Tray process' {
        $process = @(Get-Process t3tray -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
        if (-not $process.Count) { throw 'Tray process is missing.' }
    }
    Invoke-T3TrayStep 't3tray status' {
        $state = (& $exe status --json | Out-String) | ConvertFrom-Json
        if ($state.status -ne 'running') { throw 'Tray status is not running.' }
    }
    Invoke-T3TrayStep 'HTTP 200' {
        $response = Invoke-WebRequest (Get-T3TrayLocalUrl $Config.ListenHost $Config.Port) -UseBasicParsing -TimeoutSec 15
        if ($response.StatusCode -ne 200) { throw 'Server did not return HTTP 200.' }
    }
    Invoke-T3TrayStep 'server.getConfig' {
        $server = Get-T3TrayServerConfig $Config.Port
        if ($server.environment.capabilities.serverSelfUpdate -ne 'boot-service') { throw 'Expected serverSelfUpdate=boot-service.' }
    }
}
