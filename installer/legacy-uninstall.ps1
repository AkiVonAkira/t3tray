param([switch]$Purge, [switch]$ShowSteps)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 't3tray requires Windows.' }
$trayDir = Join-Path $env:USERPROFILE '.t3tray'
$exe = Join-Path $trayDir 't3tray.exe'
if ($ShowSteps) { Write-T3TrayStep 'Stop tray' running }
$running = @(Get-Process -Name t3tray -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
if ($running.Count -gt 0) {
    & $exe quit | Out-Host
    $running | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    $running | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
}
if ($ShowSteps) { Write-T3TrayStep 'Stop tray' ok; Write-T3TrayStep 'Remove sign-in startup' running }
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name T3Tray -ErrorAction SilentlyContinue
if ($ShowSteps) { Write-T3TrayStep 'Remove sign-in startup' ok; Write-T3TrayStep 'Remove executable and wrapper' running }
foreach ($path in @($exe, (Join-Path $env:USERPROFILE '.t3\bin\t3tray.cmd'))) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}
if ($ShowSteps) { Write-T3TrayStep 'Remove executable and wrapper' ok }
if ($Purge -and (Test-Path -LiteralPath $trayDir)) { Remove-Item -LiteralPath $trayDir -Recurse -Force }
Write-Output 'Uninstalled t3tray. The T3 home and its data are unchanged.'
