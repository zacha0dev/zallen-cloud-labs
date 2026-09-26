# labs/lab-004-vwan-default-route-propagation/deploy.ps1
# Deploys vWAN with two hubs demonstrating default route (0/0) propagation behavior
#
# PHASES:
#   0 - Preflight Checks
#   1 - Core Fabric (vWAN + vHubs)
#   2 - Spoke VNets
#   3 - Hub Connections + Routing
#   4 - Test VMs
#   5 - Validation
#   6 - Summary

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [string]$Location = "eastus2",
  [string]$AdminPassword,
  [string]$Owner,
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path

# Load shared helpers
. (Join-Path $RepoRoot "scripts\labs-common.ps1")

# -----------------------------------------------------------------------------
# Lab Configuration
# -----------------------------------------------------------------------------
$ResourceGroup = "rg-lab-004-vwan-route-prop"
$VwanName = "vwan-lab-004"
$HubAName = "vhub-a-lab-004"
$HubBName = "vhub-b-lab-004"
$AdminUsername = "azureuser"
$VmSize = "Standard_B1s"

# Address spaces
$HubACidr = "10.100.0.0/24"
$HubBCidr = "10.101.0.0/24"
$VnetFwCidr = "10.110.0.0/24"
$VnetFwSubnetCidr = "10.110.0.0/26"
$SpokeA1Cidr = "10.111.0.0/24"
$SpokeA2Cidr = "10.112.0.0/24"
$SpokeA3Cidr = "10.113.0.0/24"
$SpokeA4Cidr = "10.114.0.0/24"
$SpokeB1Cidr = "10.121.0.0/24"
$SpokeB2Cidr = "10.122.0.0/24"

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------
function Write-Phase {
  param([int]$Number, [string]$Title)
  Write-Host ""
  Write-Host ("=" * 60) -ForegroundColor Cyan
  Write-Host "PHASE $Number : $Title" -ForegroundColor Cyan
  Write-Host ("=" * 60) -ForegroundColor Cyan
  Write-Host ""
}

function Write-Step {
  param([string]$Message)
  Write-Host "  --> $Message" -ForegroundColor White
}

function Write-SubStep {
  param([string]$Message)
  Write-Host "      $Message" -ForegroundColor DarkGray
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

function Get-ElapsedTime {
  param([datetime]$StartTime)
  $elapsed = (Get-Date) - $StartTime
  return "$([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
}

function Ensure-Directory {
  param([string]$Path)
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Write-Log {
  param([string]$Message)
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $logMessage = "[$timestamp] $Message"
  Add-Content -Path $script:LogFile -Value $logMessage
  Write-Host $logMessage -ForegroundColor DarkGray
}

function Test-HasDefaultRoute {
  param([array]$Routes)
  foreach ($route in $Routes) {
    if ($route.addressPrefix -eq "0.0.0.0/0") { return $true }
  }
  return $false
}

function Get-EffectiveRoutes {
  param([string]$NicName)
  $oldErrPref = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  $json = az network nic show-effective-route-table -g $ResourceGroup -n $NicName -o json 2>$null
  $ErrorActionPreference = $oldErrPref
  if ($LASTEXITCODE -ne 0 -or -not $json) { return @() }
  return ($json | ConvertFrom-Json).value
}

# -----------------------------------------------------------------------------
# Setup Logging
# -----------------------------------------------------------------------------
$LogsDir = Join-Path $LabRoot "logs"
$OutputsDir = Join-Path $LabRoot "outputs"
Ensure-Directory $LogsDir
Ensure-Directory $OutputsDir

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$script:LogFile = Join-Path $LogsDir "lab-004-$timestamp.log"

# -----------------------------------------------------------------------------
# Banner
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Magenta
Write-Host "  Lab 004: vWAN Default Route (0/0) Propagation" -ForegroundColor Magenta
Write-Host ("=" * 60) -ForegroundColor Magenta
Write-Host ""

$deployStartTime = Get-Date

# =============================================================================
# PHASE 0 : Preflight Checks
# =============================================================================
Write-Phase -Number 0 -Title "Preflight Checks"

Write-Step "Checking required tools..."
$requiredCommands = @("az")
foreach ($cmd in $requiredCommands) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $cmd. Run scripts\setup.ps1 first."
  }
  Write-SubStep "$cmd found"
}

Write-Step "Loading configuration..."
Show-ConfigPreflight -RepoRoot $RepoRoot
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot

Write-Step "Authenticating with Azure..."
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null
Write-SubStep "Subscription: $SubscriptionId"

# Resolve owner
if (-not $Owner) {
  $Owner = $env:USER
  if (-not $Owner) { $Owner = $env:USERNAME }
  if (-not $Owner) { $Owner = "unknown" }
}

# AdminPassword: prompt securely only if it was not supplied
if (-not $AdminPassword) {
  Write-Host "  This lab deploys VMs and requires an admin password." -ForegroundColor Yellow
  Write-Host "  Requirements: 12+ chars, uppercase, lowercase, number, special char." -ForegroundColor DarkGray
  $secPwd = Read-Host "  VM Admin Password" -AsSecureString
  $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPwd)
  $AdminPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
  [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  if (-not $AdminPassword) { throw "Provide -AdminPassword (temporary lab password for VM)." }
}

# Build tags (standard five via shared helper, passed as discrete args)
$Tags = Get-LabTags -LabId "lab-004" -Owner $Owner
$Tags["purpose"] = "vwan-route-propagation"
$tagArgs = Get-LabTagArgs -Tags $Tags

Write-Step "Deployment configuration:"
Write-SubStep "Location: $Location"
Write-SubStep "Resource Group: $ResourceGroup"
Write-SubStep "Owner: $Owner"
Write-SubStep "Log file: $($script:LogFile)"

if (-not $Force) {
  Write-Host ""
  Write-Host "This lab creates 2 vWAN hubs (~`$0.50/hour combined) + 7 VMs." -ForegroundColor Yellow
  Write-Host "Total estimated cost: ~`$0.60/hour" -ForegroundColor Yellow
  Write-Host ""
  $confirm = Read-Host "Type DEPLOY to proceed"
  if ($confirm -ne "DEPLOY") { throw "Cancelled." }
}

Write-Log "Phase 0 complete - Preflight passed"

# =============================================================================
# PHASE 1 : Core Fabric (vWAN + vHubs)
# =============================================================================
Write-Phase -Number 1 -Title "Core Fabric (vWAN + vHubs)"
$phase1Start = Get-Date

Write-Step "Creating resource group: $ResourceGroup"
$existingRg = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEap
if ($existingRg) {
  Write-SubStep "Resource group already exists, reusing"
} else {
  az group create -n $ResourceGroup -l $Location --tags @tagArgs -o none
  Write-SubStep "Created"
}

Write-Step "Creating Virtual WAN: $VwanName"
$existingVwan = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingVwan = az network vwan show -g $ResourceGroup -n $VwanName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEap
if ($existingVwan) {
  Write-SubStep "vWAN already exists, reusing"
} else {
  az network vwan create `
    -g $ResourceGroup `
    -n $VwanName `
    -l $Location `
    --type Standard `
    --branch-to-branch-traffic true `
    --tags @tagArgs `
    -o none
  Write-SubStep "Created"
}

Write-Step "Creating Virtual Hub A: $HubAName (10-20 min)"
$existingHubA = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingHubA = az network vhub show -g $ResourceGroup -n $HubAName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEap
if ($existingHubA -and $existingHubA.provisioningState -eq "Succeeded") {
  Write-SubStep "Hub A already exists and is ready"
} else {
  if (-not $existingHubA) {
    az network vhub create `
      -g $ResourceGroup `
      -n $HubAName `
      --vwan $VwanName `
      -l $Location `
      --address-prefix $HubACidr `
      --tags @tagArgs `
      -o none --no-wait
    Write-SubStep "Hub A creation initiated"
  }
}

Write-Step "Creating Virtual Hub B: $HubBName (10-20 min)"
$existingHubB = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingHubB = az network vhub show -g $ResourceGroup -n $HubBName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEap
if ($existingHubB -and $existingHubB.provisioningState -eq "Succeeded") {
  Write-SubStep "Hub B already exists and is ready"
} else {
  if (-not $existingHubB) {
    az network vhub create `
      -g $ResourceGroup `
      -n $HubBName `
      --vwan $VwanName `
      -l $Location `
      --address-prefix $HubBCidr `
      --tags @tagArgs `
      -o none --no-wait
    Write-SubStep "Hub B creation initiated"
  }
}

Write-Step "Waiting for both vHubs to provision..."
$maxWaitMinutes = 30
$waitStart = Get-Date
$hubsReady = $false

while (-not $hubsReady) {
  $elapsed = (Get-Date) - $waitStart
  if ($elapsed.TotalMinutes -gt $maxWaitMinutes) {
    throw "Timeout waiting for vHubs to provision after $maxWaitMinutes minutes"
  }

  $hubAState = $null
  $oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $hubAState = (az network vhub show -g $ResourceGroup -n $HubAName --query provisioningState -o tsv 2>$null)
  $ErrorActionPreference = $oldEap
  $hubBState = $null
  $oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $hubBState = (az network vhub show -g $ResourceGroup -n $HubBName --query provisioningState -o tsv 2>$null)
  $ErrorActionPreference = $oldEap

  $elapsedStr = Get-ElapsedTime -StartTime $waitStart
  Write-SubStep "[$elapsedStr] Hub A: $hubAState, Hub B: $hubBState"

  if ($hubAState -eq "Succeeded" -and $hubBState -eq "Succeeded") {
    $hubsReady = $true
  } elseif ($hubAState -eq "Failed" -or $hubBState -eq "Failed") {
    throw "vHub provisioning failed"
  } else {
    Start-Sleep -Seconds 30
  }
}

Write-SubStep "Both hubs provisioned successfully"

$phase1Elapsed = Get-ElapsedTime -StartTime $phase1Start
Write-Log "Phase 1 complete in $phase1Elapsed"

# =============================================================================
# PHASE 2 : Spoke VNets
# =============================================================================
Write-Phase -Number 2 -Title "Spoke VNets"
$phase2Start = Get-Date

$vnets = @(
  @{ Name = "vnet-fw-lab-004";   Cidr = $VnetFwCidr;  Subnet = "snet-fw"; SubnetCidr = $VnetFwSubnetCidr }
  @{ Name = "vnet-spoke-a1";     Cidr = $SpokeA1Cidr; Subnet = "default"; SubnetCidr = $SpokeA1Cidr }
  @{ Name = "vnet-spoke-a2";     Cidr = $SpokeA2Cidr; Subnet = "default"; SubnetCidr = $SpokeA2Cidr }
  @{ Name = "vnet-spoke-a3";     Cidr = $SpokeA3Cidr; Subnet = "default"; SubnetCidr = $SpokeA3Cidr }
  @{ Name = "vnet-spoke-a4";     Cidr = $SpokeA4Cidr; Subnet = "default"; SubnetCidr = $SpokeA4Cidr }
  @{ Name = "vnet-spoke-b1";     Cidr = $SpokeB1Cidr; Subnet = "default"; SubnetCidr = $SpokeB1Cidr }
  @{ Name = "vnet-spoke-b2";     Cidr = $SpokeB2Cidr; Subnet = "default"; SubnetCidr = $SpokeB2Cidr }
)

foreach ($vnet in $vnets) {
  Write-Step "Creating VNet: $($vnet.Name)"
  $existing = $null
  $oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $existing = az network vnet show -g $ResourceGroup -n $vnet.Name -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEap
  if ($existing) {
    Write-SubStep "Already exists, skipping"
  } else {
    az network vnet create `
      -g $ResourceGroup `
      -n $vnet.Name `
      -l $Location `
      --address-prefix $vnet.Cidr `
      --subnet-name $vnet.Subnet `
      --subnet-prefix $vnet.SubnetCidr `
      --tags @tagArgs `
      -o none
    Write-SubStep "Created with subnet $($vnet.Subnet)"
  }
}

$phase2Elapsed = Get-ElapsedTime -StartTime $phase2Start
Write-Log "Phase 2 complete in $phase2Elapsed"

# =============================================================================
# PHASE 3 : Hub Connections + Routing
# =============================================================================
Write-Phase -Number 3 -Title "Hub Connections + Routing"
$phase3Start = Get-Date

# Get VNet IDs
$vnetFwId = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vnetFwId = az network vnet show -g $ResourceGroup -n "vnet-fw-lab-004" --query id -o tsv
$ErrorActionPreference = $oldEap
if (-not $vnetFwId) { throw "Could not resolve VNet ID for vnet-fw-lab-004" }
$vnetA1Id = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vnetA1Id = az network vnet show -g $ResourceGroup -n "vnet-spoke-a1" --query id -o tsv
$ErrorActionPreference = $oldEap
if (-not $vnetA1Id) { throw "Could not resolve VNet ID for vnet-spoke-a1" }
$vnetA2Id = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vnetA2Id = az network vnet show -g $ResourceGroup -n "vnet-spoke-a2" --query id -o tsv
$ErrorActionPreference = $oldEap
if (-not $vnetA2Id) { throw "Could not resolve VNet ID for vnet-spoke-a2" }
$vnetA3Id = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vnetA3Id = az network vnet show -g $ResourceGroup -n "vnet-spoke-a3" --query id -o tsv
$ErrorActionPreference = $oldEap
if (-not $vnetA3Id) { throw "Could not resolve VNet ID for vnet-spoke-a3" }
$vnetA4Id = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vnetA4Id = az network vnet show -g $ResourceGroup -n "vnet-spoke-a4" --query id -o tsv
$ErrorActionPreference = $oldEap
if (-not $vnetA4Id) { throw "Could not resolve VNet ID for vnet-spoke-a4" }
$vnetB1Id = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vnetB1Id = az network vnet show -g $ResourceGroup -n "vnet-spoke-b1" --query id -o tsv
$ErrorActionPreference = $oldEap
if (-not $vnetB1Id) { throw "Could not resolve VNet ID for vnet-spoke-b1" }
$vnetB2Id = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vnetB2Id = az network vnet show -g $ResourceGroup -n "vnet-spoke-b2" --query id -o tsv
$ErrorActionPreference = $oldEap
if (-not $vnetB2Id) { throw "Could not resolve VNet ID for vnet-spoke-b2" }

# Step 1: Create FW VNet connection first (needed for route table)
Write-Step "Creating FW VNet connection to Hub A"
$existingFwConn = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingFwConn = az network vhub connection show -g $ResourceGroup --vhub-name $HubAName -n "conn-vnet-fw" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEap
if ($existingFwConn) {
  Write-SubStep "Already exists, skipping"
} else {
  az network vhub connection create `
    -g $ResourceGroup `
    --vhub-name $HubAName `
    -n "conn-vnet-fw" `
    --remote-vnet $vnetFwId `
    -o none
  Write-SubStep "Created"
  # Wait for connection to succeed
  Write-SubStep "Waiting for connection to provision..."
  $maxAttempts = 30
  for ($i = 1; $i -le $maxAttempts; $i++) {
    $state = $null
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $state = az network vhub connection show -g $ResourceGroup --vhub-name $HubAName -n "conn-vnet-fw" --query provisioningState -o tsv 2>$null
    $ErrorActionPreference = $oldEap
    if ($state -eq "Succeeded") { break }
    if ($state -eq "Failed") { throw "FW connection failed" }
    Start-Sleep -Seconds 10
  }
}

# Step 2: Create custom route table with 0.0.0.0/0 -> FW
Write-Step "Creating custom route table: rt-fw-default"
$existingRt = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRt = az network vhub route-table show -g $ResourceGroup --vhub-name $HubAName -n "rt-fw-default" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEap
if ($existingRt) {
  Write-SubStep "Already exists, skipping"
  $rtFwDefaultId = $existingRt.id
} else {
  # Get the FW connection ID for the next hop
  $fwConnId = $null
  $oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $fwConnId = az network vhub connection show -g $ResourceGroup --vhub-name $HubAName -n "conn-vnet-fw" --query id -o tsv
  $ErrorActionPreference = $oldEap
  if (-not $fwConnId) { throw "Could not resolve hub connection ID for conn-vnet-fw" }

  az network vhub route-table create `
    -g $ResourceGroup `
    --vhub-name $HubAName `
    -n "rt-fw-default" `
    --labels "fw-default" `
    --route-name "default-to-fw" `
    --destination-type CIDR `
    --destinations "0.0.0.0/0" `
    --next-hop-type ResourceId `
    --next-hop $fwConnId `
    -o none
  Write-SubStep "Created with static 0.0.0.0/0 route"
  $rtFwDefaultId = $null
  $oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $rtFwDefaultId = az network vhub route-table show -g $ResourceGroup --vhub-name $HubAName -n "rt-fw-default" --query id -o tsv
  $ErrorActionPreference = $oldEap
  if (-not $rtFwDefaultId) { throw "Could not resolve route table ID for rt-fw-default" }
}

# Step 3: Create spoke connections with routing configuration
# A1 and A2 -> rt-fw-default (will learn 0/0)
Write-Step "Creating Spoke A1/A2 connections (rt-fw-default)"
foreach ($spoke in @(@{Name="conn-spoke-a1"; VnetId=$vnetA1Id}, @{Name="conn-spoke-a2"; VnetId=$vnetA2Id})) {
  $existing = $null
  $oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $existing = az network vhub connection show -g $ResourceGroup --vhub-name $HubAName -n $spoke.Name -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEap
  if ($existing) {
    Write-SubStep "$($spoke.Name) already exists"
  } else {
    az network vhub connection create `
      -g $ResourceGroup `
      --vhub-name $HubAName `
      -n $spoke.Name `
      --remote-vnet $spoke.VnetId `
      --associated-route-table $rtFwDefaultId `
      --propagated-route-tables $rtFwDefaultId `
      --labels "fw-default" `
      -o none
    Write-SubStep "Created $($spoke.Name) -> rt-fw-default"
    Start-Sleep -Seconds 5
  }
}

# A3 and A4 -> Default RT (will NOT learn 0/0)
Write-Step "Creating Spoke A3/A4 connections (Default RT)"
foreach ($spoke in @(@{Name="conn-spoke-a3"; VnetId=$vnetA3Id}, @{Name="conn-spoke-a4"; VnetId=$vnetA4Id})) {
  $existing = $null
  $oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $existing = az network vhub connection show -g $ResourceGroup --vhub-name $HubAName -n $spoke.Name -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEap
  if ($existing) {
    Write-SubStep "$($spoke.Name) already exists"
  } else {
    az network vhub connection create `
      -g $ResourceGroup `
      --vhub-name $HubAName `
      -n $spoke.Name `
      --remote-vnet $spoke.VnetId `
      -o none
    Write-SubStep "Created $($spoke.Name) -> Default RT"
    Start-Sleep -Seconds 5
  }
}

# B1 and B2 -> Hub B Default RT
Write-Step "Creating Spoke B1/B2 connections (Hub B, Default RT)"
foreach ($spoke in @(@{Name="conn-spoke-b1"; VnetId=$vnetB1Id}, @{Name="conn-spoke-b2"; VnetId=$vnetB2Id})) {
  $existing = $null
  $oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $existing = az network vhub connection show -g $ResourceGroup --vhub-name $HubBName -n $spoke.Name -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEap
  if ($existing) {
    Write-SubStep "$($spoke.Name) already exists"
  } else {
    az network vhub connection create `
      -g $ResourceGroup `
      --vhub-name $HubBName `
      -n $spoke.Name `
      --remote-vnet $spoke.VnetId `
      -o none
    Write-SubStep "Created $($spoke.Name) -> Hub B Default RT"
    Start-Sleep -Seconds 5
  }
}

# Wait for all connections to complete
Write-Step "Waiting for all connections to provision..."
$allConns = @(
  @{Hub=$HubAName; Conn="conn-vnet-fw"}
  @{Hub=$HubAName; Conn="conn-spoke-a1"}
  @{Hub=$HubAName; Conn="conn-spoke-a2"}
  @{Hub=$HubAName; Conn="conn-spoke-a3"}
  @{Hub=$HubAName; Conn="conn-spoke-a4"}
  @{Hub=$HubBName; Conn="conn-spoke-b1"}
  @{Hub=$HubBName; Conn="conn-spoke-b2"}
)

$maxAttempts = 60
for ($i = 1; $i -le $maxAttempts; $i++) {
  $allReady = $true
  foreach ($c in $allConns) {
    $state = $null
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $state = az network vhub connection show -g $ResourceGroup --vhub-name $c.Hub -n $c.Conn --query provisioningState -o tsv 2>$null
    $ErrorActionPreference = $oldEap
    if ($state -ne "Succeeded") {
      $allReady = $false
      break
    }
  }
  if ($allReady) { break }
  Write-SubStep "Waiting... (attempt $i/$maxAttempts)"
  Start-Sleep -Seconds 10
}

Write-SubStep "All connections ready"

$phase3Elapsed = Get-ElapsedTime -StartTime $phase3Start
Write-Log "Phase 3 complete in $phase3Elapsed"

# =============================================================================
# PHASE 4 : Test VMs
# =============================================================================
Write-Phase -Number 4 -Title "Test VMs"
$phase4Start = Get-Date

$vms = @(
  @{ Name = "vm-fw"; Vnet = "vnet-fw-lab-004"; Subnet = "snet-fw"; EnableForwarding = $true }
  @{ Name = "vm-a1"; Vnet = "vnet-spoke-a1"; Subnet = "default"; EnableForwarding = $false }
  @{ Name = "vm-a2"; Vnet = "vnet-spoke-a2"; Subnet = "default"; EnableForwarding = $false }
  @{ Name = "vm-a3"; Vnet = "vnet-spoke-a3"; Subnet = "default"; EnableForwarding = $false }
  @{ Name = "vm-a4"; Vnet = "vnet-spoke-a4"; Subnet = "default"; EnableForwarding = $false }
  @{ Name = "vm-b1"; Vnet = "vnet-spoke-b1"; Subnet = "default"; EnableForwarding = $false }
  @{ Name = "vm-b2"; Vnet = "vnet-spoke-b2"; Subnet = "default"; EnableForwarding = $false }
)

foreach ($vm in $vms) {
  Write-Step "Creating VM: $($vm.Name)"
  $nicName = "nic-$($vm.Name)"

  # Check if VM exists
  $existingVm = $null
  $oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $existingVm = az vm show -g $ResourceGroup -n $vm.Name -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEap
  if ($existingVm) {
    Write-SubStep "Already exists, skipping"
    continue
  }

  # Create NIC
  $nicExists = $null
  $oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $nicExists = az network nic show -g $ResourceGroup -n $nicName -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEap
  if (-not $nicExists) {
    $nicArgs = @(
      "-g", $ResourceGroup,
      "-n", $nicName,
      "--vnet-name", $vm.Vnet,
      "--subnet", $vm.Subnet,
      "-o", "none"
    )
    if ($vm.EnableForwarding) {
      $nicArgs += "--ip-forwarding", "true"
    }
    az network nic create @nicArgs
    Write-SubStep "Created NIC: $nicName"
  }

  # Create VM
  az vm create `
    -g $ResourceGroup `
    -n $vm.Name `
    -l $Location `
    --nics $nicName `
    --image "Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest" `
    --size $VmSize `
    --admin-username $AdminUsername `
    --admin-password $AdminPassword `
    --authentication-type password `
    --tags @tagArgs `
    --no-wait `
    -o none
  Write-SubStep "VM creation initiated"
}

# Wait for VMs
Write-Step "Waiting for VMs to provision..."
$maxAttempts = 60
for ($i = 1; $i -le $maxAttempts; $i++) {
  $allReady = $true
  foreach ($vm in $vms) {
    $state = $null
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $state = az vm show -g $ResourceGroup -n $vm.Name --query provisioningState -o tsv 2>$null
    $ErrorActionPreference = $oldEap
    if ($state -ne "Succeeded") {
      $allReady = $false
      break
    }
  }
  if ($allReady) { break }
  Write-SubStep "Waiting for VMs... (attempt $i/$maxAttempts)"
  Start-Sleep -Seconds 10
}

Write-SubStep "All VMs ready"

$phase4Elapsed = Get-ElapsedTime -StartTime $phase4Start
Write-Log "Phase 4 complete in $phase4Elapsed"

# =============================================================================
# PHASE 5 : Validation
# =============================================================================
Write-Phase -Number 5 -Title "Validation"
$phase5Start = Get-Date

Write-Step "Waiting for routes to propagate (30s)..."
Start-Sleep -Seconds 30

Write-Step "Checking infrastructure..."
$passCount = 0
$failCount = 0

# vWAN check
$vwanState = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vwanState = az network vwan show -g $ResourceGroup -n $VwanName --query type -o tsv 2>$null
$ErrorActionPreference = $oldEap
$pass = ($vwanState -eq "Standard")
if ($pass) { $passCount++ } else { $failCount++ }
Write-Validation -Check "vWAN exists (Standard)" -Passed $pass -Details $vwanState

# Hub A check
$hubAState = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$hubAState = az network vhub show -g $ResourceGroup -n $HubAName --query provisioningState -o tsv 2>$null
$ErrorActionPreference = $oldEap
$pass = ($hubAState -eq "Succeeded")
if ($pass) { $passCount++ } else { $failCount++ }
Write-Validation -Check "Hub A provisioned" -Passed $pass -Details $hubAState

# Hub B check
$hubBState = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$hubBState = az network vhub show -g $ResourceGroup -n $HubBName --query provisioningState -o tsv 2>$null
$ErrorActionPreference = $oldEap
$pass = ($hubBState -eq "Succeeded")
if ($pass) { $passCount++ } else { $failCount++ }
Write-Validation -Check "Hub B provisioned" -Passed $pass -Details $hubBState

# Custom route table check
$rtState = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$rtState = az network vhub route-table show -g $ResourceGroup --vhub-name $HubAName -n "rt-fw-default" --query provisioningState -o tsv 2>$null
$ErrorActionPreference = $oldEap
$pass = ($rtState -eq "Succeeded")
if ($pass) { $passCount++ } else { $failCount++ }
Write-Validation -Check "Custom route table (rt-fw-default)" -Passed $pass -Details $rtState

Write-Host ""
Write-Step "Checking default route (0/0) propagation..."
Write-Host ""
Write-Host "  Expected: A1/A2 have 0/0, A3/A4/B1/B2 do NOT" -ForegroundColor Gray
Write-Host ""

$routeTests = @(
  @{ Nic = "nic-vm-a1"; Expect = $true;  Label = "Spoke A1 (rt-fw-default)" }
  @{ Nic = "nic-vm-a2"; Expect = $true;  Label = "Spoke A2 (rt-fw-default)" }
  @{ Nic = "nic-vm-a3"; Expect = $false; Label = "Spoke A3 (Default RT)" }
  @{ Nic = "nic-vm-a4"; Expect = $false; Label = "Spoke A4 (Default RT)" }
  @{ Nic = "nic-vm-b1"; Expect = $false; Label = "Spoke B1 (Hub B)" }
  @{ Nic = "nic-vm-b2"; Expect = $false; Label = "Spoke B2 (Hub B)" }
)

foreach ($t in $routeTests) {
  $routes = Get-EffectiveRoutes $t.Nic
  $has00 = Test-HasDefaultRoute $routes
  $ok = ($t.Expect -eq $has00)

  if ($ok) { $passCount++ } else { $failCount++ }

  $status = if ($has00) { "has 0/0" } else { "no 0/0" }
  $expected = if ($t.Expect) { "should have 0/0" } else { "should NOT have 0/0" }
  Write-Validation -Check "$($t.Label)" -Passed $ok -Details "$status ($expected)"
}

$phase5Elapsed = Get-ElapsedTime -StartTime $phase5Start
Write-Log "Phase 5 complete in $phase5Elapsed - $passCount passed, $failCount failed"

# =============================================================================
# PHASE 6 : Summary
# =============================================================================
Write-Phase -Number 6 -Title "Summary"

$totalElapsed = Get-ElapsedTime -StartTime $deployStartTime

# Generate outputs.json
$outputs = @{
  timestamp       = (Get-Date).ToString("o")
  resourceGroup   = $ResourceGroup
  subscriptionId  = $SubscriptionId
  location        = $Location
  vwanName        = $VwanName
  hubAName        = $HubAName
  hubBName        = $HubBName
  customRouteTable = "rt-fw-default"
  deployTime      = $totalElapsed
  validation      = @{
    passed = $passCount
    failed = $failCount
  }
}
$outputsFile = Join-Path $OutputsDir "outputs.json"
$outputs | ConvertTo-Json -Depth 10 | Set-Content -Path $outputsFile

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Green
if ($failCount -eq 0) {
  Write-Host "  DEPLOYMENT SUCCESSFUL" -ForegroundColor Green
} else {
  Write-Host "  DEPLOYMENT COMPLETED WITH ISSUES" -ForegroundColor Yellow
}
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host ""
Write-Host "  Resource Group:     $ResourceGroup" -ForegroundColor White
Write-Host "  Location:           $Location" -ForegroundColor White
Write-Host "  vWAN:               $VwanName" -ForegroundColor White
Write-Host "  Hub A:              $HubAName ($HubACidr)" -ForegroundColor White
Write-Host "  Hub B:              $HubBName ($HubBCidr)" -ForegroundColor White
Write-Host "  Custom Route Table: rt-fw-default" -ForegroundColor White
Write-Host ""
Write-Host "  Validation:         $passCount passed, $failCount failed" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Yellow" })
Write-Host "  Total time:         $totalElapsed" -ForegroundColor White
Write-Host ""
Write-Host "  Log file:           $($script:LogFile)" -ForegroundColor DarkGray
Write-Host "  Outputs:            $outputsFile" -ForegroundColor DarkGray
Write-Host ""

# Portal link
$portalUrl = "https://portal.azure.com/#@/resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/overview"
Write-Host "  Portal: $portalUrl" -ForegroundColor Cyan
Write-Host ""

Write-Host "Key Learnings:" -ForegroundColor Yellow
Write-Host "  - Spokes A1/A2 associated with rt-fw-default SEE the 0/0 route" -ForegroundColor Gray
Write-Host "  - Spokes A3/A4 on Default RT do NOT see the 0/0 from custom RT" -ForegroundColor Gray
Write-Host "  - Spokes B1/B2 on Hub B do NOT see routes from Hub A custom RT" -ForegroundColor Gray
Write-Host ""

if ($failCount -gt 0) {
  Write-Host "Some validations failed. Routes may need more time to propagate." -ForegroundColor Yellow
  Write-Host "Re-run validation: See docs/validation.md" -ForegroundColor Yellow
  exit 1
}
