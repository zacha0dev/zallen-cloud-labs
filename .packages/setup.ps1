<#
setup.ps1
One-command setup for Azure Labs tooling.

Ensures:
- winget
- Azure CLI (az)
- Bicep (az bicep)
- Azure PowerShell (Az module)

Optional:
- -DoLogin          => runs az login if needed
- -UpgradeAz        => upgrades Az module (can be breaking; off by default)
- -SubscriptionKey  => sets az account to a key in .data/subs.json (lab|prod)
#>

[CmdletBinding()]
param(
  [switch]$DoLogin,
  [switch]$UpgradeAz,
  [ValidateSet("lab","prod")]
  [string]$SubscriptionKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------- UI helpers ----------
$script:TotalSteps = 7
$script:StepIndex  = 0

function Show-Progress([string]$Activity, [string]$Status) {
  $pct = [int](($script:StepIndex / $script:TotalSteps) * 100)
  Write-Progress -Activity $Activity -Status $Status -PercentComplete $pct
}

function Next-Step([string]$Title) {
  $script:StepIndex++
  Write-Host "`n==> [$script:StepIndex/$script:TotalSteps] $Title" -ForegroundColor Cyan
  Show-Progress "Azure Labs Setup" $Title
}

function OK($m){ Write-Host "   [OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "   [WARN] $m" -ForegroundColor Yellow }
function HasCmd([string]$name){ return [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# repo root is one level up from .packages
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$SubsPath = Join-Path $RepoRoot ".data\subs.json"

# ---------- checks / installs ----------
function Ensure-WinGet {
  Next-Step "Checking winget"
  if (-not (HasCmd "winget")) {
    throw "winget not found. Install 'App Installer' (Windows Package Manager) and re-run."
  }
  OK "winget available"
}

function Ensure-AzureCLI {
  Next-Step "Checking Azure CLI (az)"
  if (HasCmd "az") {
    $v = ((az version --output json | ConvertFrom-Json)."azure-cli")
    OK "Azure CLI present (v$v)"
    return
  }
  Warn "Azure CLI not found. Installing via winget..."
  winget install --exact --id Microsoft.AzureCLI --accept-package-agreements --accept-source-agreements
  if (-not (HasCmd "az")) { throw "Azure CLI installed but 'az' not found. Restart terminal and re-run." }
  $v = ((az version --output json | ConvertFrom-Json)."azure-cli")
  OK "Azure CLI installed (v$v)"
}

function Ensure-Bicep {
  Next-Step "Checking Bicep (az bicep)"
  az bicep version 1>$null 2>$null
  if ($LASTEXITCODE -eq 0) {
    $bv = (az bicep version 2>$null)
    OK "Bicep available ($bv)"
    return
  }
  Warn "Bicep not available. Installing via 'az bicep install'..."
  az bicep install
  az bicep version 1>$null 2>$null
  if ($LASTEXITCODE -ne 0) { throw "Bicep install failed. Restart terminal and re-run." }
  $bv = (az bicep version 2>$null)
  OK "Bicep installed ($bv)"
}

function Ensure-AzPowerShell {
  Next-Step "Checking Azure PowerShell (Az module)"
  $azMod = Get-Module -ListAvailable -Name Az -ErrorAction SilentlyContinue |
           Sort-Object Version -Descending |
           Select-Object -First 1

  if (-not $azMod) {
    Warn "Az module not found. Installing (CurrentUser)..."
    Install-Module -Name Az -Scope CurrentUser -Force -AllowClobber
    $azMod = Get-Module -ListAvailable -Name Az -ErrorAction SilentlyContinue |
             Sort-Object Version -Descending |
             Select-Object -First 1
    if (-not $azMod) { throw "Az module install failed." }
    OK "Az module installed (v$($azMod.Version))"
  } else {
    OK "Az module present (v$($azMod.Version))"
  }

  if ($UpgradeAz) {
    Next-Step "Upgrading Az module (optional)"
    Warn "Upgrading Az can include breaking changes. You enabled -UpgradeAz so proceeding..."
    Update-Module -Name Az -Force
    $azMod2 = Get-Module -ListAvailable -Name Az | Sort-Object Version -Descending | Select-Object -First 1
    OK "Az upgraded (v$($azMod2.Version))"
  }
}

function Clear-AzureCredentialCache {
  # Remove local MSAL / token caches so az login starts fresh.
  $home_ = $env:USERPROFILE
  if (-not $home_) { $home_ = $env:HOME }
  $azDir = Join-Path $home_ ".azure"

  foreach ($pattern in @("msal_token_cache*", "accessTokens.json", "TokenCache.dat")) {
    $files = Get-ChildItem -Path $azDir -Filter $pattern -ErrorAction SilentlyContinue
    foreach ($f in $files) {
      Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
      Warn "Cleared stale cache: $($f.Name)"
    }
  }
}

function Test-AzureTokenFresh {
  # az account show can succeed with cached metadata even when the token is expired.
  # Actually try to obtain a fresh token to be sure.
  az account get-access-token --query "expiresOn" -o tsv 1>$null 2>$null
  return ($LASTEXITCODE -eq 0)
}

function Ensure-AzureAuth {
  Next-Step "Checking Azure auth"

  $needsLogin = $false

  az account show 1>$null 2>$null
  if ($LASTEXITCODE -ne 0) {
    Warn "Azure CLI not authenticated."
    $needsLogin = $true
  } else {
    # Session metadata exists — verify the token is actually fresh
    if (-not (Test-AzureTokenFresh)) {
      Warn "Azure token expired or stale. Clearing credential caches..."
      Clear-AzureCredentialCache
      $needsLogin = $true
    } else {
      $sub = (az account show --query "name" -o tsv)
      OK "Azure CLI authenticated (subscription: $sub)"
    }
  }

  if ($needsLogin) {
    if ($DoLogin) {
      Warn "Running: az login (opens browser)"
      az login
      az account show 1>$null 2>$null
      if ($LASTEXITCODE -ne 0) { throw "az login failed or was cancelled." }
      $sub = (az account show --query "name" -o tsv)
      OK "Azure CLI authenticated (subscription: $sub)"
    } else {
      Warn "Run: az login  (or rerun setup with -DoLogin)"
    }
  }

  Import-Module Az -ErrorAction Stop
  OK "Az module imports successfully"
}

function Select-Subscription {
  Next-Step "Selecting subscription (optional)"

  if (-not (Test-Path $SubsPath)) {
    Warn "No .data/subs.json found. Skipping subscription selection."
    Warn "Tip: copy .data/subs.example.json -> .data/subs.json and add your real IDs."
    return
  }

  $cfg = Get-Content $SubsPath -Raw | ConvertFrom-Json

  $key = $SubscriptionKey
  if (-not $key) { $key = $cfg.default }

  if (-not $key) {
    Warn "No SubscriptionKey provided and no default set in .data/subs.json. Skipping."
    return
  }

  $sub = $cfg.subscriptions.$key
  if (-not $sub) {
    Warn "Key '$key' not found in .data/subs.json. Skipping."
    return
  }

  Write-Host "Setting az subscription -> $key ($($sub.name)) [$($sub.id)]" -ForegroundColor Cyan
  az account set --subscription $sub.id | Out-Null

  # persist default if caller explicitly picked one
  if ($SubscriptionKey) {
    $cfg.default = $SubscriptionKey
    $cfg | ConvertTo-Json -Depth 10 | Set-Content $SubsPath -Encoding UTF8
  }

  $active = az account show --query "{name:name, id:id, user:user.name}" -o json | ConvertFrom-Json
  OK "Active subscription: $($active.name) [$($active.id)]"
}

function SelfTest {
  Next-Step "Self-test: Bicep -> ARM compile + cmdlets"

  $tmp = Join-Path $env:TEMP ("azure-doctor-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $tmp | Out-Null

  $bicepPath = Join-Path $tmp "main.bicep"

@'
param location string = 'eastus2'

var suffix = uniqueString(resourceGroup().id)
var saName = toLower('doctest${take(suffix, 18)}')

resource sa 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: saName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
}
'@ | Set-Content -Path $bicepPath -Encoding UTF8

  az bicep build --file $bicepPath --outfile (Join-Path $tmp "main.json") | Out-Null
  if (-not (Test-Path (Join-Path $tmp "main.json"))) {
    throw "Bicep build failed (ARM JSON not produced)."
  }

  OK "Bicep compile works"

  foreach ($c in @(
    "New-AzResourceGroupDeployment",
    "Test-AzResourceGroupDeployment",
    "New-AzSubscriptionDeployment"
  )) {
    if (-not (Get-Command $c -ErrorAction SilentlyContinue)) {
      throw "Missing Az cmdlet: $c"
    }
  }

  OK "Az ARM deployment cmdlets available"

  Remove-Item -Recurse -Force $tmp
}

# ---------- run ----------
Write-Host "`nAzure Labs Setup" -ForegroundColor Cyan
Write-Host "----------------" -ForegroundColor Cyan

try {
  Show-Progress "Azure Labs Setup" "Starting..."
  Ensure-WinGet
  Ensure-AzureCLI
  Ensure-Bicep
  Ensure-AzPowerShell
  Ensure-AzureAuth
  Select-Subscription
  SelfTest

  $script:StepIndex = $script:TotalSteps
  Show-Progress "Azure Labs Setup" "Complete"
  Write-Progress -Activity "Azure Labs Setup" -Completed

  Write-Host "`nDone." -ForegroundColor Green
  Write-Host "Common commands:" -ForegroundColor Cyan
  Write-Host "  az login" -ForegroundColor Gray
  Write-Host "  .\.packages\set-sub.ps1 lab" -ForegroundColor Gray
  Write-Host "  .\.packages\get-sub.ps1" -ForegroundColor Gray
}
catch {
  Write-Progress -Activity "Azure Labs Setup" -Completed
  throw
}
