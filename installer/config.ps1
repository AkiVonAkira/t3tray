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

function Get-T3TrayLocalUrl {
    param([string]$ListenHost, [int]$Port)
    $address = $ListenHost.Trim('[', ']')
    if ($address -in @('', '0.0.0.0', '::', '*')) { $address = '127.0.0.1' }
    elseif ($address.Contains(':')) { $address = "[$address]" }
    "http://${address}:$Port/"
}

function Get-T3TrayStatusCommand {
    param([string]$PathValue = $env:Path, [string]$BinDir = (Join-Path $env:USERPROFILE '.t3\bin'))
    $entries = @($PathValue -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') })
    if ($entries -contains $BinDir.TrimEnd('\')) { return 't3tray status' }
    "& `"$(Join-Path $BinDir 't3tray.cmd')`" status"
}

function Get-T3TrayPlanStep {
    param($Config, [bool]$NoStart = $false)
    $changes = @(
        if ($Config.Firewall) { "Allow TCP $($Config.Port) in Windows Firewall, Private networks only (UAC)" }
        'Get t3tray.exe and check its SHA-256 before replacing anything'
        'Stop the running tray and replace t3tray.exe'
        if ($Config.Retire) { 'Stop and disable win-t3service' }
        'Write the t3tray command wrapper'
        if ($Config.StartAtSignIn) { 'Set the sign-in entry' } else { 'Remove the sign-in entry' }
        if (-not $NoStart) { 'Start the tray' })
    $checks = @(if (-not $NoStart) {
        'Tray process and t3tray status'
        "HTTP 200 at $(Get-T3TrayLocalUrl $Config.ListenHost $Config.Port)"
        'server.getConfig reports boot-service updates'
    })
    foreach ($text in $changes) { [pscustomobject]@{ Group = 'Changes'; Text = $text } }
    foreach ($text in $checks) { [pscustomobject]@{ Group = 'Checks'; Text = $text } }
}
