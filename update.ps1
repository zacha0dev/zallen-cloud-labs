<#
.SYNOPSIS
    Updates the azure-labs package to the latest version.

.DESCRIPTION
    Pulls the latest labs, scripts, and docs from GitHub.
    Automatically stashes local changes, updates, then restores them.
    Runs setup.ps1 -Status after update to verify your environment.

.EXAMPLE
    .\update.ps1

.NOTES
    Compatible with Windows PowerShell 5.1 and PowerShell 7+
#>

[CmdletBinding()]
param()

$UpdateScript = Join-Path (Join-Path $PSScriptRoot "tools") "update-azure-labs.ps1"

if (-not (Test-Path $UpdateScript)) {
    Write-Host "Error: Update script not found at: $UpdateScript" -ForegroundColor Red
    exit 1
}

& $UpdateScript @args
exit $LASTEXITCODE
