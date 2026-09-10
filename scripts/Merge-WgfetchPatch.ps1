#requires -Version 7.0
<#
.SYNOPSIS
    Applies wgfetch-owned metadata to component manifests without replacing human-owned fields.
.DESCRIPTION
    The patch document must use schemaVersion 1 and contain a components array. Each item is joined
    by wingetId. Only downloadUrl, downloadFileName, sha256, verified, and availableVersion are copied.
#>
param(
    [Parameter(Mandatory)] [string]$PatchPath,
    [string]$ComponentsRoot = (Join-Path (Resolve-Path "$PSScriptRoot\..").Path 'manifest\components')
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\lib\ComponentContract.psm1" -Force

$patch = Get-Content -LiteralPath $PatchPath -Raw | ConvertFrom-Json -Depth 30
if ($patch.schemaVersion -ne 1) {
    throw "Unsupported wgfetch patch schemaVersion '$($patch.schemaVersion)'."
}
if (-not $patch.components) {
    throw "wgfetch patch '$PatchPath' has no components array."
}

$componentFiles = Get-ChildItem -Path $ComponentsRoot -Filter '*.json' -File
$byWingetId = @{}
foreach ($file in $componentFiles) {
    $component = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 30
    Assert-ComponentDefinition -Component $component -Source $file.FullName
    if ($byWingetId.ContainsKey($component.wingetId)) {
        throw "Duplicate wingetId '$($component.wingetId)' in component manifests."
    }
    $byWingetId[$component.wingetId] = $file
}

foreach ($patchItem in $patch.components) {
    if (-not $patchItem.wingetId) {
        throw 'Every wgfetch patch component must include wingetId.'
    }
    if (-not $byWingetId.ContainsKey($patchItem.wingetId)) {
        throw "No component manifest matches wingetId '$($patchItem.wingetId)'."
    }

    $file = $byWingetId[$patchItem.wingetId]
    $component = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 30
    $component = Merge-WgfetchPatchData -Component $component -PatchItem $patchItem -Source $file.FullName

    $tempPath = "$($file.FullName).tmp"
    $component | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $tempPath -Encoding utf8
    Move-Item -LiteralPath $tempPath -Destination $file.FullName -Force
    Write-Output "Updated $($file.Name) from $($patchItem.wingetId)"
}
