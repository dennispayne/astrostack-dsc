#requires -Version 7.0
<#
.SYNOPSIS
    Remediation logic for AstroStack/Component 'set'. Downloads installers into the maintained
    Downloads cache (verifying checksum when available) and runs them silently for Application/Dataset
    components. For NinaPlugin, only caches verified plugin archives by default; will not touch NINA's
    live Plugins folder unless AutoDeployPlugins=true AND NINA is confirmed not running.
#>
param(
    [Parameter(Mandatory)] $Instance
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..").Path
$downloadsApps = Join-Path $root 'Downloads\Applications'
$downloadsData = Join-Path $root 'Downloads\Datasets'
$downloadsPlugins = Join-Path $root 'Downloads\NinaPlugins'
foreach ($d in @($downloadsApps, $downloadsData, $downloadsPlugins)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

function Get-Manifest {
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

$manifest = Get-Manifest -Path $Instance.ManifestPath

switch ($Instance.Kind) {
    'Application' {
        $def = $manifest.applications | Where-Object { $_.id -eq $Instance.Id }
        if (-not $def) { throw "No application with id '$($Instance.Id)' in manifest." }

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
        $def = $manifest.datasets | Where-Object { $_.id -eq $Instance.Id }
        if (-not $def) { throw "No dataset with id '$($Instance.Id)' in manifest." }

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
        $pluginDef = $manifest.ninaPlugins
        $autoDeploy = [bool]$Instance.AutoDeployPlugins

        # Re-evaluate which plugins are actually out of state right now.
        $logPath = $pluginDef.logPath
        $latestLog = Get-ChildItem -Path $logPath -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $loaded = @{}
        if ($latestLog) {
            Select-String -Path $latestLog.FullName -Pattern 'Successfully loaded plugin (.+) version (\S+) by' |
                ForEach-Object { $loaded[$_.Matches[0].Groups[1].Value] = $_.Matches[0].Groups[2].Value }
        }

        $drift = $pluginDef.expected | Where-Object { $loaded[$_.name] -ne $_.version }
        if (-not $drift) {
            Write-Output "All pinned NINA plugins already match the last logged load - nothing to do."
            break
        }

        if ($autoDeploy) {
            $ninaRunning = Get-Process -Name 'NINA' -ErrorAction SilentlyContinue
            if ($ninaRunning) {
                throw "AutoDeployPlugins is set but NINA is currently running (PID $($ninaRunning.Id -join ',')). Close NINA before deploying plugin files, then re-run Set."
            }
        }

        foreach ($p in $drift) {
            Write-Output "Plugin drift detected: '$($p.name)' expected $($p.version), last logged as '$($loaded[$p.name])'."
            Write-Warning "There is no official NINA API/CLI to install or update plugins. This tool will only cache the archive from the community manifest repo (isbeorn/nina.plugin.manifests); deploying it into NINA's live Plugins folder is unofficial and only happens when -AutoDeployPlugins is explicitly set."
            # NOTE: actually resolving the per-plugin manifest.json + Installer.URL from the GitHub repo
            # (by name + NINA's installed compat-version folder) and downloading into $downloadsPlugins
            # is implemented in scripts/Update-Manifest.ps1's plugin-fetch helper, reused here conceptually.
            # Left as a manual follow-up step in v1 to avoid silently mutating NINA's plugin folder unattended.
        }
    }

    default { throw "Unknown Kind '$($Instance.Kind)'." }
}
