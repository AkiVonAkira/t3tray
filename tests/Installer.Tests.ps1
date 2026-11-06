[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester invokes TestCases with Value bound at runtime.')]
param()
BeforeAll {
    . "$PSScriptRoot/../installer/config.ps1"
    . "$PSScriptRoot/../installer/ui.ps1"
}
Describe 'Mode selection' {
    It 'opens the wizard with no arguments or with only DryRun' {
        Test-T3TrayInteractive @{} @() $false $false $false | Should -BeTrue
        Test-T3TrayInteractive @{ DryRun = $true } @() $false $false $false | Should -BeTrue
    }
    It 'keeps explicit parameters unattended even when false' {
        foreach ($name in @('Channel', 'Port', 'ListenHost', 'Version', 'ExePath', 'AssetDir', 'NoStart', 'RetireWinT3Service', 'NonInteractive')) {
            $parameters = @{}; $parameters[$name] = $false
            Test-T3TrayInteractive $parameters @() $false $false $false | Should -BeFalse
        }
    }
    It 'keeps every T3TRAY environment variable unattended' {
        Test-T3TrayInteractive @{} @('T3TRAY_FUTURE') $false $false $false | Should -BeFalse
    }
    It 'stays interactive when only T3TRAY_REF picks the helper branch' {
        Test-T3TrayInteractive @{} @('T3TRAY_REF') $false $false $false | Should -BeTrue
    }
    It 'keeps redirection and CI unattended' {
        Test-T3TrayInteractive @{} @() $true $false $false | Should -BeFalse
        Test-T3TrayInteractive @{} @() $false $true $false | Should -BeFalse
        Test-T3TrayInteractive @{} @() $false $false $true | Should -BeFalse
    }
}
Describe 'Configuration and plans' {
    It 'has the existing defaults' {
        $config = New-T3TrayConfig
        $config.Channel | Should -Be stable
        $config.ListenHost | Should -Be '127.0.0.1'
        $config.Port | Should -Be 3773
        $config.StartAtSignIn | Should -BeTrue
        $config.Firewall | Should -BeFalse
    }
    It 'uses existing Run arguments before the detected desktop channel' {
        $config = ConvertFrom-T3TrayRunValue '"C:\Users\Example\.t3tray\t3tray.exe" --host 0.0.0.0 --port 4000 --channel stable' nightly
        $config.Channel | Should -Be stable
        $config.Port | Should -Be 4000
        $config.ListenHost | Should -Be '0.0.0.0'
        (ConvertFrom-T3TrayRunValue '' nightly).Channel | Should -Be nightly
    }
    It 'rejects invalid ports' -TestCases @(@{ Value = '0' }, @{ Value = '65536' }, @{ Value = 'abc' }, @{ Value = '37.73' }, @{ Value = '' }) {
        param($Value)
        { New-T3TrayConfig -Port $Value } | Should -Throw
    }
    It 'accepts port boundaries' {
        (New-T3TrayConfig -Port 1).Port | Should -Be 1
        (New-T3TrayConfig -Port 65535).Port | Should -Be 65535
    }
    It 'rejects command injection at configuration boundaries' {
        { New-T3TrayConfig -ListenHost 'localhost; bad' } | Should -Throw
        { New-T3TrayConfig -Channel 'beta' } | Should -Throw
    }
    It 'only offers a firewall rule for LAN' {
        (New-T3TrayConfig -Firewall $true).Firewall | Should -BeFalse
        (New-T3TrayConfig -ListenHost '0.0.0.0' -Firewall $true).Firewall | Should -BeTrue
    }
    It 'plans all requested changes and verification' {
        $config = New-T3TrayConfig -Channel nightly -ListenHost '0.0.0.0' -Port 4000 -Firewall $true -Retire $true -StartAtSignIn $false
        $plan = (Get-T3TrayPlan $config) -join "`n"
        $plan | Should -Match 'Private profile only'
        $plan | Should -Match 'TCP 4000'
        $plan | Should -Match 'Remove T3Tray sign-in'
        $plan | Should -Match 'disable its logon task'
        $plan | Should -Match 'server.getConfig serverSelfUpdate=boot-service'
        (Get-T3TrayPlan $config $true) -join "`n" | Should -Not -Match 'Verify HTTP'
    }
    It 'dry-run never invokes an install action' {
        $output = & "$PSScriptRoot/../install.ps1" -DryRun -NonInteractive -Channel nightly -ListenHost '0.0.0.0' -Port 3773 6>&1 | Out-String
        $output | Should -Match 'No changes made'
        $output | Should -Match 'channel nightly'
        $output | Should -Match 'Verification is planned, not performed'
    }
}
Describe 'Wizard navigation with scripted answers' {
    It 'preserves LAN choices through review back and skips no detected task' {
        $script:answers = [Collections.Generic.Queue[int]]::new()
        foreach ($answer in @(0, 1, 1, 0, 1, 0, 1, 0, 0)) { $script:answers.Enqueue($answer) }
        Mock Read-T3TrayChoice { $script:answers.Dequeue() }
        Mock Read-T3TrayText { '4000' }
        Mock Get-T3TrayPortOwner { 'Available' }
        $detection = [pscustomobject]@{ Config = (New-T3TrayConfig); Installed = $true; RunValue = ''; OldTask = $true; Desktop = 'nightly'; PortOwner = 'Available' }
        $config = Invoke-T3TrayWizard $detection
        $config.Channel | Should -Be nightly
        $config.Firewall | Should -BeTrue
        $config.Retire | Should -BeTrue
        $config.Port | Should -Be 4000
        $script:answers.Count | Should -Be 0
    }
    It 'stops on quit without running actions' {
        Mock Read-T3TrayChoice { throw 'cancelled' }
        { Invoke-T3TrayWizard ([pscustomobject]@{ Config = (New-T3TrayConfig) }) } | Should -Throw '*cancelled*'
    }
}
Describe 'Wizard branches' {
    It 'visits custom address and preserves values on back' {
        $script:choices = [Collections.Generic.Queue[int]]::new()
        foreach ($answer in @(0, 0, 2, 0, 0)) { $script:choices.Enqueue($answer) }
        $script:fields = [Collections.Generic.Queue[object]]::new()
        foreach ($answer in @('localhost', $null, 'localhost', '5000')) { $script:fields.Enqueue($answer) }
        Mock Read-T3TrayChoice { $script:choices.Dequeue() }
        Mock Read-T3TrayText { $script:fields.Dequeue() }
        Mock Get-T3TrayPortOwner { 'Available' }
        $detection = [pscustomobject]@{ Config = (New-T3TrayConfig); Installed = $false; RunValue = ''; OldTask = $false; Desktop = 'Not found'; PortOwner = 'Available' }
        $config = Invoke-T3TrayWizard $detection
        $config.ListenHost | Should -Be localhost
        $config.Port | Should -Be 5000
        $config.Firewall | Should -BeFalse
        $script:fields.Count | Should -Be 0
        Should -Invoke Read-T3TrayChoice -Times 0 -ParameterFilter { $Title -eq 'retire win-t3service' }
    }
}
Describe 'Streamed entry scripts' {
    It 'loads BOM-prefixed helpers without a script directory' {
        $root = (Resolve-Path "$PSScriptRoot/..").Path.Replace("'", "''")
        $command = @'
$ErrorActionPreference = 'Stop'
$root = '__ROOT__'
function Invoke-RestMethod {
    param($Uri)
    $name = ([uri]$Uri).Segments[-1]
    return [string][char]0xFEFF + [IO.File]::ReadAllText((Join-Path $root "installer/$name"))
}
$source = [IO.File]::ReadAllText((Join-Path $root 'install.ps1'))
& ([scriptblock]::Create($source)) -DryRun -NonInteractive
'@
        $command = $command.Replace('__ROOT__', $root)
        $shell = (Get-Process -Id $PID).Path
        $output = & $shell -NoProfile -Command $command 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $output
        $output | Should -Match 'No changes made'
    }
}
