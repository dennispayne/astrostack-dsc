#requires -Version 7.0
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('get', 'test')]
    [string]$Operation
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\AstapConfig.psm1" -Force

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) {
    throw 'No input JSON received on stdin.'
}

$instance = $raw | ConvertFrom-Json -Depth 20
$state = Get-AstapConfigState -Instance $instance
$state | ConvertTo-Json -Depth 20 -Compress | Write-Output
