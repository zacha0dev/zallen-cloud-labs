<#+
labs-common.ps1 — Shared helper functions for all labs.

Provides:
- Get-LabConfig: Loads and validates repo config with defensive checks
- Get-SubscriptionId: Gets subscription ID with friendly error messages
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RepoRoot {
  <# Returns the repository root path. #>
  $path = $PSScriptRoot
  while ($path -and -not (Test-Path (Join-Path $path ".git"))) {
    $path = Split-Path -Parent $path
  }
  if (-not $path) {
    throw "Could not find repository root (.git folder not found)."
  }
  return $path
}

function Get-LabConfig {
  <#
  .SYNOPSIS
    Loads repository configuration with defensive checks.
  .DESCRIPTION
    Reads .data/subs.json and validates structure.
    Prints resolved path and top-level keys for debugging.
    Throws friendly errors if config is missing or malformed.
  .OUTPUTS
    PSCustomObject with: subscriptions, default, and optionally lab metadata
  #>
  param(
    [string]$RepoRoot = (Get-RepoRoot),
    [switch]$Quiet
  )

  $subsPath = Join-Path $RepoRoot ".data\subs.json"

  if (-not $Quiet) {
    Write-Host "  Config path: $subsPath" -ForegroundColor DarkGray
  }

  if (-not (Test-Path $subsPath)) {
    Write-Host ""
    Write-Host "Lab config file not found: $subsPath" -ForegroundColor Red
    Write-Host ""
    Write-Host "Run the setup first:" -ForegroundColor Yellow
    Write-Host "  .\scripts\setup.ps1 -DoLogin" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "See: docs/labs-config.md" -ForegroundColor DarkGray
    throw "Missing config file: $subsPath"
  }

  $cfg = Get-Content $subsPath -Raw | ConvertFrom-Json

  # Validate structure
  if (-not $cfg) {
    throw "Config file is empty or invalid JSON: $subsPath"
  }

  $topKeys = @()
  if ($cfg.PSObject.Properties) {
    $topKeys = @($cfg.PSObject.Properties | ForEach-Object { $_.Name })
  }

  if (-not $Quiet) {
    Write-Host "  Config keys: $($topKeys -join ', ')" -ForegroundColor DarkGray
  }

  if (-not ($topKeys -contains "subscriptions")) {
    Write-Host ""
    Write-Host "Lab config missing 'subscriptions' block." -ForegroundColor Red
    Write-Host "File: $subsPath" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Expected structure:" -ForegroundColor White
    Write-Host '  {' -ForegroundColor Gray
    Write-Host '    "subscriptions": {' -ForegroundColor Gray
    Write-Host '      "lab": { "id": "...", "name": "..." }' -ForegroundColor Gray
    Write-Host '    },' -ForegroundColor Gray
    Write-Host '    "default": "lab"' -ForegroundColor Gray
    Write-Host '  }' -ForegroundColor Gray
    Write-Host ""
    Write-Host "See: docs/labs-config.md" -ForegroundColor DarkGray
    throw "Lab config missing 'subscriptions' block. See docs/labs-config.md"
  }

  return $cfg
}

function Get-SubscriptionId {
  <#
  .SYNOPSIS
    Gets a subscription ID from config with defensive error handling.
  .PARAMETER Key
    The subscription key to look up (e.g., "lab", "prod", or custom key).
  .PARAMETER Config
    Optional pre-loaded config object. If not provided, loads from default path.
  .PARAMETER RepoRoot
    Repository root path. Defaults to auto-detected.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$Key,
    [PSCustomObject]$Config,
    [string]$RepoRoot
  )

  if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot }
  if (-not $Config) { $Config = Get-LabConfig -RepoRoot $RepoRoot -Quiet }

  $subsPath = Join-Path $RepoRoot ".data\subs.json"

  # Get available subscription keys
  $availableKeys = @()
  if ($Config.subscriptions -and $Config.subscriptions.PSObject.Properties) {
    $availableKeys = @($Config.subscriptions.PSObject.Properties | ForEach-Object { $_.Name })
  }

  if ($availableKeys.Count -eq 0) {
    Write-Host ""
    Write-Host "No subscriptions configured in: $subsPath" -ForegroundColor Red
    Write-Host ""
    Write-Host "Run setup to add a subscription:" -ForegroundColor Yellow
    Write-Host "  .\scripts\setup.ps1 -DoLogin" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "See: docs/labs-config.md" -ForegroundColor DarkGray
    throw "No subscriptions configured. Run scripts\setup.ps1 first."
  }

  # Check if requested key exists
  if (-not ($availableKeys -contains $Key)) {
    Write-Host ""
    Write-Host "Subscription key '$Key' not found." -ForegroundColor Red
    Write-Host "File: $subsPath" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Available keys: $($availableKeys -join ', ')" -ForegroundColor White

    # Suggest using default or first available
    $suggestion = if ($Config.default -and ($availableKeys -contains $Config.default)) {
      $Config.default
    } else {
      $availableKeys[0]
    }
    Write-Host ""
    Write-Host "Try running with: -SubscriptionKey $suggestion" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Or add '$Key' to your config. See: docs/labs-config.md" -ForegroundColor DarkGray
    throw "Subscription key '$Key' not found. Available: $($availableKeys -join ', ')"
  }

  # Get the subscription object
  $sub = $Config.subscriptions.$Key

  if (-not $sub) {
    throw "Subscription '$Key' exists but has no value. Check $subsPath"
  }

  if (-not $sub.id) {
    Write-Host ""
    Write-Host "Subscription '$Key' is missing 'id' field." -ForegroundColor Red
    Write-Host "File: $subsPath" -ForegroundColor Yellow
    throw "Subscription '$Key' missing 'id'. See docs/labs-config.md"
  }

  $placeholderId = "00000000-0000-0000-0000-000000000000"
  if ($sub.id -eq $placeholderId) {
    Write-Host ""
    Write-Host "Subscription '$Key' has placeholder ID." -ForegroundColor Red
    Write-Host "File: $subsPath" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Update with your real subscription ID:" -ForegroundColor Yellow
    Write-Host "  1. Run: az account list -o table" -ForegroundColor Cyan
    Write-Host "  2. Copy your subscription ID" -ForegroundColor Cyan
    Write-Host "  3. Edit $subsPath" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Or run setup to configure automatically:" -ForegroundColor Yellow
    Write-Host "  .\scripts\setup.ps1 -DoLogin" -ForegroundColor Cyan
    throw "Subscription '$Key' has placeholder ID. Update $subsPath with real values."
  }

  return $sub.id
}

function Show-ConfigPreflight {
  <#
  .SYNOPSIS
    Shows config preflight information for debugging.
  #>
  param(
    [string]$RepoRoot = (Get-RepoRoot)
  )

  Write-Host "==> Config preflight" -ForegroundColor Yellow
  try {
    $cfg = Get-LabConfig -RepoRoot $RepoRoot
    Write-Host "  Status: OK" -ForegroundColor Green
  }
  catch {
    Write-Host "  Status: FAILED" -ForegroundColor Red
    throw
  }
}
