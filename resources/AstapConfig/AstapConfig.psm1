Set-StrictMode -Version Latest

$script:SupportedSettings = @(
    'star_database'
    'solve_search_field'
    'radius_search'
    'quad_tolerance'
    'maximum_stars'
    'min_star_size'
    'downsample'
    'ref_database'
    'live_stack_dir'
    'monitor_dir'
    'report-stars'
)

function Assert-AstapSettingsSupported {
    param([Parameter(Mandatory)] $Settings)

    foreach ($property in $Settings.PSObject.Properties) {
        if ($property.Name -notin $script:SupportedSettings) {
            throw "ASTAP setting '$($property.Name)' is not supported by this resource."
        }
    }
}

function Read-AstapSettings {
    param(
        [Parameter(Mandatory)] [string]$ConfigPath,
        [Parameter(Mandatory)] [string[]]$Names
    )

    $values = @{}
    if (Test-Path -LiteralPath $ConfigPath) {
        foreach ($line in Get-Content -LiteralPath $ConfigPath) {
            if ($line -notmatch '^\s*([^#;][^=]*)=(.*)$') { continue }
            $key = $Matches[1].Trim()
            if ($key -in $Names) {
                $values[$key] = $Matches[2]
            }
        }
    }

    $result = [ordered]@{}
    foreach ($name in $Names) {
        $result[$name] = if ($values.ContainsKey($name)) { [string]$values[$name] } else { $null }
    }
    return [PSCustomObject]$result
}

function Get-AstapConfigState {
    param([Parameter(Mandatory)] $Instance)

    if (-not $Instance.Settings) {
        throw 'Settings must contain at least one supported ASTAP setting.'
    }

    Assert-AstapSettingsSupported -Settings $Instance.Settings
    $names = @($Instance.Settings.PSObject.Properties.Name)
    $actualSettings = Read-AstapSettings -ConfigPath $Instance.ConfigPath -Names $names
    $settingsMatch = $true

    foreach ($property in $Instance.Settings.PSObject.Properties) {
        if ([string]$actualSettings.($property.Name) -cne [string]$property.Value) {
            $settingsMatch = $false
        }
    }

    $executablePath = $null
    $executableProperty = $Instance.PSObject.Properties['ExecutablePath']
    if ($executableProperty) {
        $executablePath = $executableProperty.Value
    }

    $executableExists = $true
    if ($executablePath) {
        $executableExists = Test-Path -LiteralPath $executablePath -PathType Leaf
    }

    [PSCustomObject]@{
        ConfigPath       = $Instance.ConfigPath
        ExecutablePath   = $executablePath
        ExecutableExists = [bool]$executableExists
        Settings         = $actualSettings
        InDesiredState   = [bool](
            (Test-Path -LiteralPath $Instance.ConfigPath -PathType Leaf) -and
            $executableExists -and
            $settingsMatch
        )
    }
}

Export-ModuleMember -Function Assert-AstapSettingsSupported, Read-AstapSettings, Get-AstapConfigState
