# Requires Pester 5. Run in a non-production test environment.
$launcher = Join-Path $PSScriptRoot '..\windows\Invoke-RegisteredCommand.ps1'
$profileFile = Join-Path $PSScriptRoot '..\windows\command-profiles.example.json'

Describe 'Registered xp_cmdshell launcher static safety checks' {
    BeforeAll {
        $source = Get-Content -LiteralPath $launcher -Raw
        $profiles = Get-Content -LiteralPath $profileFile -Raw | ConvertFrom-Json
    }

    It 'does not use Invoke-Expression' {
        $source | Should -Not -Match '\bInvoke-Expression\b'
    }

    It 'does not start cmd.exe' {
        $source | Should -Not -Match 'FileName\s*=\s*["'']cmd\.exe'
    }

    It 'blocks general-purpose interpreters' {
        $source | Should -Match "'cmd\.exe'"
        $source | Should -Match "'powershell\.exe'"
        $source | Should -Match "'pwsh\.exe'"
    }

    It 'requires exact profile identifiers' {
        @($profiles.profiles | Group-Object id | Where-Object Count -gt 1).Count | Should -Be 0
    }

    It 'ships example profiles disabled' {
        @($profiles.profiles | Where-Object enabled).Count | Should -Be 0
    }

    It 'anchors every example argument rule' {
        foreach ($profile in $profiles.profiles) {
            foreach ($rule in @($profile.argumentRules)) {
                $rule.pattern.StartsWith('^') | Should -BeTrue
                $rule.pattern.EndsWith('$') | Should -BeTrue
                [int]$rule.maxLength | Should -BeGreaterThan 0
            }
        }
    }
}

Describe 'Safe termination helper static safety checks' {
    BeforeAll {
        $terminationSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\windows\Invoke-SafeTermination.ps1') -Raw
        $terminationSettings = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\windows\termination-settings.example.json') -Raw | ConvertFrom-Json
    }

    It 'ships disabled and simulation-only' {
        $terminationSettings.enabled | Should -BeFalse
        $terminationSettings.simulationOnly | Should -BeTrue
        $terminationSettings.allowForcedTermination | Should -BeFalse
    }

    It 'does not call taskkill or kill by image name' {
        $terminationSource | Should -Not -Match '\btaskkill\b'
        $terminationSource | Should -Not -Match 'Get-Process\s+-Name'
    }

    It 'revalidates identity immediately before Kill' {
        $terminationSource | Should -Match 'Revalidate immutable identity'
        $terminationSource | Should -Match '\.Process\.Kill\(\)'
    }
}

