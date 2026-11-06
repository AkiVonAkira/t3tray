param(
    [ValidateSet('stable', 'nightly')]
    [string]$Channel = 'stable'
)
$ErrorActionPreference = 'Stop'
$exe = Join-Path $env:USERPROFILE '.t3tray\t3tray.exe'
$badAssets = Join-Path $env:TEMP ([Guid]::NewGuid().ToString())
try {
    $null = New-Item -ItemType Directory -Path $badAssets
    Copy-Item "$PSScriptRoot\..\dist\SHA256SUMS" $badAssets
    Set-Content -LiteralPath (Join-Path $badAssets 't3tray.exe') -Value 'corrupt executable'
    try {
        & "$PSScriptRoot\..\install.ps1" -AssetDir $badAssets -Channel $Channel -NoStart
        throw 'The installer accepted a corrupt executable.'
    } catch {
        if ($_.Exception.Message -notmatch 'SHA-256 mismatch') { throw }
        Write-Output 'Corrupt executable rejected before installation.'
    }
    # Hosted runners have no interactive logon token for the one-shot task.
    & "$PSScriptRoot\..\install.ps1" -ExePath "$PSScriptRoot\..\dist\t3tray.exe" -Channel $Channel -NoStart
    $runValue = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name T3Tray).T3Tray
    if ($runValue -notlike "*--channel $Channel") { throw "Run value does not select $Channel." }
    Start-Process -FilePath $exe -ArgumentList "--host 127.0.0.1 --port 3773 --channel $Channel"
    $deadline = (Get-Date).AddMinutes(10)
    do {
        $state = (& $exe status | Out-String).Trim()
        if ($state -match '"status":"running"') { break }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    if ($state -notmatch '"status":"running"') { throw "Tray did not start. Last state $state" }
    Write-Output $state
    $initial = $state | ConvertFrom-Json
    if ($initial.channel -ne $Channel) { throw "Expected $Channel in status." }
    $versionPattern = if ($Channel -eq 'nightly') { '^\d+\.\d+\.\d+-nightly\.\d{8}\.\d+$' } else { '^\d+\.\d+\.\d+$' }
    if ($initial.version -notmatch $versionPattern) { throw "Wrong seed for $Channel, got $($initial.version)." }
    $response = Invoke-WebRequest 'http://127.0.0.1:3773/' -UseBasicParsing
    if ($response.StatusCode -ne 200) { throw "Unexpected HTTP status $($response.StatusCode)" }
    $null = & $exe stop | Out-String
    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Seconds 1
        $stopped = (& $exe status | Out-String).Trim()
    } while ($stopped -notmatch '"status":"stopped"' -and (Get-Date) -lt $deadline)
    if ($stopped -notmatch '"status":"stopped"') { throw 'Stop command failed.' }
    $null = & $exe start | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'Start command failed.' }
    $null = & $exe quit | Out-String
    $tray = Get-Process -Name t3tray -ErrorAction SilentlyContinue
    if ($tray) { $tray | Wait-Process -Timeout 30 -ErrorAction Stop }
    $otherChannel = if ($Channel -eq 'stable') { 'nightly' } else { 'stable' }
    Start-Process -FilePath $exe -ArgumentList "--host 127.0.0.1 --port 3773 --channel $otherChannel"
    $deadline = (Get-Date).AddMinutes(2)
    do {
        Start-Sleep -Seconds 2
        $state = (& $exe status | Out-String).Trim()
    } while ($state -notmatch '"status":"running"' -and (Get-Date) -lt $deadline)
    if ($state -notmatch '"status":"running"') { throw 'Tray did not restart with the other channel.' }
    $restarted = $state | ConvertFrom-Json
    if ($restarted.channel -ne $otherChannel -or $restarted.version -ne $initial.version) {
        throw 'Changing channel replaced the existing activeVersion or reported the wrong channel.'
    }
    Write-Output "Existing activeVersion $($restarted.version) preserved with channel $otherChannel."
} finally {
    Remove-Item -LiteralPath $badAssets -Recurse -Force -ErrorAction SilentlyContinue
    & "$PSScriptRoot\..\uninstall.ps1"
    if (Test-Path "$env:USERPROFILE\.t3tray\logs") {
        Get-ChildItem "$env:USERPROFILE\.t3tray\logs" -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Tail 60 }
    }
}
$remaining = @(Get-Process -Name t3tray, t3 -ErrorAction SilentlyContinue)
if ($remaining.Count -gt 0) { throw "Processes remain after uninstall: $($remaining.Name -join ', ')" }
if (Test-Path -LiteralPath $exe) { throw 'Uninstall left the executable.' }
if (Test-Path "$env:USERPROFILE\.t3\bin\t3tray.cmd") { throw 'Uninstall left the wrapper.' }
if (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name T3Tray -ErrorAction SilentlyContinue) {
    throw 'Uninstall left the Run value.'
}
if (-not (Test-Path "$env:USERPROFILE\.t3\runtime\service-state.json")) { throw 'Uninstall removed T3 data.' }
if (-not (Test-Path "$env:USERPROFILE\.t3tray\logs")) { throw 'Uninstall removed logs without -Purge.' }
& "$PSScriptRoot\..\uninstall.ps1" -Purge
if (Test-Path "$env:USERPROFILE\.t3tray") { throw '-Purge left the tray directory.' }
if (-not (Test-Path "$env:USERPROFILE\.t3\runtime\service-state.json")) { throw '-Purge removed T3 data.' }
Write-Output 'Install, HTTP readiness, stop/start, uninstall, and purge passed.'
