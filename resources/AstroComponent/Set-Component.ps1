#requires -Version 7.0
<#
.SYNOPSIS
    Remediation logic for AstroStack/Component 'set'. Downloads installers into a caller-supplied
    Downloads cache (verifying checksum when available) and runs them silently for Application/Dataset
    components. NinaPlugin remediation is intentionally unsupported until a verified deployment
    mechanism is implemented.
.PARAMETER DownloadsRoot
    Root folder for the installer/dataset/plugin cache. Not part of this repo - supply a path outside
    source control (e.g. via the DSC instance's DownloadsRoot property). Applications and Datasets
    subfolders are created under it on demand.
#>
param(
    [Parameter(Mandatory)] $Instance,
    [Parameter(Mandatory)] [string]$DownloadsRoot
)

$ErrorActionPreference = 'Stop'
function Get-ComponentDef {
    param([string]$Path)
    return Get-Content -Path $Path -Raw | ConvertFrom-Json -Depth 20
}

function Assert-Checksum {
    param([string]$FilePath, [string]$ExpectedSha256)
    if (-not $ExpectedSha256) { return $true }
    $actual = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash
    if ($actual -ne $ExpectedSha256.ToUpperInvariant().Replace('SHA256:', '')) {
        throw "Checksum mismatch for '$FilePath'. Expected $ExpectedSha256, got $actual. Refusing to install a file that doesn't match the pinned manifest."
    }
    return $true
}

function Get-CachedOrDownload {
    param([string]$Url, [string]$DestFolder, [string]$FileName, [string]$Sha256)

    if (-not $Url) {
        throw "No downloadUrl recorded in manifest for this component - it requires manual download (see manifest 'notes' field), Set cannot remediate automatically."
    }
    $dest = Join-Path $DestFolder $FileName
    $needsDownload = $true
    if (Test-Path $dest) {
        if ($Sha256) {
            $actual = (Get-FileHash -Path $dest -Algorithm SHA256).Hash
            $needsDownload = ($actual -ne $Sha256.ToUpperInvariant())
        } else {
            $needsDownload = $false  # no checksum to verify against; trust existing cache
        }
    }
    if ($needsDownload) {
        curl.exe -L -s -o $dest $Url
        if (-not (Test-Path $dest) -or (Get-Item $dest).Length -eq 0) {
            Remove-Item $dest -Force -ErrorAction SilentlyContinue
            throw "Download failed or produced an empty file for '$Url'."
        }
    }
    if ($Sha256) { Assert-Checksum -FilePath $dest -ExpectedSha256 $Sha256 }
    return $dest
}

$def = Get-ComponentDef -Path $Instance.ManifestPath

switch ($def.kind) {
    'Application' {
        $downloadsApps = Join-Path $DownloadsRoot 'Applications'
        if (-not (Test-Path $downloadsApps)) {
            New-Item -ItemType Directory -Path $downloadsApps -Force | Out-Null
        }
        $installerPath = Get-CachedOrDownload -Url $def.downloadUrl -DestFolder $downloadsApps `
            -FileName $def.downloadFileName -Sha256 $def.sha256

        if (-not $def.silentInstallArgs) {
            Write-Warning "Installer for '$($def.id)' cached at '$installerPath' but no silent-install args are known. Run it manually."
            break
        }
        if ($def.archiveContainsInstaller) {
            Write-Warning "'$($def.id)' is an archive bundle, not a direct installer - cached at '$installerPath'. Extract and run the inner installer manually."
            break
        }

        $p = Start-Process -FilePath $installerPath -ArgumentList $def.silentInstallArgs -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "Installer for '$($def.id)' exited with code $($p.ExitCode)." }
    }

    'Dataset' {
        $downloadsData = Join-Path $DownloadsRoot 'Datasets'
        if (-not (Test-Path $downloadsData)) {
            New-Item -ItemType Directory -Path $downloadsData -Force | Out-Null
        }
        $installerPath = Get-CachedOrDownload -Url $def.downloadUrl -DestFolder $downloadsData `
            -FileName $def.downloadFileName -Sha256 $def.sha256

        if (-not $def.silentInstallArgs) {
            Write-Warning "Installer for '$($def.id)' cached at '$installerPath' but no silent-install args are known. Run it manually."
            break
        }
        $p = Start-Process -FilePath $installerPath -ArgumentList $def.silentInstallArgs -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "Installer for '$($def.id)' exited with code $($p.ExitCode)." }
    }

    'NinaPlugin' {
        throw "Automatic NINA plugin remediation is not implemented. Use DSC Test to audit the pinned plugin set."
    }

    default { throw "Unknown kind '$($def.kind)' in '$($Instance.ManifestPath)'." }
}
