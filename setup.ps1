<#
setup.ps1
Single entry point for Azure Labs environment setup.

Usage:
  .\setup.ps1                             # Azure setup (default - no AWS required)
  .\setup.ps1 -Status                     # Quick status check (no prompts)
  .\setup.ps1 -Azure                      # Azure setup only
  .\setup.ps1 -Aws                        # AWS setup only (lab-003 only)
  .\setup.ps1 -SkipUpdate                 # Skip update check
  .\setup.ps1 -ConfigureSubs              # Guided subscription configuration wizard
  .\setup.ps1 -SubscriptionId <id>        # Write subscription ID directly to config
  .\setup.ps1 -SubscriptionName <name>    # Friendly key name for the subscription (default: lab)

After setup is green, deploy labs directly:
  .\labs\lab-000_resource-group\deploy.ps1

AWS is OPTIONAL and only required for lab-003 (hybrid Azure-AWS connectivity).
For all other labs, run this script without -Aws.
#>

[CmdletBinding()]
param(
  [switch]$Azure,
  [switch]$Aws,
  [switch]$Status,
  [switch]$SkipUpdate,
  [switch]$ConfigureSubs,
  [string]$SubscriptionId,
  [string]$SubscriptionName = "lab",
  [string]$AwsProfile = "aws-labs"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Suppress Python 32-bit-on-64-bit-Windows UserWarning from Azure CLI.
# Without this, stderr warnings become terminating errors under PS 5.1.
$env:PYTHONWARNINGS = "ignore::UserWarning"

$RepoRoot = $PSScriptRoot
$DataDir = Join-Path $RepoRoot ".data"
$SubsPath = Join-Path $DataDir "subs.json"

# --- Helpers ---
function HasCmd([string]$name) {
  [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Write-Status([string]$Label, [bool]$Ok, [string]$Detail = "") {
  $mark = if ($Ok) { "[ok]" } else { "[--]" }
  $color = if ($Ok) { "Green" } else { "Yellow" }
  $line = "  $mark $Label"
  if ($Detail) { $line += ": $Detail" }
  Write-Host $line -ForegroundColor $color
}

function Ensure-DataDir {
  if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir | Out-Null
  }
}

function Get-SubsConfig {
  if (-not (Test-Path $SubsPath)) { return $null }
  try {
    return Get-Content $SubsPath -Raw | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Test-SubsConfigValid {
  <# Returns true if subs.json exists, has at least one real subscription, and default is set. #>
  $cfg = Get-SubsConfig
  if (-not $cfg) { return $false }
  if (-not $cfg.subscriptions) { return $false }
  $keys = @()
  if ($cfg.subscriptions.PSObject.Properties) {
    $keys = @($cfg.subscriptions.PSObject.Properties | ForEach-Object { $_.Name })
  }
  if ($keys.Count -eq 0) { return $false }
  $placeholder = "00000000-0000-0000-0000-000000000000"
  foreach ($k in $keys) {
    $sub = $cfg.subscriptions.$k
    if ($sub -and $sub.id -and $sub.id -ne $placeholder) {
      return $true
    }
  }
  return $false
}

# --- Azure Checks ---
function Test-AzureCli {
  if (-not (HasCmd "az")) { return @{ ok = $false; version = $null } }
  try {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $raw = az version --output json 2>$null
    $ErrorActionPreference = $oldPreference
    if ($raw) {
      $ver = ($raw | ConvertFrom-Json)."azure-cli"
      return @{ ok = $true; version = $ver }
    }
    return @{ ok = $true; version = "unknown" }
  } catch {
    return @{ ok = $true; version = "unknown" }
  }
}

function Test-AzureAuth {
  if (-not (HasCmd "az")) { return @{ ok = $false; user = $null; sub = $null } }
  try {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    az account get-access-token --query "expiresOn" -o tsv 2>$null | Out-Null
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $oldPreference
    if ($exitCode -ne 0) { return @{ ok = $false; user = $null; sub = $null } }
    $acct = az account show -o json 2>$null | ConvertFrom-Json
    return @{ ok = $true; user = $acct.user.name; sub = $acct.name }
  } catch {
    return @{ ok = $false; user = $null; sub = $null }
  }
}

function Test-Bicep {
  if (-not (HasCmd "az")) { return @{ ok = $false; version = $null } }
  try {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $ver = az bicep version 2>$null
    $ErrorActionPreference = $oldPreference
    if ($LASTEXITCODE -ne 0 -or -not $ver) { return @{ ok = $false; version = $null } }
    return @{ ok = $true; version = $ver }
  } catch {
    return @{ ok = $false; version = $null }
  }
}

function Test-Terraform {
  if (-not (HasCmd "terraform")) { return @{ ok = $false; version = $null } }
  try {
    $ver = (terraform version -json 2>$null | ConvertFrom-Json).terraform_version
    return @{ ok = $true; version = $ver }
  } catch {
    return @{ ok = $true; version = "installed" }
  }
}

# --- AWS Checks ---
function Test-AwsCli {
  if (-not (HasCmd "aws")) { return @{ ok = $false; version = $null } }
  try {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $ver = (aws --version 2>&1) -replace "aws-cli/([^\s]+).*", '$1'
    $ErrorActionPreference = $oldPreference
    return @{ ok = $true; version = $ver }
  } catch {
    return @{ ok = $true; version = "installed" }
  }
}

function Test-AwsAuth([string]$Profile) {
  if (-not (HasCmd "aws")) { return @{ ok = $false; account = $null } }
  try {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $result = aws sts get-caller-identity --profile $Profile --output json 2>$null
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $oldPreference
    if ($exitCode -ne 0) { return @{ ok = $false; account = $null } }
    $id = $result | ConvertFrom-Json
    return @{ ok = $true; account = $id.Account; arn = $id.Arn }
  } catch {
    return @{ ok = $false; account = $null }
  }
}

# --- Subscription Configuration Wizard ---
function Invoke-SubsWizard {
  <#
  .SYNOPSIS
    Guided interactive wizard to detect Azure subscriptions and write .data/subs.json.
  .PARAMETER PreselectedId
    Skip the interactive menu and use this subscription ID directly.
  .PARAMETER FriendlyName
    The key name to use in subs.json (default: "lab").
  #>
  param(
    [string]$PreselectedId = "",
    [string]$FriendlyName = "lab"
  )

  Write-Host ""
  Write-Host "Subscription Configuration Wizard" -ForegroundColor Cyan
  Write-Host "---------------------------------" -ForegroundColor Cyan
  Write-Host ""

  # Check az CLI
  if (-not (HasCmd "az")) {
    Write-Host "  Azure CLI not found. Install from: https://aka.ms/installazurecli" -ForegroundColor Red
    return $false
  }

  # Check auth
  $azAuth = Test-AzureAuth
  if (-not $azAuth.ok) {
    Write-Host "  Not authenticated. Running az login..." -ForegroundColor Yellow
    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    az login -o none 2>$null
    $ErrorActionPreference = $oldPref
    $azAuth = Test-AzureAuth
    if (-not $azAuth.ok) {
      Write-Host "  Authentication failed. Run: az login" -ForegroundColor Red
      return $false
    }
  }

  Write-Host "  Authenticated as: $($azAuth.user)" -ForegroundColor Green
  Write-Host ""

  $selectedId = ""
  $selectedDisplayName = ""

  if ($PreselectedId -ne "") {
    # Use the provided ID directly
    $selectedId = $PreselectedId
    $selectedDisplayName = $FriendlyName
    Write-Host "  Using provided subscription ID: $selectedId" -ForegroundColor Gray
  } else {
    # List available subscriptions
    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $subsRaw = az account list -o json 2>$null
    $ErrorActionPreference = $oldPref

    if (-not $subsRaw) {
      Write-Host "  Could not list subscriptions. Check your login." -ForegroundColor Red
      return $false
    }

    $allSubs = $subsRaw | ConvertFrom-Json
    $enabledSubs = @($allSubs | Where-Object { $_.state -eq "Enabled" })

    if ($enabledSubs.Count -eq 0) {
      Write-Host "  No enabled subscriptions found." -ForegroundColor Red
      Write-Host "  Verify your Azure account has at least one active subscription." -ForegroundColor Yellow
      return $false
    }

    if ($enabledSubs.Count -eq 1) {
      $selectedId = $enabledSubs[0].id
      $selectedDisplayName = $enabledSubs[0].name
      Write-Host "  One subscription found - selected automatically:" -ForegroundColor Green
      Write-Host "    Name: $selectedDisplayName" -ForegroundColor White
      Write-Host "    ID:   $selectedId" -ForegroundColor DarkGray
    } else {
      Write-Host "  Available subscriptions:" -ForegroundColor White
      Write-Host ""
      for ($i = 0; $i -lt $enabledSubs.Count; $i++) {
        $isDefault = ""
        if ($enabledSubs[$i].isDefault) { $isDefault = " (current az context)" }
        Write-Host "  [$($i + 1)] $($enabledSubs[$i].name)$isDefault" -ForegroundColor White
        Write-Host "      ID: $($enabledSubs[$i].id)" -ForegroundColor DarkGray
        Write-Host ""
      }

      $pick = Read-Host "  Select subscription number [1-$($enabledSubs.Count)]"
      $pickInt = 0
      $parseOk = [int]::TryParse($pick.Trim(), [ref]$pickInt)
      if (-not $parseOk -or $pickInt -lt 1 -or $pickInt -gt $enabledSubs.Count) {
        Write-Host "  Invalid selection. Run again: .\setup.ps1 -ConfigureSubs" -ForegroundColor Red
        return $false
      }

      $selectedId = $enabledSubs[$pickInt - 1].id
      $selectedDisplayName = $enabledSubs[$pickInt - 1].name
      Write-Host ""
      Write-Host "  Selected: $selectedDisplayName" -ForegroundColor Green
    }
  }

  # Validate ID format
  $uuidPattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
  $placeholder = "00000000-0000-0000-0000-000000000000"
  if ($selectedId -notmatch $uuidPattern -or $selectedId -eq $placeholder) {
    Write-Host "  Invalid or placeholder subscription ID: $selectedId" -ForegroundColor Red
    Write-Host "  Run: az account list -o table  to find your real subscription ID." -ForegroundColor Yellow
    return $false
  }

  # Fetch additional details (tenantId, verified name)
  $tenantId = ""
  $verifiedName = $selectedDisplayName
  $oldPref = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  $subDetail = az account show --subscription $selectedId -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldPref
  if ($subDetail) {
    if ($subDetail.tenantId) { $tenantId = $subDetail.tenantId }
    if ($subDetail.name) { $verifiedName = $subDetail.name }
  }

  # Load existing config to preserve other subscription keys
  Ensure-DataDir
  $existing = Get-SubsConfig
  $subsHash = @{}
  if ($existing -and $existing.subscriptions -and $existing.subscriptions.PSObject.Properties) {
    foreach ($prop in $existing.subscriptions.PSObject.Properties) {
      $subsHash[$prop.Name] = @{
        id       = $prop.Value.id
        name     = $prop.Value.name
        tenantId = if ($prop.Value.tenantId) { $prop.Value.tenantId } else { "" }
      }
    }
  }

  # Add or update the selected subscription
  $subsHash[$FriendlyName] = @{
    id       = $selectedId
    name     = $verifiedName
    tenantId = $tenantId
  }

  # Build final config
  $config = @{
    subscriptions = $subsHash
    default       = $FriendlyName
  }

  $json = $config | ConvertTo-Json -Depth 5
  Set-Content -Path $SubsPath -Value $json -Encoding UTF8

  # Print summary
  Write-Host ""
  Write-Host "  Written to: .data/subs.json" -ForegroundColor Green
  Write-Host ""
  Write-Host "  Configured subscription summary:" -ForegroundColor Yellow
  Write-Host "    Key:          $FriendlyName" -ForegroundColor White
  Write-Host "    Name:         $verifiedName" -ForegroundColor White
  Write-Host "    ID:           $selectedId" -ForegroundColor White
  if ($tenantId) {
    Write-Host "    Tenant ID:    $tenantId" -ForegroundColor White
  }
  Write-Host "    Default:      yes" -ForegroundColor White
  Write-Host ""

  # Validate by re-reading
  if (Test-SubsConfigValid) {
    Write-Host "  Validation: PASS" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Ready to deploy labs:" -ForegroundColor Cyan
    Write-Host "    cd labs\lab-000_resource-group" -ForegroundColor Gray
    Write-Host "    .\deploy.ps1" -ForegroundColor Gray
  } else {
    Write-Host "  Validation: WARNING - could not verify written config." -ForegroundColor Yellow
    Write-Host "  Check: .data/subs.json" -ForegroundColor Yellow
  }

  Write-Host ""
  return $true
}

# --- Status Display ---
function Show-Status {
  Write-Host ""
  Write-Host "Azure Labs - Environment Status" -ForegroundColor Cyan
  Write-Host "================================" -ForegroundColor Cyan
  Write-Host ""

  # Azure Section
  Write-Host "Azure (required)" -ForegroundColor White
  $azCli = Test-AzureCli
  Write-Status "CLI (az)" $azCli.ok $(if ($azCli.version) { "v$($azCli.version)" } else { "not installed - https://aka.ms/installazurecli" })

  $bicep = Test-Bicep
  Write-Status "Bicep" $bicep.ok $(if ($bicep.version) { $bicep.version } else { "not installed - run: az bicep install" })

  $azAuth = Test-AzureAuth
  Write-Status "Auth" $azAuth.ok $(if ($azAuth.ok) { $azAuth.user } else { "not authenticated - run: az login" })

  if ($azAuth.ok) {
    Write-Status "Active subscription" $true $azAuth.sub
  }

  $subsOk = Test-SubsConfigValid
  $cfg = Get-SubsConfig
  if ($cfg -and $cfg.subscriptions) {
    $count = @($cfg.subscriptions.PSObject.Properties).Count
    $detail = "$count subscription(s), default: $($cfg.default)"
    Write-Status "Config (.data/subs.json)" $subsOk $detail
    if (-not $subsOk) {
      Write-Host "    Run: .\setup.ps1 -ConfigureSubs" -ForegroundColor DarkGray
    }
  } else {
    Write-Status "Config (.data/subs.json)" $false "not configured - run: .\setup.ps1 -ConfigureSubs"
  }

  Write-Host ""

  # AWS Section (informational - only needed for lab-003)
  Write-Host "AWS (optional - lab-003 only)" -ForegroundColor DarkGray
  $awsCli = Test-AwsCli
  Write-Status "CLI (aws)" $awsCli.ok $(if ($awsCli.version) { "v$($awsCli.version)" } else { "not installed (not required for Azure-only labs)" })

  if ($awsCli.ok) {
    $tf = Test-Terraform
    Write-Status "Terraform" $tf.ok $(if ($tf.version) { "v$($tf.version)" } else { "not installed" })

    $awsAuth = Test-AwsAuth -Profile $AwsProfile
    Write-Status "Auth (profile: $AwsProfile)" $awsAuth.ok $(if ($awsAuth.ok) { "account $($awsAuth.account)" } else { "not authenticated - run: aws sso login --profile $AwsProfile" })
  }

  Write-Host ""

  # Summary
  $allAzureOk = $azCli.ok -and $azAuth.ok -and $subsOk
  $allAwsOk = $awsCli.ok -and (Test-AwsAuth -Profile $AwsProfile).ok

  if ($allAzureOk -and $allAwsOk) {
    Write-Host "Ready for all labs (including lab-003)." -ForegroundColor Green
  } elseif ($allAzureOk) {
    Write-Host "Ready for Azure-only labs (lab-000 through lab-002, lab-004 through lab-006)." -ForegroundColor Green
    Write-Host "For lab-003 (hybrid AWS): .\setup.ps1 -Aws" -ForegroundColor DarkGray
  } else {
    Write-Host "Setup needed - see issues above." -ForegroundColor Yellow
    if (-not ($azCli.ok -and $azAuth.ok)) {
      Write-Host "Run: .\setup.ps1 -Azure" -ForegroundColor Cyan
    }
    if (-not $subsOk) {
      Write-Host "Run: .\setup.ps1 -ConfigureSubs" -ForegroundColor Cyan
    }
  }

  Write-Host ""
}

# --- Azure Setup ---
function Setup-Azure {
  Write-Host ""
  Write-Host "Azure Setup" -ForegroundColor Cyan
  Write-Host "-----------" -ForegroundColor Cyan

  Ensure-DataDir

  # Check CLI
  $azCli = Test-AzureCli
  if (-not $azCli.ok) {
    Write-Host "  Azure CLI not found. Installing..." -ForegroundColor Yellow
    if (HasCmd "winget") {
      winget install --exact --id Microsoft.AzureCLI --accept-package-agreements --accept-source-agreements
    } else {
      Write-Host "  Please install Azure CLI: https://aka.ms/installazurecli" -ForegroundColor Red
      return $false
    }
  } else {
    Write-Host "  CLI: v$($azCli.version)" -ForegroundColor Green
  }

  # Check Bicep
  $bicep = Test-Bicep
  if (-not $bicep.ok) {
    Write-Host "  Installing Bicep..." -ForegroundColor Yellow
    az bicep install
  } else {
    Write-Host "  Bicep: $($bicep.version)" -ForegroundColor Green
  }

  # Check Auth
  $azAuth = Test-AzureAuth
  if (-not $azAuth.ok) {
    Write-Host ""
    Write-Host "  Azure CLI not authenticated." -ForegroundColor Yellow
    $login = Read-Host "  Login now? (y/n)"
    if ($login.Trim().ToLower() -eq "y") {
      Write-Host "  Running: az login" -ForegroundColor Cyan
      az login
      $azAuth = Test-AzureAuth
    }
  }

  if ($azAuth.ok) {
    Write-Host "  Auth: $($azAuth.user)" -ForegroundColor Green
    Write-Host "  Active subscription: $($azAuth.sub)" -ForegroundColor Green
  } else {
    Write-Host "  Auth: not authenticated" -ForegroundColor Yellow
    Write-Host "  Run: az login" -ForegroundColor Yellow
    return $false
  }

  # Check subscription config - run wizard if missing or unconfigured
  if (-not (Test-SubsConfigValid)) {
    Write-Host ""
    Write-Host "  No valid subscriptions configured in .data/subs.json" -ForegroundColor Yellow
    Write-Host "  Starting subscription configuration wizard..." -ForegroundColor Cyan
    Write-Host ""
    $wizardOk = Invoke-SubsWizard -FriendlyName $SubscriptionName
    if (-not $wizardOk) {
      Write-Host ""
      Write-Host "  Subscription not configured. Re-run: .\setup.ps1 -ConfigureSubs" -ForegroundColor Yellow
      return $false
    }
  } else {
    $cfg = Get-SubsConfig
    $count = @($cfg.subscriptions.PSObject.Properties).Count
    Write-Host "  Config: $count subscription(s), default: $($cfg.default)" -ForegroundColor Green
  }

  Write-Host ""
  return $true
}

# --- AWS Setup ---
function Setup-Aws {
  Write-Host ""
  Write-Host "AWS Setup (lab-003 only)" -ForegroundColor Cyan
  Write-Host "------------------------" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "  AWS is only required for lab-003 (Azure vWAN to AWS VPN)." -ForegroundColor DarkGray
  Write-Host "  Skip this section for all other labs." -ForegroundColor DarkGray
  Write-Host ""

  # Check CLI
  $awsCli = Test-AwsCli
  if (-not $awsCli.ok) {
    Write-Host "  AWS CLI not found." -ForegroundColor Yellow
    if (HasCmd "winget") {
      $install = Read-Host "  Install AWS CLI now? (y/n)"
      if ($install.Trim().ToLower() -eq "y") {
        Write-Host "  Installing AWS CLI..." -ForegroundColor Yellow
        winget install --exact --id Amazon.AWSCLI --accept-package-agreements --accept-source-agreements
        $awsCli = Test-AwsCli
      }
    } else {
      Write-Host "  Install from: https://aws.amazon.com/cli/" -ForegroundColor Yellow
    }
  }

  if ($awsCli.ok) {
    Write-Host "  CLI: v$($awsCli.version)" -ForegroundColor Green
  }

  # Check Terraform
  $tf = Test-Terraform
  if (-not $tf.ok) {
    Write-Host "  Terraform not found." -ForegroundColor Yellow
    if (HasCmd "winget") {
      $install = Read-Host "  Install Terraform now? (y/n)"
      if ($install.Trim().ToLower() -eq "y") {
        Write-Host "  Installing Terraform..." -ForegroundColor Yellow
        winget install --exact --id Hashicorp.Terraform --accept-package-agreements --accept-source-agreements
        $tf = Test-Terraform
      }
    } else {
      Write-Host "  Install from: https://developer.hashicorp.com/terraform/downloads" -ForegroundColor Yellow
    }
  }

  if ($tf.ok) {
    Write-Host "  Terraform: v$($tf.version)" -ForegroundColor Green
  }

  # Check Auth
  $awsAuth = Test-AwsAuth -Profile $AwsProfile
  if (-not $awsAuth.ok) {
    Write-Host ""
    Write-Host "  AWS profile '$AwsProfile' not authenticated." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  To authenticate, run one of these:" -ForegroundColor Cyan
    Write-Host "    aws sso login --profile $AwsProfile     # If SSO is configured" -ForegroundColor Gray
    Write-Host "    aws configure sso --profile $AwsProfile # To set up SSO" -ForegroundColor Gray
    Write-Host "    aws configure --profile $AwsProfile     # For IAM access keys" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  After authenticating, run: .\setup.ps1 -Status" -ForegroundColor Yellow
  } else {
    Write-Host "  Auth: account $($awsAuth.account)" -ForegroundColor Green
  }

  Write-Host ""
  return $awsAuth.ok
}

# =============================================================================
# MAIN
# =============================================================================

Clear-Host
Write-Host ""
Write-Host "Azure Labs Setup" -ForegroundColor Cyan
Write-Host "================" -ForegroundColor Cyan

Ensure-DataDir

# -ConfigureSubs: run the guided wizard and exit
if ($ConfigureSubs -or $SubscriptionId -ne "") {
  Write-Host ""
  if ($SubscriptionId -ne "") {
    Write-Host "Writing subscription ID directly to config..." -ForegroundColor Gray
    $ok = Invoke-SubsWizard -PreselectedId $SubscriptionId -FriendlyName $SubscriptionName
  } else {
    $ok = Invoke-SubsWizard -FriendlyName $SubscriptionName
  }
  Show-Status
  exit $(if ($ok) { 0 } else { 1 })
}

# Check for updates (skip in -Status mode or if -SkipUpdate)
if (-not $Status -and -not $SkipUpdate) {
  $updateScript = Join-Path (Join-Path $RepoRoot "scripts") "update-labs.ps1"
  if (Test-Path $updateScript) {
    & $updateScript -RepoRoot $RepoRoot
  }
}

if ($Status) {
  Show-Status
  exit 0
}

if ($Azure -and -not $Aws) {
  # Azure only
  $ok = Setup-Azure
  Show-Status
  exit $(if ($ok) { 0 } else { 1 })
}

if ($Aws -and -not $Azure) {
  # AWS only (lab-003 prerequisite)
  $ok = Setup-Aws
  Show-Status
  exit $(if ($ok) { 0 } else { 1 })
}

if ($Aws -and $Azure) {
  # Both explicitly requested
  $azOk = Setup-Azure
  $awsOk = Setup-Aws
  Show-Status
  exit $(if ($azOk) { 0 } else { 1 })
}

# Default: Azure-only interactive mode
# AWS is NOT checked by default - it is only needed for lab-003.
$azOk = Setup-Azure

Show-Status

Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  First lab (free): cd labs\lab-000_resource-group && .\deploy.ps1" -ForegroundColor Gray
Write-Host "  Check status:     .\setup.ps1 -Status" -ForegroundColor Gray
Write-Host "  AWS (lab-003):    .\setup.ps1 -Aws" -ForegroundColor DarkGray
Write-Host ""

exit $(if ($azOk) { 0 } else { 1 })
