# Requires Windows 10/11 x64 and Windows PowerShell 5.1 or newer.
param(
    [string]$Version = $env:T3TRAY_VERSION,
    [ValidatePattern('^[a-zA-Z0-9.:_-]+$')]
    [string]$ListenHost = $(if ($env:T3TRAY_HOST) { $env:T3TRAY_HOST } else { '127.0.0.1' }),
    [ValidateRange(1, 65535)]
    [int]$Port = $(if ($env:T3TRAY_PORT) { [int]$env:T3TRAY_PORT } else { 3773 }),
    [ValidateSet('stable', 'nightly')]
    [string]$Channel = $(if ($env:T3TRAY_CHANNEL) { $env:T3TRAY_CHANNEL } else { 'stable' }),
    [string]$ExePath,
    [string]$AssetDir,
    [string]$BaseDir,
    [switch]$NoStart,
    [bool]$StartAtSignIn = $true,
    [switch]$ShowSteps
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($env:OS -ne 'Windows_NT') { throw 't3tray requires Windows.' }
if (-not [Environment]::Is64BitOperatingSystem) { throw 't3tray requires 64-bit Windows.' }
if ($ExePath -and $AssetDir) { throw 'Use either -ExePath or -AssetDir.' }
if ($Version -and $Version -notmatch '^v?[0-9][a-zA-Z0-9.+-]*$') { throw 'Invalid release version.' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$trayDir = Join-Path $env:USERPROFILE '.t3tray'
$exe = Join-Path $trayDir 't3tray.exe'
$binDir = Join-Path $env:USERPROFILE '.t3\bin'
$temporary = $null
$stepState = @{ Label = ''; Step = $null }
function Complete-InstallStep([string]$State) {
    if ($stepState.Step) { Write-T3TrayStepResult $stepState.Step $State; $stepState.Step = $null }
}
function Write-InstallStep([string]$Label) {
    if ($ShowSteps) {
        Complete-InstallStep ok
        $stepState.Step = Write-T3TrayStepStart $Label
    }
    $stepState.Label = $Label
}
# Child command output stays out of the console; it is returned for error messages.
function Invoke-InstallCommand([scriptblock]$Command) {
    $ErrorActionPreference = 'Continue'
    $output = & $Command 2>&1 | ForEach-Object { "$_" } | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output.Trim() }
}
try {
    Write-InstallStep 'Acquire release assets'
    if ($AssetDir) {
        $ExePath = Join-Path $AssetDir 't3tray.exe'
    } elseif (-not $ExePath) {
        $temporary = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $temporary
        $base = 'https://github.com/AkiVonAkira/t3tray/releases'
        if ($Version) { $base += '/download/v' + $Version.TrimStart('v') } else { $base += '/latest/download' }
        foreach ($asset in @('t3tray.exe', 'SHA256SUMS')) {
            Invoke-WebRequest "$base/$asset" -OutFile (Join-Path $temporary $asset) -UseBasicParsing
        }
        $ExePath = Join-Path $temporary 't3tray.exe'
    }
    Write-InstallStep 'Verify SHA-256'
    $ExePath = (Resolve-Path -LiteralPath $ExePath).Path
    $sums = Join-Path (Split-Path -Parent $ExePath) 'SHA256SUMS'
    $entries = @(Get-Content -LiteralPath $sums | Where-Object { $_ -match '^[a-fA-F0-9]{64}\s+\*?t3tray\.exe$' })
    if ($entries.Count -ne 1) { throw 'SHA256SUMS must contain exactly one t3tray.exe entry.' }
    $expected = ($entries[0] -split '\s+')[0]
    if ((Get-FileHash -LiteralPath $ExePath -Algorithm SHA256).Hash -ne $expected) { throw 't3tray.exe SHA-256 mismatch.' }
    if ($ExePath -eq $exe) { throw 'Source executable must be outside the install directory.' }

    Write-InstallStep 'Stop and replace tray'
    # t3tray update starts this installer and waits for it; leave that process running.
    $updater = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -Property ParentProcessId).ParentProcessId
    $running = @(Get-Process -Name t3tray -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe -and $_.Id -ne $updater })
    if ($running.Count -gt 0) {
        $null = Invoke-InstallCommand { & $exe quit }
        $running | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
        $running | Stop-Process -Force -ErrorAction SilentlyContinue
        $running | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    }
    $null = New-Item -ItemType Directory -Force -Path $trayDir, $binDir
    Install-T3TrayExecutable $ExePath $exe
    Write-InstallStep 'Write command wrapper'
    # Piping makes PowerShell wait for the GUI executable and forward its output.
    "@echo off`r`npowershell.exe -NoLogo -NoProfile -Command `"& (Join-Path `$env:USERPROFILE '.t3tray\t3tray.exe') %* | ForEach-Object { `$_ }; exit `$LASTEXITCODE`"`r`nexit /b %ERRORLEVEL%" |
        Set-Content -LiteralPath (Join-Path $binDir 't3tray.cmd') -Encoding ascii
    Write-InstallStep 'Configure sign-in startup'
    $runArgs = "run --host $ListenHost --port $Port --channel $($Channel.ToLowerInvariant())"
    if ($BaseDir) { $runArgs += " --base-dir `"$BaseDir`"" }
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (-not (Test-Path -LiteralPath $runKey)) { $null = New-Item -Path $runKey }
    if ($StartAtSignIn) {
        Set-ItemProperty -Path $runKey -Name T3Tray -Value "`"$exe`" $runArgs"
    } else {
        Remove-ItemProperty -Path $runKey -Name T3Tray -ErrorAction SilentlyContinue
    }
    if ($NoStart) { Complete-InstallStep ok; return }

    Write-InstallStep 'Start tray'
    $scheduler = New-Object -ComObject Schedule.Service
    $scheduler.Connect()
    $definition = $scheduler.NewTask(0)
    $definition.Principal.LogonType = 3
    $definition.Settings.ExecutionTimeLimit = 'PT0S'
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    $action = $definition.Actions.Create(0)
    $action.Path = $exe
    $action.Arguments = $runArgs
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $folder = $scheduler.GetFolder('\')
    $taskName = 't3tray-start-' + [Guid]::NewGuid().ToString()
    $task = $folder.RegisterTaskDefinition($taskName, $definition, 6, $user, $null, 3)
    try {
        $null = $task.Run($null)
        Start-Sleep -Seconds 3
    } finally { $folder.DeleteTask($taskName, 0) }
    Write-InstallStep 'Wait for server readiness'
    $deadline = (Get-Date).AddMinutes(10)
    do {
        $state = (& $exe status --json | Out-String).Trim()
        if ($state -match '"status":"running"') { Complete-InstallStep ok; return }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "t3tray did not report running within 10 minutes. See $trayDir\logs. Last state $state"
} catch {
    if ($ShowSteps) {
        Complete-InstallStep failed
        throw "$($stepState.Label) failed. $($_.Exception.Message) Resolve the error and rerun. See $trayDir/logs."
    }
    throw
} finally {
    if ($temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
