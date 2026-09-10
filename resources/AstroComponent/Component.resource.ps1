#requires -Version 7.0
<#
.SYNOPSIS
    DSC v3 custom resource implementation for AstroStack/Component.
    Handles three kinds of tracked items:
      - Application : software with a registry Uninstall entry (DisplayVersion or regex-from-DisplayName)
      - Dataset      : ASTAP program / star databases, tracked by file presence/date (no real version string)
      - NinaPlugin   : the full set of NINA plugins, verified via NINA's own log output (pinned list, all-or-nothing)

    Invoked by dsc.exe as: pwsh -NoProfile -File Component.resource.ps1 <get|set|test|schema>
    Instance JSON (Id, Kind, ManifestPath, [AutoDeployPlugins]) is read from stdin, JSON result written to stdout.
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('get', 'set', 'test', 'schema')]
    [string]$Operation
)

$ErrorActionPreference = 'Stop'

function Read-StdinJson {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "No input JSON received on stdin." }
    return $raw | ConvertFrom-Json -Depth 20
}

function Write-JsonLine {
    param($Object)
    $Object | ConvertTo-Json -Depth 20 -Compress | Write-Output
}

function Get-Manifest {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Manifest not found at '$Path'." }
    return Get-Content -Path $Path -Raw | ConvertFrom-Json -Depth 20
}

function Get-InstalledPrograms {
    # Cache within a single process invocation only (DSC invokes a fresh process per call anyway)
    $paths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        Select-Object DisplayName, DisplayVersion, InstallDate
}

function Resolve-ApplicationState {
    param($AppDef, $InstalledPrograms)

    # Some vendors (e.g. ASTAP) leave duplicate/orphaned Uninstall registry keys behind after a
    # reinstall - always prefer the most recently installed match, not just the first one found.
    $match = $InstalledPrograms | Where-Object { $_.DisplayName -eq $AppDef.displayName } |
        Sort-Object { [int]($_.InstallDate) } -Descending | Select-Object -First 1
    if (-not $match) {
        # fall back to a startswith match in case of trailing version drift in DisplayName
        $match = $InstalledPrograms | Where-Object { $_.DisplayName -like "$($AppDef.displayName)*" } |
            Sort-Object { [int]($_.InstallDate) } -Descending | Select-Object -First 1
    }

    $installedVersion = $null
    if ($match) {
        switch ($AppDef.versionSource) {
            'DisplayVersion' { $installedVersion = $match.DisplayVersion }
            'DisplayNameRegex' {
                if ($match.DisplayName -match $AppDef.versionRegex) { $installedVersion = $Matches[1] }
            }
            'InstallDate' { $installedVersion = $match.InstallDate }
            default { $installedVersion = $match.DisplayVersion }
        }
    }

    [PSCustomObject]@{
        Id               = $AppDef.id
        Kind             = 'Application'
        Installed        = [bool]$match
        InstalledVersion = $installedVersion
        ExpectedVersion  = $AppDef.expectedVersion
        InDesiredState   = ($match -and $installedVersion -eq $AppDef.expectedVersion)
    }
}

function Resolve-DatasetState {
    param($DatasetDef, $InstalledPrograms)

    $exists = Test-Path $DatasetDef.checkPath
    $detail = $null
    $installedVersion = $null
    $registryOk = $true  # only meaningful when the dataset def declares a displayName to check

    if ($exists -and $DatasetDef.versionStrategy -eq 'PathExists') {
        $itemCount = (Get-ChildItem $DatasetDef.checkPath -ErrorAction SilentlyContinue | Measure-Object).Count
        $detail = "ItemCount=$itemCount"
    }

    # Preferred: the Inno Setup Uninstall registry key (DisplayName + InstallDate/regex-captured
    # version) is far more reliable than file timestamps, which reflect the vendor's original build
    # date rather than when it was actually installed on this machine (confirmed via live testing).
    if ($DatasetDef.displayName) {
        $match = $InstalledPrograms | Where-Object { $_.DisplayName -eq $DatasetDef.displayName } |
            Sort-Object { [int]($_.InstallDate) } -Descending | Select-Object -First 1
        switch ($DatasetDef.versionSource) {
            'InstallDate' { $installedVersion = $match.InstallDate }
            'DisplayNameRegex' {
                if ($match -and $match.DisplayName -match $DatasetDef.versionRegex) { $installedVersion = $Matches[1] }
            }
        }
        $registryOk = ($match -and $installedVersion -eq $DatasetDef.expectedVersion)
        $detail = "$detail InstalledVersion=$installedVersion"
    }

    [PSCustomObject]@{
        Id               = $DatasetDef.id
        Kind             = 'Dataset'
        PathExists       = $exists
        InstalledVersion = $installedVersion
        ExpectedVersion  = $DatasetDef.expectedVersion
        Detail           = $detail
        InDesiredState   = [bool]($exists -and $registryOk)
    }
}

function Get-LatestNinaLogPluginVersions {
    param([string]$LogPath)

    if (-not (Test-Path $LogPath)) { return @{ Versions = @{}; LogFile = $null } }

    $latestLog = Get-ChildItem -Path $LogPath -Filter '*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $latestLog) { return @{ Versions = @{}; LogFile = $null } }

    $versions = @{}
    Select-String -Path $latestLog.FullName -Pattern 'Successfully loaded plugin (.+) version (\S+) by' |
        ForEach-Object {
            $name = $_.Matches[0].Groups[1].Value
            $ver = $_.Matches[0].Groups[2].Value
            $versions[$name] = $ver
        }

    return @{ Versions = $versions; LogFile = $latestLog.FullName; LogTimeUtc = $latestLog.LastWriteTimeUtc }
}

function Resolve-NinaPluginState {
    param($PluginDef)

    $logResult = Get-LatestNinaLogPluginVersions -LogPath $PluginDef.logPath
    $loaded = $logResult.Versions

    $items = foreach ($p in $PluginDef.expected) {
        $actual = $loaded[$p.name]
        [PSCustomObject]@{
            Name           = $p.name
            ExpectedVersion = $p.version
            ActualVersion   = $actual
            InDesiredState  = ($actual -eq $p.version)
        }
    }

    $orphaned = foreach ($o in $PluginDef.knownOrphanedFolders) {
        [PSCustomObject]@{ Name = $o.name; Note = $o.note; LoadedThisSession = [bool]$loaded[$o.name] }
    }

    [PSCustomObject]@{
        Id             = 'nina-plugins'
        Kind           = 'NinaPlugin'
        LogFileUsed    = $logResult.LogFile
        LogTimeUtc     = $logResult.LogTimeUtc
        Items          = $items
        Orphaned       = $orphaned
        InDesiredState = -not ($items | Where-Object { -not $_.InDesiredState })
    }
}

function Get-ComponentState {
    param($Instance)

    $manifest = Get-Manifest -Path $Instance.ManifestPath

    switch ($Instance.Kind) {
        'Application' {
            $appDef = $manifest.applications | Where-Object { $_.id -eq $Instance.Id }
            if (-not $appDef) { throw "No application with id '$($Instance.Id)' in manifest." }
            $installed = Get-InstalledPrograms
            return Resolve-ApplicationState -AppDef $appDef -InstalledPrograms $installed
        }
        'Dataset' {
            $dsDef = $manifest.datasets | Where-Object { $_.id -eq $Instance.Id }
            if (-not $dsDef) { throw "No dataset with id '$($Instance.Id)' in manifest." }
            $installed = Get-InstalledPrograms
            return Resolve-DatasetState -DatasetDef $dsDef -InstalledPrograms $installed
        }
        'NinaPlugin' {
            return Resolve-NinaPluginState -PluginDef $manifest.ninaPlugins
        }
        default { throw "Unknown Kind '$($Instance.Kind)'." }
    }
}

switch ($Operation) {
    'schema' {
        # Minimal inline JSON schema describing the instance shape DSC should validate against.
        $schema = [ordered]@{
            '$schema'  = 'http://json-schema.org/draft-07/schema#'
            type       = 'object'
            required   = @('Id', 'Kind', 'ManifestPath')
            properties = [ordered]@{
                Id               = @{ type = 'string' }
                Kind             = @{ type = 'string'; enum = @('Application', 'Dataset', 'NinaPlugin') }
                ManifestPath     = @{ type = 'string' }
                AutoDeployPlugins = @{ type = 'boolean' }
                InDesiredState   = @{ type = 'boolean' }
            }
        }
        Write-JsonLine $schema
    }

    'get' {
        $instance = Read-StdinJson
        $state = Get-ComponentState -Instance $instance
        $result = [ordered]@{
            Id             = $instance.Id
            Kind           = $instance.Kind
            ManifestPath   = $instance.ManifestPath
            InDesiredState = $state.InDesiredState
            Detail         = $state
        }
        Write-JsonLine $result
    }

    'test' {
        $instance = Read-StdinJson
        $state = Get-ComponentState -Instance $instance
        # DSC 'test' convention: echo back the instance properties plus _inDesiredState
        $result = [ordered]@{
            Id             = $instance.Id
            Kind           = $instance.Kind
            ManifestPath   = $instance.ManifestPath
            InDesiredState = $state.InDesiredState
            Detail         = $state
        }
        Write-JsonLine $result
    }

    'set' {
        $instance = Read-StdinJson
        & "$PSScriptRoot\Set-Component.ps1" -Instance $instance | Out-Null
        # Re-evaluate and emit the resulting state so `dsc` can report what Set achieved.
        $state = Get-ComponentState -Instance $instance
        $result = [ordered]@{
            Id             = $instance.Id
            Kind           = $instance.Kind
            ManifestPath   = $instance.ManifestPath
            InDesiredState = $state.InDesiredState
            Detail         = $state
        }
        Write-JsonLine $result
    }
}
