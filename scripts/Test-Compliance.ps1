#requires -Version 7.0
<#
.SYNOPSIS
    Generates and tests the complete modular AstroStack DSC configuration.
.PARAMETER OutputPath
    Optional path for the raw DSC JSON result. The default is outside the repository.
#>
param(
    [string]$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [string]$OutputPath = (Join-Path $env:TEMP 'astrostack-dsc-test-result.json')
)

$ErrorActionPreference = 'Stop'

& (Join-Path $RepoRoot 'scripts\Generate-DscConfig.ps1') -RepoRoot $RepoRoot | Write-Verbose

$dscCommand = Get-Command dsc -ErrorAction Stop
$pwshCommand = Get-Command pwsh -ErrorAction Stop
$pwshDirectory = Split-Path $pwshCommand.Source -Parent
$resourceDirectories = Get-ChildItem -Path (Join-Path $RepoRoot 'resources') -Directory |
    Where-Object {
        Get-ChildItem -Path $_.FullName -Filter '*.dsc.resource.json' -File -ErrorAction SilentlyContinue
    } |
    Select-Object -ExpandProperty FullName
$dscPackage = Get-AppxPackage -Name Microsoft.DesiredStateConfiguration |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $dscPackage.InstallLocation) {
    throw 'Unable to locate the installed Microsoft.DesiredStateConfiguration package.'
}

$env:DSC_RESOURCE_PATH = @(
    $resourceDirectories
    $pwshDirectory
    $dscPackage.InstallLocation
) -join [IO.Path]::PathSeparator

$configPath = Join-Path $RepoRoot 'config\astro-stack.dsc.config.json'
$resultText = & $dscCommand.Source config test --file $configPath 2>&1
$exitCode = $LASTEXITCODE

$jsonLine = $resultText | Where-Object { $_ -is [string] -and $_.StartsWith('{"executionInformation"') } |
    Select-Object -Last 1
if (-not $jsonLine) {
    throw "DSC did not emit a configuration result. Output:`n$($resultText -join [Environment]::NewLine)"
}

$jsonLine | Set-Content -Path $OutputPath -Encoding utf8
$result = $jsonLine | ConvertFrom-Json -Depth 30

$summary = foreach ($module in $result.results) {
    foreach ($resource in $module.result) {
        [PSCustomObject]@{
            Module         = $module.name -replace '^Module: ', ''
            Resource       = $resource.name
            InDesiredState = $resource.result.inDesiredState
        }
    }
}

$summary | Format-Table -AutoSize
Write-Output "hadErrors=$($result.hadErrors); duration=$($result.executionInformation.duration); result=$OutputPath"

if ($exitCode -ne 0 -or $result.hadErrors -or ($summary.InDesiredState -contains $false)) {
    exit 1
}
