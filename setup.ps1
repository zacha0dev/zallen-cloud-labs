<#
setup.ps1
Single entry point for Azure Labs environment setup.

Usage:
  .\setup.ps1              # Interactive - checks for updates, prompts for logins
  .\setup.ps1 -Status      # Quick status check (no prompts, no update check)
  .\setup.ps1 -Azure       # Azure setup only
  .\setup.ps1 -Aws         # AWS setup only
  .\setup.ps1 -SkipUpdate  # Skip update check

After setup is green, deploy labs directly:
  .\labs\lab-003-vwan-aws-vpn-bgp-apipa\scripts\deploy.ps1
#>

[CmdletBinding()]
param(
  [switch]$Azure,
  [switch]$Aws,
  [switch]$Status,
  [switch]$SkipUpdate,
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

  # Copy template files if needed
  $subsExample = Join-Path $DataDir "subs.example.json"
  if (-not (Test-Path $SubsPath) -and (Test-Path $subsExample)) {
    Copy-Item $subsExample $SubsPath
    Write-Host "  Created .data/subs.json from template" -ForegroundColor Yellow
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
    # Suppress warnings (like "new version available") by capturing all output
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

# --- Status Display ---
function Show-Status {
  Write-Host ""
  Write-Host "Azure Labs - Environment Status" -ForegroundColor Cyan
  Write-Host "================================" -ForegroundColor Cyan
  Write-Host ""

  # Azure Section
  Write-Host "Azure" -ForegroundColor White
  $azCli = Test-AzureCli
  Write-Status "CLI (az)" $azCli.ok $(if ($azCli.version) { "v$($azCli.version)" } else { "not installed" })

  $bicep = Test-Bicep
  Write-Status "Bicep" $bicep.ok $(if ($bicep.version) { $bicep.version } else { "not installed" })

  $azAuth = Test-AzureAuth
  Write-Status "Auth" $azAuth.ok $(if ($azAuth.ok) { "$($azAuth.user)" } else { "not authenticated" })

  if ($azAuth.ok) {
    Write-Status "Subscription" $true $azAuth.sub
  }

  $cfg = Get-SubsConfig
  if ($cfg -and $cfg.subscriptions) {
    $count = @($cfg.subscriptions.PSObject.Properties).Count
    Write-Status "Config (.data/subs.json)" ($count -gt 0) "$count subscription(s), default: $($cfg.default)"
  } else {
    Write-Status "Config (.data/subs.json)" $false "not configured"
  }

  Write-Host ""

  # AWS Section
  Write-Host "AWS" -ForegroundColor White
  $awsCli = Test-AwsCli
  Write-Status "CLI (aws)" $awsCli.ok $(if ($awsCli.version) { "v$($awsCli.version)" } else { "not installed" })

  $tf = Test-Terraform
  Write-Status "Terraform" $tf.ok $(if ($tf.version) { "v$($tf.version)" } else { "not installed" })

  $awsAuth = Test-AwsAuth -Profile $AwsProfile
  Write-Status "Auth (profile: $AwsProfile)" $awsAuth.ok $(if ($awsAuth.ok) { "account $($awsAuth.account)" } else { "not authenticated" })

  Write-Host ""

  # Summary
  $allAzureOk = $azCli.ok -and $azAuth.ok
  $allAwsOk = $awsCli.ok -and $awsAuth.ok

  if ($allAzureOk -and $allAwsOk) {
    Write-Host "Ready for all labs." -ForegroundColor Green
  } elseif ($allAzureOk) {
    Write-Host "Ready for Azure-only labs." -ForegroundColor Green
    if (-not $allAwsOk) {
      Write-Host "AWS not ready - run: .\setup.ps1 -Aws" -ForegroundColor Yellow
    }
  } else {
    Write-Host "Setup needed - see issues above." -ForegroundColor Yellow
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
    Write-Host "  Subscription: $($azAuth.sub)" -ForegroundColor Green
  } else {
    Write-Host "  Auth: not authenticated" -ForegroundColor Yellow
    Write-Host "  Run: az login" -ForegroundColor Yellow
  }

  # Check subscription config
  $cfg = Get-SubsConfig
  if (-not $cfg -or -not $cfg.subscriptions -or @($cfg.subscriptions.PSObject.Properties).Count -eq 0) {
    Write-Host ""
    Write-Host "  No subscriptions configured in .data/subs.json" -ForegroundColor Yellow
    Write-Host "  Edit .data/subs.json with your subscription IDs" -ForegroundColor Yellow
  }

  Write-Host ""
  return $azAuth.ok
}

# --- AWS Setup ---
function Setup-Aws {
  Write-Host ""
  Write-Host "AWS Setup" -ForegroundColor Cyan
  Write-Host "---------" -ForegroundColor Cyan

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
    Write-Host "  To authenticate, run one of these in a separate terminal:" -ForegroundColor Cyan
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

# --- Main ---
Clear-Host
Write-Host ""
Write-Host "Azure Labs Setup" -ForegroundColor Cyan
Write-Host "================" -ForegroundColor Cyan

Ensure-DataDir

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
  # AWS only
  $ok = Setup-Aws
  Show-Status
  exit $(if ($ok) { 0 } else { 1 })
}

# Default: Interactive mode - check both
$azOk = Setup-Azure
$awsOk = Setup-Aws

Show-Status

Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  Deploy a lab:  .\labs\lab-003-...\scripts\deploy.ps1" -ForegroundColor Gray
Write-Host "  Check status:  .\setup.ps1 -Status" -ForegroundColor Gray
Write-Host ""
