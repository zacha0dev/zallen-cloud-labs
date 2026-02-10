<#
.SYNOPSIS
    Updates the azure-labs package to the latest version.

.DESCRIPTION
    Convenience wrapper — runs setup.ps1 which checks for updates
    as its first step, then verifies your environment.

    setup.ps1 is the single entry point for all setup and update tasks.

.EXAMPLE
    .\update.ps1

.NOTES
    Compatible with Windows PowerShell 5.1 and PowerShell 7+
#>

[CmdletBinding()]
param()

$SetupScript = Join-Path $PSScriptRoot "setup.ps1"

if (-not (Test-Path $SetupScript)) {
    Write-Host "Error: setup.ps1 not found at: $SetupScript" -ForegroundColor Red
    exit 1
}

& $SetupScript @args
exit $LASTEXITCODE
