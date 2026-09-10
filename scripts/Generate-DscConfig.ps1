#requires -Version 7.0
<#
.SYNOPSIS
    Generates one DSC config file per module under config\modules\*.dsc.config.json from
    manifest\components\*.json (grouped by each file's 'module' field), plus a top-level
    aggregator config\astro-stack.dsc.config.json that Microsoft.DSC/Include-s each module file.

    Re-run this after adding/removing component files or changing a component's 'module' tag.
    Bumping an *existing* component's expectedVersion does NOT require regenerating - every
    generated resource references ManifestPath and DSC re-reads that file live on every invocation.

    Swapping a major component (e.g. NINA -> Sequence Generator Pro) means replacing the
    component file(s) for that module and regenerating just that module's config - the
    aggregator itself only lists module file paths and does not need to change.
#>
param(
    [string]$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
)

$ErrorActionPreference = 'Stop'
$componentsDir = Join-Path $RepoRoot 'manifest\components'
$modulesOutDir = Join-Path $RepoRoot 'config\modules'
if (-not (Test-Path $modulesOutDir)) { New-Item -ItemType Directory -Path $modulesOutDir -Force | Out-Null }
Get-ChildItem -Path $modulesOutDir -Filter '*.dsc.config.json' -File |
    Remove-Item -Force

$componentFiles = Get-ChildItem -Path $componentsDir -Filter '*.json' | Sort-Object Name
if (-not $componentFiles) { throw "No component files found under '$componentsDir'." }

function New-ResourceBlock {
    param([string]$Id, [string]$Kind, [string]$ManifestPathForward)
    [ordered]@{
        name       = "$Kind`: $Id"
        type       = 'AstroStack/Component'
        properties = [ordered]@{
            ManifestPath   = $ManifestPathForward
            InDesiredState = $true
        }
    }
}

# Group component files by their own 'module' field (swap-unit for extensibility).
$byModule = [ordered]@{}
foreach ($file in $componentFiles) {
    $def = Get-Content $file.FullName -Raw | ConvertFrom-Json -Depth 20
    foreach ($field in @('id', 'kind', 'module')) {
        if (-not $def.$field) { throw "Component file '$($file.FullName)' is missing required field '$field'." }
    }
    if (-not $byModule.Contains($def.module)) { $byModule[$def.module] = [System.Collections.Generic.List[object]]::new() }
    $byModule[$def.module].Add([PSCustomObject]@{
        Id           = $def.id
        Kind         = $def.kind
        ManifestPath = ($file.FullName -replace '\\', '/')
    })
}

foreach ($moduleName in ($byModule.Keys | Sort-Object)) {
    $resources = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $byModule[$moduleName]) {
        $resources.Add((New-ResourceBlock -Id $item.Id -Kind $item.Kind -ManifestPathForward $item.ManifestPath))
    }

    $moduleDoc = [ordered]@{
        '$schema' = 'https://aka.ms/dsc/schemas/v3/bundled/config/document.json'
        resources = $resources
    }

    $moduleOutPath = Join-Path $modulesOutDir "$moduleName.dsc.config.json"
    $moduleDoc | ConvertTo-Json -Depth 20 | Set-Content -Path $moduleOutPath -Encoding utf8
    Write-Output "Wrote $moduleOutPath ($($resources.Count) resource instances, module '$moduleName')"
}

# Top-level aggregator: one Microsoft.DSC/Include per module file. To swap a module (e.g. replace
# NINA with Sequence Generator Pro), replace that module's component file(s) + regenerate just its
# config file - this aggregator only references module file paths and needs no changes.
$includeResources = [System.Collections.Generic.List[object]]::new()
foreach ($moduleName in ($byModule.Keys | Sort-Object)) {
    $relPath = "modules/$moduleName.dsc.config.json"
    $includeResources.Add([ordered]@{
        name       = "Module: $moduleName"
        type       = 'Microsoft.DSC/Include'
        properties = [ordered]@{
            configurationFile = $relPath
        }
    })
}

$aggregatorDoc = [ordered]@{
    '$schema'  = 'https://aka.ms/dsc/schemas/v3/bundled/config/document.json'
    directives = [ordered]@{ securityContext = 'elevated' }
    resources  = $includeResources
}

$aggregatorOutPath = Join-Path $RepoRoot 'config\astro-stack.dsc.config.json'
$aggregatorDoc | ConvertTo-Json -Depth 20 | Set-Content -Path $aggregatorOutPath -Encoding utf8
Write-Output "Wrote $aggregatorOutPath ($($includeResources.Count) module includes)"
