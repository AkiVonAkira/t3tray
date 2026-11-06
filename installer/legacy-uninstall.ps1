param([switch]$Purge, [switch]$ShowSteps)
$ErrorActionPreference = 'Stop'
$showProgress = [bool]$ShowSteps
if ($env:OS -ne 'Windows_NT') { throw 't3tray requires Windows.' }
$trayDir = Join-Path $env:USERPROFILE '.t3tray'
$exe = Join-Path $trayDir 't3tray.exe'
function Invoke-UninstallStep {
    param([string]$Label, [scriptblock]$Action)
    if ($showProgress) { Invoke-T3TrayStep $Label $Action } else { & $Action }
}
Invoke-UninstallStep 'Stop tray' {
    $running = @(Get-Process -Name t3tray -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
    if ($running.Count -gt 0) {
        & $exe quit | Out-Host
        $running | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
        $running | Stop-Process -Force -ErrorAction SilentlyContinue
        $running | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    }
}
Invoke-UninstallStep 'Remove sign-in startup' {
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name T3Tray -ErrorAction SilentlyContinue
}
Invoke-UninstallStep 'Remove executable and wrapper' {
    foreach ($path in @($exe, (Join-Path $env:USERPROFILE '.t3\bin\t3tray.cmd'))) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}
if ($Purge -and (Test-Path -LiteralPath $trayDir)) {
    Invoke-UninstallStep 'Remove tray directory and logs' { Remove-Item -LiteralPath $trayDir -Recurse -Force }
}
Write-Output 'Uninstalled t3tray. The T3 home and its data are unchanged.'
