$ErrorActionPreference = 'Stop'
# The preview drives the production wizard through scripted Read-T3TrayKey input and asserts the result.
& "$PSScriptRoot/installer-preview.ps1"
& "$PSScriptRoot/../install.ps1" -DryRun -NonInteractive -Channel nightly -ListenHost 0.0.0.0 -Port 4000 -RetireWinT3Service
