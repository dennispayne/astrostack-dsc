BeforeAll {
    Import-Module "$PSScriptRoot\..\scripts\lib\ComponentContract.psm1" -Force

    function New-TestComponent {
        [PSCustomObject][ordered]@{
            schemaVersion    = 1
            id               = 'nina'
            wingetId         = 'AstroStack.NINA'
            kind             = 'Application'
            module           = 'imaging-app'
            allowlistDomains = @('github.com')
            requiresAuth     = $false
            expectedVersion  = '3.2.0.9001'
            availableVersion = $null
            downloadUrl      = $null
            downloadFileName = 'old.zip'
            sha256           = $null
            verified         = $false
            notes            = 'preserve this investigation'
        }
    }
}

Describe 'component manifest contract' {
    It 'accepts an unhydrated component' {
        { Assert-ComponentDefinition -Component (New-TestComponent) } | Should -Not -Throw
    }

    It 'requires a checksum when a download URL is present' {
        $component = New-TestComponent
        $component.downloadUrl = 'https://github.com/example/file.zip'

        { Assert-ComponentDefinition -Component $component } | Should -Throw '*sha256*'
    }

    It 'requires the download domain to be allow-listed' {
        $component = New-TestComponent
        $component.downloadUrl = 'https://example.com/file.zip'
        $component.sha256 = 'a' * 64

        { Assert-ComponentDefinition -Component $component } | Should -Throw '*allowlistDomains*'
    }

    It 'merges only machine-owned fields' {
        $component = New-TestComponent
        $patch = [PSCustomObject]@{
            wingetId         = 'AstroStack.NINA'
            id               = 'overwrite-attempt'
            expectedVersion  = '99.0'
            notes            = 'overwrite-attempt'
            requiresAuth     = $true
            downloadUrl      = 'https://github.com/example/file.zip'
            downloadFileName = 'new.zip'
            sha256           = 'b' * 64
            verified         = $true
            availableVersion = '3.3.0'
        }

        $merged = Merge-WgfetchPatchData -Component $component -PatchItem $patch

        $merged.id | Should -BeExactly 'nina'
        $merged.expectedVersion | Should -BeExactly '3.2.0.9001'
        $merged.notes | Should -BeExactly 'preserve this investigation'
        $merged.requiresAuth | Should -BeFalse
        $merged.downloadFileName | Should -BeExactly 'new.zip'
        $merged.availableVersion | Should -BeExactly '3.3.0'
    }

    It 'applies a patch file without replacing human-owned data' {
        $componentsRoot = Join-Path $TestDrive 'components'
        New-Item -ItemType Directory -Path $componentsRoot | Out-Null
        $componentPath = Join-Path $componentsRoot 'nina.json'
        New-TestComponent | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $componentPath

        $patchPath = Join-Path $TestDrive 'patch.json'
        [ordered]@{
            schemaVersion = 1
            components    = @(
                [ordered]@{
                    wingetId         = 'AstroStack.NINA'
                    expectedVersion  = '99.0'
                    notes            = 'overwrite-attempt'
                    requiresAuth     = $true
                    downloadUrl      = 'https://github.com/example/file.zip'
                    downloadFileName = 'new.zip'
                    sha256           = 'c' * 64
                    verified         = $true
                    availableVersion = '3.3.0'
                }
            )
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $patchPath

        & "$PSScriptRoot\..\scripts\Merge-WgfetchPatch.ps1" `
            -PatchPath $patchPath `
            -ComponentsRoot $componentsRoot | Out-Null

        $updated = Get-Content -LiteralPath $componentPath -Raw | ConvertFrom-Json
        $updated.expectedVersion | Should -BeExactly '3.2.0.9001'
        $updated.notes | Should -BeExactly 'preserve this investigation'
        $updated.requiresAuth | Should -BeFalse
        $updated.downloadFileName | Should -BeExactly 'new.zip'
        $updated.availableVersion | Should -BeExactly '3.3.0'
    }

    It 'requires requiresAuth to be boolean when present' {
        $component = New-TestComponent
        $component.requiresAuth = 'true'

        { Assert-ComponentDefinition -Component $component } | Should -Throw '*must be a boolean*'
    }
}

Describe 'wgfetch artifact map contract' {
    It 'resolves a relative artifact path by PackageIdentifier' {
        $artifactDirectory = Join-Path $TestDrive 'installers\AstroStack.NINA\3.2.0.9001'
        New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
        $artifactPath = Join-Path $artifactDirectory 'nina.zip'
        Set-Content -LiteralPath $artifactPath -Value 'fixture'

        $mapPath = Join-Path $TestDrive 'artifact-map.json'
        [ordered]@{
            schemaVersion = 1
            artifacts     = [ordered]@{
                'AstroStack.NINA' = 'installers/AstroStack.NINA/3.2.0.9001/nina.zip'
            }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mapPath

        (Resolve-WgfetchArtifact -ArtifactMapPath $mapPath -WingetId 'AstroStack.NINA') |
            Should -BeExactly ([IO.Path]::GetFullPath($artifactPath))
    }

    It 'rejects an unmapped PackageIdentifier' {
        $mapPath = Join-Path $TestDrive 'empty-map.json'
        '{"schemaVersion":1,"artifacts":{}}' | Set-Content -LiteralPath $mapPath

        {
            Resolve-WgfetchArtifact -ArtifactMapPath $mapPath -WingetId 'AstroStack.Missing'
        } | Should -Throw '*no path*'
    }
}
