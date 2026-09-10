#requires -Version 7.0
<#
.SYNOPSIS
    Exercises the AstroStack DSC resource end to end against an ephemeral synthetic stack.
.DESCRIPTION
    Creates temporary HKCU uninstall entries, a dataset directory, a NINA-style plugin log, component
    manifests, an ordered module, and a Microsoft.DSC/Include aggregate configuration. It verifies
    compliant state, deliberate drift across multiple resource kinds, and recovery. No vendor
    installers, machine-wide registry keys, application data, or hardware are touched.
#>
param(
    [string]$RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
)

$ErrorActionPreference = 'Stop'
$fixtureId = "AstroStackE2E-$([guid]::NewGuid().ToString('N'))"
$fixtureRoot = Join-Path $env:TEMP $fixtureId
$manifestRoot = Join-Path $fixtureRoot 'manifests'
$moduleRoot = Join-Path $fixtureRoot 'modules'
$logRoot = Join-Path $fixtureRoot 'logs'
$datasetRoot = Join-Path $fixtureRoot 'catalog'
$registryRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
$runtimeRegistryPath = Join-Path $registryRoot "$fixtureId-runtime"
$hostRegistryPath = Join-Path $registryRoot "$fixtureId-host"

function Write-JsonFile {
    param(
        [Parameter(Mandatory)] $Value,
        [Parameter(Mandatory)] [string]$Path
    )
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-BaseComponent {
    param(
        [Parameter(Mandatory)] [string]$Id,
        [Parameter(Mandatory)] [string]$WingetId,
        [Parameter(Mandatory)] [string]$Kind
    )
    [ordered]@{
        schemaVersion    = 1
        id               = $Id
        wingetId         = $WingetId
        kind             = $Kind
        module           = 'e2e-stack'
        allowlistDomains = @()
        availableVersion = $null
        downloadUrl      = $null
        downloadFileName = $null
        sha256           = $null
        verified         = $false
    }
}

function Set-FakeApplication {
    param(
        [Parameter(Mandatory)] [string]$RegistryPath,
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter(Mandatory)] [string]$Version
    )
    New-Item -Path $RegistryPath -Force | Out-Null
    New-ItemProperty -Path $RegistryPath -Name DisplayName -Value $DisplayName -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $RegistryPath -Name DisplayVersion -Value $Version -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $RegistryPath -Name InstallDate -Value '20260910' -PropertyType String -Force | Out-Null
}

function Write-PluginLog {
    param([Parameter(Mandatory)] [string]$Version)
    "INFO Successfully loaded plugin E2E Plate Solver version $Version by AstroStack" |
        Set-Content -LiteralPath (Join-Path $logRoot 'e2e.log') -Encoding utf8
}

function Get-DscResult {
    param([Parameter(Mandatory)] [string]$ConfigPath)

    $output = & dsc config test --file $ConfigPath --output-format json 2>&1
    $exitCode = $LASTEXITCODE
    $result = $null
    foreach ($line in $output) {
        if ($line -isnot [string] -or -not $line.TrimStart().StartsWith('{')) { continue }
        try {
            $candidate = $line | ConvertFrom-Json -Depth 30
            if ($null -ne $candidate.PSObject.Properties['results'] -and
                $null -ne $candidate.PSObject.Properties['hadErrors']) {
                $result = $candidate
            }
        } catch {
            continue
        }
    }

    if (-not $result) {
        throw "DSC emitted no result. Output:`n$($output -join [Environment]::NewLine)"
    }
    if ($exitCode -ne 0) {
        throw "DSC exited with code $exitCode. Output:`n$($output -join [Environment]::NewLine)"
    }
    return $result
}

function Get-ResourceResults {
    param([Parameter(Mandatory)] $Result)

    foreach ($include in $Result.results) {
        foreach ($resource in $include.result) {
            [PSCustomObject]@{
                Name           = $resource.name
                InDesiredState = [bool]$resource.result.inDesiredState
            }
        }
    }
}

function Assert-State {
    param(
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)] [hashtable]$Expected
    )

    if ($Result.hadErrors) {
        throw 'DSC reported resource errors.'
    }
    $actual = @{}
    foreach ($resource in Get-ResourceResults -Result $Result) {
        $actual[$resource.Name] = $resource.InDesiredState
    }
    foreach ($name in $Expected.Keys) {
        if (-not $actual.ContainsKey($name)) {
            throw "DSC result did not contain '$name'."
        }
        if ($actual[$name] -ne $Expected[$name]) {
            throw "Expected '$name' inDesiredState=$($Expected[$name]), got $($actual[$name])."
        }
    }
}

try {
    New-Item -ItemType Directory -Path $manifestRoot, $moduleRoot, $logRoot, $datasetRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $datasetRoot 'catalog.dat') -Value 'synthetic catalog'

    $runtimeName = "$fixtureId Runtime"
    $hostName = "$fixtureId Imaging Host"
    Set-FakeApplication -RegistryPath $runtimeRegistryPath -DisplayName $runtimeName -Version '1.0.0'
    Set-FakeApplication -RegistryPath $hostRegistryPath -DisplayName $hostName -Version '2.0.0'
    Write-PluginLog -Version '3.0.0'

    $runtime = New-BaseComponent -Id 'e2e-runtime' -WingetId 'AstroStack.E2E.Runtime' -Kind 'Application'
    $runtime.displayName = $runtimeName
    $runtime.versionSource = 'DisplayVersion'
    $runtime.expectedVersion = '1.0.0'

    $hostComponent = New-BaseComponent -Id 'e2e-imaging-host' -WingetId 'AstroStack.E2E.ImagingHost' -Kind 'Application'
    $hostComponent.displayName = $hostName
    $hostComponent.versionSource = 'DisplayVersion'
    $hostComponent.expectedVersion = '2.0.0'

    $plugins = New-BaseComponent -Id 'e2e-plugins' -WingetId 'AstroStack.E2E.Plugins' -Kind 'NinaPlugin'
    $plugins.logPath = $logRoot
    $plugins.pluginFolderPath = Join-Path $fixtureRoot 'plugins'
    $plugins.manifestRepo = 'synthetic/e2e'
    $plugins.expected = @([ordered]@{ name = 'E2E Plate Solver'; version = '3.0.0' })
    $plugins.knownOrphanedFolders = @()

    $dataset = New-BaseComponent -Id 'e2e-catalog' -WingetId 'AstroStack.E2E.Catalog' -Kind 'Dataset'
    $dataset.expectedVersion = 'fixture'
    $dataset.checkPath = Join-Path $datasetRoot '*'
    $dataset.versionStrategy = 'PathExists'

    $runtimePath = Join-Path $manifestRoot 'runtime.json'
    $hostPath = Join-Path $manifestRoot 'host.json'
    $pluginsPath = Join-Path $manifestRoot 'plugins.json'
    $datasetPath = Join-Path $manifestRoot 'catalog.json'
    Write-JsonFile -Value $runtime -Path $runtimePath
    Write-JsonFile -Value $hostComponent -Path $hostPath
    Write-JsonFile -Value $plugins -Path $pluginsPath
    Write-JsonFile -Value $dataset -Path $datasetPath

    $moduleConfig = [ordered]@{
        '$schema' = 'https://aka.ms/dsc/schemas/v3/bundled/config/document.json'
        resources = @(
            [ordered]@{
                name = 'Application: e2e-runtime'
                type = 'AstroStack/Component'
                properties = [ordered]@{ ManifestPath = $runtimePath; InDesiredState = $true }
            }
            [ordered]@{
                name = 'Application: e2e-imaging-host'
                type = 'AstroStack/Component'
                dependsOn = @("[resourceId('AstroStack/Component', 'Application: e2e-runtime')]")
                properties = [ordered]@{ ManifestPath = $hostPath; InDesiredState = $true }
            }
            [ordered]@{
                name = 'NinaPlugin: e2e-plugins'
                type = 'AstroStack/Component'
                dependsOn = @("[resourceId('AstroStack/Component', 'Application: e2e-imaging-host')]")
                properties = [ordered]@{ ManifestPath = $pluginsPath; InDesiredState = $true }
            }
            [ordered]@{
                name = 'Dataset: e2e-catalog'
                type = 'AstroStack/Component'
                dependsOn = @("[resourceId('AstroStack/Component', 'Application: e2e-runtime')]")
                properties = [ordered]@{ ManifestPath = $datasetPath; InDesiredState = $true }
            }
        )
    }
    $moduleConfigPath = Join-Path $moduleRoot 'e2e-stack.dsc.config.json'
    Write-JsonFile -Value $moduleConfig -Path $moduleConfigPath

    $aggregateConfig = [ordered]@{
        '$schema' = 'https://aka.ms/dsc/schemas/v3/bundled/config/document.json'
        resources = @(
            [ordered]@{
                name = 'Module: e2e-stack'
                type = 'Microsoft.DSC/Include'
                properties = [ordered]@{ configurationFile = 'modules/e2e-stack.dsc.config.json' }
            }
        )
    }
    $aggregateConfigPath = Join-Path $fixtureRoot 'e2e.dsc.config.json'
    Write-JsonFile -Value $aggregateConfig -Path $aggregateConfigPath

    $dscCommand = Get-Command dsc -ErrorAction Stop
    $pwshCommand = Get-Command pwsh -ErrorAction Stop
    $dscDirectory = Split-Path $dscCommand.Source -Parent
    $pwshDirectory = Split-Path $pwshCommand.Source -Parent
    $resourceDirectory = Join-Path $RepoRoot 'resources\AstroComponent'
    $includeManifest = Get-ChildItem -Path $dscDirectory -Filter 'include.dsc.resource.json' -File -ErrorAction SilentlyContinue

    if (-not $includeManifest) {
        $dscPackage = Get-AppxPackage -Name Microsoft.DesiredStateConfiguration -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending |
            Select-Object -First 1
        if ($dscPackage.InstallLocation) {
            $dscDirectory = $dscPackage.InstallLocation
        }
    }

    $env:DSC_RESOURCE_PATH = @($resourceDirectory, $pwshDirectory, $dscDirectory) -join [IO.Path]::PathSeparator

    Write-Output 'E2E phase 1/3: verifying compliant synthetic stack'
    $clean = Get-DscResult -ConfigPath $aggregateConfigPath
    Assert-State -Result $clean -Expected @{
        'Application: e2e-runtime'      = $true
        'Application: e2e-imaging-host' = $true
        'NinaPlugin: e2e-plugins'       = $true
        'Dataset: e2e-catalog'          = $true
    }

    Write-Output 'E2E phase 2/3: introducing and detecting drift'
    Set-FakeApplication -RegistryPath $hostRegistryPath -DisplayName $hostName -Version '1.9.0'
    Write-PluginLog -Version '2.9.0'
    Remove-Item -LiteralPath (Join-Path $datasetRoot 'catalog.dat') -Force
    $drifted = Get-DscResult -ConfigPath $aggregateConfigPath
    Assert-State -Result $drifted -Expected @{
        'Application: e2e-runtime'      = $true
        'Application: e2e-imaging-host' = $false
        'NinaPlugin: e2e-plugins'       = $false
        'Dataset: e2e-catalog'          = $false
    }

    Write-Output 'E2E phase 3/3: restoring and rechecking compliance'
    Set-FakeApplication -RegistryPath $hostRegistryPath -DisplayName $hostName -Version '2.0.0'
    Write-PluginLog -Version '3.0.0'
    Set-Content -LiteralPath (Join-Path $datasetRoot 'catalog.dat') -Value 'synthetic catalog'
    $restored = Get-DscResult -ConfigPath $aggregateConfigPath
    Assert-State -Result $restored -Expected @{
        'Application: e2e-runtime'      = $true
        'Application: e2e-imaging-host' = $true
        'NinaPlugin: e2e-plugins'       = $true
        'Dataset: e2e-catalog'          = $true
    }

    Write-Output 'End-to-end DSC fixture passed: dependencies, Include composition, application, plugin, dataset, drift, and recovery.'
}
finally {
    Remove-Item -LiteralPath $runtimeRegistryPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $hostRegistryPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
