BeforeAll {
    Import-Module "$PSScriptRoot\..\resources\AstapConfig\AstapConfig.psm1" -Force
    $script:ConfigPath = Join-Path $TestDrive 'astap.cfg'
    @'
window_left=10
star_database=d50
solve_search_field=0
radius_search=10
sqm_key=do-not-read
'@ | Set-Content -LiteralPath $script:ConfigPath
}

Describe 'AstroStack/AstapConfig' {
    It 'reads only requested supported settings' {
        $settings = Read-AstapSettings -ConfigPath $script:ConfigPath -Names @('star_database', 'radius_search')

        $settings.star_database | Should -BeExactly 'd50'
        $settings.radius_search | Should -BeExactly '10'
        $settings.PSObject.Properties.Name | Should -Not -Contain 'sqm_key'
    }

    It 'reports matching desired settings as compliant' {
        $instance = [PSCustomObject]@{
            ConfigPath = $script:ConfigPath
            Settings   = [PSCustomObject]@{
                star_database = 'd50'
                radius_search = '10'
            }
        }

        (Get-AstapConfigState -Instance $instance).InDesiredState | Should -BeTrue
    }

    It 'reports a setting mismatch as drift' {
        $instance = [PSCustomObject]@{
            ConfigPath = $script:ConfigPath
            Settings   = [PSCustomObject]@{
                star_database = 'h18'
            }
        }

        (Get-AstapConfigState -Instance $instance).InDesiredState | Should -BeFalse
    }

    It 'reports a missing executable as drift' {
        $instance = [PSCustomObject]@{
            ConfigPath     = $script:ConfigPath
            ExecutablePath = Join-Path $TestDrive 'missing.exe'
            Settings       = [PSCustomObject]@{
                star_database = 'd50'
            }
        }

        $state = Get-AstapConfigState -Instance $instance
        $state.ExecutableExists | Should -BeFalse
        $state.InDesiredState | Should -BeFalse
    }

    It 'rejects sensitive or unsupported settings' {
        {
            Assert-AstapSettingsSupported -Settings ([PSCustomObject]@{ sqm_key = 'redacted' })
        } | Should -Throw "*not supported*"
    }
}
