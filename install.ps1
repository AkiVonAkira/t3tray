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
    [string]$BaseDir,
    [switch]$NoStart,
    [switch]$NoStartAtSignIn,
    [switch]$NonInteractive,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# iex has no script directory. Read the same helpers into memory in that case.
$installerRoot = $PSScriptRoot
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# Release builds stamp the tag here. T3TRAY_REF picks a branch when piping a branch's script to iex.
$sourceRef = 'main'
if ($env:T3TRAY_REF) { $sourceRef = $env:T3TRAY_REF }
$sourceBase = "https://raw.githubusercontent.com/AkiVonAkira/t3tray/$sourceRef/installer"
$localHelpers = $installerRoot -and (Test-Path (Join-Path $installerRoot 'installer/config.ps1'))
foreach ($name in @('config.ps1', 'ui.ps1', 'verify.ps1')) {
    if ($localHelpers) { . (Join-Path $installerRoot "installer/$name") }
    else { . ([scriptblock]::Create(([string](Invoke-RestMethod "$sourceBase/$name")).TrimStart([char]0xFEFF))) }
}
$interactive = Test-T3TrayInteractive $PSBoundParameters @(Get-ChildItem Env: | Select-Object -ExpandProperty Name)
$config = New-T3TrayConfig -Channel $Channel -ListenHost $ListenHost -Port $Port -BaseDir $BaseDir -StartAtSignIn (-not $NoStartAtSignIn)
if ($interactive) {
    try { $config = Invoke-T3TrayWizard (Get-T3TrayDetection) }
    catch { if ($_.Exception.Message -eq 'cancelled') { Write-Host "$([char]0x25A0)  Cancelled. No changes made."; return }; throw }
}
$legacyArgs = @{ Version = $Version; ListenHost = $config.ListenHost; Port = $config.Port; Channel = $config.Channel
    BaseDir = $config.BaseDir; StartAtSignIn = $config.StartAtSignIn; ExePath = $ExePath; AssetDir = $AssetDir
    NoStart = $NoStart; ShowSteps = $interactive }
if ($DryRun) {
    if ($interactive) {
        Write-T3TrayFrame 'dry-run' @(Get-T3TrayReview $config '' $NoStart) 'No changes made. Verification is planned, not performed.'
        return
    }
    Write-Host 'dry-run. No changes made.'
    foreach ($line in Get-T3TrayReview $config '' $NoStart) { Write-Host "  $line" }
    Write-Host 'Plan complete. Verification is planned, not performed.'
    return
}
if ($env:OS -ne 'Windows_NT') { throw 't3tray requires Windows.' }
if ($interactive) {
    Write-T3TrayHeader 'install' -Clear
    Write-T3TrayNote 'A failed step stops the installer.'
}
if ($interactive -and $config.Firewall) {
    Write-T3TrayNote "Windows will ask for administrator approval to allow TCP $($config.Port) on Private networks."
    Invoke-T3TrayStep 'Private firewall rule (UAC)' {
        $command = "`$ErrorActionPreference='Stop'; try { Get-NetFirewallRule -Name 'T3Tray-$($config.Port)' -ErrorAction SilentlyContinue | Remove-NetFirewallRule; New-NetFirewallRule -Name 'T3Tray-$($config.Port)' -DisplayName 't3tray TCP $($config.Port)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $($config.Port) -Profile Private | Out-Null; exit 0 } catch { exit 1 }"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $child = Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -EncodedCommand $encoded" -Wait -PassThru
        if ($child.ExitCode -ne 0) { throw 'Firewall rule was not created. Approve UAC or choose to manage the firewall yourself.' }
    }
}
if ($localHelpers) { & (Join-Path $installerRoot 'installer/legacy-install.ps1') @legacyArgs }
else { & ([scriptblock]::Create(([string](Invoke-RestMethod "$sourceBase/legacy-install.ps1")).TrimStart([char]0xFEFF))) @legacyArgs }
if ($interactive -and -not $NoStart) { Invoke-T3TrayVerification $config }
Write-T3TrayInstallSummary $config -NoStart $NoStart.IsPresent -Verified $interactive -Framed $interactive
