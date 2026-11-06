param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
& "$PSScriptRoot/check-tests.ps1"
$files = @('install.ps1', 'uninstall.ps1') | ForEach-Object { Get-Item (Join-Path $root $_) }
foreach ($folder in @('installer', 'scripts', 'tests')) { $files += Get-ChildItem (Join-Path $root $folder) -File -Filter '*.ps1' -Recurse }
foreach ($file in $files) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    if (@($bytes | Where-Object { $_ -gt 127 }).Count -and -not ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) {
        throw "$($file.Name) contains non-ASCII text without a UTF-8 BOM. Windows PowerShell 5.1 needs the BOM."
    }
}
Import-Module Pester -MinimumVersion 5.7.1 -ErrorAction Stop
Import-Module PSScriptAnalyzer -MinimumVersion 1.24.0 -ErrorAction Stop
$issues = @($files | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Severity Warning,Error })
if ($issues.Count) { $issues | Format-Table -AutoSize; throw "Script analysis found $($issues.Count) issues." }
$result = Invoke-Pester -Path "$root/tests" -PassThru -Output Normal
if ($result.Result -ne 'Passed') { throw 'Installer tests failed.' }
& "$PSScriptRoot/interactive-smoke.ps1"
