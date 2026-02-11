<#+
labs-common.ps1 — Shared helper functions for all labs.

Provides:
- Get-LabConfig: Loads and validates repo config with defensive checks
- Get-SubscriptionId: Gets subscription ID with friendly error messages
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Suppress Python 32-bit-on-64-bit-Windows UserWarning from Azure CLI.
# Without this, stderr warnings become terminating errors under PS 5.1.
if (-not $env:PYTHONWARNINGS) { $env:PYTHONWARNINGS = "ignore::UserWarning" }

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
    If not provided, uses the default from config.
  .PARAMETER Config
    Optional pre-loaded config object. If not provided, loads from default path.
  .PARAMETER RepoRoot
    Repository root path. Defaults to auto-detected.
  #>
  param(
    [string]$Key,
    [PSCustomObject]$Config,
    [string]$RepoRoot
  )

  if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot }
  if (-not $Config) { $Config = Get-LabConfig -RepoRoot $RepoRoot -Quiet }

  $subsPath = Join-Path $RepoRoot ".data\subs.json"

  # If no key provided, use default from config
  if (-not $Key) {
    if ($Config.default) {
      $Key = $Config.default
      Write-Host "  Using default subscription: $Key" -ForegroundColor DarkGray
    } else {
      # No default configured, try to find first available key
      $availableKeys = @()
      if ($Config.subscriptions -and $Config.subscriptions.PSObject.Properties) {
        $availableKeys = @($Config.subscriptions.PSObject.Properties | ForEach-Object { $_.Name })
      }
      if ($availableKeys.Count -gt 0) {
        $Key = $availableKeys[0]
        Write-Host "  No default configured, using: $Key" -ForegroundColor DarkGray
      } else {
        Write-Host ""
        Write-Host "No subscriptions configured in: $subsPath" -ForegroundColor Red
        Write-Host ""
        Write-Host "Run setup to add a subscription:" -ForegroundColor Yellow
        Write-Host "  .\scripts\setup.ps1 -DoLogin" -ForegroundColor Cyan
        throw "No subscriptions configured. Run scripts\setup.ps1 first."
      }
    }
  }

  # Get available subscription keys (for validation below)
  $availableKeys = @()
  if ($Config.subscriptions -and $Config.subscriptions.PSObject.Properties) {
    $availableKeys = @($Config.subscriptions.PSObject.Properties | ForEach-Object { $_.Name })
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

function Test-AzureTokenFresh {
  <#
  .SYNOPSIS
    Tests if Azure CLI has a fresh, valid token (not just cached metadata).
    Uses JSON output (not tsv) to avoid PS 5.1 stdout-loss bugs.
    Rejects tokens with less than 5 minutes remaining.
  #>
  $oldErrPref = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  try {
    $raw = az account get-access-token -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $false }
    try {
      $tok = $raw | ConvertFrom-Json
      if ($tok.expiresOn) {
        $expiry = [datetime]::Parse($tok.expiresOn)
        $remaining = ($expiry - (Get-Date)).TotalMinutes
        if ($remaining -lt 5) { return $false }
      }
    } catch {
      # Could not parse expiry -- trust the exit code
    }
    return $true
  } finally {
    $ErrorActionPreference = $oldErrPref
  }
}

function Clear-AzureCredentialCache {
  <#
  .SYNOPSIS
    Clears local Azure CLI token caches so a fresh login is required.
  #>
  $home_ = $env:USERPROFILE
  if (-not $home_) { $home_ = $env:HOME }
  $azDir = Join-Path $home_ ".azure"

  foreach ($pattern in @("msal_token_cache*", "accessTokens.json", "TokenCache.dat")) {
    $files = Get-ChildItem -Path $azDir -Filter $pattern -ErrorAction SilentlyContinue
    foreach ($f in $files) {
      Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
      Write-Host "  Cleared stale cache: $($f.Name)" -ForegroundColor DarkGray
    }
  }
}

function Ensure-AzureAuth {
  <#
  .SYNOPSIS
    Validates Azure CLI authentication. Opens browser login when needed.
  .DESCRIPTION
    Checks if Azure CLI has a valid, non-expired token.
    With -DoLogin, automatically runs az login (opens browser) -- no y/n prompt.
    Without -DoLogin, throws with instructions.
  .PARAMETER DoLogin
    If set, runs az login automatically when not authenticated.
  #>
  param(
    [switch]$DoLogin
  )

  # Check if az CLI is installed
  if (-not (Get-Command "az" -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "Azure CLI (az) is not installed." -ForegroundColor Red
    Write-Host ""
    Write-Host "Next step:" -ForegroundColor White
    Write-Host "  .\scripts\setup.ps1 -DoLogin" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Or install manually: https://aka.ms/installazurecli" -ForegroundColor DarkGray
    throw "Azure CLI not installed. Run: .\scripts\setup.ps1"
  }

  # Fast path: already authenticated with fresh token (>5 min remaining)
  if (Test-AzureTokenFresh) {
    return
  }

  # Token missing, expired, or about to expire -- need login
  Write-Host ""
  Write-Host "Azure CLI needs authentication (no valid token)." -ForegroundColor Yellow

  if ($DoLogin) {
    # Clear stale caches so az login always opens a fresh browser prompt
    Clear-AzureCredentialCache
    Write-Host "Opening browser for Azure login..." -ForegroundColor Cyan
    Write-Host ""

    # Run az login -- this opens the browser automatically
    $oldErrPref = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    az login -o none 2>$null
    $loginExit = $LASTEXITCODE
    $ErrorActionPreference = $oldErrPref

    if ($loginExit -eq 0 -and (Test-AzureTokenFresh)) {
      $oldErrPref = $ErrorActionPreference
      $ErrorActionPreference = "SilentlyContinue"
      $subRaw = az account show -o json 2>$null
      $ErrorActionPreference = $oldErrPref
      $subName = ""
      if ($subRaw) { try { $subName = ($subRaw | ConvertFrom-Json).name } catch { } }
      Write-Host "Azure CLI authenticated: $subName" -ForegroundColor Green
      return
    }

    Write-Host ""
    Write-Host "Login did not complete. Try running manually:" -ForegroundColor Red
    Write-Host "  az login" -ForegroundColor Cyan
    throw "Azure login failed. Run: az login"
  }

  # No -DoLogin flag -- just print instructions and stop
  Write-Host ""
  Write-Host "Next step:" -ForegroundColor White
  Write-Host "  az login" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "Or run full setup:" -ForegroundColor Gray
  Write-Host "  .\scripts\setup.ps1 -DoLogin" -ForegroundColor Cyan
  Write-Host ""
  throw "Azure CLI not authenticated. Run: az login"
}
