Set-StrictMode -Version Latest

$script:MachineOwnedFields = @(
    'downloadUrl'
    'downloadFileName'
    'sha256'
    'verified'
    'availableVersion'
)

function Get-MachineOwnedFields {
    return $script:MachineOwnedFields.Clone()
}

function Assert-ComponentDefinition {
    param(
        [Parameter(Mandatory)] $Component,
        [string]$Source = '<component>'
    )

    foreach ($field in @('schemaVersion', 'id', 'wingetId', 'kind', 'module', 'allowlistDomains')) {
        if ($null -eq $Component.PSObject.Properties[$field]) {
            throw "Component '$Source' is missing required field '$field'."
        }
    }

    if ($Component.schemaVersion -ne 1) {
        throw "Component '$Source' uses unsupported schemaVersion '$($Component.schemaVersion)'."
    }
    if ($Component.wingetId -notmatch '^[A-Za-z0-9]+(?:\.[A-Za-z0-9]+)+$') {
        throw "Component '$Source' has invalid wingetId '$($Component.wingetId)'."
    }
    if ($Component.kind -notin @('Application', 'Dataset', 'NinaPlugin')) {
        throw "Component '$Source' has unsupported kind '$($Component.kind)'."
    }
    $requiresAuthProperty = $Component.PSObject.Properties['requiresAuth']
    if ($requiresAuthProperty -and $requiresAuthProperty.Value -isnot [bool]) {
        throw "Component '$Source' field 'requiresAuth' must be a boolean."
    }

    foreach ($field in $script:MachineOwnedFields) {
        if ($null -eq $Component.PSObject.Properties[$field]) {
            throw "Component '$Source' is missing machine-owned field '$field'."
        }
    }

    if ($Component.downloadUrl) {
        if ($Component.sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "Component '$Source' must provide a 64-character sha256 when downloadUrl is set."
        }
        $downloadHost = ([uri]$Component.downloadUrl).DnsSafeHost
        if ($downloadHost -notin @($Component.allowlistDomains)) {
            throw "Component '$Source' download host '$downloadHost' is not in allowlistDomains."
        }
    }
    if ($Component.verified -and (-not $Component.downloadUrl -or -not $Component.sha256)) {
        throw "Component '$Source' cannot be verified without downloadUrl and sha256."
    }
}

function Merge-WgfetchPatchData {
    param(
        [Parameter(Mandatory)] $Component,
        [Parameter(Mandatory)] $PatchItem,
        [string]$Source = '<component>'
    )

    foreach ($field in $script:MachineOwnedFields) {
        $patchProperty = $PatchItem.PSObject.Properties[$field]
        if ($null -ne $patchProperty) {
            $Component.$field = $patchProperty.Value
        }
    }

    Assert-ComponentDefinition -Component $Component -Source $Source
    return $Component
}

function Resolve-WgfetchArtifact {
    param(
        [Parameter(Mandatory)] [string]$ArtifactMapPath,
        [Parameter(Mandatory)] [string]$WingetId
    )

    if (-not (Test-Path -LiteralPath $ArtifactMapPath -PathType Leaf)) {
        throw "wgfetch artifact map not found at '$ArtifactMapPath'."
    }

    $map = Get-Content -LiteralPath $ArtifactMapPath -Raw | ConvertFrom-Json -Depth 20
    if ($map.schemaVersion -ne 1) {
        throw "Unsupported wgfetch artifact map schemaVersion '$($map.schemaVersion)'."
    }
    if (-not $map.artifacts) {
        throw "wgfetch artifact map '$ArtifactMapPath' has no artifacts object."
    }

    $entry = $map.artifacts.PSObject.Properties[$WingetId]
    if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.Value)) {
        throw "wgfetch artifact map has no path for '$WingetId'."
    }

    $artifactPath = [string]$entry.Value
    if (-not [IO.Path]::IsPathRooted($artifactPath)) {
        $artifactPath = Join-Path (Split-Path $ArtifactMapPath -Parent) $artifactPath
    }
    $artifactPath = [IO.Path]::GetFullPath($artifactPath)

    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        throw "Mapped artifact for '$WingetId' does not exist at '$artifactPath'."
    }
    return $artifactPath
}

Export-ModuleMember -Function Get-MachineOwnedFields, Assert-ComponentDefinition, Merge-WgfetchPatchData, Resolve-WgfetchArtifact
