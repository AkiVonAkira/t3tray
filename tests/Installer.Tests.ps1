[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Pester invokes TestCases with Value bound at runtime.')]
param()
BeforeAll {
    . "$PSScriptRoot/../installer/config.ps1"
    . "$PSScriptRoot/../installer/ui.ps1"
    function Get-TestKey {
        param([ConsoleKey]$Key, [char]$Character = 0, [switch]$Control)
        [ConsoleKeyInfo]::new($Character, $Key, $false, $false, $Control.IsPresent)
    }
    function Initialize-TestInput {
        param([ConsoleKeyInfo[]]$Keys)
        $script:keys = [Collections.Generic.Queue[ConsoleKeyInfo]]::new()
        foreach ($key in $Keys) { $script:keys.Enqueue($key) }
    }
}
Describe 'Keyboard input through the real controls' {
    BeforeEach {
        Mock Write-T3TrayFrame {}
        Mock Read-T3TrayKey { $script:keys.Dequeue() }
    }
    It 'replaces the suggested port when the user types' {
        Initialize-TestInput @((Get-TestKey D4 '4'), (Get-TestKey D0 '0'), (Get-TestKey D0 '0'), (Get-TestKey D0 '0'), (Get-TestKey Enter))
        Read-T3TrayText 'port' '3773' Port | Should -Be '4000'
    }
    It 'keeps the suggested value on Enter and edits it with movement and deletion' {
        Initialize-TestInput @((Get-TestKey Enter))
        Read-T3TrayText 'port' '3773' Port | Should -Be '3773'
        Initialize-TestInput @((Get-TestKey Home), (Get-TestKey Delete), (Get-TestKey End), (Get-TestKey Backspace), (Get-TestKey D8 '8'), (Get-TestKey Enter))
        Read-T3TrayText 'port' '3773' Port | Should -Be '778'
    }
    It 'waits for a valid port after a rejected submission' {
        Initialize-TestInput @((Get-TestKey D0 '0'), (Get-TestKey Enter), (Get-TestKey A ([char]1) -Control), (Get-TestKey D8 '8'), (Get-TestKey D0 '0'), (Get-TestKey Enter))
        Read-T3TrayText 'port' '3773' Port | Should -Be '80'
    }
    It 'returns on Escape and cancels on Ctrl+C' {
        Initialize-TestInput @((Get-TestKey Escape))
        Read-T3TrayText 'port' '3773' Port | Should -BeNullOrEmpty
        Initialize-TestInput @((Get-TestKey C ([char]3) -Control))
        { Read-T3TrayText 'port' '3773' Port } | Should -Throw '*cancelled*'
    }
    It 'selects choices with arrow keys and returns on back' {
        Initialize-TestInput @((Get-TestKey UpArrow), (Get-TestKey Enter))
        Read-T3TrayChoice 'channel' @('stable', 'nightly') | Should -Be 1
        Initialize-TestInput @((Get-TestKey B 'b'))
        Read-T3TrayChoice 'channel' @('stable', 'nightly') | Should -Be -1
        Initialize-TestInput @((Get-TestKey Q 'q'))
        { Read-T3TrayChoice 'channel' @('stable', 'nightly') } | Should -Throw '*cancelled*'
    }
}
Describe 'Mode selection' {
    It 'opens the wizard with no arguments or with only DryRun' {
        Test-T3TrayInteractive @{} @() $false $false $false | Should -BeTrue
        Test-T3TrayInteractive @{ DryRun = $true } @() $false $false $false | Should -BeTrue
    }
    It 'keeps explicit parameters unattended even when false' {
        foreach ($name in @('Channel', 'Port', 'ListenHost', 'Version', 'ExePath', 'AssetDir', 'BaseDir', 'NoStart', 'NoStartAtSignIn', 'NonInteractive')) {
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
    It 'uses existing Run arguments before the detected desktop channel' {
        $config = ConvertFrom-T3TrayRunValue '"C:\Users\Example\.t3tray\t3tray.exe" --host 0.0.0.0 --port 4000 --channel stable' nightly
        $config.Channel | Should -Be stable
        $config.Port | Should -Be 4000
        $config.ListenHost | Should -Be '0.0.0.0'
        (ConvertFrom-T3TrayRunValue '' nightly).Channel | Should -Be nightly
    }
    It 'reads the run command and a quoted T3 home from the sign-in entry' {
        $config = ConvertFrom-T3TrayRunValue '"C:\Users\Example\.t3tray\t3tray.exe" run --host 127.0.0.1 --port 4100 --channel nightly --base-dir "D:\T3 Home"'
        $config.Port | Should -Be 4100
        $config.Channel | Should -Be nightly
        $config.BaseDir | Should -Be 'D:\T3 Home'
    }
    It 'rejects a T3 home that would break the sign-in command' {
        { New-T3TrayConfig -BaseDir 'D:\' } | Should -Throw
        { New-T3TrayConfig -BaseDir 'D:\a"b' } | Should -Throw
        (New-T3TrayConfig -BaseDir 'D:\T3 Home\').BaseDir | Should -Be 'D:\T3 Home'
    }
    It 'rejects invalid ports' -TestCases @(@{ Value = '0' }, @{ Value = '65536' }, @{ Value = 'abc' }, @{ Value = '37.73' }) {
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
    It 'dry-run never invokes an install action' {
        $fixture = Join-Path $TestDrive 'dry-run'
        $null = New-Item -ItemType Directory "$fixture/installer"
        Copy-Item "$PSScriptRoot/../install.ps1" $fixture
        Copy-Item "$PSScriptRoot/../installer/*.ps1" "$fixture/installer"
        Set-Content "$fixture/installer/legacy-install.ps1" "throw 'Dry-run invoked an install action.'"
        $previousProfile = $env:USERPROFILE
        try {
            $env:USERPROFILE = Join-Path $TestDrive 'user'
            $null = New-Item -ItemType Directory $env:USERPROFILE
            & "$fixture/install.ps1" -DryRun -NonInteractive -Channel nightly -ListenHost '0.0.0.0' -Port 3773 6>$null
            @(Get-ChildItem $env:USERPROFILE -Force).Count | Should -Be 0
        } finally { $env:USERPROFILE = $previousProfile }
    }
}
Describe 'Wizard navigation with scripted answers' {
    It 'goes from start at sign-in to review and back, keeping LAN choices and the T3 home' {
        $script:answers = [Collections.Generic.Queue[int]]::new()
        foreach ($answer in @(0, 1, 1, 0, 1, 1, 0, 0)) { $script:answers.Enqueue($answer) }
        Mock Read-T3TrayChoice { $script:answers.Dequeue() }
        Mock Read-T3TrayText { '4000' }
        Mock Get-T3TrayPortOwner { 'Available' }
        $detection = [pscustomobject]@{ Config = (New-T3TrayConfig -BaseDir 'D:\T3 Home'); Installed = $true; RunValue = ''; Desktop = 'nightly'; PortOwner = 'Available' }
        $config = Invoke-T3TrayWizard $detection
        $config.Channel | Should -Be nightly
        $config.Firewall | Should -BeTrue
        $config.StartAtSignIn | Should -BeTrue
        $config.BaseDir | Should -Be 'D:\T3 Home'
        $config.Port | Should -Be 4000
        $script:answers.Count | Should -Be 0
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
        $detection = [pscustomobject]@{ Config = (New-T3TrayConfig); Installed = $false; RunValue = ''; Desktop = 'Not found'; PortOwner = 'Available' }
        $config = Invoke-T3TrayWizard $detection
        $config.ListenHost | Should -Be localhost
        $config.Port | Should -Be 5000
        $config.Firewall | Should -BeFalse
        $script:fields.Count | Should -Be 0
    }
}
Describe 'Executable replacement' {
    It 'replaces t3tray.exe while a process runs from it, as t3tray update does' {
        $tray = Join-Path $TestDrive 'tray'
        $null = New-Item -ItemType Directory $tray
        $exe = Join-Path $tray 't3tray.exe'
        Copy-Item "$env:SystemRoot\System32\PING.EXE" $exe
        $source = Join-Path $TestDrive 'new.exe'
        Set-Content -LiteralPath $source -Value 'new release'
        $info = New-Object Diagnostics.ProcessStartInfo -Property @{ FileName = $exe; Arguments = '-n 120 127.0.0.1'
            UseShellExecute = $false; CreateNoWindow = $true; RedirectStandardOutput = $true }
        $running = [Diagnostics.Process]::Start($info)
        try { Install-T3TrayExecutable $source $exe }
        finally { $running.Kill(); $running.WaitForExit() }
        Get-Content -LiteralPath $exe | Should -Be 'new release'
        Install-T3TrayExecutable $source $exe
        @(Get-ChildItem -LiteralPath $tray -Filter 't3tray.*.old').Count | Should -Be 1
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
        $script = Join-Path $TestDrive 'streamed.ps1'
        Set-Content -LiteralPath $script -Value $command -Encoding UTF8
        $output = & powershell.exe -NoProfile -File $script 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $output
        $output | Should -Match 'No changes made'
    }
}
