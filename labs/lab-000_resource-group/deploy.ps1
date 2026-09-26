# labs/lab-000_resource-group/deploy.ps1
# Baseline lab: Creates resource group + VNet with proper tagging
#
# This is the simplest lab - use it to verify your Azure Labs setup.
# Phases: 0 (Preflight) -> 1 (Core Fabric) -> 5 (Validation) -> 6 (Summary)

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [string]$Location = "centralus",
  [string]$Owner = "",
  [switch]$Force
)

# ============================================
# GUARDRAILS
# ============================================
$AllowedLocations = @("centralus", "eastus", "eastus2", "westus2", "westus3", "northeurope", "westeurope")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path
$LogsDir = Join-Path $LabRoot "logs"
$OutputsPath = Join-Path $RepoRoot ".data\lab-000\outputs.json"

# Load shared helpers
. (Join-Path $RepoRoot "scripts\labs-common.ps1")

# Lab configuration
$ResourceGroup = "rg-lab-000-baseline"
$VnetName = "vnet-lab-000"
$VnetCidr = "10.50.0.0/16"
$Subnet1Name = "snet-workload"
$Subnet1Cidr = "10.50.1.0/24"
$Subnet2Name = "snet-management"
$Subnet2Cidr = "10.50.2.0/24"

# ============================================
# HELPER FUNCTIONS
# ============================================

function Require-Command($name, $installHint) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $name. $installHint"
  }
}

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Write-Phase {
  param([int]$Number, [string]$Title)
  Write-Host ""
  Write-Host ("=" * 60) -ForegroundColor Cyan
  Write-Host "PHASE $Number : $Title" -ForegroundColor Cyan
  Write-Host ("=" * 60) -ForegroundColor Cyan
  Write-Host ""
}

function Write-Validation {
  param([string]$Check, [bool]$Passed, [string]$Details = "")
  if ($Passed) {
    Write-Host "  [PASS] $Check" -ForegroundColor Green
  } else {
    Write-Host "  [FAIL] $Check" -ForegroundColor Red
  }
  if ($Details) {
    Write-Host "         $Details" -ForegroundColor DarkGray
  }
}

function Write-Log {
  param([string]$Message, [string]$Level = "INFO")
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $logLine = "[$timestamp] [$Level] $Message"
  Add-Content -Path $script:LogFile -Value $logLine

  switch ($Level) {
    "ERROR" { Write-Host $Message -ForegroundColor Red }
    "WARN"  { Write-Host $Message -ForegroundColor Yellow }
    "SUCCESS" { Write-Host $Message -ForegroundColor Green }
    default { Write-Host $Message }
  }
}

function Get-ElapsedTime {
  param([datetime]$StartTime)
  $elapsed = (Get-Date) - $StartTime
  return "$([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
}

function Assert-LocationAllowed {
  param([string]$Location, [string[]]$AllowedLocations)
  if ($AllowedLocations -notcontains $Location) {
    Write-Host ""
    Write-Host "HARD STOP: Location '$Location' is not in the allowlist." -ForegroundColor Red
    Write-Host "Allowed locations: $($AllowedLocations -join ', ')" -ForegroundColor Yellow
    throw "Location '$Location' not allowed."
  }
}

# ============================================
# MAIN DEPLOYMENT
# ============================================

Write-Host ""
Write-Host "Lab 000: Resource Group + VNet Baseline" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Purpose: Verify Azure Labs setup and create baseline infrastructure." -ForegroundColor White
Write-Host ""

$deploymentStartTime = Get-Date

# ============================================
# PHASE 0: Preflight
# ============================================
Write-Phase -Number 0 -Title "Preflight Checks"

$phase0Start = Get-Date

# Initialize log directory and file
Ensure-Directory $LogsDir
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$script:LogFile = Join-Path $LogsDir "lab-000-$timestamp.log"
Write-Log "Deployment started"
Write-Log "Location: $Location"

# Check Azure CLI
Require-Command az "Install Azure CLI: https://aka.ms/installazurecli"
Write-Validation -Check "Azure CLI installed" -Passed $true

# Check location
Assert-LocationAllowed -Location $Location -AllowedLocations $AllowedLocations
Write-Validation -Check "Location '$Location' allowed" -Passed $true

# Load config
Show-ConfigPreflight -RepoRoot $RepoRoot
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Write-Validation -Check "Subscription resolved" -Passed $true -Details $SubscriptionId

# Azure auth
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null
$subName = az account show --query name -o tsv
Write-Validation -Check "Azure authenticated" -Passed $true -Details $subName

# Set owner from environment if not provided
if (-not $Owner) {
  $Owner = $env:USERNAME
  if (-not $Owner) { $Owner = $env:USER }
  if (-not $Owner) { $Owner = "unknown" }
}

Write-Log "Preflight checks passed" "SUCCESS"

# Cost warning (minimal for this lab)
Write-Host ""
Write-Host "Cost estimate: FREE" -ForegroundColor Green
Write-Host "  Resource groups and VNets have no cost." -ForegroundColor Gray
Write-Host ""

if (-not $Force) {
  $confirm = Read-Host "Type DEPLOY to proceed"
  if ($confirm -ne "DEPLOY") { throw "Cancelled." }
}

# Portal link
$portalUrl = "https://portal.azure.com/#@/resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/overview"
Write-Host ""
Write-Host "Azure Portal:" -ForegroundColor Yellow
Write-Host "  $portalUrl" -ForegroundColor Cyan
Write-Host ""
Write-Host "Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host ""

$phase0Elapsed = Get-ElapsedTime -StartTime $phase0Start
Write-Log "Phase 0 completed in $phase0Elapsed" "SUCCESS"

# ============================================
# PHASE 1: Core Fabric (Resource Group + VNet)
# ============================================
Write-Phase -Number 1 -Title "Core Fabric (Resource Group + VNet)"

$phase1Start = Get-Date

# Build tags
# Standard tags (project, lab, owner, environment, cost-center) from labs-common.ps1
$labTags = Get-LabTags -LabId "lab-000" -Owner $Owner
$tagArgs = Get-LabTagArgs -Tags $labTags

# Create Resource Group
Write-Host "Creating resource group: $ResourceGroup" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if ($existingRg) {
  Write-Host "  Resource group already exists, skipping..." -ForegroundColor DarkGray
} else {
  az group create `
    --name $ResourceGroup `
    --location $Location `
    --tags @tagArgs `
    --output none
  Write-Log "Resource group created: $ResourceGroup"
}

# Create VNet with first subnet
Write-Host "Creating VNet: $VnetName" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingVnet = az network vnet show -g $ResourceGroup -n $VnetName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if ($existingVnet) {
  Write-Host "  VNet already exists, skipping..." -ForegroundColor DarkGray
} else {
  az network vnet create `
    --resource-group $ResourceGroup `
    --name $VnetName `
    --location $Location `
    --address-prefixes $VnetCidr `
    --subnet-name $Subnet1Name `
    --subnet-prefixes $Subnet1Cidr `
    --tags @tagArgs `
    --output none
  Write-Log "VNet created: $VnetName with subnet $Subnet1Name"
}

# Create second subnet
Write-Host "Creating subnet: $Subnet2Name" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingSnet2 = az network vnet subnet show -g $ResourceGroup --vnet-name $VnetName -n $Subnet2Name -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if ($existingSnet2) {
  Write-Host "  Subnet already exists, skipping..." -ForegroundColor DarkGray
} else {
  az network vnet subnet create `
    --resource-group $ResourceGroup `
    --vnet-name $VnetName `
    --name $Subnet2Name `
    --address-prefixes $Subnet2Cidr `
    --output none
  Write-Log "Subnet created: $Subnet2Name"
}

$phase1Elapsed = Get-ElapsedTime -StartTime $phase1Start
Write-Log "Phase 1 completed in $phase1Elapsed" "SUCCESS"

# ============================================
# PHASE 2: Primary Feature Resources (N/A)
# ============================================
Write-Phase -Number 2 -Title "Primary Feature Resources (N/A for this lab)"

$phase2Start = Get-Date
Write-Host "No primary feature resources for baseline lab." -ForegroundColor Gray
$phase2Elapsed = Get-ElapsedTime -StartTime $phase2Start
Write-Log "Phase 2 completed in $phase2Elapsed (no-op)" "SUCCESS"

# ============================================
# PHASE 3: Secondary Resources (N/A)
# ============================================
Write-Phase -Number 3 -Title "Secondary Resources (N/A for this lab)"

$phase3Start = Get-Date
Write-Host "No secondary resources for baseline lab." -ForegroundColor Gray
$phase3Elapsed = Get-ElapsedTime -StartTime $phase3Start
Write-Log "Phase 3 completed in $phase3Elapsed (no-op)" "SUCCESS"

# ============================================
# PHASE 4: Connections / Bindings (N/A)
# ============================================
Write-Phase -Number 4 -Title "Connections / Bindings (N/A for this lab)"

$phase4Start = Get-Date
Write-Host "No connections for baseline lab." -ForegroundColor Gray
$phase4Elapsed = Get-ElapsedTime -StartTime $phase4Start
Write-Log "Phase 4 completed in $phase4Elapsed (no-op)" "SUCCESS"

# ============================================
# PHASE 5: Validation
# ============================================
Write-Phase -Number 5 -Title "Validation"

$phase5Start = Get-Date

Write-Host "Validating deployed resources..." -ForegroundColor Gray
Write-Host ""

$allValid = $true

# Validate resource group
$rg = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$rg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEap
$rgValid = ($rg -ne $null)
Write-Validation -Check "Resource group exists" -Passed $rgValid -Details $ResourceGroup
if (-not $rgValid) { $allValid = $false }

# Validate VNet
$vnet = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vnet = az network vnet show -g $ResourceGroup -n $VnetName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEap
$vnetValid = ($vnet -ne $null -and $vnet.addressSpace.addressPrefixes -contains $VnetCidr)
Write-Validation -Check "VNet exists with correct CIDR" -Passed $vnetValid -Details "$VnetName ($VnetCidr)"
if (-not $vnetValid) { $allValid = $false }

# Validate subnets
$snet1 = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$snet1 = az network vnet subnet show -g $ResourceGroup --vnet-name $VnetName -n $Subnet1Name -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEap
$snet1Valid = ($snet1 -ne $null -and $snet1.addressPrefix -eq $Subnet1Cidr)
Write-Validation -Check "Subnet 1 exists" -Passed $snet1Valid -Details "$Subnet1Name ($Subnet1Cidr)"
if (-not $snet1Valid) { $allValid = $false }

$snet2 = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$snet2 = az network vnet subnet show -g $ResourceGroup --vnet-name $VnetName -n $Subnet2Name -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEap
$snet2Valid = ($snet2 -ne $null -and $snet2.addressPrefix -eq $Subnet2Cidr)
Write-Validation -Check "Subnet 2 exists" -Passed $snet2Valid -Details "$Subnet2Name ($Subnet2Cidr)"
if (-not $snet2Valid) { $allValid = $false }

# Validate tags
$rgTags = $rg.tags
$tagsValid = ($rgTags.project -eq "azure-labs" -and $rgTags.lab -eq "lab-000")
Write-Validation -Check "Tags applied correctly" -Passed $tagsValid -Details "project=azure-labs, lab=lab-000"
if (-not $tagsValid) { $allValid = $false }

$phase5Elapsed = Get-ElapsedTime -StartTime $phase5Start
Write-Log "Phase 5 completed in $phase5Elapsed" "SUCCESS"

# ============================================
# PHASE 6: Summary + Cleanup Guidance
# ============================================
Write-Phase -Number 6 -Title "Summary + Cleanup Guidance"

$phase6Start = Get-Date
$totalElapsed = Get-ElapsedTime -StartTime $deploymentStartTime

# Save outputs
Ensure-Directory (Split-Path -Parent $OutputsPath)

$outputs = [pscustomobject]@{
  metadata = [pscustomobject]@{
    lab = "lab-000"
    deployedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    deploymentTime = $totalElapsed
    status = if ($allValid) { "PASS" } else { "PARTIAL" }
    tags = @{
      project = "azure-labs"
      lab = "lab-000"
      owner = $Owner
      environment = "lab"
      "cost-center" = "learning"
    }
  }
  azure = [pscustomobject]@{
    subscriptionId = $SubscriptionId
    subscriptionName = $subName
    location = $Location
    resourceGroup = $ResourceGroup
    vnet = [pscustomobject]@{
      name = $VnetName
      cidr = $VnetCidr
      subnets = @(
        @{ name = $Subnet1Name; cidr = $Subnet1Cidr }
        @{ name = $Subnet2Name; cidr = $Subnet2Cidr }
      )
    }
  }
}

$outputs | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputsPath -Encoding UTF8

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "DEPLOYMENT SUMMARY" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host ""
Write-Host "Results:" -ForegroundColor Yellow
Write-Host "  Total deployment time: $totalElapsed" -ForegroundColor White
Write-Host "  Resource Group: $ResourceGroup" -ForegroundColor Gray
Write-Host "  Location: $Location" -ForegroundColor Gray
Write-Host "  VNet: $VnetName ($VnetCidr)" -ForegroundColor Gray
Write-Host "  Subnets: $Subnet1Name, $Subnet2Name" -ForegroundColor Gray
Write-Host ""

if ($allValid) {
  Write-Host "STATUS: PASS" -ForegroundColor Green
  Write-Host "  All resources created and validated successfully." -ForegroundColor Green
} else {
  Write-Host "STATUS: PARTIAL" -ForegroundColor Yellow
  Write-Host "  Some validations failed. Check above for details." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Outputs saved to: $OutputsPath" -ForegroundColor Gray
Write-Host "Log saved to: $script:LogFile" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  - Verify in Azure Portal: $portalUrl" -ForegroundColor Gray
Write-Host "  - Review validation: docs/validation.md" -ForegroundColor Gray
Write-Host "  - Cleanup: ./destroy.ps1" -ForegroundColor Gray
Write-Host ""

$phase6Elapsed = Get-ElapsedTime -StartTime $phase6Start
Write-Log "Phase 6 completed in $phase6Elapsed" "SUCCESS"
Write-Log "Deployment completed with status: $(if ($allValid) { 'PASS' } else { 'PARTIAL' })" "SUCCESS"
