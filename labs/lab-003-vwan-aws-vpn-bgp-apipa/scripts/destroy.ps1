# labs/lab-003-vwan-aws-vpn-bgp-apipa/scripts/destroy.ps1
# Destroys AWS and Azure resources for lab-003

[CmdletBinding()]
param(
  [ValidateSet("lab","prod")]
  [string]$SubscriptionKey = "lab",
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..")
$OutputsPath = Join-Path $RepoRoot ".data\lab-003\outputs.json"
$AwsDir = Join-Path $LabRoot "aws"

# Load shared helpers
. (Join-Path $RepoRoot "scripts\labs-common.ps1")
. (Join-Path $RepoRoot "scripts\aws\aws-common.ps1")

Write-Host ""
Write-Host "Lab 003: Destroy Resources" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan
Write-Host ""

# Load outputs if available
$awsProfile = "aws-labs"
$awsRegion = "us-east-2"
$resourceGroup = "rg-lab-003-vwan-aws"

if (Test-Path $OutputsPath) {
  $outputs = Get-Content $OutputsPath -Raw | ConvertFrom-Json
  $awsProfile = $outputs.aws.profile
  $awsRegion = $outputs.aws.region
  $resourceGroup = $outputs.azure.resourceGroup
}

# Auth checks
Show-ConfigPreflight -RepoRoot $RepoRoot
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
az account get-access-token 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Azure CLI not authenticated." }
az account set --subscription $SubscriptionId | Out-Null

Ensure-AwsAuth -Profile $awsProfile

if (-not $Force) {
  Write-Host "This will destroy:" -ForegroundColor Yellow
  Write-Host "  AWS: VPC, VGW, VPN Connection, CGW" -ForegroundColor Gray
  Write-Host "  Azure: Resource group '$resourceGroup' and all contents" -ForegroundColor Gray
  Write-Host ""
  $confirm = Read-Host "Type DELETE to confirm"
  if ($confirm -ne "DELETE") { throw "Cancelled." }
}

# ============================================
# Phase 1: Destroy AWS (Terraform)
# ============================================
Write-Host ""
Write-Host "==> Phase 1: AWS teardown (Terraform)" -ForegroundColor Cyan

$tfvarsPath = Join-Path $AwsDir "terraform.tfvars"
$tfstatePath = Join-Path $AwsDir "terraform.tfstate"

if (Test-Path $tfstatePath) {
  $env:AWS_PROFILE = $awsProfile

  Push-Location $AwsDir
  try {
    Write-Host "Running terraform destroy..." -ForegroundColor Gray
    terraform destroy -auto-approve -input=false
    if ($LASTEXITCODE -ne 0) {
      Write-Host "  Terraform destroy had issues, continuing..." -ForegroundColor Yellow
    }
  }
  finally {
    Pop-Location
  }

  # Clean up terraform files
  if (Test-Path $tfvarsPath) { Remove-Item $tfvarsPath -Force }
  if (Test-Path $tfstatePath) { Remove-Item $tfstatePath -Force }
  $tfstateBackup = Join-Path $AwsDir "terraform.tfstate.backup"
  if (Test-Path $tfstateBackup) { Remove-Item $tfstateBackup -Force }
  $tfLock = Join-Path $AwsDir ".terraform.lock.hcl"
  if (Test-Path $tfLock) { Remove-Item $tfLock -Force }
  $tfDir = Join-Path $AwsDir ".terraform"
  if (Test-Path $tfDir) { Remove-Item $tfDir -Recurse -Force }
} else {
  Write-Host "  No Terraform state found, skipping AWS teardown" -ForegroundColor Gray
}

# ============================================
# Phase 2: Destroy Azure
# ============================================
Write-Host ""
Write-Host "==> Phase 2: Azure teardown" -ForegroundColor Cyan

$rgExists = az group exists --name $resourceGroup
if ($rgExists -eq "true") {
  Write-Host "Deleting resource group '$resourceGroup'..." -ForegroundColor Gray
  az group delete --name $resourceGroup --yes --no-wait
  Write-Host "  Deletion started (runs in background)" -ForegroundColor Green
} else {
  Write-Host "  Resource group '$resourceGroup' not found" -ForegroundColor Gray
}

# Clean up outputs file
if (Test-Path $OutputsPath) {
  Remove-Item $OutputsPath -Force
  Write-Host "  Removed outputs file" -ForegroundColor Gray
}

Write-Host ""
Write-Host "===========================" -ForegroundColor Cyan
Write-Host "Destroy initiated" -ForegroundColor Green
Write-Host "===========================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Azure RG deletion runs in background (~10-20 min)" -ForegroundColor Gray
Write-Host "Monitor: az group show -n $resourceGroup --query provisioningState -o tsv" -ForegroundColor Gray
