function Test-T3TrayInteractive {
    param([System.Collections.IDictionary]$Parameters, [string[]]$EnvironmentNames = @(),
        [bool]$InputRedirected = [Console]::IsInputRedirected,
        [bool]$OutputRedirected = [Console]::IsOutputRedirected, [bool]$CiSet = (Test-Path Env:CI))
    if ($InputRedirected -or $OutputRedirected -or $CiSet) { return $false }
    if (@($EnvironmentNames | Where-Object { $_ -like 'T3TRAY_*' -and $_ -ne 'T3TRAY_REF' }).Count) { return $false }
    return @($Parameters.Keys | Where-Object { $_ -ne 'DryRun' }).Count -eq 0
}

function New-T3TrayConfig {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory configuration without side effects.')]
    param([string]$Channel = 'stable', [string]$ListenHost = '127.0.0.1', [string]$Port = '3773',
        [bool]$StartAtSignIn = $true, [bool]$Firewall = $false, [bool]$Retire = $false)
    $number = 0
    if (-not [int]::TryParse($Port, [ref]$number) -or $number -lt 1 -or $number -gt 65535) {
        throw 'Port must be a number from 1 to 65535.'
    }
    if ($Channel -notin @('stable', 'nightly')) { throw 'Choose stable or nightly.' }
    if ($ListenHost -notmatch '^[a-zA-Z0-9.:_-]+$') { throw 'Host must be an address or hostname without spaces.' }
    [pscustomobject]@{ Channel = $Channel; ListenHost = $ListenHost; Port = $number
        StartAtSignIn = $StartAtSignIn; Firewall = ($Firewall -and $ListenHost -eq '0.0.0.0'); Retire = $Retire }
}

function ConvertFrom-T3TrayRunValue {
    param([string]$RunValue, [string]$DesktopChannel = 'stable')
    $values = @{ Channel = $DesktopChannel }
    foreach ($pair in @(@('host', 'ListenHost'), @('port', 'Port'), @('channel', 'Channel'))) {
        if ($RunValue -match ('--' + $pair[0] + '\s+([^\s"]+)')) { $values[$pair[1]] = $Matches[1] }
    }
    New-T3TrayConfig @values
}

function Get-T3TrayDetection {
    $result = [pscustomobject]@{ Installed = $false; RunValue = ''; OldTask = $false
        Desktop = 'Not found'; DesktopChannel = 'stable'; PortOwner = 'Not checked on this OS'; Config = (New-T3TrayConfig) }
    if ($env:OS -ne 'Windows_NT') { return $result }
    $result.Installed = Test-Path (Join-Path $env:USERPROFILE '.t3tray\t3tray.exe')
    $run = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name T3Tray -ErrorAction SilentlyContinue
    if ($run) { $result.RunValue = $run.T3Tray }
    $result.OldTask = [bool](Get-ScheduledTask -TaskName 'T3 Code Server (User Logon)' -ErrorAction SilentlyContinue)
    $desktopDir = Join-Path $env:LOCALAPPDATA 'Programs\t3code'
    $uninstaller = Get-ChildItem $desktopDir -Filter 'Uninstall*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($uninstaller) {
        $version = $uninstaller.VersionInfo.ProductVersion
        $result.DesktopChannel = if ($version -match 'nightly') { 'nightly' } else { 'stable' }
        $result.Desktop = "$version ($($result.DesktopChannel))"
    }
    $result.Config = ConvertFrom-T3TrayRunValue $result.RunValue $result.DesktopChannel
    if ($result.Installed) { $result.Config.StartAtSignIn = [bool]$result.RunValue }
    $result.PortOwner = Get-T3TrayPortOwner $result.Config.Port
    return $result
}

function Get-T3TrayPortOwner {
    param([int]$Port)
    if ($env:OS -ne 'Windows_NT') { return 'Not checked on this OS' }
    $connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
    if (-not $connections.Count) { return 'Available' }
    return (@($connections | ForEach-Object {
        $process = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        "$($process.ProcessName) (PID $($_.OwningProcess), $($_.LocalAddress):$Port)"
    }) | Select-Object -Unique) -join ', '
}

function Get-T3TrayPlan {
    param($Config, [bool]$NoStart = $false)
    if ($Config.Firewall) { "Request UAC to allow TCP $($Config.Port) on Windows Firewall Private profile only" }
    'Download release assets (or use supplied assets)'
    'Verify t3tray.exe SHA-256 before replacing anything'
    'Stop existing tray and copy executable'
    if ($Config.Retire) { 'Stop win-t3service, disable its logon task, remove its wrapper' }
    'Write t3tray.cmd wrapper'
    if ($Config.StartAtSignIn) { 'Set T3Tray sign-in Run value' } else { 'Remove T3Tray sign-in Run value' }
    "Arguments --host $($Config.ListenHost) --port $($Config.Port) --channel $($Config.Channel)"
    if (-not $NoStart) {
        'Start tray through a temporary interactive scheduled task'
        'Verify tray process and t3tray status running'
        "Verify HTTP 200 at http://127.0.0.1:$($Config.Port)/"
        'Verify server.getConfig serverSelfUpdate=boot-service'
    }
}
