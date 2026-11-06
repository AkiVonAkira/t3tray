param([string]$Path = (Join-Path $PSScriptRoot '../tests'))
$ErrorActionPreference = 'Stop'
$violations = @()
foreach ($file in Get-ChildItem -LiteralPath $Path -Filter '*.ps1' -File -Recurse) {
    $tokens = $null; $parseIssues = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseIssues)
    foreach ($issue in $parseIssues) { $violations += "$($file.Name): $($issue.Message)" }
    $commands = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)
    foreach ($command in $commands) {
        $name = $command.GetCommandName()
        $parameters = @($command.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
        if ($name -eq 'Start-Sleep' -or $name -eq 'Assert-MockCalled' -or ($name -eq 'Should' -and ($parameters -contains 'Invoke' -or $parameters -contains 'InvokeVerifiable'))) {
            $violations += "$($file.Name):$($command.Extent.StartLineNumber): assert the result of an action; do not sleep or assert mock calls."
        }
    }
}
if ($violations.Count) { throw ($violations -join "`n") }
Write-Output 'Test policy passed.'
