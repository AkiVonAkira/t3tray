param(
    [ValidateSet('stable', 'nightly')]
    [string]$Channel = 'stable',
    # A custom T3 home proves every installer and tray path uses it, not ~/.t3.
    [string]$BaseDir,
    # A build with the fixture-releases feature. When set, the installed t3tray updates itself from local fixture releases.
    [string]$UpdaterExePath
)
$ErrorActionPreference = 'Stop'
foreach ($name in @('config.ps1', 'ui.ps1', 'verify.ps1')) { . "$PSScriptRoot\..\installer\$name" }
$exe = Join-Path $env:USERPROFILE '.t3tray\t3tray.exe'
$t3Home = if ($BaseDir) { $BaseDir } else { Join-Path $env:USERPROFILE '.t3' }
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$badAssets = Join-Path $env:TEMP ([Guid]::NewGuid().ToString())
$fixture = $null

function Wait-TrayStatus([string]$Status, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $state = (& $exe status --json | Out-String).Trim()
        if ($state -match "`"status`":`"$Status`"") { return $state }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "Tray did not reach $Status. Last state $state"
}

function Assert-ServerReady {
    $response = Invoke-WebRequest 'http://127.0.0.1:3773/' -UseBasicParsing
    if ($response.StatusCode -ne 200) { throw "Unexpected HTTP status $($response.StatusCode)" }
    # The installer wizard's own verification, with the configured T3 home.
    Invoke-T3TrayVerification (New-T3TrayConfig -Channel $Channel -Port 3773 -BaseDir $BaseDir)
}

function Invoke-Updater([string[]]$UpdateArgs) {
    $ErrorActionPreference = 'Continue'
    $output = & $exe update @UpdateArgs 2>&1 | ForEach-Object { "$_" } | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Get-InstalledHash { (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash }

# Serves GitHub's release URL shapes from a folder: releases/latest redirects to
# releases/tag/<tag>, releases/download/<tag>/<file> and installer/<file> serve files.
function Open-FixtureReleaseServer([string]$Root, [int]$Port) {
    $listener = New-Object Net.HttpListener
    $listener.Prefixes.Add("http://127.0.0.1:$Port/")
    $listener.Start()
    $shell = [powershell]::Create()
    $null = $shell.AddScript({
        param($listener, $root)
        while ($listener.IsListening) {
            try { $context = $listener.GetContext() } catch { break }
            $response = $context.Response
            $parts = @($context.Request.Url.AbsolutePath.Trim('/') -split '/')
            $file = $null
            if ($parts.Count -eq 2 -and $parts[0] -eq 'releases' -and $parts[1] -eq 'latest') {
                $response.StatusCode = 302
                $response.RedirectLocation = $context.Request.Url.GetLeftPart('Authority') + '/releases/tag/v0.1.1'
            } elseif ($parts.Count -eq 4 -and $parts[0] -eq 'releases' -and $parts[1] -eq 'download') {
                $file = Join-Path (Join-Path $root $parts[2]) $parts[3]
            } elseif ($parts.Count -eq 2 -and $parts[0] -eq 'installer') {
                $file = Join-Path (Join-Path $root 'installer') $parts[1]
            }
            if ($file -and ($parts | Where-Object { $_ -notmatch '^[A-Za-z0-9.-]+$' -or $_ -eq '..' })) { $file = $null }
            if ($file -and (Test-Path -LiteralPath $file -PathType Leaf)) {
                $bytes = [IO.File]::ReadAllBytes($file)
                $response.ContentType = 'application/octet-stream'
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            } elseif ($response.StatusCode -ne 302) { $response.StatusCode = 404 }
            $response.Close()
        }
    }).AddArgument($listener).AddArgument($Root)
    $null = $shell.BeginInvoke()
    [pscustomobject]@{ Listener = $listener; Shell = $shell; Root = $Root; Url = "http://127.0.0.1:$Port" }
}

function Add-FixtureRelease([string]$Root, [string]$Tag, [string]$Installer, [string]$ExeSource, [string]$ExeHash) {
    $dir = Join-Path $Root $Tag
    $null = New-Item -ItemType Directory -Force $dir
    Copy-Item -LiteralPath $Installer -Destination (Join-Path $dir 'install.ps1')
    Copy-Item -LiteralPath $ExeSource -Destination (Join-Path $dir 't3tray.exe')
    $installerHash = (Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $dir 'SHA256SUMS'), "$($ExeHash.ToLowerInvariant())  t3tray.exe`n$installerHash  install.ps1`n")
}

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
    $releaseExe = (Resolve-Path "$PSScriptRoot\..\dist\t3tray.exe").Path
    $firstExe = if ($UpdaterExePath) { (Resolve-Path $UpdaterExePath).Path } else { $releaseExe }
    # Hosted runners have no interactive logon token for the one-shot task.
    $installArgs = @{ ExePath = $firstExe; NoStart = $true; Channel = $Channel }
    $launchArgs = "run --host 127.0.0.1 --port 3773 --channel $Channel"
    if ($BaseDir) {
        $installArgs.BaseDir = $BaseDir
        $launchArgs += " --base-dir `"$BaseDir`""
    }
    & "$PSScriptRoot\..\install.ps1" @installArgs
    $runValue = (Get-ItemProperty -Path $runKey -Name T3Tray).T3Tray
    if ($runValue -ne "`"$exe`" $launchArgs") { throw "Run value does not launch the configured tray. $runValue" }
    Start-Process -FilePath $exe -ArgumentList $launchArgs
    $state = Wait-TrayStatus running 600
    Write-Output $state
    $initial = $state | ConvertFrom-Json
    if ($initial.channel -ne $Channel) { throw "Expected $Channel in status." }
    $versionPattern = if ($Channel -eq 'nightly') { '^\d+\.\d+\.\d+-nightly\.\d{8}\.\d+$' } else { '^\d+\.\d+\.\d+$' }
    if ($initial.version -notmatch $versionPattern) { throw "Wrong seed for $Channel, got $($initial.version)." }
    Assert-ServerReady
    if ($BaseDir -and (Test-Path (Join-Path $env:USERPROFILE '.t3\runtime'))) { throw 'The server used ~/.t3 instead of the configured T3 home.' }

    if ($UpdaterExePath) {
        $releases = Join-Path $env:TEMP ('t3tray-releases-' + [Guid]::NewGuid())
        $null = New-Item -ItemType Directory -Force (Join-Path $releases 'installer')
        Copy-Item "$PSScriptRoot\..\installer\*.ps1" (Join-Path $releases 'installer')
        $fixture = Open-FixtureReleaseServer $releases 8765
        # Same one-line stamp as release packaging: helpers come from the fixture instead of a GitHub ref.
        $stampedInstaller = Join-Path $releases 'install.ps1'
        $source = [IO.File]::ReadAllText((Resolve-Path "$PSScriptRoot\..\install.ps1"))
        $stamped = $source.Replace('"https://raw.githubusercontent.com/AkiVonAkira/t3tray/$sourceRef/installer"', "'$($fixture.Url)/installer'")
        if ($stamped -eq $source) { throw 'Could not point the fixture installer at local helpers.' }
        [IO.File]::WriteAllText($stampedInstaller, $stamped)
        $releaseHash = (Get-FileHash -LiteralPath $releaseExe -Algorithm SHA256).Hash
        $corrupt = Join-Path $releases 'corrupt.exe'
        Set-Content -LiteralPath $corrupt -Value 'corrupt executable'
        Add-FixtureRelease $releases 'v0.2.98' $stampedInstaller $corrupt $releaseHash
        Add-FixtureRelease $releases 'v0.2.99' $stampedInstaller $releaseExe $releaseHash
        $env:T3TRAY_FIXTURE_RELEASES = "$($fixture.Url)/releases"
        $before = Get-InstalledHash

        Write-Output 'Update to a latest release older than v0.2.0 is refused before downloads.'
        $result = Invoke-Updater @()
        if ($result.ExitCode -ne 1 -or $result.Output -notmatch 'release v0\.1\.1: t3tray update installs v0\.2\.0 or newer' -or $result.Output -notmatch 'Nothing was changed') {
            throw "Latest v0.1.1 was not refused. Exit $($result.ExitCode). $($result.Output)"
        }
        if ((Get-InstalledHash) -ne $before) { throw 'A refused update replaced the executable.' }
        $null = Wait-TrayStatus running 10

        Write-Output 'A failing installer exit code reaches the caller while the tray keeps running.'
        $result = Invoke-Updater @('--version', 'v0.2.98')
        if ($result.ExitCode -eq 0 -or $result.Output -notmatch 'SHA-256 mismatch' -or $result.Output -notmatch "installer exited with code $($result.ExitCode)") {
            throw "A failed installer did not fail the update. Exit $($result.ExitCode). $($result.Output)"
        }
        if ((Get-InstalledHash) -ne $before) { throw 'A failed update replaced the executable.' }
        if ((Get-ItemProperty -Path $runKey -Name T3Tray).T3Tray -ne $runValue) { throw 'A failed update changed the sign-in entry.' }
        $null = Wait-TrayStatus running 10

        # The installer's restart uses an interactive-token task that hosted runners cannot run, so the tray is stopped
        # first; update then passes -NoStart. The installer still finds the running updater at the installed path.
        $null = & $exe quit | Out-String
        Get-Process -Name t3tray -ErrorAction SilentlyContinue | Wait-Process -Timeout 30 -ErrorAction Stop
        Write-Output 'Installed t3tray replaces its own running executable.'
        $result = Invoke-Updater @('--version', '0.2.99')
        Write-Output $result.Output
        if ($result.ExitCode -ne 0 -or $result.Output -notmatch 'Updating t3tray v\d+\.\d+\.\d+ to v0\.2\.99') {
            throw "Update failed. Exit $($result.ExitCode)."
        }
        if ((Get-InstalledHash) -ne $releaseHash) { throw 'Update did not install the release executable.' }
        if (-not (Get-ChildItem (Split-Path $exe) -Filter 't3tray.*.old' -File)) { throw 'The running updater was not renamed aside.' }
        if ((Get-ItemProperty -Path $runKey -Name T3Tray).T3Tray -ne $runValue) { throw 'Update did not keep the sign-in settings.' }
        $help = & $exe help | Out-String
        if ($LASTEXITCODE -ne 0 -or $help -notmatch '(?m)^\s+update \[--version vX\.Y\.Z\]') { throw "Installed help is wrong. $help" }
        Start-Process -FilePath $exe -ArgumentList $launchArgs
        $updated = Wait-TrayStatus running 300 | ConvertFrom-Json
        if ($updated.version -ne $initial.version -or $updated.channel -ne $Channel) { throw 'Update changed the server version or channel.' }
        Assert-ServerReady
        Write-Output 'Updated tray serves HTTP and server.getConfig with the kept settings.'
    }

    $null = & $exe stop | Out-String
    $null = Wait-TrayStatus stopped 30
    $null = & $exe start | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'Start command failed.' }
    $null = & $exe quit | Out-String
    $tray = Get-Process -Name t3tray -ErrorAction SilentlyContinue
    if ($tray) { $tray | Wait-Process -Timeout 30 -ErrorAction Stop }
    $otherChannel = if ($Channel -eq 'stable') { 'nightly' } else { 'stable' }
    Write-Output 'Relaunching with the flag-only sign-in command written by t3tray 0.1.'
    $legacyArgs = "--host 127.0.0.1 --port 3773 --channel $otherChannel"
    if ($BaseDir) { $legacyArgs += " --base-dir `"$BaseDir`"" }
    Start-Process -FilePath $exe -ArgumentList $legacyArgs
    $restarted = Wait-TrayStatus running 120 | ConvertFrom-Json
    if ($restarted.channel -ne $otherChannel -or $restarted.version -ne $initial.version) {
        throw 'Changing channel replaced the existing activeVersion or reported the wrong channel.'
    }
    Write-Output "Existing activeVersion $($restarted.version) preserved with channel $otherChannel."
} finally {
    if ($fixture) {
        $fixture.Listener.Stop(); $fixture.Listener.Close(); $fixture.Shell.Dispose()
        Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\T3TRAY_FIXTURE_RELEASES -ErrorAction SilentlyContinue
    }
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
if (Get-ItemProperty -Path $runKey -Name T3Tray -ErrorAction SilentlyContinue) {
    throw 'Uninstall left the Run value.'
}
if (-not (Test-Path "$t3Home\runtime\service-state.json")) { throw 'Uninstall removed T3 data.' }
if (-not (Test-Path "$env:USERPROFILE\.t3tray\logs")) { throw 'Uninstall removed logs without -Purge.' }
& "$PSScriptRoot\..\uninstall.ps1" -Purge
if (Test-Path "$env:USERPROFILE\.t3tray") { throw '-Purge left the tray directory.' }
if (-not (Test-Path "$t3Home\runtime\service-state.json")) { throw '-Purge removed T3 data.' }
Write-Output 'Install, HTTP readiness, server.getConfig, update, stop/start, uninstall, and purge passed.'
