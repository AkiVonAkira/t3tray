[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console UI output intentionally bypasses the success pipeline.')]
param([switch]$Purge, [switch]$NonInteractive, [switch]$DryRun)
$ErrorActionPreference = 'Stop'
$sourceBase = 'https://raw.githubusercontent.com/AkiVonAkira/t3tray/main/installer'
foreach ($name in @('config.ps1', 'ui.ps1')) {
    if ($PSScriptRoot) { . (Join-Path $PSScriptRoot "installer/$name") }
    else { . ([scriptblock]::Create((Invoke-RestMethod "$sourceBase/$name"))) }
}
$interactive = Test-T3TrayInteractive $PSBoundParameters @(Get-ChildItem Env: | Select-Object -ExpandProperty Name)
if ($interactive) {
    try {
        $choice = Read-T3TrayChoice 'uninstall' @('Uninstall t3tray', 'Cancel') 1 @(
            'Stop the tray, remove sign-in startup, executable and wrapper.', 'Keep logs and T3 data. -Purge also removes tray logs.')
        if ($choice -ne 0) { Write-Host '■  Cancelled.'; return }
    } catch { if ($_.Exception.Message -eq 'cancelled') { Write-Host '■  Cancelled.'; return }; throw }
}
if ($DryRun) {
    foreach ($step in @('Stop tray', 'Remove sign-in startup', 'Remove executable and wrapper')) { Write-T3TrayStep $step planned }
    if ($Purge) { Write-T3TrayStep 'Remove tray directory and logs' planned }
    return
}
$action = {
    if ($PSScriptRoot) { & (Join-Path $PSScriptRoot 'installer/legacy-uninstall.ps1') -Purge:$Purge -ShowSteps:$interactive }
    else { & ([scriptblock]::Create((Invoke-RestMethod "$sourceBase/legacy-uninstall.ps1"))) -Purge:$Purge -ShowSteps:$interactive }
}
& $action
