BeforeDiscovery {
    $componentCases = Get-ChildItem "$PSScriptRoot\..\manifest\components\*.json" |
        ForEach-Object {
            @{
                Path = $_.FullName
                Data = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 30
            }
        }
}

BeforeAll {
    Import-Module "$PSScriptRoot\..\scripts\lib\ComponentContract.psm1" -Force
    $script:Components = Get-ChildItem "$PSScriptRoot\..\manifest\components\*.json" |
        ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -Depth 30
        }
}

Describe 'repository component manifests' {
    It 'contains a valid schemaVersion 1 component: <Path>' -ForEach $componentCases {
        { Assert-ComponentDefinition -Component $Data -Source $Path } | Should -Not -Throw
    }

    It 'uses unique wingetId values' {
        $ids = @($script:Components.wingetId)
        @($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
    }

    It 'models ASTAP itself as an application' {
        ($script:Components | Where-Object id -eq 'astap').kind | Should -BeExactly 'Application'
    }

    It 'models SharpCap as requiring authenticated acquisition' {
        ($script:Components | Where-Object id -eq 'sharpcap').requiresAuth | Should -BeTrue
    }
}
