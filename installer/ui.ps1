# Visual reference: Kayzel's Stillwater installer and palette.json.
# This implementation uses only the controls needed by t3tray.
function Initialize-T3TrayConsole {
    try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding } catch { }
    if ($env:OS -ne 'Windows_NT' -or $Host.UI.SupportsVirtualTerminal) { return }
    if (-not ('T3TrayNativeConsole' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class T3TrayNativeConsole {
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int id);
    [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr handle, out uint mode);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr handle, uint mode);
}
'@
    }
    $handle = [T3TrayNativeConsole]::GetStdHandle(-11)
    [uint32]$mode = 0
    if ([T3TrayNativeConsole]::GetConsoleMode($handle, [ref]$mode)) {
        [void][T3TrayNativeConsole]::SetConsoleMode($handle, ($mode -bor 4))
    }
}

function Get-T3TrayStyle {
    $esc = [char]27
    $style = @{ Reset = "$esc[0m"; Accent = "$esc[38;2;90;168;180m"
        Text = "$esc[38;2;235;219;178m"; Muted = "$esc[38;2;143;143;153m"
        Warm = "$esc[38;2;196;164;137m"; Error = "$esc[38;2;244;71;71m" }
    if ($env:NO_COLOR -or [Console]::IsOutputRedirected) { foreach ($key in @($style.Keys)) { $style[$key] = '' } }
    return $style
}

function Write-T3TrayFrame {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console UI output intentionally bypasses the success pipeline.')]
    param([string]$Title, [string[]]$Lines, [string]$Hints = 'enter continue  ·  b back  ·  q quit')
    $s = Get-T3TrayStyle
    $esc = [char]27
    [Console]::Write("$esc[H$esc[2J")
    Write-Host "$($s.Muted)┌$($s.Reset)  $($s.Accent)t3tray$($s.Reset)  $($s.Warm)windows"
    Write-Host "$($s.Accent)◆$($s.Reset)  $($s.Text)$Title$($s.Reset)"
    foreach ($line in $Lines) { Write-Host "$($s.Muted)│$($s.Reset)  $line$($s.Reset)" }
    Write-Host "$($s.Muted)└$($s.Reset)  $($s.Accent)$Hints$($s.Reset)"
}

function Read-T3TrayChoice {
    param([string]$Title, [string[]]$Options, [int]$Selected = 0, [string[]]$Details = @())
    $s = Get-T3TrayStyle
    while ($true) {
        $lines = @($Details)
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $lines += if ($i -eq $Selected) { "$($s.Accent)●  $($s.Text)$($Options[$i])" } else { "$($s.Muted)○  $($Options[$i])" }
        }
        Write-T3TrayFrame $Title $lines '↑↓ jk nav  ·  space/enter choose  ·  b back  ·  q quit'
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'UpArrow' -or $key.KeyChar -eq 'k') { $Selected = ($Selected + $Options.Count - 1) % $Options.Count }
        if ($key.Key -eq 'DownArrow' -or $key.KeyChar -eq 'j') { $Selected = ($Selected + 1) % $Options.Count }
        if ($key.KeyChar -eq 'q' -or $key.Key -eq 'Escape' -or [int]$key.KeyChar -eq 3) { throw 'cancelled' }
        if ($key.KeyChar -eq 'b' -or $key.Key -eq 'LeftArrow') { return -1 }
        if ($key.Key -in @('Enter', 'Spacebar')) { return $Selected }
    }
}

function Read-T3TrayText {
    param([string]$Title, [string]$Value, [ValidateSet('Port', 'ListenHost')][string]$Field)
    $message = ''
    while ($true) {
        Write-T3TrayFrame $Title @($Value, $message) 'type value  ·  enter continue  ·  esc back  ·  ctrl+c quit'
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Escape') { return $null }
        if ([int]$key.KeyChar -eq 3) { throw 'cancelled' }
        if ($key.Key -eq 'Enter') {
            try { $argsMap = @{}; $argsMap[$Field] = $Value; $null = New-T3TrayConfig @argsMap; return $Value }
            catch { $message = $_.Exception.Message }
        } elseif ($key.Key -eq 'Backspace') {
            if ($Value.Length) { $Value = $Value.Substring(0, $Value.Length - 1) }
        } elseif (-not [char]::IsControl($key.KeyChar)) { $Value += $key.KeyChar }
    }
}

function Invoke-T3TrayWizard {
    param($Detection)
    Initialize-T3TrayConsole
    $config = $Detection.Config
    $step = 'Check'
    $listenChoice = if ($config.ListenHost -eq '127.0.0.1') { 0 } elseif ($config.ListenHost -eq '0.0.0.0') { 1 } else { 2 }
    while ($true) {
        switch ($step) {
            'Check' {
                $choice = Read-T3TrayChoice 'check' @('Configure and install') 0 @(
                    "Existing t3tray install: $($Detection.Installed)", "Run value: $($Detection.RunValue)",
                    "win-t3service task: $($Detection.OldTask)", "T3 desktop: $($Detection.Desktop)",
                    "Port $($config.Port): $($Detection.PortOwner)")
                if ($choice -ge 0) { $step = 'Channel' }
            }
            'Channel' {
                $choice = Read-T3TrayChoice 'channel' @('Stable', 'Nightly') ([int]($config.Channel -eq 'nightly'))
                if ($choice -lt 0) { $step = 'Check' } else { $config.Channel = @('stable', 'nightly')[$choice]; $step = 'Listen' }
            }
            'Listen' {
                $choice = Read-T3TrayChoice 'listen address' @('This PC only (127.0.0.1)', 'LAN (0.0.0.0)', 'Custom') $listenChoice
                if ($choice -lt 0) { $step = 'Channel'; break }
                $listenChoice = $choice
                switch ($choice) {
                    0 { $config.ListenHost = '127.0.0.1'; $config.Firewall = $false; $step = 'Port' }
                    1 { $config.ListenHost = '0.0.0.0'; $step = 'Firewall' }
                    2 { $config.Firewall = $false; $step = 'Custom' }
                }
            }
            'Custom' {
                $value = Read-T3TrayText 'custom listen address' $config.ListenHost 'ListenHost'
                if ($null -eq $value) { $step = 'Listen' } else { $config.ListenHost = $value; $step = 'Port' }
            }
            'Firewall' {
                $choice = Read-T3TrayChoice 'Windows Firewall' @('Yes, allow this port on Private networks', 'No, manage firewall myself') ([int](-not $config.Firewall)) @(
                    'Only this step will request administrator approval (UAC).', 'The rest of the installer runs as your user.')
                if ($choice -lt 0) { $step = 'Listen' } else { $config.Firewall = $choice -eq 0; $step = 'Port' }
            }
            'Port' {
                $value = Read-T3TrayText 'port (1 to 65535)' ([string]$config.Port) 'Port'
                if ($null -eq $value) { $step = if ($listenChoice -eq 1) { 'Firewall' } elseif ($listenChoice -eq 2) { 'Custom' } else { 'Listen' } }
                else { $config.Port = [int]$value; $step = 'Startup' }
            }
            'Startup' {
                $choice = Read-T3TrayChoice 'start at sign-in' @('Yes', 'No') ([int](-not $config.StartAtSignIn))
                if ($choice -lt 0) { $step = 'Port' } else {
                    $config.StartAtSignIn = $choice -eq 0
                    $step = if ($Detection.OldTask) { 'Retire' } else { 'Review' }
                }
            }
            'Retire' {
                $choice = Read-T3TrayChoice 'retire win-t3service' @('Yes, stop and disable the old service', 'No, keep it') ([int](-not $config.Retire))
                if ($choice -lt 0) { $step = 'Startup' } else { $config.Retire = $choice -eq 0; $step = 'Review' }
            }
            'Review' {
                $owner = Get-T3TrayPortOwner $config.Port
                $choice = Read-T3TrayChoice 'review' @('Install', 'Go back') 0 (@("Port $($config.Port): $owner") + @(Get-T3TrayPlan $config))
                if ($choice -ne 0) { $step = if ($Detection.OldTask) { 'Retire' } else { 'Startup' } }
                else { return (New-T3TrayConfig -Channel $config.Channel -ListenHost $config.ListenHost -Port $config.Port -StartAtSignIn $config.StartAtSignIn -Firewall $config.Firewall -Retire $config.Retire) }
            }
        }
    }
}

function Write-T3TrayStep {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console UI output intentionally bypasses the success pipeline.')]
    param([string]$Label, [ValidateSet('running', 'ok', 'failed', 'planned')][string]$State)
    $s = Get-T3TrayStyle
    $mark = switch ($State) { 'running' { '⠋' } 'ok' { '●' } 'failed' { '■' } 'planned' { '○' } }
    $color = if ($State -eq 'failed') { $s.Error } else { $s.Accent }
    Write-Host "$($s.Muted)│$($s.Reset)  $color$mark$($s.Reset)  $($s.Text)$($Label.PadRight(26))  $color$State$($s.Reset)"
}

function Invoke-T3TrayStep {
    param([string]$Label, [scriptblock]$Action)
    Write-T3TrayStep $Label running
    try { & $Action; Write-T3TrayStep $Label ok }
    catch {
        Write-T3TrayStep $Label failed
        throw "$Label failed. $($_.Exception.Message) Resolve this error, then rerun the installer. Logs are in ~/.t3tray/logs."
    }
}
