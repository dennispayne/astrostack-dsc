#requires -Version 7.0
<#
.SYNOPSIS
    Runs fast, machine-independent repository validation suitable for local use and GitHub Actions.
#>
param(
    [string]$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
)

$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()

$powerShellFiles = Get-ChildItem -Path @(
    (Join-Path $RepoRoot 'resources')
    (Join-Path $RepoRoot 'scripts')
    (Join-Path $RepoRoot 'tests')
) -Recurse -File -Include '*.ps1', '*.psm1'

foreach ($file in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    foreach ($parseError in $errors) {
        $failures.Add("$($file.FullName): $parseError")
    }
}

$jsonFiles = Get-ChildItem -Path @(
    (Join-Path $RepoRoot 'manifest')
    (Join-Path $RepoRoot 'resources')
    (Join-Path $RepoRoot 'config')
) -Recurse -File -Filter '*.json'

foreach ($file in $jsonFiles) {
    try {
        Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 30 | Out-Null
    } catch {
        $failures.Add("$($file.FullName): $_")
    }
}

foreach ($file in Get-ChildItem -Path (Join-Path $RepoRoot 'assets') -File -Filter '*.svg') {
    try {
        [xml](Get-Content -LiteralPath $file.FullName -Raw) | Out-Null
    } catch {
        $failures.Add("$($file.FullName): $_")
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

$pester = Get-Module -ListAvailable Pester |
    Where-Object Version -ge 5.7.1 |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $pester) {
    throw 'Pester 5.7.1 or newer is required. Install it with: Install-Module Pester -Scope CurrentUser'
}

Import-Module $pester.Path -Force
$result = Invoke-Pester -Path (Join-Path $RepoRoot 'tests') -PassThru
if ($result.FailedCount -gt 0) {
    exit 1
}

Write-Output "Repository validation passed: $($powerShellFiles.Count) PowerShell files, $($jsonFiles.Count) JSON files, $($result.PassedCount) tests."
