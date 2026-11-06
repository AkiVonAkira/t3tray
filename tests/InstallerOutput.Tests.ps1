BeforeAll {
    . "$PSScriptRoot/../installer/config.ps1"
    . "$PSScriptRoot/../installer/ui.ps1"
    $script:root = (Resolve-Path "$PSScriptRoot/..").Path
    function Invoke-InstallerConsole([string]$Body) {
        $file = Join-Path $TestDrive "console-$([Guid]::NewGuid()).ps1"
        $header = ". '$($script:root)/installer/config.ps1'; . '$($script:root)/installer/ui.ps1'`r`n"
        Set-Content -LiteralPath $file -Value ($header + $Body) -Encoding UTF8
        $output = & powershell.exe -NoProfile -File $file
        @($output | ForEach-Object { [string]$_ })
    }
}
Describe 'Local URL and status command' {
    It 'maps wildcard listen addresses to loopback' -TestCases @(
        @{ ListenHost = '0.0.0.0'; Expected = 'http://127.0.0.1:4000/' }
        @{ ListenHost = '::'; Expected = 'http://127.0.0.1:4000/' }
        @{ ListenHost = '127.0.0.1'; Expected = 'http://127.0.0.1:4000/' }
        @{ ListenHost = '192.168.1.5'; Expected = 'http://192.168.1.5:4000/' }
        @{ ListenHost = '::1'; Expected = 'http://[::1]:4000/' }) {
        param($ListenHost, $Expected)
        Get-T3TrayLocalUrl $ListenHost 4000 | Should -Be $Expected
    }
    It 'uses the short command only when the wrapper folder is on PATH' {
        Get-T3TrayStatusCommand 'C:\Windows;C:\Users\Example\.t3\bin\' 'C:\Users\Example\.t3\bin' | Should -Be 't3tray status'
        Get-T3TrayStatusCommand 'C:\Windows' 'C:\Users\Example\.t3\bin' | Should -Be '& "C:\Users\Example\.t3\bin\t3tray.cmd" status'
    }
}
Describe 'Console output' {
    It 'prints each step once with its result on the same line and hides action output' {
        $lines = Invoke-InstallerConsole @'
Invoke-T3TrayStep 'Copy executable' { 'child chatter' }
try { Invoke-T3TrayStep 'HTTP 200' { throw 'Server did not return HTTP 200.' } } catch { Write-Host "error: $($_.Exception.Message)" }
'@
        @($lines | Where-Object { $_ -match 'Copy executable' }).Count | Should -Be 1
        $lines -match 'Copy executable .* ok\b' | Should -Not -BeNullOrEmpty
        $lines -match 'HTTP 200 .* failed\b' | Should -Not -BeNullOrEmpty
        $lines -match 'child chatter' | Should -BeNullOrEmpty
        $lines -match '^error: HTTP 200 failed\. Server did not return HTTP 200\.' | Should -Not -BeNullOrEmpty
    }
    It 'does not claim a running tray after -NoStart' {
        $lines = Invoke-InstallerConsole @'
$config = New-T3TrayConfig -ListenHost 0.0.0.0 -Port 4000
Write-T3TrayInstallSummary $config -NoStart $true
'@
        ($lines -join "`n") | Should -Not -Match 'running'
        ($lines -join "`n") | Should -Match 'Not started'
        ($lines -join "`n") | Should -Match '--port 4000'
    }
}
