[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console UI output intentionally bypasses the success pipeline.')]
param()
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../installer/config.ps1"
. "$PSScriptRoot/../installer/ui.ps1"
# Replace only terminal input. The wizard, validation and plan are production code.
function Read-T3TrayChoice {
    param($Title, $Options, $Selected, $Details)
    Write-Host "$Title (detected selection $Selected): $($Options -join ', ') $Details"
    switch ($Title) {
        'channel' { return 1 }
        'listen address' { return 1 }
        'Windows Firewall' { return 0 }
        default { return 0 }
    }
}
function Read-T3TrayText {
    param($Title, $Value, $Field)
    Write-Host "$Title = $Value ($Field)"
    return '3773'
}
$detection = Get-T3TrayDetection
$detection.OldTask = $true
$config = Invoke-T3TrayWizard $detection
if ($config.Channel -ne 'nightly' -or -not $config.Firewall -or -not $config.Retire) { throw 'Wizard choices were lost.' }
foreach ($step in Get-T3TrayPlan $config) { Write-T3TrayStep $step planned }
& "$PSScriptRoot/../install.ps1" -DryRun -NonInteractive -Channel $config.Channel -ListenHost $config.ListenHost -Port $config.Port -RetireWinT3Service:$config.Retire
