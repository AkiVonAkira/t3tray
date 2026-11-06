# Requires Windows 10/11 x64 and Windows PowerShell 5.1 or newer.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console UI output intentionally bypasses the success pipeline.')]
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
    [switch]$NoStart,
    [switch]$RetireWinT3Service,
    [switch]$NonInteractive,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# iex has no script directory. Read the same helpers into memory in that case.
$installerRoot = $PSScriptRoot
$sourceBase = 'https://raw.githubusercontent.com/AkiVonAkira/t3tray/main/installer'
foreach ($name in @('config.ps1', 'ui.ps1', 'verify.ps1')) {
    if ($installerRoot) { . (Join-Path $installerRoot "installer/$name") }
    else { . ([scriptblock]::Create((Invoke-RestMethod "$sourceBase/$name"))) }
}
$interactive = Test-T3TrayInteractive $PSBoundParameters @(Get-ChildItem Env: | Select-Object -ExpandProperty Name)
$legacyArgs = @{ Version = $Version; ListenHost = $ListenHost; Port = $Port; Channel = $Channel
    ExePath = $ExePath; AssetDir = $AssetDir; NoStart = $NoStart; RetireWinT3Service = $RetireWinT3Service }
$config = New-T3TrayConfig -Channel $Channel -ListenHost $ListenHost -Port $Port -Retire $RetireWinT3Service
if ($interactive) {
    try { $config = Invoke-T3TrayWizard (Get-T3TrayDetection) }
    catch { if ($_.Exception.Message -eq 'cancelled') { Write-Host '■  Cancelled. No changes made.'; return }; throw }
    $legacyArgs.ListenHost = $config.ListenHost
    $legacyArgs.Port = $config.Port
    $legacyArgs.Channel = $config.Channel
    $legacyArgs.RetireWinT3Service = $config.Retire
    $legacyArgs.StartAtSignIn = $config.StartAtSignIn
    $legacyArgs.ShowSteps = $true
}
if ($DryRun) {
    Write-Host '┌  t3tray  windows'
    Write-Host '◇  dry-run. No changes made.'
    foreach ($step in Get-T3TrayPlan $config $NoStart) { Write-T3TrayStep $step planned }
    Write-Host '└  Plan complete. Verification is planned, not performed.'
    return
}
if ($env:OS -ne 'Windows_NT') { throw 't3tray requires Windows.' }
if ($interactive -and $config.Firewall) {
    Invoke-T3TrayStep 'Private firewall rule (UAC)' {
        Write-Host "Windows will ask for administrator approval to allow TCP $($config.Port) on Private networks."
        $command = "`$ErrorActionPreference='Stop'; try { Get-NetFirewallRule -Name 'T3Tray-$($config.Port)' -ErrorAction SilentlyContinue | Remove-NetFirewallRule; New-NetFirewallRule -Name 'T3Tray-$($config.Port)' -DisplayName 't3tray TCP $($config.Port)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $($config.Port) -Profile Private | Out-Null; exit 0 } catch { exit 1 }"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $child = Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -EncodedCommand $encoded" -Wait -PassThru
        if ($child.ExitCode -ne 0) { throw 'Firewall rule was not created. Approve UAC or choose to manage the firewall yourself.' }
    }
}
if ($installerRoot) { & (Join-Path $installerRoot 'installer/legacy-install.ps1') @legacyArgs }
else { & ([scriptblock]::Create((Invoke-RestMethod "$sourceBase/legacy-install.ps1"))) @legacyArgs }
if ($interactive -and -not $NoStart) { Invoke-T3TrayVerification $config }
