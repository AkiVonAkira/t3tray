param([Parameter(Mandatory = $true)][string]$ExePath)
$ErrorActionPreference = 'Stop'
$ExePath = (Resolve-Path -LiteralPath $ExePath).Path
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('t3tray-cli-' + [Guid]::NewGuid())
$previousProfile = $env:USERPROFILE
$previousUser = $env:USERNAME
$mutex = $null
try {
    $env:USERPROFILE = $fixture
    $env:USERNAME = 't3tray-fixture-' + [Guid]::NewGuid()
    $stateDir = Join-Path $fixture '.t3tray'
    $null = New-Item -ItemType Directory $stateDir
    $state = @{ status = 'running'; channel = 'nightly'; version = '0.1.8-nightly.20261106.1'
        host = '0.0.0.0'; port = 4000; trayPid = 7; serverPid = 42; logs = "$stateDir\logs"
        serviceUpdate = @{ status = 'pending'; fromVersion = '0.1.7'; targetVersion = '0.1.8' }
        lastExit = $null; message = '' }
    [IO.File]::WriteAllText((Join-Path $stateDir 'state.json'), ($state | ConvertTo-Json -Compress))
    foreach ($helpArgs in @(@(), @('help'), @('--help'))) {
        $help = (& $ExePath @helpArgs | Out-String)
        if ($LASTEXITCODE -ne 0 -or $help -notmatch '(?m)^Usage: t3tray <command>' -or $help -notmatch '(?m)^\s+update \[--version vX\.Y\.Z\]') { throw "t3tray $helpArgs did not print help: $help" }
    }
    $absentHelp = (& $ExePath status --json | Out-String) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 3 -or $absentHelp.status -ne 'not running') { throw 'Printing help started a tray.' }
    foreach ($badArgs in @(@('frobnicate'), @('stop', 'now'), @('run', '--port', '0'), @('--port', '0'), @('update', '--version', 'latest'))) {
        $ErrorActionPreference = 'Continue'
        $usage = & $ExePath @badArgs 2>&1 | Out-String
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -ne 2 -or $usage -notmatch 't3tray help') { throw "t3tray $badArgs did not fail with usage code 2: $usage" }
    }
    $absentRun = (& $ExePath status --json | Out-String) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 3 -or $absentRun.status -ne 'not running') { throw 'An invalid run command started a tray.' }
    $mutex = New-Object Threading.Mutex($false, "Global\t3tray-$($env:USERNAME.ToLowerInvariant())-instance")
    $human = (& $ExePath status | Out-String)
    if ($LASTEXITCODE -ne 0 -or $human.TrimStart().StartsWith('{') -or $human -notmatch 'http://127.0.0.1:4000/') { throw "Human status did not describe the fixture: $human" }
    foreach ($row in @(@('Status','running'), @('Channel',$state.channel), @('Server',$state.version), @('Listen','0.0.0.0:4000'), @('Update','pending 0.1.8 (from 0.1.7)'), @('PIDs','tray 7, server 42'), @('Logs',$state.logs))) {
        if ($human -notmatch ('(?m)^' + [regex]::Escape($row[0]) + '\s+' + [regex]::Escape($row[1]) + '\r?$')) { throw "Human status lost $($row[0])." }
    }
    if ($human -match '(?m)^(Message|Last exit)\s') { throw 'Human status displayed empty optional fields.' }
    $json = (& $ExePath status --json | Out-String) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $json.status -ne 'running' -or $json.port -ne 4000 -or $json.serverPid -ne 42) { throw 'JSON status lost state fields.' }
    foreach ($flags in @(@('--jsn'), @('--json','--json'))) {
        $null = & $ExePath status @flags | Out-String
        if ($LASTEXITCODE -ne 2) { throw 'Invalid status flags did not fail with usage code 2.' }
    }
    $mutex.Dispose(); $mutex = $null
    $absent = (& $ExePath status --json | Out-String) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 3 -or $absent.status -eq 'running') { throw 'Stale state reported a running tray.' }
    Write-Output 'CLI passed help, usage, human status, JSON status, and stale-state checks with an isolated profile and mutex.'
} finally {
    if ($mutex) { $mutex.Dispose() }
    $env:USERPROFILE = $previousProfile
    $env:USERNAME = $previousUser
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 't3tray-cli-*') { throw 'Refusing to remove a path outside the CLI fixture.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
$global:LASTEXITCODE = 0
