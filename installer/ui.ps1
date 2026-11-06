# Visual reference: Kayzel's Stillwater installer and palette.json.
# This implementation uses only the controls needed by t3tray.
function Initialize-T3TrayConsole {
    try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding }
    catch { Write-Verbose 'Console encoding could not be set. Using the terminal default.' }
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
        Warm = "$esc[38;2;196;164;137m"; Error = "$esc[38;2;244;71;71m"
        Invert = "$esc[7m"; Revert = "$esc[27m" }
    if ($env:NO_COLOR -or [Console]::IsOutputRedirected) { foreach ($key in @($style.Keys)) { $style[$key] = '' } }
    return $style
}

# Every wizard keypress goes through here so tests can script real keys.
function Read-T3TrayKey { [Console]::ReadKey($true) }

function Write-T3TrayHeader {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console UI output intentionally bypasses the success pipeline.')]
    param([string]$Title, [switch]$Clear)
    $s = Get-T3TrayStyle
    $esc = [char]27
    if ($Clear -and -not [Console]::IsOutputRedirected) { [Console]::Write("$esc[H$esc[2J") }
    Write-Host "$($s.Muted)┌$($s.Reset)  $($s.Accent)t3tray$($s.Reset)  $($s.Warm)windows$($s.Reset)"
    Write-Host "$($s.Accent)◆$($s.Reset)  $($s.Text)$Title$($s.Reset)"
}

function Write-T3TrayNote {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console UI output intentionally bypasses the success pipeline.')]
    param([string]$Text)
    $s = Get-T3TrayStyle
    Write-Host "$($s.Muted)│  $Text$($s.Reset)"
}

function Write-T3TrayFrame {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console UI output intentionally bypasses the success pipeline.')]
    param([string]$Title, [string[]]$Lines, [string]$Hints = 'enter continue  ·  b back  ·  q quit')
    $s = Get-T3TrayStyle
    Write-T3TrayHeader $Title -Clear
    foreach ($line in $Lines) { Write-Host "$($s.Muted)│$($s.Reset)  $line$($s.Reset)" }
    Write-Host "$($s.Muted)└$($s.Reset)  $($s.Accent)$Hints$($s.Reset)"
}

function Read-T3TrayChoice {
    param([string]$Title, [string[]]$Options, [int]$Selected = 0, [string[]]$Details = @())
    $s = Get-T3TrayStyle
    while ($true) {
        $lines = @($Details)
        if ($lines.Count) { $lines += '' }
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $lines += if ($i -eq $Selected) { "$($s.Accent)●  $($s.Text)$($Options[$i])" } else { "$($s.Muted)○  $($Options[$i])" }
        }
        Write-T3TrayFrame $Title $lines '↑↓ jk move  ·  space/enter choose  ·  b back  ·  q quit'
        $key = Read-T3TrayKey
        if ($key.Key -eq 'UpArrow' -or $key.KeyChar -eq 'k') { $Selected = ($Selected + $Options.Count - 1) % $Options.Count }
        if ($key.Key -eq 'DownArrow' -or $key.KeyChar -eq 'j') { $Selected = ($Selected + 1) % $Options.Count }
        if ($key.KeyChar -eq 'q' -or $key.Key -eq 'Escape' -or [int]$key.KeyChar -eq 3) { throw 'cancelled' }
        if ($key.KeyChar -eq 'b' -or $key.Key -eq 'LeftArrow') { return -1 }
        if ($key.Key -in @('Enter', 'Spacebar')) { return $Selected }
    }
}

function Get-T3TrayFieldRule {
    param([ValidateSet('Port', 'ListenHost')][string]$Field)
    if ($Field -eq 'Port') {
        return @{ Label = 'Port'; Allowed = '^[0-9]$'; MaxLength = 5; Hint = '1 to 65535'; Rejected = 'Port accepts digits only.' }
    }
    @{ Label = 'Address'; Allowed = '^[a-zA-Z0-9.:_-]$'; MaxLength = 60; Hint = 'IP address or hostname'
        Rejected = 'Use letters, digits, dot, colon, dash or underscore.' }
}

# Pure key handler for the text field. Mode prefill and all both replace on typing;
# Backspace edits a prefill but clears a Ctrl+A selection.
function Invoke-T3TrayFieldKey {
    param([hashtable]$State, [ConsoleKeyInfo]$Key, [hashtable]$Rule)
    $value = [string]$State.Value
    $caret = [Math]::Min([int]$State.Caret, $value.Length)
    $mode = $State.Mode
    $action = ''
    $message = ''
    $control = ($Key.Modifiers -band [ConsoleModifiers]::Control) -ne 0
    $code = [int]$Key.KeyChar
    if ($code -eq 3) { $action = 'cancel' }
    elseif ($Key.Key -eq 'Enter') { $action = 'submit' }
    elseif ($Key.Key -eq 'Escape') { $action = 'back' }
    elseif ($code -eq 1 -or ($control -and $Key.Key -eq 'A')) { $mode = 'all'; $caret = $value.Length }
    elseif ($Key.Key -eq 'LeftArrow') { $caret = [Math]::Max(0, $caret - 1); $mode = 'none' }
    elseif ($Key.Key -eq 'RightArrow') { $caret = [Math]::Min($value.Length, $caret + 1); $mode = 'none' }
    elseif ($Key.Key -eq 'Home') { $caret = 0; $mode = 'none' }
    elseif ($Key.Key -eq 'End') { $caret = $value.Length; $mode = 'none' }
    elseif ($Key.Key -in @('Backspace', 'Delete') -and $mode -eq 'all') { $value = ''; $caret = 0; $mode = 'none' }
    elseif ($Key.Key -eq 'Backspace') {
        if ($caret -gt 0) { $value = $value.Remove($caret - 1, 1); $caret-- }
        $mode = 'none'
    } elseif ($Key.Key -eq 'Delete') {
        if ($caret -lt $value.Length) { $value = $value.Remove($caret, 1) }
        $mode = 'none'
    } elseif ($code -ne 0 -and -not [char]::IsControl($Key.KeyChar)) {
        if ([string]$Key.KeyChar -notmatch $Rule.Allowed) { $message = $Rule.Rejected }
        elseif ($mode -ne 'none') { $value = [string]$Key.KeyChar; $caret = 1; $mode = 'none' }
        elseif ($value.Length -ge $Rule.MaxLength) { $message = "Use at most $($Rule.MaxLength) characters." }
        else { $value = $value.Insert($caret, [string]$Key.KeyChar); $caret++ }
    }
    @{ Value = $value; Caret = $caret; Mode = $mode; Action = $action; Message = $message }
}

function Format-T3TrayField {
    param([hashtable]$State, [hashtable]$Rule)
    $s = Get-T3TrayStyle
    $value = [string]$State.Value
    $caret = [int]$State.Caret
    $color = if ($State.Mode -eq 'none') { $s.Text } else { $s.Muted }
    $before = $value.Substring(0, $caret)
    $after = $value.Substring($caret)
    if ($s.Invert) {
        $at = if ($after) { $after.Substring(0, 1) } else { ' ' }
        $after = if ($after) { $after.Substring(1) } else { '' }
        $cell = "$color$before$($s.Invert)$at$($s.Revert)$after$($s.Reset)"
        $visible = [Math]::Max($value.Length, $caret + 1)
    } else {
        $cell = "$before|$after"
        $visible = $value.Length + 1
    }
    $padding = ' ' * ($Rule.MaxLength + 1 - $visible)
    "$($s.Warm)$($Rule.Label)$($s.Reset)  $($s.Muted)[$($s.Reset)$cell$padding$($s.Muted)]  $($Rule.Hint)$($s.Reset)"
}

function Read-T3TrayText {
    param([string]$Title, [string]$Value, [ValidateSet('Port', 'ListenHost')][string]$Field)
    $s = Get-T3TrayStyle
    $rule = Get-T3TrayFieldRule $Field
    $state = @{ Value = $Value; Caret = $Value.Length; Mode = 'prefill'; Action = ''; Message = '' }
    while ($true) {
        $note = if ($state.Message) { "$($s.Error)$($state.Message)" }
        elseif ($state.Mode -eq 'prefill' -and $state.Value) { "$($s.Muted)Type to replace $($state.Value), or press Backspace to edit it." }
        else { '' }
        Write-T3TrayFrame $Title @((Format-T3TrayField $state $rule), '', $note) 'type  ·  ←→ home end move  ·  ctrl+a select all  ·  enter continue  ·  esc back  ·  ctrl+c quit'
        $state = Invoke-T3TrayFieldKey $state (Read-T3TrayKey) $rule
        if ($state.Action -eq 'cancel') { throw 'cancelled' }
        if ($state.Action -eq 'back') { return $null }
        if ($state.Action -eq 'submit') {
            try { $argsMap = @{}; $argsMap[$Field] = $state.Value; $null = New-T3TrayConfig @argsMap; return $state.Value }
            catch { $state.Message = $_.Exception.Message }
        }
    }
}

function Format-T3TrayTable {
    param([System.Collections.IDictionary]$Rows, [string]$Indent = '')
    $s = Get-T3TrayStyle
    $width = (@($Rows.Keys | ForEach-Object { ([string]$_).Length }) | Measure-Object -Maximum).Maximum
    foreach ($key in $Rows.Keys) { "$Indent$($s.Muted)$(([string]$key).PadRight($width))$($s.Reset)  $($s.Text)$($Rows[$key])$($s.Reset)" }
}

function Get-T3TrayReview {
    param($Config, [string]$PortOwner = '', [bool]$NoStart = $false)
    $s = Get-T3TrayStyle
    $listen = switch ($Config.ListenHost) {
        '127.0.0.1' { '127.0.0.1 (this PC only)' }
        '0.0.0.0' { '0.0.0.0 (LAN)' }
        default { $Config.ListenHost }
    }
    $settings = [ordered]@{ Channel = $Config.Channel; Listen = $listen
        Port = if ($PortOwner) { "$($Config.Port) ($PortOwner)" } else { [string]$Config.Port }
        'Local URL' = Get-T3TrayLocalUrl $Config.ListenHost $Config.Port
        'Start at sign-in' = if ($Config.StartAtSignIn) { 'Yes' } else { 'No' } }
    if ($Config.BaseDir) { $settings['T3 home'] = $Config.BaseDir }
    "$($s.Warm)Settings$($s.Reset)"
    Format-T3TrayTable $settings '  '
    foreach ($group in @(Get-T3TrayPlanStep $Config $NoStart | Group-Object Group)) {
        ''
        "$($s.Warm)$($group.Name)$($s.Reset)"
        foreach ($step in $group.Group) { "  $($s.Muted)-$($s.Reset)  $($step.Text)" }
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
                $choice = Read-T3TrayChoice 'check' @('Configure and install') 0 @(Format-T3TrayTable ([ordered]@{
                    'Existing t3tray install' = $Detection.Installed; 'Run value' = $Detection.RunValue
                    'T3 desktop' = $Detection.Desktop
                    "Port $($config.Port)" = $Detection.PortOwner }))
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
                $value = Read-T3TrayText 'port' ([string]$config.Port) 'Port'
                if ($null -eq $value) { $step = if ($listenChoice -eq 1) { 'Firewall' } elseif ($listenChoice -eq 2) { 'Custom' } else { 'Listen' } }
                else { $config.Port = [int]$value; $step = 'Startup' }
            }
            'Startup' {
                $choice = Read-T3TrayChoice 'start at sign-in' @('Yes', 'No') ([int](-not $config.StartAtSignIn))
                if ($choice -lt 0) { $step = 'Port' } else {
                    $config.StartAtSignIn = $choice -eq 0
                    $step = 'Review'
                }
            }
            'Review' {
                $owner = Get-T3TrayPortOwner $config.Port
                $choice = Read-T3TrayChoice 'review' @('Install', 'Go back') 0 @(Get-T3TrayReview $config $owner)
                if ($choice -ne 0) { $step = 'Startup' }
                else { return (New-T3TrayConfig -Channel $config.Channel -ListenHost $config.ListenHost -Port $config.Port -BaseDir $config.BaseDir -StartAtSignIn $config.StartAtSignIn -Firewall $config.Firewall) }
            }
        }
    }
}

function Write-T3TrayStep {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console UI output intentionally bypasses the success pipeline.')]
    param([string]$Label, [ValidateSet('planned')][string]$State = 'planned')
    $s = Get-T3TrayStyle
    Write-Host "$($s.Muted)│$($s.Reset)  $($s.Accent)○$($s.Reset)  $($s.Text)$Label$($s.Reset)  $($s.Muted)$State$($s.Reset)"
}

# Progress is append-only: the label prints while the step runs, the result
# finishes the same line. Nothing else may write to the host in between.
function Write-T3TrayStepStart {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console UI output intentionally bypasses the success pipeline.')]
    param([string]$Label)
    $s = Get-T3TrayStyle
    $leader = '.' * [Math]::Max(2, 32 - $Label.Length)
    Write-Host -NoNewline "$($s.Muted)│$($s.Reset)  $($s.Text)$Label$($s.Reset) $($s.Muted)$leader$($s.Reset) "
    [pscustomobject]@{ Label = $Label; Clock = [Diagnostics.Stopwatch]::StartNew() }
}

function Write-T3TrayStepResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console UI output intentionally bypasses the success pipeline.')]
    param($Step, [ValidateSet('ok', 'failed')][string]$State)
    if (-not $Step) { return }
    $s = Get-T3TrayStyle
    $color = if ($State -eq 'failed') { $s.Error } else { $s.Accent }
    $seconds = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0}s', $Step.Clock.Elapsed.TotalSeconds)
    Write-Host "$color$State$($s.Reset)  $($s.Muted)$seconds$($s.Reset)"
}

function Invoke-T3TrayStep {
    param([string]$Label, [scriptblock]$Action)
    $step = Write-T3TrayStepStart $Label
    try { $null = & $Action }
    catch {
        Write-T3TrayStepResult $step failed
        throw "$Label failed. $($_.Exception.Message) Resolve this error, then rerun the installer. Logs are in ~/.t3tray/logs."
    }
    Write-T3TrayStepResult $step ok
}

function Write-T3TrayInstallSummary {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console UI output intentionally bypasses the success pipeline.')]
    param($Config, [bool]$NoStart = $false, [bool]$Verified = $false, [bool]$Framed = $false)
    $s = Get-T3TrayStyle
    $trayDir = Join-Path $env:USERPROFILE '.t3tray'
    if ($NoStart) {
        $title = 'Installed. Not started because -NoStart was set.'
        $start = "& `"$(Join-Path $trayDir 't3tray.exe')`" run --host $($Config.ListenHost) --port $($Config.Port) --channel $($Config.Channel)"
        if ($Config.BaseDir) { $start += " --base-dir `"$($Config.BaseDir)`"" }
        $rows = [ordered]@{ Start = $start }
    } else {
        $title = if ($Verified) { 'Installed and verified. t3tray is running.' } else { 'Installed. t3tray is running.' }
        $rows = [ordered]@{ Open = Get-T3TrayLocalUrl $Config.ListenHost $Config.Port; Status = Get-T3TrayStatusCommand }
    }
    $rows.Logs = Join-Path $trayDir 'logs'
    if ($Framed) {
        Write-Host "$($s.Muted)│$($s.Reset)"
        Write-Host "$($s.Accent)◆$($s.Reset)  $($s.Text)$title$($s.Reset)"
        foreach ($line in Format-T3TrayTable $rows) { Write-Host "$($s.Muted)│$($s.Reset)  $line" }
        Write-Host "$($s.Muted)└$($s.Reset)"
    } else {
        Write-Host $title
        foreach ($line in Format-T3TrayTable $rows '  ') { Write-Host $line }
    }
}
