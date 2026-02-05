<#
.SYNOPSIS
    Updates the azure-labs repository to the latest version.

.DESCRIPTION
    Wrapper script that calls tools/update-azure-labs.ps1.
    Safely fetches and pulls the latest changes from the remote repository.

.EXAMPLE
    .\update.ps1

.NOTES
    This script never pushes, resets, or automatically stashes changes.
    If you have local modifications, commit or stash them first.
#>

[CmdletBinding()]
param()

$UpdateScript = Join-Path $PSScriptRoot "tools" "update-azure-labs.ps1"

if (-not (Test-Path $UpdateScript)) {
    Write-Host "Error: Update script not found at: $UpdateScript" -ForegroundColor Red
    exit 1
}

& $UpdateScript @args
exit $LASTEXITCODE
