[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Preview output is console UI.')]
param()
# Runs the real wizard, review, progress and summary code on fixture data with scripted keys.
# Nothing is installed, no registry or firewall change is made, and no window opens.
# Redirect the output to capture plain frames: .\scripts\installer-preview.ps1 *> preview.txt
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../installer/config.ps1"
. "$PSScriptRoot/../installer/ui.ps1"

function Get-PreviewKey([ConsoleKey]$Key, [char]$Char = [char]0) { New-Object ConsoleKeyInfo -ArgumentList $Char, $Key, $false, $false, $false }
$script:keys = [Collections.Generic.Queue[ConsoleKeyInfo]]::new()
function Add-PreviewKey {
    foreach ($item in $args) {
        if ($item -is [ConsoleKey]) { $script:keys.Enqueue((Get-PreviewKey $item)) }
        else { foreach ($char in ([string]$item).ToCharArray()) { $script:keys.Enqueue((Get-PreviewKey ([ConsoleKey]::A) $char)) } }
    }
}
function Read-T3TrayKey {
    if (-not $script:keys.Count) { throw 'The preview ran out of scripted keys.' }
    $script:keys.Dequeue()
}
function Get-T3TrayPortOwner { 'Available' }

$enter = [ConsoleKey]::Enter
Add-PreviewKey $enter                                   # check
Add-PreviewKey ([ConsoleKey]::DownArrow) $enter         # channel: nightly
Add-PreviewKey ([ConsoleKey]::DownArrow) $enter         # listen: LAN
Add-PreviewKey ([ConsoleKey]::UpArrow) $enter           # firewall: yes
Add-PreviewKey ([ConsoleKey]::Escape) $enter            # port: esc goes back to firewall, enter returns
Add-PreviewKey '4' ([ConsoleKey]::Backspace) 'x' '0' $enter
Add-PreviewKey ([ConsoleKey]::Home) '4' ([ConsoleKey]::End) '00' $enter
Add-PreviewKey $enter                                   # start at sign-in: yes
Add-PreviewKey ([ConsoleKey]::UpArrow) $enter           # retire: yes
Add-PreviewKey $enter                                   # review: install

$detection = [pscustomobject]@{ Config = (New-T3TrayConfig); Installed = $false; RunValue = ''; OldTask = $true
    Desktop = '0.0.20-nightly.20261101.4 (nightly)'; DesktopChannel = 'nightly'; PortOwner = 'Available' }
$config = Invoke-T3TrayWizard $detection
if ($script:keys.Count) { throw "$($script:keys.Count) scripted keys were not read." }
if ($config.Channel -ne 'nightly' -or $config.ListenHost -ne '0.0.0.0' -or -not $config.Firewall -or $config.Port -ne 4000 -or -not $config.Retire) {
    throw "Wizard returned the wrong configuration: $($config | ConvertTo-Json -Compress)"
}

$profileBefore = $env:USERPROFILE
$env:USERPROFILE = 'C:\Users\Example'
try {
    Write-T3TrayHeader 'install' -Clear
    Write-T3TrayNote 'A failed step stops the installer.'
    Invoke-T3TrayStep 'Acquire release assets' {}
    Invoke-T3TrayStep 'Verify SHA-256' { 'child output that must stay hidden' }
    Invoke-T3TrayStep 'HTTP 200' {}
    Write-T3TrayInstallSummary $config -Verified $true -Framed $true
    Write-Host ''
    Write-Host 'Unattended, -NoStart:'
    Write-T3TrayInstallSummary $config -NoStart $true
    Write-Host ''
    Write-Host 'Separate failure example:'
    try { Invoke-T3TrayStep 'HTTP 200' { throw 'Server did not return HTTP 200.' } }
    catch { Write-T3TrayNote $_.Exception.Message }
} finally { $env:USERPROFILE = $profileBefore }
