#requires -Version 7.0
<#
.SYNOPSIS
    DSC v3 custom resource implementation for AstroStack/Component.
    Each instance points ManifestPath at ONE component file under manifest/components/*.json
    (single object, not an array) - e.g. manifest/components/nina.json. Handles three kinds:
      - Application : software with a registry Uninstall entry (DisplayVersion or regex-from-DisplayName)
      - Dataset      : ASTAP star databases, tracked by file presence and registry metadata
      - NinaPlugin   : the full set of NINA plugins, verified via NINA's own log output (pinned list, all-or-nothing)

    Invoked by dsc.exe as: pwsh -NoProfile -File Component.resource.ps1 <get|set|test>
    Instance JSON (ManifestPath, [ArtifactMapPath]) is read from stdin, JSON result written to stdout.
    Id/Kind are read from the component file itself, not the instance - one file, one component, no lookup needed.
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('get', 'set', 'test')]
    [string]$Operation
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\..\scripts\lib\ComponentContract.psm1" -Force

function Read-StdinJson {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "No input JSON received on stdin." }
    return $raw | ConvertFrom-Json -Depth 20
}

function Write-JsonLine {
    param($Object)
    $Object | ConvertTo-Json -Depth 20 -Compress | Write-Output
}

function Get-ComponentDef {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Component manifest not found at '$Path'." }
    $def = Get-Content -Path $Path -Raw | ConvertFrom-Json -Depth 20
    if (-not $def.kind) { throw "Component manifest '$Path' is missing a 'kind' field (Application/Dataset/NinaPlugin)." }
    Assert-ComponentDefinition -Component $def -Source $Path
    return $def
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
        AvailableVersion = $AppDef.availableVersion
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
        AvailableVersion = $DatasetDef.availableVersion
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
        Id             = $PluginDef.id
        Kind           = 'NinaPlugin'
        LogFileUsed    = $logResult.LogFile
        LogTimeUtc     = $logResult.LogTimeUtc
        AvailableVersion = $PluginDef.availableVersion
        Items          = $items
        Orphaned       = $orphaned
        InDesiredState = -not ($items | Where-Object { -not $_.InDesiredState })
    }
}

function Get-ComponentState {
    param($Instance)

    $def = Get-ComponentDef -Path $Instance.ManifestPath

    switch ($def.kind) {
        'Application' {
            $installed = Get-InstalledPrograms
            return Resolve-ApplicationState -AppDef $def -InstalledPrograms $installed
        }
        'Dataset' {
            $installed = Get-InstalledPrograms
            return Resolve-DatasetState -DatasetDef $def -InstalledPrograms $installed
        }
        'NinaPlugin' {
            return Resolve-NinaPluginState -PluginDef $def
        }
        default { throw "Unknown kind '$($def.kind)' in '$($Instance.ManifestPath)'." }
    }
}

function New-EchoResult {
    param($Instance, $State)
    $result = [ordered]@{
        Id             = $State.Id
        Kind           = $State.Kind
        ManifestPath   = $Instance.ManifestPath
        InDesiredState = $State.InDesiredState
        Detail         = $State
    }
    if ($null -ne $Instance.ArtifactMapPath) { $result.ArtifactMapPath = $Instance.ArtifactMapPath }
    return $result
}

switch ($Operation) {
    'get' {
        $instance = Read-StdinJson
        $state = Get-ComponentState -Instance $instance
        Write-JsonLine (New-EchoResult -Instance $instance -State $state)
    }

    'test' {
        $instance = Read-StdinJson
        $state = Get-ComponentState -Instance $instance
        Write-JsonLine (New-EchoResult -Instance $instance -State $state)
    }

    'set' {
        $instance = Read-StdinJson
        if (-not $instance.ArtifactMapPath) {
            throw "ArtifactMapPath is required for 'set' and must point to wgfetch's PackageIdentifier-to-path mapping file."
        }
        & "$PSScriptRoot\Set-Component.ps1" -Instance $instance -ArtifactMapPath $instance.ArtifactMapPath | Out-Null
        # Re-evaluate and emit the resulting state so `dsc` can report what Set achieved.
        $state = Get-ComponentState -Instance $instance
        Write-JsonLine (New-EchoResult -Instance $instance -State $state)
    }
}
