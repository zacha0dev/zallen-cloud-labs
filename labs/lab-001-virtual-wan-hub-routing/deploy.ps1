# labs/lab-001-virtual-wan-hub-routing/deploy.ps1
# Azure Virtual WAN Hub Routing fundamentals
#
# This lab creates:
# - Virtual WAN (Standard SKU)
# - Virtual Hub
# - Spoke VNet connected to hub
# - Test VM in spoke

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [string]$Location = "centralus",
  [string]$Owner = "",
  [string]$AdminPassword,
  [string]$AdminUser = "azureuser",
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
$OutputsPath = Join-Path $RepoRoot ".data\lab-001\outputs.json"

# Load shared helpers
. (Join-Path $RepoRoot "scripts\labs-common.ps1")

# Lab configuration
$ResourceGroup = "rg-lab-001-vwan-routing"
$VwanName = "vwan-lab-001"
$VhubName = "vhub-lab-001"
$VhubCidr = "10.60.0.0/24"
$VnetName = "vnet-spoke-lab-001"
$VnetCidr = "10.61.0.0/16"
$SubnetCidr = "10.61.1.0/24"
$SubnetName = "snet-workload"
$VmName = "vm-lab-001"

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
Write-Host "Lab 001: Virtual WAN Hub Routing" -ForegroundColor Cyan
Write-Host "=================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Purpose: Learn Azure Virtual WAN fundamentals with hub routing." -ForegroundColor White
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
$script:LogFile = Join-Path $LogsDir "lab-001-$timestamp.log"
Write-Log "Deployment started"
Write-Log "Location: $Location"

# Check Azure CLI
Require-Command az "Install Azure CLI: https://aka.ms/installazurecli"
Write-Validation -Check "Azure CLI installed" -Passed $true

# Check location
Assert-LocationAllowed -Location $Location -AllowedLocations $AllowedLocations
Write-Validation -Check "Location '$Location' allowed" -Passed $true

# Check AdminPassword
if (-not $AdminPassword) {
  throw "Provide -AdminPassword (temporary lab password for VM)."
}
Write-Validation -Check "AdminPassword provided" -Passed $true

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

# Cost warning
Write-Host ""
Write-Host "Cost estimate: ~`$0.26/hour" -ForegroundColor Yellow
Write-Host "  vWAN Hub: ~`$0.25/hr" -ForegroundColor Gray
Write-Host "  VM (Standard_B1s): ~`$0.01/hr" -ForegroundColor Gray
Write-Host "  VNets, Connections: minimal" -ForegroundColor Gray
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
# PHASE 1: Core Fabric (RG + vWAN + vHub)
# ============================================
Write-Phase -Number 1 -Title "Core Fabric (vWAN + vHub)"

$phase1Start = Get-Date

# Build tags
$tagsString = "project=azure-labs lab=lab-001 owner=$Owner environment=lab cost-center=learning"

# Create Resource Group
Write-Host "Creating resource group: $ResourceGroup" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if ($existingRg) {
  Write-Host "  Resource group already exists, skipping..." -ForegroundColor DarkGray
} else {
  az group create --name $ResourceGroup --location $Location --tags $tagsString --output none
  Write-Log "Resource group created: $ResourceGroup"
}

# Create vWAN
Write-Host "Creating Virtual WAN: $VwanName" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingVwan = az network vwan show -g $ResourceGroup -n $VwanName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if ($existingVwan) {
  Write-Host "  vWAN already exists, skipping..." -ForegroundColor DarkGray
} else {
  az network vwan create `
    --name $VwanName `
    --resource-group $ResourceGroup `
    --location $Location `
    --type Standard `
    --tags $tagsString `
    --output none
  Write-Log "vWAN created: $VwanName"
}

# Create vHub
Write-Host "Creating Virtual Hub: $VhubName (this takes 10-20 minutes)" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingVhub = az network vhub show -g $ResourceGroup -n $VhubName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if ($existingVhub -and $existingVhub.provisioningState -eq "Succeeded") {
  Write-Host "  vHub already exists and is healthy, skipping..." -ForegroundColor DarkGray
} else {
  if (-not $existingVhub) {
    az network vhub create `
      --name $VhubName `
      --resource-group $ResourceGroup `
      --vwan $VwanName `
      --location $Location `
      --address-prefix $VhubCidr `
      --tags $tagsString `
      --output none
    Write-Log "vHub creation started: $VhubName"
  }

  # Wait for vHub provisioning
  Write-Host "  Waiting for vHub to provision..." -ForegroundColor Gray
  $maxAttempts = 80  # 20 minutes at 15s intervals
  $attempt = 0
  $vhubReady = $false

  while ($attempt -lt $maxAttempts) {
    $attempt++
    $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $vhub = az network vhub show -g $ResourceGroup -n $VhubName -o json 2>$null | ConvertFrom-Json
    $ErrorActionPreference = $oldErrPref

    if ($vhub.provisioningState -eq "Succeeded") {
      $vhubReady = $true
      break
    } elseif ($vhub.provisioningState -eq "Failed") {
      throw "vHub provisioning failed. Check portal for details."
    }

    $elapsed = Get-ElapsedTime -StartTime $phase1Start
    Write-Host "    [$elapsed] vHub state: $($vhub.provisioningState) (attempt $attempt/$maxAttempts)" -ForegroundColor DarkGray
    Start-Sleep -Seconds 15
  }

  if (-not $vhubReady) {
    throw "vHub did not provision within timeout. Check portal."
  }
}

$phase1Elapsed = Get-ElapsedTime -StartTime $phase1Start
Write-Host ""
Write-Host "Phase 1 Validation:" -ForegroundColor Yellow
Write-Validation -Check "vHub provisioningState = Succeeded" -Passed $true -Details "Completed in $phase1Elapsed"
Write-Log "Phase 1 completed in $phase1Elapsed" "SUCCESS"

# ============================================
# PHASE 2: Primary Feature Resources (VNet)
# ============================================
Write-Phase -Number 2 -Title "Primary Feature Resources (Spoke VNet)"

$phase2Start = Get-Date

# Create VNet
Write-Host "Creating spoke VNet: $VnetName" -ForegroundColor Gray
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
    --subnet-name $SubnetName `
    --subnet-prefixes $SubnetCidr `
    --tags $tagsString `
    --output none
  Write-Log "VNet created: $VnetName"
}

$phase2Elapsed = Get-ElapsedTime -StartTime $phase2Start
Write-Log "Phase 2 completed in $phase2Elapsed" "SUCCESS"

# ============================================
# PHASE 3: Secondary Resources (VM)
# ============================================
Write-Phase -Number 3 -Title "Secondary Resources (Test VM)"

$phase3Start = Get-Date

# Create VM
Write-Host "Creating test VM: $VmName" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingVm = az vm show -g $ResourceGroup -n $VmName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if ($existingVm) {
  Write-Host "  VM already exists, skipping..." -ForegroundColor DarkGray
} else {
  az vm create `
    --resource-group $ResourceGroup `
    --name $VmName `
    --image Ubuntu2204 `
    --size Standard_B1s `
    --vnet-name $VnetName `
    --subnet $SubnetName `
    --nsg-rule NONE `
    --admin-username $AdminUser `
    --admin-password $AdminPassword `
    --authentication-type password `
    --tags $tagsString `
    --output none
  Write-Log "VM created: $VmName"
}

$phase3Elapsed = Get-ElapsedTime -StartTime $phase3Start
Write-Log "Phase 3 completed in $phase3Elapsed" "SUCCESS"

# ============================================
# PHASE 4: Connections / Bindings
# ============================================
Write-Phase -Number 4 -Title "Connections (Hub Connection)"

$phase4Start = Get-Date

# Get VNet ID
$vnetId = az network vnet show -g $ResourceGroup -n $VnetName --query id -o tsv
if (-not $vnetId) {
  throw "Failed to resolve VNet ID for $VnetName"
}

$connectionName = "conn-$VnetName"

# Create Hub Connection
Write-Host "Creating hub connection: $connectionName" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingConn = az network vhub connection show -g $ResourceGroup --vhub-name $VhubName -n $connectionName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if ($existingConn -and $existingConn.provisioningState -eq "Succeeded") {
  Write-Host "  Hub connection already exists, skipping..." -ForegroundColor DarkGray
} else {
  az network vhub connection create `
    --resource-group $ResourceGroup `
    --vhub-name $VhubName `
    --name $connectionName `
    --remote-vnet $vnetId `
    --output none
  Write-Log "Hub connection created: $connectionName"

  # Wait for connection to provision
  Write-Host "  Waiting for connection to provision..." -ForegroundColor Gray
  $maxAttempts = 30
  $attempt = 0
  while ($attempt -lt $maxAttempts) {
    $attempt++
    $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $conn = az network vhub connection show -g $ResourceGroup --vhub-name $VhubName -n $connectionName -o json 2>$null | ConvertFrom-Json
    $ErrorActionPreference = $oldErrPref

    if ($conn.provisioningState -eq "Succeeded") {
      break
    }

    $elapsed = Get-ElapsedTime -StartTime $phase4Start
    Write-Host "    [$elapsed] Connection state: $($conn.provisioningState) (attempt $attempt/$maxAttempts)" -ForegroundColor DarkGray
    Start-Sleep -Seconds 10
  }
}

$phase4Elapsed = Get-ElapsedTime -StartTime $phase4Start
Write-Log "Phase 4 completed in $phase4Elapsed" "SUCCESS"

# ============================================
# PHASE 5: Validation
# ============================================
Write-Phase -Number 5 -Title "Validation"

$phase5Start = Get-Date

Write-Host "Validating deployed resources..." -ForegroundColor Gray
Write-Host ""

$allValid = $true

# Validate vWAN
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vwan = az network vwan show -g $ResourceGroup -n $VwanName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
$vwanValid = ($vwan -ne $null -and $vwan.type -eq "Standard")
Write-Validation -Check "vWAN exists (Standard)" -Passed $vwanValid -Details $VwanName
if (-not $vwanValid) { $allValid = $false }

# Validate vHub
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vhub = az network vhub show -g $ResourceGroup -n $VhubName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
$vhubValid = ($vhub -ne $null -and $vhub.provisioningState -eq "Succeeded")
Write-Validation -Check "vHub provisioned" -Passed $vhubValid -Details "$VhubName ($VhubCidr)"
if (-not $vhubValid) { $allValid = $false }

# Validate VNet
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vnet = az network vnet show -g $ResourceGroup -n $VnetName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
$vnetValid = ($vnet -ne $null)
Write-Validation -Check "Spoke VNet exists" -Passed $vnetValid -Details "$VnetName ($VnetCidr)"
if (-not $vnetValid) { $allValid = $false }

# Validate Hub Connection
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$conn = az network vhub connection show -g $ResourceGroup --vhub-name $VhubName -n $connectionName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
$connValid = ($conn -ne $null -and $conn.provisioningState -eq "Succeeded")
Write-Validation -Check "Hub connection active" -Passed $connValid -Details $connectionName
if (-not $connValid) { $allValid = $false }

# Validate VM
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vm = az vm show -g $ResourceGroup -n $VmName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
$vmValid = ($vm -ne $null)
Write-Validation -Check "Test VM exists" -Passed $vmValid -Details $VmName
if (-not $vmValid) { $allValid = $false }

# Validate tags
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$rg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
$rgTags = $rg.tags
$tagsValid = ($rgTags.project -eq "azure-labs" -and $rgTags.lab -eq "lab-001")
Write-Validation -Check "Tags applied correctly" -Passed $tagsValid -Details "project=azure-labs, lab=lab-001"
if (-not $tagsValid) { $allValid = $false }

# Get effective routes
Write-Host ""
Write-Host "Hub Effective Routes:" -ForegroundColor Yellow
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$effectiveRoutes = az network vhub get-effective-routes `
  --resource-group $ResourceGroup `
  --name $VhubName `
  --resource-type VirtualNetworkConnection `
  --resource-id "$($vhub.id)/hubVirtualNetworkConnections/$connectionName" `
  --query "value[].{prefix:addressPrefixes[0], nextHop:nextHopType, asPath:asPath}" `
  -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if ($effectiveRoutes) {
  foreach ($route in $effectiveRoutes) {
    Write-Host "  $($route.prefix) -> $($route.nextHop)" -ForegroundColor Gray
  }
} else {
  Write-Host "  (Routes may take a few minutes to populate)" -ForegroundColor DarkGray
}

$phase5Elapsed = Get-ElapsedTime -StartTime $phase5Start
Write-Log "Phase 5 completed in $phase5Elapsed" "SUCCESS"

# ============================================
# PHASE 6: Summary + Cleanup Guidance
# ============================================
Write-Phase -Number 6 -Title "Summary + Cleanup Guidance"

$phase6Start = Get-Date
$totalElapsed = Get-ElapsedTime -StartTime $deploymentStartTime

# Get VM private IP
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vmPrivateIp = az vm list-ip-addresses -g $ResourceGroup -n $VmName --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv 2>$null
$ErrorActionPreference = $oldErrPref

# Save outputs
Ensure-Directory (Split-Path -Parent $OutputsPath)

$outputs = [pscustomobject]@{
  metadata = [pscustomobject]@{
    lab = "lab-001"
    deployedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    deploymentTime = $totalElapsed
    status = if ($allValid) { "PASS" } else { "PARTIAL" }
    tags = @{
      project = "azure-labs"
      lab = "lab-001"
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
    vwan = $VwanName
    vhub = [pscustomobject]@{
      name = $VhubName
      cidr = $VhubCidr
    }
    spokeVnet = [pscustomobject]@{
      name = $VnetName
      cidr = $VnetCidr
      subnet = $SubnetCidr
    }
    hubConnection = $connectionName
    vm = [pscustomobject]@{
      name = $VmName
      privateIp = $vmPrivateIp
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
Write-Host ""
Write-Host "  vWAN: $VwanName" -ForegroundColor Gray
Write-Host "  vHub: $VhubName ($VhubCidr)" -ForegroundColor Gray
Write-Host "  Spoke VNet: $VnetName ($VnetCidr)" -ForegroundColor Gray
Write-Host "  Hub Connection: $connectionName" -ForegroundColor Gray
Write-Host "  Test VM: $VmName (IP: $vmPrivateIp)" -ForegroundColor Gray
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
Write-Host "  - View effective routes: ./inspect.ps1" -ForegroundColor Gray
Write-Host "  - Review validation: docs/validation.md" -ForegroundColor Gray
Write-Host "  - Cleanup: ./destroy.ps1" -ForegroundColor Gray
Write-Host ""

$phase6Elapsed = Get-ElapsedTime -StartTime $phase6Start
Write-Log "Phase 6 completed in $phase6Elapsed" "SUCCESS"
Write-Log "Deployment completed with status: $(if ($allValid) { 'PASS' } else { 'PARTIAL' })" "SUCCESS"
