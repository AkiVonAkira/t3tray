[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console UI output intentionally bypasses the success pipeline.')]
param([switch]$Purge, [switch]$NonInteractive, [switch]$DryRun)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$sourceBase = 'https://raw.githubusercontent.com/AkiVonAkira/t3tray/main/installer'
foreach ($name in @('config.ps1', 'ui.ps1')) {
    if ($PSScriptRoot) { . (Join-Path $PSScriptRoot "installer/$name") }
    else { . ([scriptblock]::Create(([string](Invoke-RestMethod "$sourceBase/$name")).TrimStart([char]0xFEFF))) }
}
$interactive = Test-T3TrayInteractive $PSBoundParameters @(Get-ChildItem Env: | Select-Object -ExpandProperty Name)
if ($interactive) {
    Initialize-T3TrayConsole
    try {
        $choice = Read-T3TrayChoice 'uninstall' @('Uninstall t3tray', 'Cancel') 1 @(
            'Stop the tray, remove sign-in startup, executable and wrapper.', 'Keep logs and T3 data. -Purge also removes tray logs.')
        if ($choice -ne 0) { Write-Host "$([char]0x25A0)  Cancelled."; return }
    } catch { if ($_.Exception.Message -eq 'cancelled') { Write-Host "$([char]0x25A0)  Cancelled."; return }; throw }
}
if ($DryRun) {
    if ($interactive) { Write-T3TrayFrame 'uninstall dry-run' @() 'No changes made.' }
    foreach ($step in @('Stop tray', 'Remove sign-in startup', 'Remove executable and wrapper')) { Write-T3TrayStep $step planned }
    if ($Purge) { Write-T3TrayStep 'Remove tray directory and logs' planned }
    return
}
$action = {
    if ($PSScriptRoot) { & (Join-Path $PSScriptRoot 'installer/legacy-uninstall.ps1') -Purge:$Purge -ShowSteps:$interactive }
    else { & ([scriptblock]::Create(([string](Invoke-RestMethod "$sourceBase/legacy-uninstall.ps1")).TrimStart([char]0xFEFF))) -Purge:$Purge -ShowSteps:$interactive }
}
& $action
