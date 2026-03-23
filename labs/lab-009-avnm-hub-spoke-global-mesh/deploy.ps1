# labs/lab-009-avnm-hub-spoke-global-mesh/deploy.ps1
# Azure Virtual Network Manager - Dual Region Hub-Spoke + Global Mesh Lab
#
# Deploys two independent hub-and-spoke topologies managed by AVNM:
#   Region 1 (eastus):   vnet-hub-lab-009-r1 + vnet-spoke-lab-009-r1
#   Region 2 (westus2):  vnet-hub-lab-009-r2 + vnet-spoke-lab-009-r2
#
# AVNM manages all peerings. No manual VNet peerings are created.
# Global Mesh is NOT enabled by this script - enable it manually via the
# Azure Portal after deployment (see README.md Step 4).
#
# Phases:
#   0 - Preflight    : Auth, region validation, cost warning, confirmation
#   1 - Core Fabric  : Resource group + 4 VNets (2 hubs, 2 spokes)
#   2 - AVNM         : Azure Virtual Network Manager instance
#   3 - Network Groups : ng-hub-spoke-r1 and ng-hub-spoke-r2 + static members
#   4 - Connectivity   : Hub-spoke configs + deploy (post-commit)
#   5 - Validation     : AVNM deployment state + VNet peering state
#   6 - Summary        : Print outputs, save to .data/lab-009/outputs.json

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [string]$Location  = "eastus",
  [string]$Location2 = "westus2",
  [string]$Owner     = "",
  [switch]$Force
)

# ============================================
# REGION GUARDRAILS
# ============================================
# AVNM is available in most regions; restrict to well-tested set.
$AllowedLocations = @(
  "eastus","eastus2","centralus","westus","westus2","westus3",
  "northeurope","westeurope","uksouth","ukwest",
  "australiaeast","southeastasia","japaneast"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot  = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path
$DataDir  = Join-Path $RepoRoot ".data\lab-009"

. (Join-Path $RepoRoot "scripts\labs-common.ps1")

# ============================================
# RESOURCE NAMES
# ============================================
$ResourceGroup = "rg-lab-009-avnm"
$AvnmName      = "avnm-lab-009"

# VNets
$HubVnetR1   = "vnet-hub-lab-009-r1"
$SpokeVnetR1 = "vnet-spoke-lab-009-r1"
$HubVnetR2   = "vnet-hub-lab-009-r2"
$SpokeVnetR2 = "vnet-spoke-lab-009-r2"

# Network groups
$NgR1 = "ng-hub-spoke-r1"
$NgR2 = "ng-hub-spoke-r2"

# Connectivity configurations
$CcR1 = "cc-hub-spoke-r1"
$CcR2 = "cc-hub-spoke-r2"

# ============================================
# HELPERS
# ============================================
function Get-ElapsedTime {
  param([datetime]$StartTime)
  $elapsed = (Get-Date) - $StartTime
  return "$([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
}

function Write-Phase {
  param([string]$Message)
  Write-Host ""
  Write-Host $Message -ForegroundColor Cyan
  Write-Host ("-" * $Message.Length) -ForegroundColor DarkCyan
}

function Write-Pass { param([string]$Msg) Write-Host "  [PASS] $Msg" -ForegroundColor Green }
function Write-Skip { param([string]$Msg) Write-Host "  [SKIP] $Msg" -ForegroundColor DarkGray }
function Write-Fail { param([string]$Msg) Write-Host "  [FAIL] $Msg" -ForegroundColor Red }
function Write-Info { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor Gray }

# ============================================
# PHASE 0 - PREFLIGHT
# ============================================
Write-Phase "Phase 0: Preflight"

if ($AllowedLocations -notcontains $Location) {
  throw "Location '$Location' is not supported. Allowed: $($AllowedLocations -join ', ')"
}
if ($AllowedLocations -notcontains $Location2) {
  throw "Location2 '$Location2' is not supported. Allowed: $($AllowedLocations -join ', ')"
}
if ($Location -eq $Location2) {
  throw "Location and Location2 must be different regions."
}

Write-Info "Primary region  : $Location"
Write-Info "Secondary region: $Location2"

$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null
Write-Pass "Authenticated to subscription: $SubscriptionId"

Write-Host ""
Write-Host "Cost estimate: ~`$0.01/hr while deployed" -ForegroundColor Yellow
Write-Host "  - Azure VNET Manager: billed per connected VNet-hour (~`$0.001/hr each)" -ForegroundColor Gray
Write-Host "  - 4 VNets + hub-spoke peerings = ~`$0.004-0.008/hr" -ForegroundColor Gray
Write-Host "  - No VMs, gateways, or VPN tunnels - near free" -ForegroundColor Gray
Write-Host "  Always run .\destroy.ps1 when done!" -ForegroundColor Yellow
Write-Host ""
Write-Host "  NOTE: Global Mesh is NOT deployed by this script." -ForegroundColor Cyan
Write-Host "        Enable it manually in the portal after deploy (see README.md)." -ForegroundColor Cyan
Write-Host ""

if (-not $Force) {
  $confirm = Read-Host "Type DEPLOY to proceed"
  if ($confirm -ne "DEPLOY") { throw "Cancelled." }
}

$deployStart = Get-Date

# ============================================
# PHASE 1 - CORE FABRIC: Resource Group + VNets
# ============================================
Write-Phase "Phase 1: Core Fabric (Resource Group + VNets)"
$phase1Start = Get-Date

if (-not $Owner) {
  $Owner = (az account show --query "user.name" -o tsv 2>$null)
  if (-not $Owner) { $Owner = "lab-owner" }
}
$Tags = "project=azure-labs lab=lab-009 owner=$Owner environment=lab cost-center=learning"

# Resource Group
$existingRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
if ($existingRg) {
  Write-Skip "Resource group already exists: $ResourceGroup"
} else {
  Write-Info "Creating resource group: $ResourceGroup"
  az group create `
    --name $ResourceGroup `
    --location $Location `
    --tags $Tags | Out-Null
  Write-Pass "Created: $ResourceGroup ($Location)"
}

# VNets - PS5.1 compatible: no ternary, define as array of hashtables
$vnets = @(
  @{ Name=$HubVnetR1;   Loc=$Location;  Prefix="10.10.0.0/16"; Subnet="10.10.0.0/24"; Role="hub-r1"   },
  @{ Name=$SpokeVnetR1; Loc=$Location;  Prefix="10.11.0.0/16"; Subnet="10.11.0.0/24"; Role="spoke-r1" },
  @{ Name=$HubVnetR2;   Loc=$Location2; Prefix="10.20.0.0/16"; Subnet="10.20.0.0/24"; Role="hub-r2"   },
  @{ Name=$SpokeVnetR2; Loc=$Location2; Prefix="10.21.0.0/16"; Subnet="10.21.0.0/24"; Role="spoke-r2" }
)

foreach ($v in $vnets) {
  $existing = az network vnet show -g $ResourceGroup -n $v.Name -o json 2>$null | ConvertFrom-Json
  if ($existing) {
    Write-Skip "VNet already exists: $($v.Name)"
  } else {
    Write-Info "Creating VNet: $($v.Name) ($($v.Loc)) [$($v.Prefix)]"
    az network vnet create `
      --resource-group $ResourceGroup `
      --name $v.Name `
      --location $v.Loc `
      --address-prefixes $v.Prefix `
      --subnet-name "snet-default" `
      --subnet-prefixes $v.Subnet `
      --tags $Tags | Out-Null
    Write-Pass "Created: $($v.Name)"
  }
}

$phase1Time = Get-ElapsedTime -StartTime $phase1Start
Write-Host ""
Write-Info "Phase 1 complete in $phase1Time"

# ============================================
# PHASE 2 - AVNM INSTANCE
# ============================================
Write-Phase "Phase 2: Azure Virtual Network Manager"
$phase2Start = Get-Date

$existingAvnm = az network manager show `
  --name $AvnmName `
  --resource-group $ResourceGroup `
  -o json 2>$null | ConvertFrom-Json

if ($existingAvnm) {
  Write-Skip "AVNM already exists: $AvnmName"
} else {
  Write-Info "Creating AVNM instance: $AvnmName"
  $subscriptionScope = "/subscriptions/$SubscriptionId"
  az network manager create `
    --name $AvnmName `
    --resource-group $ResourceGroup `
    --location $Location `
    --scope-accesses Connectivity `
    --network-manager-scopes subscriptions="/subscriptions/$SubscriptionId" | Out-Null
  Write-Pass "Created AVNM: $AvnmName (scope: $subscriptionScope)"
}

$phase2Time = Get-ElapsedTime -StartTime $phase2Start
Write-Host ""
Write-Info "Phase 2 complete in $phase2Time"

# ============================================
# PHASE 3 - NETWORK GROUPS + STATIC MEMBERS
# ============================================
Write-Phase "Phase 3: Network Groups"
$phase3Start = Get-Date

$HubVnetR1Id   = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/virtualNetworks/$HubVnetR1"
$SpokeVnetR1Id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/virtualNetworks/$SpokeVnetR1"
$HubVnetR2Id   = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/virtualNetworks/$HubVnetR2"
$SpokeVnetR2Id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/virtualNetworks/$SpokeVnetR2"

# Create group ng-hub-spoke-r1
$existingNgR1 = az network manager group show `
  --name $NgR1 `
  --network-manager-name $AvnmName `
  --resource-group $ResourceGroup `
  -o json 2>$null | ConvertFrom-Json

if ($existingNgR1) {
  Write-Skip "Network group already exists: $NgR1"
} else {
  Write-Info "Creating network group: $NgR1"
  az network manager group create `
    --name $NgR1 `
    --network-manager-name $AvnmName `
    --resource-group $ResourceGroup `
    --description "Region 1 hub-spoke group (eastus)" | Out-Null
  Write-Pass "Created: $NgR1"
}

# Create group ng-hub-spoke-r2
$existingNgR2 = az network manager group show `
  --name $NgR2 `
  --network-manager-name $AvnmName `
  --resource-group $ResourceGroup `
  -o json 2>$null | ConvertFrom-Json

if ($existingNgR2) {
  Write-Skip "Network group already exists: $NgR2"
} else {
  Write-Info "Creating network group: $NgR2"
  az network manager group create `
    --name $NgR2 `
    --network-manager-name $AvnmName `
    --resource-group $ResourceGroup `
    --description "Region 2 hub-spoke group (westus2)" | Out-Null
  Write-Pass "Created: $NgR2"
}

# Static members for ng-hub-spoke-r1
$staticMembers = @(
  @{ Group=$NgR1; MemberName="member-hub-r1";   VnetId=$HubVnetR1Id;   Label="hub-r1"   },
  @{ Group=$NgR1; MemberName="member-spoke-r1"; VnetId=$SpokeVnetR1Id; Label="spoke-r1" },
  @{ Group=$NgR2; MemberName="member-hub-r2";   VnetId=$HubVnetR2Id;   Label="hub-r2"   },
  @{ Group=$NgR2; MemberName="member-spoke-r2"; VnetId=$SpokeVnetR2Id; Label="spoke-r2" }
)

foreach ($sm in $staticMembers) {
  $existingSm = az network manager group static-member show `
    --name $sm.MemberName `
    --network-group-name $sm.Group `
    --network-manager-name $AvnmName `
    --resource-group $ResourceGroup `
    -o json 2>$null | ConvertFrom-Json

  if ($existingSm) {
    Write-Skip "Static member already exists: $($sm.Label) in $($sm.Group)"
  } else {
    Write-Info "Adding static member: $($sm.Label) to $($sm.Group)"
    az network manager group static-member create `
      --name $sm.MemberName `
      --network-group-name $sm.Group `
      --network-manager-name $AvnmName `
      --resource-group $ResourceGroup `
      --resource-id $sm.VnetId | Out-Null
    Write-Pass "Added: $($sm.Label) -> $($sm.Group)"
  }
}

$phase3Time = Get-ElapsedTime -StartTime $phase3Start
Write-Host ""
Write-Info "Phase 3 complete in $phase3Time"

# ============================================
# PHASE 4 - CONNECTIVITY CONFIGURATIONS + DEPLOY
# ============================================
Write-Phase "Phase 4: Connectivity Configurations + Deployment"
$phase4Start = Get-Date

$NgR1Id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/networkManagers/$AvnmName/networkGroups/$NgR1"
$NgR2Id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/networkManagers/$AvnmName/networkGroups/$NgR2"

# Build JSON arguments (PS5.1 safe string building, no special operators)
$hubsR1Json = '[{"resourceId":"' + $HubVnetR1Id + '","resourceType":"Microsoft.Network/virtualNetworks"}]'
$appGroupR1Json = '[{"networkGroupId":"' + $NgR1Id + '","groupConnectivity":"None","isGlobal":false,"useHubGateway":false}]'

$hubsR2Json = '[{"resourceId":"' + $HubVnetR2Id + '","resourceType":"Microsoft.Network/virtualNetworks"}]'
$appGroupR2Json = '[{"networkGroupId":"' + $NgR2Id + '","groupConnectivity":"None","isGlobal":false,"useHubGateway":false}]'

# Connectivity config cc-hub-spoke-r1
$existingCcR1 = az network manager connect-config show `
  --configuration-name $CcR1 `
  --network-manager-name $AvnmName `
  --resource-group $ResourceGroup `
  -o json 2>$null | ConvertFrom-Json

if ($existingCcR1) {
  Write-Skip "Connectivity config already exists: $CcR1"
} else {
  Write-Info "Creating connectivity config: $CcR1 (hub-spoke, Region 1)"
  az network manager connect-config create `
    --configuration-name $CcR1 `
    --network-manager-name $AvnmName `
    --resource-group $ResourceGroup `
    --connectivity-topology HubAndSpoke `
    --hubs $hubsR1Json `
    --applies-to-groups $appGroupR1Json `
    --description "Hub-spoke topology for Region 1 (eastus)" | Out-Null
  Write-Pass "Created: $CcR1"
}

# Connectivity config cc-hub-spoke-r2
$existingCcR2 = az network manager connect-config show `
  --configuration-name $CcR2 `
  --network-manager-name $AvnmName `
  --resource-group $ResourceGroup `
  -o json 2>$null | ConvertFrom-Json

if ($existingCcR2) {
  Write-Skip "Connectivity config already exists: $CcR2"
} else {
  Write-Info "Creating connectivity config: $CcR2 (hub-spoke, Region 2)"
  az network manager connect-config create `
    --configuration-name $CcR2 `
    --network-manager-name $AvnmName `
    --resource-group $ResourceGroup `
    --connectivity-topology HubAndSpoke `
    --hubs $hubsR2Json `
    --applies-to-groups $appGroupR2Json `
    --description "Hub-spoke topology for Region 2 (westus2)" | Out-Null
  Write-Pass "Created: $CcR2"
}

# Deploy (post-commit) both configs to both regions
Write-Host ""
Write-Info "Deploying connectivity configs via AVNM post-commit..."
Write-Info "  Targets: $Location, $Location2"
Write-Info "  This triggers AVNM to create managed VNet peerings."
Write-Info "  Allow 1-3 minutes for peerings to reach Connected state."

$CcR1Id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/networkManagers/$AvnmName/connectivityConfigurations/$CcR1"
$CcR2Id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/networkManagers/$AvnmName/connectivityConfigurations/$CcR2"

az network manager post-commit `
  --network-manager-name $AvnmName `
  --resource-group $ResourceGroup `
  --commit-type Connectivity `
  --target-locations $Location $Location2 `
  --configuration-ids $CcR1Id $CcR2Id | Out-Null

Write-Pass "Post-commit submitted. AVNM is reconciling peerings..."

$phase4Time = Get-ElapsedTime -StartTime $phase4Start
Write-Host ""
Write-Info "Phase 4 complete in $phase4Time"

# ============================================
# PHASE 5 - VALIDATION
# ============================================
Write-Phase "Phase 5: Validation"
$phase5Start = Get-Date

Write-Info "Waiting 60 seconds for AVNM reconciliation..."
Start-Sleep -Seconds 60

# Check AVNM deployment status
Write-Host ""
Write-Info "Checking AVNM active deployments..."
$activeDeployments = az network manager list-active-connectivity-config `
  --name $AvnmName `
  --resource-group $ResourceGroup `
  --regions $Location $Location2 `
  -o json 2>$null | ConvertFrom-Json

if ($activeDeployments -and $activeDeployments.value -and $activeDeployments.value.Count -gt 0) {
  Write-Pass "AVNM reports $($activeDeployments.value.Count) active deployment(s)"
  foreach ($d in $activeDeployments.value) {
    Write-Info "  Config: $($d.id.Split('/')[-1]) | Regions: $($d.configurationGroups -join ', ')"
  }
} else {
  Write-Host "  [WARN] No active deployments detected yet - reconciliation may still be in progress" -ForegroundColor Yellow
  Write-Info "  Run .\inspect.ps1 to check status after a few minutes"
}

# Check VNet peerings created by AVNM
Write-Host ""
Write-Info "Checking VNet peerings created by AVNM..."
$allVnets = @($HubVnetR1, $SpokeVnetR1, $HubVnetR2, $SpokeVnetR2)
$totalPeerings = 0

foreach ($vnetName in $allVnets) {
  $peerings = az network vnet peering list `
    --resource-group $ResourceGroup `
    --vnet-name $vnetName `
    -o json 2>$null | ConvertFrom-Json

  if ($peerings -and $peerings.Count -gt 0) {
    $totalPeerings = $totalPeerings + $peerings.Count
    foreach ($p in $peerings) {
      $state = $p.peeringState
      if ($state -eq "Connected") {
        Write-Pass "$vnetName -> $($p.remoteVirtualNetwork.id.Split('/')[-1]) : $state"
      } else {
        Write-Host "  [WAIT] $vnetName -> $($p.remoteVirtualNetwork.id.Split('/')[-1]) : $state" -ForegroundColor Yellow
      }
    }
  } else {
    Write-Host "  [WAIT] $vnetName : no peerings yet (AVNM may still be reconciling)" -ForegroundColor Yellow
  }
}

if ($totalPeerings -gt 0) {
  Write-Host ""
  Write-Info "Total peerings detected: $totalPeerings"
  Write-Info "Expected: 4 (hub<->spoke per region, bidirectional = 4 peering objects)"
}

$phase5Time = Get-ElapsedTime -StartTime $phase5Start
Write-Host ""
Write-Info "Phase 5 complete in $phase5Time"

# ============================================
# PHASE 6 - SUMMARY + OUTPUTS
# ============================================
Write-Phase "Phase 6: Summary"

$totalTime = Get-ElapsedTime -StartTime $deployStart

if (-not (Test-Path $DataDir)) {
  New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}

$outputs = @{
  metadata = @{
    lab           = "lab-009"
    deployedAt    = (Get-Date -Format "o")
    deploymentTime = $totalTime
    status        = "PASS"
  }
  azure = @{
    subscriptionId    = $SubscriptionId
    location          = $Location
    location2         = $Location2
    resourceGroup     = $ResourceGroup
    avnm              = $AvnmName
    networkGroups     = @($NgR1, $NgR2)
    connectivityConfigs = @($CcR1, $CcR2)
    vnets             = @(
      @{ name=$HubVnetR1;   region=$Location;  cidr="10.10.0.0/16"; role="hub"   },
      @{ name=$SpokeVnetR1; region=$Location;  cidr="10.11.0.0/16"; role="spoke" },
      @{ name=$HubVnetR2;   region=$Location2; cidr="10.20.0.0/16"; role="hub"   },
      @{ name=$SpokeVnetR2; region=$Location2; cidr="10.21.0.0/16"; role="spoke" }
    )
    globalMeshEnabled = $false
  }
}

$outputs | ConvertTo-Json -Depth 6 | Out-File -FilePath (Join-Path $DataDir "outputs.json") -Encoding utf8
Write-Pass "Outputs saved: .data/lab-009/outputs.json"

Write-Host ""
Write-Host ("=" * 65) -ForegroundColor Green
Write-Host " Lab 009 deployed successfully!" -ForegroundColor Green
Write-Host ("=" * 65) -ForegroundColor Green
Write-Host ""
Write-Host "  AVNM instance  : $AvnmName" -ForegroundColor White
Write-Host "  Network groups : $NgR1, $NgR2" -ForegroundColor White
Write-Host "  Configs        : $CcR1, $CcR2" -ForegroundColor White
Write-Host ""
Write-Host "  Region 1 ($Location):" -ForegroundColor White
Write-Host "    Hub   : $HubVnetR1   (10.10.0.0/16)" -ForegroundColor Gray
Write-Host "    Spoke : $SpokeVnetR1 (10.11.0.0/16)" -ForegroundColor Gray
Write-Host ""
Write-Host "  Region 2 ($Location2):" -ForegroundColor White
Write-Host "    Hub   : $HubVnetR2   (10.20.0.0/16)" -ForegroundColor Gray
Write-Host "    Spoke : $SpokeVnetR2 (10.21.0.0/16)" -ForegroundColor Gray
Write-Host ""
Write-Host "  Deployment time: $totalTime" -ForegroundColor DarkGray
Write-Host ""
Write-Host ("=" * 65) -ForegroundColor Cyan
Write-Host " NEXT STEP: Enable Global Mesh via Azure Portal" -ForegroundColor Cyan
Write-Host ("=" * 65) -ForegroundColor Cyan
Write-Host ""
Write-Host "  See README.md Section 4 for full portal walkthrough." -ForegroundColor Yellow
Write-Host "  Portal: https://portal.azure.com" -ForegroundColor DarkGray
Write-Host "  Navigate to: $AvnmName > Configurations > + Add > Connectivity" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  To validate the deployment now:" -ForegroundColor White
Write-Host "    .\inspect.ps1" -ForegroundColor Cyan
Write-Host ""
Write-Host "  When done with the lab:" -ForegroundColor White
Write-Host "    .\destroy.ps1" -ForegroundColor Cyan
Write-Host ""
