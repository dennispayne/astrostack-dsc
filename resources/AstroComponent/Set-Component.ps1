#requires -Version 7.0
<#
.SYNOPSIS
    Remediation logic for AstroStack/Component 'set'. Resolves an installer from wgfetch's
    PackageIdentifier-to-path artifact map, verifies its pinned checksum, and runs known silent
    installers. NinaPlugin and nested-installer archive remediation remain unsupported.
.PARAMETER ArtifactMapPath
    Path to the schemaVersion 1 wgfetch artifact map. Artifact paths may be absolute or relative to
    the map file. AstroStack DSC never guesses wgfetch's installers/ layout.
#>
param(
    [Parameter(Mandatory)] $Instance,
    [Parameter(Mandatory)] [string]$ArtifactMapPath
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\..\scripts\lib\ComponentContract.psm1" -Force

function Get-ComponentDef {
    param([string]$Path)
    return Get-Content -Path $Path -Raw | ConvertFrom-Json -Depth 20
}

function Assert-Checksum {
    param([string]$FilePath, [string]$ExpectedSha256)
    if ($ExpectedSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "Component has no valid pinned sha256. Refusing to use '$FilePath'."
    }
    $actual = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash
    if ($actual -ne $ExpectedSha256.ToUpperInvariant().Replace('SHA256:', '')) {
        throw "Checksum mismatch for '$FilePath'. Expected $ExpectedSha256, got $actual. Refusing to install a file that doesn't match the pinned manifest."
    }
    return $true
}

$def = Get-ComponentDef -Path $Instance.ManifestPath
Assert-ComponentDefinition -Component $def -Source $Instance.ManifestPath

switch ($def.kind) {
    'Application' {
        $installerPath = Resolve-WgfetchArtifact -ArtifactMapPath $ArtifactMapPath -WingetId $def.wingetId
        Assert-Checksum -FilePath $installerPath -ExpectedSha256 $def.sha256

        if ($def.archiveContainsInstaller) {
            throw "'$($def.id)' is a nested-installer archive. wgfetch preserves it unchanged; extraction and installer selection are not implemented by AstroStack DSC."
        }
        if (-not $def.silentInstallArgs) {
            throw "No silent-install arguments are defined for '$($def.id)'."
        }

        $p = Start-Process -FilePath $installerPath -ArgumentList $def.silentInstallArgs -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "Installer for '$($def.id)' exited with code $($p.ExitCode)." }
    }

    'Dataset' {
        $installerPath = Resolve-WgfetchArtifact -ArtifactMapPath $ArtifactMapPath -WingetId $def.wingetId
        Assert-Checksum -FilePath $installerPath -ExpectedSha256 $def.sha256

        if (-not $def.silentInstallArgs) {
            throw "No silent-install arguments are defined for '$($def.id)'."
        }
        if ($def.archiveContainsInstaller) {
            throw "'$($def.id)' is a nested-installer archive. Extraction is not implemented by AstroStack DSC."
        }

        $p = Start-Process -FilePath $installerPath -ArgumentList $def.silentInstallArgs -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "Installer for '$($def.id)' exited with code $($p.ExitCode)." }
    }

    'NinaPlugin' {
        throw "Automatic NINA plugin remediation is not implemented. Use DSC Test to audit the pinned plugin set."
    }

    default { throw "Unknown kind '$($def.kind)' in '$($Instance.ManifestPath)'." }
}
