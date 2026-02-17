#!/usr/bin/env pwsh
# scripts/check-powershell.ps1
# Canonical script to lint and test PowerShell code.

$ErrorActionPreference = "Stop"

$repoRoot = $PSScriptRoot | Split-Path -Parent
$modulePath = Join-Path $repoRoot ".modules"

if (-not (Test-Path $modulePath)) {
    New-Item -ItemType Directory -Path $modulePath | Out-Null
}

# Add local module path to environment
$env:PSModulePath = "$modulePath$([System.IO.Path]::PathSeparator)$env:PSModulePath"

# Pinned versions
$modules = @{
    "Pester" = "5.5.0"
    "PSScriptAnalyzer" = "1.21.0"
}

Write-Host "==> Checking Dependencies..."

# Ensure NuGet provider is available (scoped to current user if needed)
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Write-Host "Installing NuGet provider..."
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
}

# Install modules if missing
foreach ($key in $modules.Keys) {
    $name = $key
    $version = $modules[$key]

    $installed = Get-Module -ListAvailable -Name $name | Where-Object { $_.Version -eq $version }

    if (-not $installed) {
        Write-Host "Installing $name $version to $modulePath..."
        try {
            Save-Module -Name $name -RequiredVersion $version -Path $modulePath -Force -ErrorAction Stop
        } catch {
            Write-Error "Failed to install $name. Ensure you have internet access and PowerShellGet."
            throw $_
        }
    } else {
        Write-Host "$name $version is present."
    }
}

Write-Host "`n==> Running PSScriptAnalyzer..."
Import-Module PSScriptAnalyzer -RequiredVersion $modules["PSScriptAnalyzer"] -Force

$analyzerResults = Invoke-ScriptAnalyzer -Path "$repoRoot/powershell" -Recurse -Severity Error,Warning
if ($analyzerResults) {
    $analyzerResults | Format-Table
    $errors = $analyzerResults | Where-Object { $_.Severity -eq "Error" }
    if ($errors) {
        Write-Error "PSScriptAnalyzer found errors."
        exit 1
    }
} else {
    Write-Host "PSScriptAnalyzer passed."
}

Write-Host "`n==> Running Pester Tests..."
Import-Module Pester -RequiredVersion $modules["Pester"] -Force

$pesterConfig = [PesterConfiguration]::Default
$pesterConfig.Run.Path = "$repoRoot/powershell/tests"
$pesterConfig.Run.Exit = $false # We handle exit manually
$pesterConfig.Output.Verbosity = "Detailed"
$pesterConfig.TestResult.Enabled = $true
$pesterConfig.TestResult.OutputPath = "$repoRoot/test-results.xml"

$result = Invoke-Pester -Configuration $pesterConfig

if ($result.FailedCount -gt 0) {
    Write-Error "$($result.FailedCount) tests failed."
    exit 1
} else {
    Write-Host "All tests passed."
    exit 0
}
