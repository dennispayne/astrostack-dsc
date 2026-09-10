#requires -Version 7.0
<#
.SYNOPSIS
    Generates config\astro-stack.dsc.config.yaml from manifest\astro-stack.manifest.json.
    Re-run this after adding/removing entries in the manifest so the DSC config stays in sync.
    (Bumping an *existing* entry's expectedVersion does NOT require regenerating - the config
    references ManifestPath and re-reads it live on every dsc invocation.)
#>
param(
    [string]$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
)

$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $RepoRoot 'manifest\astro-stack.manifest.json'
$manifestPathForward = $manifestPath -replace '\\', '/'
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json -Depth 20

function New-ResourceBlock {
    param([string]$Name, [string]$Id, [string]$Kind)
    [ordered]@{
        name = $Name
        type = 'AstroStack/Component'
        properties = [ordered]@{
            Id             = $Id
            Kind           = $Kind
            ManifestPath   = $manifestPathForward
            InDesiredState = $true
        }
    }
}

$resources = [System.Collections.Generic.List[object]]::new()

foreach ($app in $manifest.applications) {
    $resources.Add((New-ResourceBlock -Name "Application: $($app.id)" -Id $app.id -Kind 'Application'))
}
foreach ($ds in $manifest.datasets) {
    $resources.Add((New-ResourceBlock -Name "Dataset: $($ds.id)" -Id $ds.id -Kind 'Dataset'))
}
$resources.Add((New-ResourceBlock -Name 'NINA plugins (pinned set)' -Id 'nina-plugins' -Kind 'NinaPlugin'))

$doc = [ordered]@{
    '$schema'   = 'https://aka.ms/dsc/schemas/v3/bundled/config/document.json'
    directives  = [ordered]@{ securityContext = 'elevated' }
    resources   = $resources
}

# ConvertTo-Yaml isn't built into PowerShell; DSC accepts JSON too (config documents may be JSON or YAML),
# so emit JSON with a .dsc.config.yaml-compatible name isn't ideal - write real JSON with a .json extension
# instead, which `dsc config` accepts identically to YAML.
$outPath = Join-Path $RepoRoot 'config\astro-stack.dsc.config.json'
$doc | ConvertTo-Json -Depth 20 | Set-Content -Path $outPath -Encoding utf8
Write-Output "Wrote $outPath ($($resources.Count) resource instances)"
