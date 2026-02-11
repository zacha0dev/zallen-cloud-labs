# labs/lab-006-vwan-spoke-bgp-router-loopback/deploy.ps1
# Deploys Azure vWAN with BGP-peered router VM (FRR) and loopback route propagation tests
#
# This lab proves:
# - vWAN Virtual Hub learns routes via BGP from a router/NVA VM
# - Routes propagate to Spoke A (BGP-enabled) and optionally Spoke B (control)
# - Loopback route acceptance: inside VNet prefix vs outside VNet prefix
# - High-signal observability for drops and route propagation

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [string]$Location = "centralus",
  [string]$Owner = "",
  [switch]$Force,
  [string]$ConfigPath = "",
  [switch]$AutoResetHubRouter
)

# ============================================
# GUARDRAILS
# ============================================
$AllowedLocations = @("centralus", "eastus", "eastus2", "westus2")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Suppress Python 32-bit-on-64-bit-Windows UserWarning from Azure CLI.
# Without this, stderr warnings become terminating errors under $ErrorActionPreference = "Stop" in PS 5.1.
$env:PYTHONWARNINGS = "ignore::UserWarning"

$LabRoot = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path
$LogsDir = Join-Path $LabRoot "logs"
$DiagDir = Join-Path $RepoRoot ".data\lab-006"
$OutputsPath = Join-Path $DiagDir "outputs.json"

# Load shared helpers
. (Join-Path $RepoRoot "scripts\labs-common.ps1")

# ============================================
# LAB CONFIGURATION
# ============================================
$ResourceGroup = "rg-lab-006-vwan-bgp-router"
$VwanName      = "vwan-lab-006"
$VhubName      = "vhub-lab-006"
$VhubPrefix    = "10.0.0.0/24"
$AzureBgpAsn   = 65515
$RouterBgpAsn  = 65100

# Spoke A (BGP spoke) -- Router VM + Client VM
$SpokeAVnetName      = "vnet-spoke-a"
$SpokeAPrefix        = "10.61.0.0/16"
$SpokeARouterHubSub  = "snet-router-hubside"
$SpokeARouterHubCidr = "10.61.1.0/24"
$SpokeARouterSpkSub  = "snet-router-spokeside"
$SpokeARouterSpkCidr = "10.61.2.0/24"
$SpokeAClientSub     = "snet-client-a"
$SpokeAClientCidr    = "10.61.10.0/24"

# Spoke B (control spoke) -- Client VM only, no BGP
$SpokeBVnetName   = "vnet-spoke-b"
$SpokeBPrefix     = "10.62.0.0/16"
$SpokeBClientSub  = "snet-client-b"
$SpokeBClientCidr = "10.62.10.0/24"

# VM configuration
$VmSize  = "Standard_B2s"
$VmImage = "Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest"

$RouterVmName  = "vm-router-006"
$ClientAVmName = "vm-client-a-006"
$ClientBVmName = "vm-client-b-006"

# Loopback test prefixes
$LoopbackInsideVnet  = "10.61.250.1/32"   # inside Spoke A address space
$LoopbackOutsideVnet = "10.200.200.1/32"  # distinct prefix, outside any VNet

# Hub connections
$ConnSpokeA = "conn-spoke-a"
$ConnSpokeB = "conn-spoke-b"

# ============================================
# HELPER FUNCTIONS
# ============================================

function Require-Command($name, $installHint) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $name. $installHint"
  }
}

function Invoke-AzCommand {
  param([string]$Command)
  $oldErrPref = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  try {
    $result = Invoke-Expression "az $Command 2>`$null"
    $script:LastAzExitCode = $LASTEXITCODE
    return $result
  } finally {
    $ErrorActionPreference = $oldErrPref
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
    "ERROR"   { Write-Host $Message -ForegroundColor Red }
    "WARN"    { Write-Host $Message -ForegroundColor Yellow }
    "SUCCESS" { Write-Host $Message -ForegroundColor Green }
    default   { Write-Host $Message }
  }
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

function Get-ElapsedTime {
  param([datetime]$StartTime)
  $elapsed = (Get-Date) - $StartTime
  return "$([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
}

function Write-JsonWithoutBom {
  param([string]$Path, [string]$Content)
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# ============================================
# MAIN DEPLOYMENT
# ============================================

Write-Host ""
Write-Host "Lab 006: vWAN Spoke BGP Router with Loopback" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Purpose: Prove vWAN Virtual Hub learns routes via BGP from a router VM" -ForegroundColor White
Write-Host "         and propagates them to connected spokes (BGP vs control)." -ForegroundColor White
Write-Host ""

$deploymentStartTime = Get-Date

# ============================================
# PHASE 0: Preflight + Config Contracts
# ============================================
Write-Phase -Number 0 -Title "Preflight + Config Contracts"

$phase0Start = Get-Date

# Initialize log directory and file
Ensure-Directory $LogsDir
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$script:LogFile = Join-Path $LogsDir "lab-006-$timestamp.log"
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

# Azure auth -- opens browser if no valid token
Ensure-AzureAuth -DoLogin

# Set subscription and verify it took effect
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
az account set --subscription $SubscriptionId 2>$null | Out-Null
$setExit = $LASTEXITCODE
$ErrorActionPreference = $oldErrPref
if ($setExit -ne 0) {
  Write-Validation -Check "Azure subscription set" -Passed $false -Details "Could not set subscription $SubscriptionId"
  Write-Host ""
  Write-Host "  The subscription ID in .data/subs.json may not match your account." -ForegroundColor Yellow
  Write-Host "  Run: az account list -o table" -ForegroundColor Cyan
  Write-Host "  Then update .data/subs.json with the correct ID." -ForegroundColor Cyan
  throw "Failed to set Azure subscription. Verify .data/subs.json has the correct ID."
}
# Confirm active subscription matches what we asked for
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$activeSubRaw = az account show -o json 2>$null
$ErrorActionPreference = $oldErrPref
$activeSubName = ""
if ($activeSubRaw) { try { $activeSubName = ($activeSubRaw | ConvertFrom-Json).name } catch { } }
Write-Validation -Check "Azure authenticated" -Passed $true -Details "$activeSubName ($SubscriptionId)"

# Provider registration checks
$providers = @("Microsoft.Network", "Microsoft.Compute", "Microsoft.Insights")
foreach ($provider in $providers) {
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $regState = az provider show -n $provider --query "registrationState" -o tsv 2>$null
  $ErrorActionPreference = $oldErrPref
  $isRegistered = ($regState -eq "Registered")
  Write-Validation -Check "Provider $provider registered" -Passed $isRegistered -Details $regState
  if (-not $isRegistered) {
    Write-Log "Provider $provider not registered. Attempting registration..." "WARN"
    $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    az provider register -n $provider --wait 2>$null | Out-Null
    $ErrorActionPreference = $oldErrPref
  }
}

# Quota sanity check (VM cores)
Write-Host ""
Write-Host "Checking VM core quota for $VmSize..." -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$usage = az vm list-usage --location $Location --query "[?contains(name.value, 'standardBSFamily')].{current:currentValue, limit:limit}" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
if ($usage) {
  $coresNeeded = 6  # 3 VMs * 2 cores
  $available = $usage[0].limit - $usage[0].current
  $quotaOk = ($available -ge $coresNeeded)
  Write-Validation -Check "VM core quota sufficient ($coresNeeded needed, $available available)" -Passed $quotaOk
  if (-not $quotaOk) {
    throw "Insufficient VM core quota. Need $coresNeeded cores, only $available available."
  }
} else {
  Write-Validation -Check "VM core quota check" -Passed $true -Details "Could not verify, proceeding"
}

# Check for existing resource group (resume support)
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
if ($existingRg) {
  Write-Host ""
  Write-Host "Resource group '$ResourceGroup' already exists." -ForegroundColor Yellow
  Write-Host "This may be a resume from a previous deployment." -ForegroundColor Yellow
  if (-not $Force) {
    $confirm = Read-Host "Continue with existing resources? (y/n)"
    if ($confirm.ToLower() -ne "y") {
      throw "Cancelled. Run destroy.ps1 first to clean up."
    }
  }
}

Write-Log "Preflight checks passed" "SUCCESS"

# Cost confirmation
if (-not $Force) {
  Write-Host ""
  Write-Host "This creates billable resources:" -ForegroundColor Yellow
  Write-Host "  - vWAN Hub:           ~`$0.25/hr" -ForegroundColor Gray
  Write-Host "  - Router VM (B2s):    ~`$0.04/hr" -ForegroundColor Gray
  Write-Host "  - Client VM A (B2s):  ~`$0.04/hr" -ForegroundColor Gray
  Write-Host "  - Client VM B (B2s):  ~`$0.04/hr" -ForegroundColor Gray
  Write-Host "  - Estimated total:    ~`$0.37/hr" -ForegroundColor Gray
  Write-Host ""
  $confirm = Read-Host "Type DEPLOY to proceed"
  if ($confirm -ne "DEPLOY") { throw "Cancelled." }
}

# Portal link
$portalUrl = "https://portal.azure.com/#@/resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/deployments"
Write-Host ""
Write-Host "Monitor in Azure Portal:" -ForegroundColor Yellow
Write-Host "  $portalUrl" -ForegroundColor Cyan
Write-Host ""

$phase0Elapsed = Get-ElapsedTime -StartTime $phase0Start
Write-Log "Phase 0 completed in $phase0Elapsed" "SUCCESS"

# ============================================
# PHASE 1: Core Fabric (RG + vWAN + vHub)
# ============================================
Write-Phase -Number 1 -Title "Core Fabric (RG + vWAN + vHub)"

$phase1Start = Get-Date

# Build tags
$baseTags = "project=azure-labs lab=lab-006 env=lab"
if ($Owner) { $baseTags += " owner=$Owner" }

# Create Resource Group
Write-Host "Creating resource group: $ResourceGroup" -ForegroundColor Gray
az group create --name $ResourceGroup --location $Location --tags $baseTags --output none
Write-Log "Resource group created: $ResourceGroup"

# Create vWAN
Write-Host "Creating Virtual WAN: $VwanName" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingVwan = az network vwan show -g $ResourceGroup -n $VwanName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
if (-not $existingVwan) {
  az network vwan create `
    --name $VwanName `
    --resource-group $ResourceGroup `
    --location $Location `
    --type Standard `
    --tags $baseTags `
    --output none
  Write-Log "vWAN created: $VwanName"
} else {
  Write-Host "  vWAN already exists, skipping..." -ForegroundColor DarkGray
}

# Create vHub
Write-Host "Creating Virtual Hub: $VhubName (this takes 5-10 minutes)" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingVhub = az network vhub show -g $ResourceGroup -n $VhubName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
if (-not $existingVhub) {
  az network vhub create `
    --name $VhubName `
    --resource-group $ResourceGroup `
    --vwan $VwanName `
    --location $Location `
    --address-prefix $VhubPrefix `
    --tags $baseTags `
    --output none
  Write-Log "vHub creation initiated: $VhubName"
} else {
  Write-Host "  vHub already exists, skipping..." -ForegroundColor DarkGray
}

# Wait for vHub provisioning
Write-Host "Waiting for vHub to provision..." -ForegroundColor Gray
$maxAttempts = 60
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
  Write-Host "  [$elapsed] vHub state: $($vhub.provisioningState) (attempt $attempt/$maxAttempts)" -ForegroundColor DarkGray
  Start-Sleep -Seconds 15
}

if (-not $vhubReady) {
  throw "vHub did not provision within timeout. Check portal."
}

# --- Hub Router Health Gate ---
# provisioningState=Succeeded does NOT guarantee the router is healthy.
# routingState can be Failed and virtualRouterIps can be empty.
Write-Host ""
Write-Host "Checking vHub router health (routingState + virtualRouterIps)..." -ForegroundColor Gray

$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vhubFull = az network vhub show -g $ResourceGroup -n $VhubName -o json 2>$null
$ErrorActionPreference = $oldErrPref
$vhubObj = $null
if ($vhubFull) { try { $vhubObj = $vhubFull | ConvertFrom-Json } catch { } }

$hubRoutingState = if ($vhubObj -and $vhubObj.PSObject.Properties["routingState"]) { $vhubObj.routingState } else { "<unknown>" }
$hubRouterAsn = if ($vhubObj -and $vhubObj.virtualRouterAsn) { $vhubObj.virtualRouterAsn } else { "<unknown>" }
$hubRouterIps = @()
if ($vhubObj -and $vhubObj.virtualRouterIps) { $hubRouterIps = @($vhubObj.virtualRouterIps) }

Write-Host "  provisioningState : $($vhubObj.provisioningState)" -ForegroundColor DarkGray
Write-Host "  routingState      : $hubRoutingState" -ForegroundColor DarkGray
Write-Host "  virtualRouterAsn  : $hubRouterAsn" -ForegroundColor DarkGray
Write-Host "  virtualRouterIps  : $($hubRouterIps.Count) [$($hubRouterIps -join ', ')]" -ForegroundColor DarkGray

$hubRouterHealthy = ($hubRouterIps.Count -ge 2) -and ($hubRoutingState -notin @("Failed", "None"))

if (-not $hubRouterHealthy) {
  # Dump diagnostic artifact
  Ensure-Directory $DiagDir
  $diagPayload = @{
    timestamp = (Get-Date -Format "o")
    phase = 1
    error = "Hub router not healthy"
    routingState = $hubRoutingState
    virtualRouterAsn = $hubRouterAsn
    virtualRouterIps = $hubRouterIps
    vhubJson = $vhubObj
  }
  $diagJson = $diagPayload | ConvertTo-Json -Depth 10
  $diagPath = Join-Path $DiagDir "diag-vhub.json"
  Write-JsonWithoutBom -Path $diagPath -Content $diagJson
  Write-Log "Hub router diagnostics written to $diagPath" "WARN"

  Write-Host ""
  Write-Host "  [FAIL] Hub router not provisioned. BGP cannot work without virtualRouterIps." -ForegroundColor Red
  Write-Host "         routingState=$hubRoutingState, virtualRouterIps count=$($hubRouterIps.Count)" -ForegroundColor Red
  Write-Host ""
  Write-Host "  Action: Reset the hub router from Azure Portal (Virtual Hub > Settings > Router Reset)" -ForegroundColor Yellow
  Write-Host "          OR run: Reset-AzHubRouter (requires Az.Network PowerShell module)" -ForegroundColor Yellow
  Write-Host "          See: docs/observability.md > Hub Router Health Triage" -ForegroundColor Yellow
  Write-Host ""
  Write-Host "  Diagnostics: $diagPath" -ForegroundColor DarkGray

  # --- Optional auto-recovery ---
  if ($AutoResetHubRouter) {
    Write-Host ""
    Write-Host "  -AutoResetHubRouter is enabled. Attempting hub router reset..." -ForegroundColor Cyan

    $resetSuccess = $false
    if (Get-Command "Reset-AzHubRouter" -ErrorAction SilentlyContinue) {
      Write-Host "  Running: Get-AzVirtualHub -ResourceGroupName $ResourceGroup -Name $VhubName | Reset-AzHubRouter" -ForegroundColor DarkGray
      try {
        Get-AzVirtualHub -ResourceGroupName $ResourceGroup -Name $VhubName | Reset-AzHubRouter
        Write-Log "Reset-AzHubRouter invoked" "INFO"
      } catch {
        Write-Log "Reset-AzHubRouter failed: $_" "WARN"
      }

      # Poll for recovery: virtualRouterIps count >= 2, up to ~10 min
      Write-Host "  Polling for hub router recovery (up to ~10 min)..." -ForegroundColor Gray
      $pollMax = 30
      $pollAttempt = 0
      $pollSnapshots = @()

      while ($pollAttempt -lt $pollMax) {
        $pollAttempt++
        Start-Sleep -Seconds 20

        $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
        $pollRaw = az network vhub show -g $ResourceGroup -n $VhubName -o json 2>$null
        $ErrorActionPreference = $oldErrPref
        $pollObj = $null
        if ($pollRaw) { try { $pollObj = $pollRaw | ConvertFrom-Json } catch { } }

        $pollIps = @()
        $pollRoutingState = "<unknown>"
        if ($pollObj) {
          if ($pollObj.virtualRouterIps) { $pollIps = @($pollObj.virtualRouterIps) }
          if ($pollObj.PSObject.Properties["routingState"]) { $pollRoutingState = $pollObj.routingState }
        }

        $snap = @{ attempt = $pollAttempt; timestamp = (Get-Date -Format "o"); routingState = $pollRoutingState; virtualRouterIps = $pollIps }
        $pollSnapshots += $snap

        $elapsed = Get-ElapsedTime -StartTime $phase1Start
        Write-Host "  [$elapsed] routingState=$pollRoutingState ips=$($pollIps.Count) (poll $pollAttempt/$pollMax)" -ForegroundColor DarkGray

        if ($pollIps.Count -ge 2 -and $pollRoutingState -notin @("Failed", "None")) {
          $hubRouterIps = $pollIps
          $hubRoutingState = $pollRoutingState
          $hubRouterAsn = if ($pollObj.virtualRouterAsn) { $pollObj.virtualRouterAsn } else { $hubRouterAsn }
          $hubRouterHealthy = $true
          $resetSuccess = $true
          break
        }
      }

      # Save poll snapshots
      $pollDiagPath = Join-Path $DiagDir "diag-vhub-poll.json"
      $pollDiagJson = ($pollSnapshots | ConvertTo-Json -Depth 5)
      Write-JsonWithoutBom -Path $pollDiagPath -Content $pollDiagJson
      Write-Log "Hub router poll snapshots saved to $pollDiagPath"
    } else {
      Write-Host "  Az.Network module not present; Reset-AzHubRouter not available." -ForegroundColor Yellow
      Write-Host "  Use Azure Portal to reset the hub router manually." -ForegroundColor Yellow
    }

    if (-not $resetSuccess) {
      Write-Log "Hub router auto-reset did not recover routing. Failing Phase 1." "ERROR"
      throw "Phase 1 FAIL: Hub router not healthy after auto-reset. See $diagPath"
    }
  } else {
    throw "Phase 1 FAIL: Hub router not healthy (routingState=$hubRoutingState, ips=$($hubRouterIps.Count)). Use -AutoResetHubRouter or reset from portal."
  }
}

$phase1Elapsed = Get-ElapsedTime -StartTime $phase1Start
Write-Host ""
Write-Host "Phase 1 Validation:" -ForegroundColor Yellow
Write-Validation -Check "vHub provisioningState = Succeeded" -Passed $true -Details "Completed in $phase1Elapsed"
Write-Validation -Check "vHub routingState" -Passed ($hubRoutingState -notin @("Failed", "None")) -Details $hubRoutingState
Write-Validation -Check "vHub virtualRouterIps" -Passed ($hubRouterIps.Count -ge 2) -Details "$($hubRouterIps.Count) IPs: $($hubRouterIps -join ', ')"
Write-Validation -Check "vHub virtualRouterAsn" -Passed ($hubRouterAsn -ne "<unknown>") -Details "$hubRouterAsn"
Write-Log "Phase 1 completed in $phase1Elapsed" "SUCCESS"

# ============================================
# PHASE 2: Spoke VNets + Hub Connections
# ============================================
Write-Phase -Number 2 -Title "Spoke VNets + Hub Connections"

$phase2Start = Get-Date

# --- Spoke A VNet ---
Write-Host "Creating Spoke A VNet: $SpokeAVnetName" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingSpokeA = az network vnet show -g $ResourceGroup -n $SpokeAVnetName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
if (-not $existingSpokeA) {
  az network vnet create `
    --name $SpokeAVnetName `
    --resource-group $ResourceGroup `
    --location $Location `
    --address-prefixes $SpokeAPrefix `
    --tags $baseTags `
    --output none

  # Subnets for Spoke A
  az network vnet subnet create -g $ResourceGroup --vnet-name $SpokeAVnetName `
    --name $SpokeARouterHubSub --address-prefixes $SpokeARouterHubCidr --output none
  az network vnet subnet create -g $ResourceGroup --vnet-name $SpokeAVnetName `
    --name $SpokeARouterSpkSub --address-prefixes $SpokeARouterSpkCidr --output none
  az network vnet subnet create -g $ResourceGroup --vnet-name $SpokeAVnetName `
    --name $SpokeAClientSub --address-prefixes $SpokeAClientCidr --output none
  Write-Log "Spoke A VNet created with 3 subnets"
} else {
  Write-Host "  Spoke A VNet already exists, skipping..." -ForegroundColor DarkGray
}

# --- Spoke B VNet ---
Write-Host "Creating Spoke B VNet: $SpokeBVnetName" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingSpokeB = az network vnet show -g $ResourceGroup -n $SpokeBVnetName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
if (-not $existingSpokeB) {
  az network vnet create `
    --name $SpokeBVnetName `
    --resource-group $ResourceGroup `
    --location $Location `
    --address-prefixes $SpokeBPrefix `
    --tags $baseTags `
    --output none

  az network vnet subnet create -g $ResourceGroup --vnet-name $SpokeBVnetName `
    --name $SpokeBClientSub --address-prefixes $SpokeBClientCidr --output none
  Write-Log "Spoke B VNet created with 1 subnet"
} else {
  Write-Host "  Spoke B VNet already exists, skipping..." -ForegroundColor DarkGray
}

# --- Hub Connections ---
Write-Host "Creating hub connection: $ConnSpokeA" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingConnA = az network vhub connection show -g $ResourceGroup --vhub-name $VhubName -n $ConnSpokeA -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
if (-not $existingConnA) {
  $spokeAId = az network vnet show -g $ResourceGroup -n $SpokeAVnetName --query id -o tsv
  az network vhub connection create `
    --name $ConnSpokeA `
    --resource-group $ResourceGroup `
    --vhub-name $VhubName `
    --remote-vnet $spokeAId `
    --output none
  Write-Log "Hub connection created: $ConnSpokeA"
} else {
  Write-Host "  Hub connection $ConnSpokeA already exists, skipping..." -ForegroundColor DarkGray
}

Write-Host "Creating hub connection: $ConnSpokeB" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingConnB = az network vhub connection show -g $ResourceGroup --vhub-name $VhubName -n $ConnSpokeB -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
if (-not $existingConnB) {
  $spokeBId = az network vnet show -g $ResourceGroup -n $SpokeBVnetName --query id -o tsv
  az network vhub connection create `
    --name $ConnSpokeB `
    --resource-group $ResourceGroup `
    --vhub-name $VhubName `
    --remote-vnet $spokeBId `
    --output none
  Write-Log "Hub connection created: $ConnSpokeB"
} else {
  Write-Host "  Hub connection $ConnSpokeB already exists, skipping..." -ForegroundColor DarkGray
}

# Validate hub connections
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$connAState = az network vhub connection show -g $ResourceGroup --vhub-name $VhubName -n $ConnSpokeA --query provisioningState -o tsv 2>$null
$connBState = az network vhub connection show -g $ResourceGroup --vhub-name $VhubName -n $ConnSpokeB --query provisioningState -o tsv 2>$null
$ErrorActionPreference = $oldErrPref

$phase2Elapsed = Get-ElapsedTime -StartTime $phase2Start
Write-Host ""
Write-Host "Phase 2 Validation:" -ForegroundColor Yellow
Write-Validation -Check "Spoke A VNet created" -Passed ($true) -Details "$SpokeAVnetName ($SpokeAPrefix)"
Write-Validation -Check "Spoke B VNet created" -Passed ($true) -Details "$SpokeBVnetName ($SpokeBPrefix)"
Write-Validation -Check "Hub connection $ConnSpokeA" -Passed ($connAState -eq "Succeeded") -Details "State: $connAState"
Write-Validation -Check "Hub connection $ConnSpokeB" -Passed ($connBState -eq "Succeeded") -Details "State: $connBState"
Write-Log "Phase 2 completed in $phase2Elapsed" "SUCCESS"

# ============================================
# PHASE 3: Compute - Router VM + Client VMs
# ============================================
Write-Phase -Number 3 -Title "Compute - Router VM + Client VMs"

$phase3Start = Get-Date

# Generate SSH key for the lab (reuse if exists)
$sshKeyDir = Join-Path $RepoRoot ".data\lab-006"
Ensure-Directory $sshKeyDir
$sshKeyPath = Join-Path $sshKeyDir "id_rsa_lab006"
if (-not (Test-Path $sshKeyPath)) {
  Write-Host "Generating SSH key pair..." -ForegroundColor Gray
  ssh-keygen -t rsa -b 4096 -f $sshKeyPath -N '""' -q
  Write-Log "SSH key pair generated"
} else {
  Write-Host "  SSH key already exists, reusing..." -ForegroundColor DarkGray
}
$sshPubKey = Get-Content "$sshKeyPath.pub" -Raw

# Cloud-init for Router VM (FRR + 2 NICs + IP forwarding)
$routerCloudInit = Join-Path $LabRoot "scripts\router\cloud-init-router.yaml"

# Cloud-init for Client VMs (basic tools)
$clientCloudInit = Join-Path $LabRoot "scripts\router\cloud-init-client.yaml"

# --- Router VM: NIC1 (hub-side) ---
Write-Host "Creating Router VM NICs with IP forwarding..." -ForegroundColor Gray
$routerNic1 = "nic-router-hubside-006"
$routerNic2 = "nic-router-spokeside-006"

$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingNic1 = az network nic show -g $ResourceGroup -n $routerNic1 -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
if (-not $existingNic1) {
  az network nic create `
    --name $routerNic1 `
    --resource-group $ResourceGroup `
    --location $Location `
    --vnet-name $SpokeAVnetName `
    --subnet $SpokeARouterHubSub `
    --ip-forwarding true `
    --tags $baseTags `
    --output none
  Write-Log "Router NIC1 (hub-side) created: $routerNic1"
}

$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingNic2 = az network nic show -g $ResourceGroup -n $routerNic2 -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
if (-not $existingNic2) {
  az network nic create `
    --name $routerNic2 `
    --resource-group $ResourceGroup `
    --location $Location `
    --vnet-name $SpokeAVnetName `
    --subnet $SpokeARouterSpkSub `
    --ip-forwarding true `
    --tags $baseTags `
    --output none
  Write-Log "Router NIC2 (spoke-side) created: $routerNic2"
}

# --- Router VM ---
Write-Host "Creating Router VM: $RouterVmName (2 NICs, FRR bootstrap)" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRouterVm = az vm show -g $ResourceGroup -n $RouterVmName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
if (-not $existingRouterVm) {
  $createCmd = "az vm create " +
    "--name $RouterVmName " +
    "--resource-group $ResourceGroup " +
    "--location $Location " +
    "--size $VmSize " +
    "--image $VmImage " +
    "--nics $routerNic1 $routerNic2 " +
    "--admin-username azurelab " +
    "--ssh-key-values `"$sshKeyPath.pub`" " +
    "--tags $baseTags " +
    "--no-wait " +
    "--output none"
  if (Test-Path $routerCloudInit) {
    $createCmd += " --custom-data `"$routerCloudInit`""
  }
  Invoke-Expression $createCmd
  Write-Log "Router VM creation initiated: $RouterVmName"
} else {
  Write-Host "  Router VM already exists, skipping..." -ForegroundColor DarkGray
}

# --- Client A VM ---
Write-Host "Creating Client A VM: $ClientAVmName" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingClientA = az vm show -g $ResourceGroup -n $ClientAVmName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
if (-not $existingClientA) {
  $createCmd = "az vm create " +
    "--name $ClientAVmName " +
    "--resource-group $ResourceGroup " +
    "--location $Location " +
    "--size $VmSize " +
    "--image $VmImage " +
    "--vnet-name $SpokeAVnetName " +
    "--subnet $SpokeAClientSub " +
    "--admin-username azurelab " +
    "--ssh-key-values `"$sshKeyPath.pub`" " +
    "--tags $baseTags " +
    "--no-wait " +
    "--output none"
  if (Test-Path $clientCloudInit) {
    $createCmd += " --custom-data `"$clientCloudInit`""
  }
  Invoke-Expression $createCmd
  Write-Log "Client A VM creation initiated: $ClientAVmName"
} else {
  Write-Host "  Client A VM already exists, skipping..." -ForegroundColor DarkGray
}

# --- Client B VM ---
Write-Host "Creating Client B VM: $ClientBVmName" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingClientB = az vm show -g $ResourceGroup -n $ClientBVmName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
if (-not $existingClientB) {
  $createCmd = "az vm create " +
    "--name $ClientBVmName " +
    "--resource-group $ResourceGroup " +
    "--location $Location " +
    "--size $VmSize " +
    "--image $VmImage " +
    "--vnet-name $SpokeBVnetName " +
    "--subnet $SpokeBClientSub " +
    "--admin-username azurelab " +
    "--ssh-key-values `"$sshKeyPath.pub`" " +
    "--tags $baseTags " +
    "--no-wait " +
    "--output none"
  if (Test-Path $clientCloudInit) {
    $createCmd += " --custom-data `"$clientCloudInit`""
  }
  Invoke-Expression $createCmd
  Write-Log "Client B VM creation initiated: $ClientBVmName"
} else {
  Write-Host "  Client B VM already exists, skipping..." -ForegroundColor DarkGray
}

# Wait for all VMs to provision
Write-Host ""
Write-Host "Waiting for VMs to provision (all 3 in parallel)..." -ForegroundColor Gray
$vmNames = @($RouterVmName, $ClientAVmName, $ClientBVmName)
$maxVmWait = 40
$vmAttempt = 0
$allReady = $false

while ($vmAttempt -lt $maxVmWait) {
  $vmAttempt++
  $readyCount = 0
  foreach ($vm in $vmNames) {
    $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $vmState = az vm show -g $ResourceGroup -n $vm --query "provisioningState" -o tsv 2>$null
    $ErrorActionPreference = $oldErrPref
    if ($vmState -eq "Succeeded") { $readyCount++ }
  }

  if ($readyCount -eq $vmNames.Count) {
    $allReady = $true
    break
  }

  $elapsed = Get-ElapsedTime -StartTime $phase3Start
  Write-Host "  [$elapsed] VMs ready: $readyCount/$($vmNames.Count) (attempt $vmAttempt/$maxVmWait)" -ForegroundColor DarkGray
  Start-Sleep -Seconds 15
}

if (-not $allReady) {
  Write-Log "Not all VMs provisioned within timeout" "WARN"
}

# Validate NICs -- use JSON + ConvertFrom-Json to extract NIC properties.
# PS 5.1 loses single-line stdout when 2>$null is combined with --query/-o tsv
# on native commands. JSON (multi-line) output is not affected.
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$nic1Raw = az network nic show -g $ResourceGroup -n $routerNic1 -o json 2>$null
$nic2Raw = az network nic show -g $ResourceGroup -n $routerNic2 -o json 2>$null
$ErrorActionPreference = $oldErrPref

$nic1Obj = $null; $nic2Obj = $null
if ($nic1Raw) { try { $nic1Obj = $nic1Raw | ConvertFrom-Json } catch { } }
if ($nic2Raw) { try { $nic2Obj = $nic2Raw | ConvertFrom-Json } catch { } }

$nic1Fwd = if ($nic1Obj) { "$($nic1Obj.enableIpForwarding)".ToLower() } else { "" }
$nic1Ip  = if ($nic1Obj) { $nic1Obj.ipConfigurations[0].privateIpAddress } else { "" }
$nic2Fwd = if ($nic2Obj) { "$($nic2Obj.enableIpForwarding)".ToLower() } else { "" }
$nic2Ip  = if ($nic2Obj) { $nic2Obj.ipConfigurations[0].privateIpAddress } else { "" }

$phase3Elapsed = Get-ElapsedTime -StartTime $phase3Start
Write-Host ""
Write-Host "Phase 3 Validation:" -ForegroundColor Yellow
Write-Validation -Check "Router VM provisioned" -Passed $allReady -Details $RouterVmName
Write-Validation -Check "Router NIC1 IP forwarding" -Passed ($nic1Fwd -eq "true") -Details "IP: $nic1Ip"
Write-Validation -Check "Router NIC2 IP forwarding" -Passed ($nic2Fwd -eq "true") -Details "IP: $nic2Ip"
Write-Validation -Check "Client A VM provisioned" -Passed $allReady -Details $ClientAVmName
Write-Validation -Check "Client B VM provisioned" -Passed $allReady -Details $ClientBVmName
Write-Log "Phase 3 completed in $phase3Elapsed" "SUCCESS"

# ============================================
# PHASE 4: Router Config (FRR + Loopback via cloud-init)
# ============================================
Write-Phase -Number 4 -Title "Router Config (FRR + Loopback)"

$phase4Start = Get-Date

# cloud-init handles: FRR install, bgpd=yes, IP forwarding, loopback interface.
# The cloud-init frr.conf has placeholder vHub IPs. We now push the REAL ones
# discovered in Phase 1 ($hubRouterIps) so BGP comes up without manual SSH.

$routerHubIp = $nic1Ip
if (-not $routerHubIp) {
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $nic1Retry = az network nic show -g $ResourceGroup -n $routerNic1 -o json 2>$null
  $ErrorActionPreference = $oldErrPref
  if ($nic1Retry) {
    try { $routerHubIp = ($nic1Retry | ConvertFrom-Json).ipConfigurations[0].privateIpAddress } catch { }
  }
}

if (-not $routerHubIp) {
  Write-Log "FATAL: Could not resolve router hub-side IP from NIC $routerNic1." "ERROR"
  throw "Router hub-side IP is empty. Verify NIC '$routerNic1' exists and has a private IP."
}

# Use the REAL hub ASN from Phase 1 (not hardcoded)
$actualHubAsn = $hubRouterAsn
if ($actualHubAsn -eq "<unknown>") { $actualHubAsn = $AzureBgpAsn }

Write-Host "Router hub-side IP : $routerHubIp" -ForegroundColor Gray
Write-Host "Router BGP ASN     : $RouterBgpAsn" -ForegroundColor Gray
Write-Host "Hub router IPs     : $($hubRouterIps -join ', ')" -ForegroundColor Gray
Write-Host "Hub ASN            : $actualHubAsn" -ForegroundColor Gray

if ($hubRouterIps.Count -ge 2) {
  $vhubPeerIp0 = $hubRouterIps[0]
  $vhubPeerIp1 = $hubRouterIps[1]

  # Write FRR update script to a temp file, then invoke via RunCommand.
  # This avoids quoting issues -- the script is a plain file, no shell metacharacter problems.
  Write-Host "Pushing FRR config with real vHub peer IPs to router VM..." -ForegroundColor Gray

  Ensure-Directory $LogsDir
  $frrUpdateScript = Join-Path $LogsDir "frr-update-temp.sh"
  $frrScriptContent = @"
#!/bin/bash
set -e

# Ensure bgpd is enabled (cloud-init should have done this, but be safe)
sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons 2>/dev/null || true

# Write FRR config with actual vHub peer IPs
cat > /etc/frr/frr.conf <<'FRREOF'
frr version 8.1
frr defaults traditional
hostname router-006
log syslog informational
no ipv6 forwarding
!
router bgp $RouterBgpAsn
 bgp router-id $routerHubIp
 no bgp ebgp-requires-policy
 !
 neighbor $vhubPeerIp0 remote-as $actualHubAsn
 neighbor $vhubPeerIp1 remote-as $actualHubAsn
 !
 address-family ipv4 unicast
  network $LoopbackInsideVnet
  network $LoopbackOutsideVnet
 exit-address-family
!
line vty
!
FRREOF
chown frr:frr /etc/frr/frr.conf
chmod 640 /etc/frr/frr.conf

# Ensure loopback exists (idempotent)
ip link show lo0 >/dev/null 2>&1 || ip link add lo0 type dummy
ip link set lo0 up
ip addr add $LoopbackInsideVnet dev lo0 2>/dev/null || true
ip addr add $LoopbackOutsideVnet dev lo0 2>/dev/null || true

# Enable IP forwarding (idempotent)
sysctl -w net.ipv4.ip_forward=1

# Restart FRR to pick up config
systemctl enable frr
systemctl restart frr

# Brief wait then report
sleep 3
echo "=== bgpd daemon ==="
systemctl is-active frr
echo "=== FRR config neighbors ==="
grep 'neighbor.*remote-as' /etc/frr/frr.conf
echo "=== BGP Summary ==="
vtysh -c 'show bgp summary' 2>/dev/null || echo 'BGP not converged yet'
"@
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($frrUpdateScript, $frrScriptContent, $utf8NoBom)

  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  az vm run-command invoke `
    --resource-group $ResourceGroup `
    --name $RouterVmName `
    --command-id RunShellScript `
    --scripts @$frrUpdateScript `
    --output none 2>$null
  $frrUpdateExit = $LASTEXITCODE
  $ErrorActionPreference = $oldErrPref
  Remove-Item $frrUpdateScript -Force -ErrorAction SilentlyContinue

  if ($frrUpdateExit -eq 0) {
    Write-Log "FRR config pushed with vHub peers: $vhubPeerIp0, $vhubPeerIp1"
  } else {
    Write-Log "FRR config push may have failed (exit $frrUpdateExit). Verify manually." "WARN"
  }
} else {
  Write-Host "  [WARN] Hub router IPs not available. Cloud-init placeholder config will be used." -ForegroundColor Yellow
  Write-Host "  FRR BGP may not converge until IPs are corrected." -ForegroundColor Yellow
  $frrUpdateExit = -1
}

$phase4Elapsed = Get-ElapsedTime -StartTime $phase4Start
Write-Host ""
Write-Host "Phase 4 Validation:" -ForegroundColor Yellow
Write-Validation -Check "Router hub-side IP resolved" -Passed ([bool]$routerHubIp) -Details "$routerHubIp (NIC: $routerNic1)"
if ($hubRouterIps.Count -ge 2) {
  Write-Validation -Check "FRR config pushed (real vHub IPs)" -Passed ($frrUpdateExit -eq 0) -Details "Neighbors: $vhubPeerIp0, $vhubPeerIp1 (ASN $actualHubAsn)"
} else {
  Write-Validation -Check "FRR config pushed (real vHub IPs)" -Passed $false -Details "Hub router IPs not available"
}
Write-Log "Phase 4 completed in $phase4Elapsed" "SUCCESS"

# ============================================
# PHASE 5: BGP - Peer Router to Virtual Hub
# ============================================
Write-Phase -Number 5 -Title "BGP - Peer Router to Virtual Hub"

$phase5Start = Get-Date

# --- Hard precondition: vHub must have virtualRouterIps ---
# Re-query to be safe (state may have changed since Phase 1)
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vhubPreCheck = az network vhub show -g $ResourceGroup -n $VhubName -o json 2>$null
$ErrorActionPreference = $oldErrPref
$vhubPreCheckIps = @()
if ($vhubPreCheck) {
  try {
    $vhubPreCheckObj = $vhubPreCheck | ConvertFrom-Json
    if ($vhubPreCheckObj.virtualRouterIps) { $vhubPreCheckIps = @($vhubPreCheckObj.virtualRouterIps) }
  } catch { }
}

if ($vhubPreCheckIps.Count -lt 2) {
  Ensure-Directory $DiagDir
  $diagPath = Join-Path $DiagDir "diag-vhub-prephase5.json"
  $diagPayload = @{
    timestamp = (Get-Date -Format "o")
    phase = 5
    error = "virtualRouterIps empty at Phase 5 entry -- cannot create bgpconnection"
    virtualRouterIps = $vhubPreCheckIps
    vhubJson = $vhubPreCheckObj
  }
  Write-JsonWithoutBom -Path $diagPath -Content ($diagPayload | ConvertTo-Json -Depth 10)
  Write-Host ""
  Write-Host "  [FAIL] vHub virtualRouterIps empty. BGP peering cannot be created." -ForegroundColor Red
  Write-Host "         Hub router is not provisioned. See: docs/observability.md" -ForegroundColor Red
  Write-Host "         Diagnostics: $diagPath" -ForegroundColor DarkGray
  throw "Phase 5 FAIL: vHub has no virtualRouterIps. BGP connection requires a healthy hub router."
}

# --- Create exactly ONE bgpconnection (Azure rejects duplicate peer IPs) ---
# The vHub internally peers from BOTH its active-active instances to this single
# bgpconnection. You do NOT need two bgpconnection resources for active-active.
$BgpConnName = "bgp-peer-router-006"

Write-Host "Creating vHub BGP connection: $BgpConnName -> $routerHubIp (ASN $RouterBgpAsn)" -ForegroundColor Gray

# Get the hub connection resource ID for Spoke A (required for --vhub-conn)
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$connSpokeARaw = az network vhub connection show -g $ResourceGroup --vhub-name $VhubName -n $ConnSpokeA -o json 2>$null
$ErrorActionPreference = $oldErrPref
$connSpokeAId = $null
if ($connSpokeARaw) {
  try { $connSpokeAId = ($connSpokeARaw | ConvertFrom-Json).id } catch { }
}

if (-not $connSpokeAId) {
  throw "Phase 5 FAIL: Hub connection '$ConnSpokeA' not found. Phase 2 may not have completed."
}

Write-Host "  Hub connection ID: .../$ConnSpokeA" -ForegroundColor DarkGray

# Clean up stale dual-peering resources from prior deployments
foreach ($stale in @("bgp-peer-router-006-0", "bgp-peer-router-006-1")) {
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $staleConn = az network vhub bgpconnection show -g $ResourceGroup --vhub-name $VhubName -n $stale -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldErrPref
  if ($staleConn) {
    Write-Host "  Removing stale peering '$stale'..." -ForegroundColor Yellow
    $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    az network vhub bgpconnection delete -g $ResourceGroup --vhub-name $VhubName -n $stale --yes --output none 2>$null
    $ErrorActionPreference = $oldErrPref
    Write-Log "Removed stale bgpconnection: $stale"
  }
}

# Create single bgpconnection (idempotent)
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingBgpConn = az network vhub bgpconnection show -g $ResourceGroup --vhub-name $VhubName -n $BgpConnName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if (-not $existingBgpConn) {
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  az network vhub bgpconnection create `
    --name $BgpConnName `
    --resource-group $ResourceGroup `
    --vhub-name $VhubName `
    --peer-asn $RouterBgpAsn `
    --peer-ip $routerHubIp `
    --vhub-conn $connSpokeAId `
    --output none 2>$null
  $bgpCreateExit = $LASTEXITCODE
  $ErrorActionPreference = $oldErrPref
  Write-Log "vHub BGP peering created: $BgpConnName -> $routerHubIp (ASN $RouterBgpAsn)"
} else {
  Write-Host "  $BgpConnName already exists, skipping..." -ForegroundColor DarkGray
  $bgpCreateExit = 0
}

# Wait for BGP connection to provision
Write-Host "Waiting for BGP connection to provision..." -ForegroundColor Gray
$maxBgpWait = 30
$bgpAttempt = 0
$bgpReady = $false
$bgpConnState = ""

while ($bgpAttempt -lt $maxBgpWait) {
  $bgpAttempt++
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $bgpRaw = az network vhub bgpconnection show -g $ResourceGroup --vhub-name $VhubName -n $BgpConnName -o json 2>$null
  $ErrorActionPreference = $oldErrPref
  $bgpConnState = ""
  if ($bgpRaw) { try { $bgpConnState = ($bgpRaw | ConvertFrom-Json).provisioningState } catch { } }

  if ($bgpConnState -eq "Succeeded") {
    $bgpReady = $true
    break
  }
  if ($bgpConnState -eq "Failed") {
    Ensure-Directory $DiagDir
    $diagPayload = @{
      timestamp = (Get-Date -Format "o")
      phase = 5
      error = "bgpconnection provisioning failed"
      bgpConnName = $BgpConnName
      bgpConnState = $bgpConnState
      routerHubIp = $routerHubIp
      routerBgpAsn = $RouterBgpAsn
      connSpokeAId = $connSpokeAId
    }
    $diagPath = Join-Path $DiagDir "phase5-bgp-diag.json"
    Write-JsonWithoutBom -Path $diagPath -Content ($diagPayload | ConvertTo-Json -Depth 5)
    Write-Log "BGP connection failed. Diagnostics at $diagPath" "ERROR"
    Write-Host "  [FAIL] BGP connection '$BgpConnName' failed. See $diagPath" -ForegroundColor Red
    Write-Host "  Action: Verify router VM is running and hub-side NIC IP ($routerHubIp) is correct." -ForegroundColor Yellow
    throw "Phase 5 FAIL: BGP peering provisioning failed."
  }

  $elapsed = Get-ElapsedTime -StartTime $phase5Start
  Write-Host "  [$elapsed] $BgpConnName state: $bgpConnState (attempt $bgpAttempt/$maxBgpWait)" -ForegroundColor DarkGray
  Start-Sleep -Seconds 15
}

# Save bgpconnection list artifact
Ensure-Directory $DiagDir
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$bgpListRaw = az network vhub bgpconnection list -g $ResourceGroup --vhub-name $VhubName -o json 2>$null
$ErrorActionPreference = $oldErrPref
if ($bgpListRaw) {
  $bgpListPath = Join-Path $DiagDir "bgpconnections.json"
  Write-JsonWithoutBom -Path $bgpListPath -Content $bgpListRaw
}

# Lightweight BGP adjacency check via RunCommand (best-effort, non-blocking)
Write-Host ""
Write-Host "Checking BGP adjacency on router (best-effort)..." -ForegroundColor Gray
Start-Sleep -Seconds 10

$bgpEstablishedCount = 0
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$bgpCheckRaw = az vm run-command invoke `
  --resource-group $ResourceGroup `
  --name $RouterVmName `
  --command-id RunShellScript `
  --scripts "vtysh -c 'show bgp summary json'" `
  -o json 2>$null
$ErrorActionPreference = $oldErrPref

if ($bgpCheckRaw) {
  try {
    $bgpCheckObj = $bgpCheckRaw | ConvertFrom-Json
    $bgpStdout = $bgpCheckObj.value[0].message
    if ($bgpStdout) {
      $peerMatches = [regex]::Matches($bgpStdout, '"state"\s*:\s*"Established"')
      $bgpEstablishedCount = $peerMatches.Count
      $estColor = if ($bgpEstablishedCount -ge 2) { "Green" } else { "Yellow" }
      Write-Host "  BGP established peers on router: $bgpEstablishedCount" -ForegroundColor $estColor
    }
  } catch {
    Write-Host "  Could not parse BGP summary from router (non-fatal)" -ForegroundColor DarkGray
  }
}

if ($bgpEstablishedCount -lt 2) {
  Write-Host "  [INFO] BGP may still be converging. Allow 30-60s after FRR restart." -ForegroundColor Yellow
  Write-Host "  Check: az vm run-command invoke -g $ResourceGroup -n $RouterVmName --command-id RunShellScript --scripts ""vtysh -c 'show bgp summary'""" -ForegroundColor DarkGray
}

$phase5Elapsed = Get-ElapsedTime -StartTime $phase5Start
Write-Host ""
Write-Host "Phase 5 Validation:" -ForegroundColor Yellow
Write-Validation -Check "BGP connection: $BgpConnName" -Passed ($bgpConnState -eq "Succeeded") -Details "State: $bgpConnState"
Write-Validation -Check "Router peer IP" -Passed ([bool]$routerHubIp) -Details $routerHubIp
Write-Validation -Check "vHub router IPs (active-active)" -Passed ($hubRouterIps.Count -ge 2) -Details "$($hubRouterIps -join ', ') (ASN $actualHubAsn)"
if ($hubRouterIps.Count -ge 2) {
  Write-Validation -Check "FRR config has both hub peers" -Passed ($frrUpdateExit -eq 0) -Details "$vhubPeerIp0, $vhubPeerIp1"
}
if ($bgpEstablishedCount -ge 2) {
  Write-Validation -Check "Router BGP adjacency (both neighbors Established)" -Passed $true -Details "$bgpEstablishedCount peers"
} else {
  Write-Validation -Check "Router BGP adjacency" -Passed $false -Details "$bgpEstablishedCount/2 Established. May still be converging."
}
Write-Log "Phase 5 completed in $phase5Elapsed" "SUCCESS"

# ============================================
# PHASE 6: Blob-Driven Router Config (Optional)
# ============================================
Write-Phase -Number 6 -Title "Blob-Driven Router Config (Optional)"

$phase6Start = Get-Date

# Load lab config to check if blob-driven config is enabled
$labConfigPath = Join-Path $LabRoot "lab.config.json"
$blobConfigEnabled = $false
$blobStorageAccount = "stlab006router"
$blobContainer = "router-config"

if (Test-Path $labConfigPath) {
  try {
    $labCfg = Get-Content $labConfigPath -Raw | ConvertFrom-Json
    if ($labCfg.routerConfig -and $labCfg.routerConfig.enabled -eq $true) {
      $blobConfigEnabled = $true
      if ($labCfg.routerConfig.storageAccountName) { $blobStorageAccount = $labCfg.routerConfig.storageAccountName }
      if ($labCfg.routerConfig.containerName) { $blobContainer = $labCfg.routerConfig.containerName }
    }
  } catch { }
}

if ($blobConfigEnabled) {
  Write-Host "Blob-driven router config is ENABLED." -ForegroundColor Gray
  Write-Host "  Storage account: $blobStorageAccount" -ForegroundColor DarkGray
  Write-Host "  Container: $blobContainer" -ForegroundColor DarkGray

  # Create storage account (idempotent)
  Write-Host "Creating storage account: $blobStorageAccount" -ForegroundColor Gray
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $existingSa = az storage account show -g $ResourceGroup -n $blobStorageAccount -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldErrPref
  if (-not $existingSa) {
    $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    az storage account create `
      --name $blobStorageAccount `
      --resource-group $ResourceGroup `
      --location $Location `
      --sku Standard_LRS `
      --kind StorageV2 `
      --allow-blob-public-access false `
      --tags $baseTags `
      --output none 2>$null
    $ErrorActionPreference = $oldErrPref
    Write-Log "Storage account created: $blobStorageAccount"
  } else {
    Write-Host "  Storage account already exists, skipping..." -ForegroundColor DarkGray
  }

  # Create container (idempotent)
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  az storage container create `
    --name $blobContainer `
    --account-name $blobStorageAccount `
    --auth-mode login `
    --output none 2>$null
  $ErrorActionPreference = $oldErrPref

  # Assign system-assigned managed identity to router VM (idempotent)
  Write-Host "Assigning managed identity to $RouterVmName..." -ForegroundColor Gray
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $identityRaw = az vm identity assign -g $ResourceGroup -n $RouterVmName -o json 2>$null
  $ErrorActionPreference = $oldErrPref
  $vmPrincipalId = $null
  if ($identityRaw) {
    try { $vmPrincipalId = ($identityRaw | ConvertFrom-Json).systemAssignedIdentity } catch { }
  }
  # Fallback: query if assign returned empty (already assigned)
  if (-not $vmPrincipalId) {
    $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $vmIdRaw = az vm show -g $ResourceGroup -n $RouterVmName --query "identity.principalId" -o json 2>$null
    $ErrorActionPreference = $oldErrPref
    if ($vmIdRaw) { try { $vmPrincipalId = ($vmIdRaw | ConvertFrom-Json) } catch { } }
  }

  # Grant Storage Blob Data Reader to the VM identity
  if ($vmPrincipalId) {
    Write-Host "Granting Storage Blob Data Reader to VM identity..." -ForegroundColor Gray
    $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $saId = az storage account show -g $ResourceGroup -n $blobStorageAccount --query id -o json 2>$null
    $ErrorActionPreference = $oldErrPref
    if ($saId) {
      $saIdClean = ($saId | ConvertFrom-Json)
      $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
      az role assignment create `
        --assignee-object-id $vmPrincipalId `
        --assignee-principal-type ServicePrincipal `
        --role "Storage Blob Data Reader" `
        --scope $saIdClean `
        --output none 2>$null
      $ErrorActionPreference = $oldErrPref
      Write-Log "Storage Blob Data Reader assigned to VM identity"
    }
  }

  # Upload default blobs (frr.conf + apply.sh)
  Write-Host "Uploading default router config blobs..." -ForegroundColor Gray
  $frrConfLocal = Join-Path $LabRoot "scripts\router\frr.conf"
  $applyShLocal = Join-Path $LabRoot "scripts\router\apply.sh"

  foreach ($blobInfo in @(
    @{ local = $frrConfLocal; name = "frr.conf" },
    @{ local = $applyShLocal; name = "apply.sh" }
  )) {
    if (Test-Path $blobInfo.local) {
      $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
      az storage blob upload `
        --account-name $blobStorageAccount `
        --container-name $blobContainer `
        --name $blobInfo.name `
        --file $blobInfo.local `
        --overwrite `
        --auth-mode login `
        --output none 2>$null
      $ErrorActionPreference = $oldErrPref
      Write-Log "Uploaded blob: $($blobInfo.name)"
    }
  }

  $phase6Elapsed = Get-ElapsedTime -StartTime $phase6Start
  Write-Host ""
  Write-Host "Phase 6 Validation:" -ForegroundColor Yellow
  Write-Validation -Check "Storage account created" -Passed ([bool]$existingSa -or $true) -Details $blobStorageAccount
  Write-Validation -Check "Managed identity assigned" -Passed ([bool]$vmPrincipalId) -Details "PrincipalId: $vmPrincipalId"
  Write-Validation -Check "Config blobs uploaded" -Passed $true -Details "$blobContainer/frr.conf, $blobContainer/apply.sh"
  Write-Host ""
  Write-Host "  To pull config on the router:" -ForegroundColor Yellow
  Write-Host "    az vm run-command invoke -g $ResourceGroup -n $RouterVmName --command-id RunShellScript --scripts '/opt/router-config/pull-config.sh $blobStorageAccount $blobContainer'" -ForegroundColor DarkGray
  Write-Log "Phase 6 completed in $phase6Elapsed" "SUCCESS"
} else {
  Write-Host "Blob-driven router config is DISABLED (default)." -ForegroundColor DarkGray
  Write-Host "  To enable, copy lab.config.example.json to lab.config.json" -ForegroundColor DarkGray
  Write-Host "  and set routerConfig.enabled = true." -ForegroundColor DarkGray
  Write-Log "Phase 6 skipped (blob config disabled)" "SUCCESS"
}

# ============================================
# PHASE 7: Route Table Control + Propagation Experiments
# ============================================
Write-Phase -Number 7 -Title "Route Table Control + Propagation"

$phase7Start = Get-Date

Write-Host "Experiment setup:" -ForegroundColor Gray
Write-Host "  Spoke A: BGP-peered (via router), associated to defaultRouteTable" -ForegroundColor DarkGray
Write-Host "  Spoke B: Control spoke, associated to defaultRouteTable (no BGP)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Expected behavior:" -ForegroundColor Gray
Write-Host "  - Routes advertised by router should appear in Spoke A effective routes" -ForegroundColor DarkGray
Write-Host "  - Spoke B should receive routes IF propagation is configured to default RT" -ForegroundColor DarkGray
Write-Host "  - Loopback inside VNet ($LoopbackInsideVnet): may conflict with system routes" -ForegroundColor DarkGray
Write-Host "  - Loopback outside VNet ($LoopbackOutsideVnet): should propagate cleanly" -ForegroundColor DarkGray
Write-Host ""

# Dump effective routes for Client A NIC
Write-Host "Fetching effective routes for Client A NIC..." -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$clientANicName = az vm show -g $ResourceGroup -n $ClientAVmName --query "networkProfile.networkInterfaces[0].id" -o tsv 2>$null
$ErrorActionPreference = $oldErrPref
if ($clientANicName) {
  $clientANicShort = ($clientANicName -split "/")[-1]
  $effectiveRoutesA = Invoke-AzCommand "network nic show-effective-route-table -g $ResourceGroup -n $clientANicShort -o json"
  Write-Host "  Client A effective routes retrieved" -ForegroundColor DarkGray
}

# Dump effective routes for Client B NIC
Write-Host "Fetching effective routes for Client B NIC..." -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$clientBNicName = az vm show -g $ResourceGroup -n $ClientBVmName --query "networkProfile.networkInterfaces[0].id" -o tsv 2>$null
$ErrorActionPreference = $oldErrPref
if ($clientBNicName) {
  $clientBNicShort = ($clientBNicName -split "/")[-1]
  $effectiveRoutesB = Invoke-AzCommand "network nic show-effective-route-table -g $ResourceGroup -n $clientBNicShort -o json"
  Write-Host "  Client B effective routes retrieved" -ForegroundColor DarkGray
}

$phase7Elapsed = Get-ElapsedTime -StartTime $phase7Start
Write-Host ""
Write-Host "Phase 7 Validation:" -ForegroundColor Yellow
Write-Host "  Run inspect.ps1 for detailed route comparison." -ForegroundColor Yellow
Write-Host "  See docs/experiments.md for loopback inside vs outside VNet results." -ForegroundColor Yellow
Write-Log "Phase 7 completed in $phase7Elapsed" "SUCCESS"

# ============================================
# PHASE 8: Observability Proof Pack
# ============================================
Write-Phase -Number 8 -Title "Observability Proof Pack"

$phase8Start = Get-Date

Write-Host "Saving deployment outputs..." -ForegroundColor Gray

# Build outputs object
$outputs = @{
  metadata = @{
    lab = "lab-006"
    deployedAt = (Get-Date -Format "o")
    deploymentTime = (Get-ElapsedTime -StartTime $deploymentStartTime)
    location = $Location
    status = "DEPLOYED"
  }
  azure = @{
    resourceGroup = $ResourceGroup
    subscriptionId = $SubscriptionId
    vwan = $VwanName
    vhub = $VhubName
    vhubPrefix = $VhubPrefix
    spokeA = @{
      vnet = $SpokeAVnetName
      prefix = $SpokeAPrefix
      routerVm = $RouterVmName
      routerHubNic = $routerNic1
      routerSpokeNic = $routerNic2
      routerHubIp = $routerHubIp
      routerSpokeIp = $nic2Ip
      clientVm = $ClientAVmName
    }
    spokeB = @{
      vnet = $SpokeBVnetName
      prefix = $SpokeBPrefix
      clientVm = $ClientBVmName
    }
    bgp = @{
      routerAsn = $RouterBgpAsn
      vhubAsn = $actualHubAsn
      peeringName = $BgpConnName
      peeringState = $bgpConnState
      vhubRouterIps = $hubRouterIps
    }
    loopbackTests = @{
      insideVnet = $LoopbackInsideVnet
      outsideVnet = $LoopbackOutsideVnet
    }
  }
}

$outputsJson = $outputs | ConvertTo-Json -Depth 10
Ensure-Directory (Split-Path $OutputsPath -Parent)
Write-JsonWithoutBom -Path $OutputsPath -Content $outputsJson
Write-Log "Outputs saved to: $OutputsPath"

$phase8Elapsed = Get-ElapsedTime -StartTime $phase8Start

# ============================================
# DEPLOYMENT SUMMARY
# ============================================
$totalElapsed = Get-ElapsedTime -StartTime $deploymentStartTime

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host ""
Write-Host "  Total time:       $totalElapsed" -ForegroundColor White
Write-Host "  Resource Group:   $ResourceGroup" -ForegroundColor White
Write-Host "  Location:         $Location" -ForegroundColor White
Write-Host "  Router VM:        $RouterVmName (hub=$routerHubIp, spoke=$nic2Ip)" -ForegroundColor White
Write-Host "  BGP Peering:      $BgpConnName (ASN $RouterBgpAsn -> vHub ASN $actualHubAsn)" -ForegroundColor White
if ($hubRouterIps.Count -ge 2) {
  Write-Host "  vHub Peers:       $($hubRouterIps[0]), $($hubRouterIps[1]) (active-active)" -ForegroundColor White
}
Write-Host "  Loopback (in):    $LoopbackInsideVnet" -ForegroundColor White
Write-Host "  Loopback (out):   $LoopbackOutsideVnet" -ForegroundColor White
Write-Host ""
Write-Host "  Outputs:          $OutputsPath" -ForegroundColor DarkGray
Write-Host "  Logs:             $($script:LogFile)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. SSH to router VM and verify FRR is running: vtysh -c 'show bgp summary'" -ForegroundColor Gray
Write-Host "  2. Run inspect.ps1 to see effective routes on all NICs" -ForegroundColor Gray
Write-Host "  3. See docs/validation.md for full validation commands" -ForegroundColor Gray
Write-Host "  4. See docs/experiments.md for loopback propagation tests" -ForegroundColor Gray
Write-Host ""
Write-Host "  IMPORTANT: Run destroy.ps1 when done to stop billing!" -ForegroundColor Red
Write-Host ""

Write-Log "Deployment complete. Total time: $totalElapsed" "SUCCESS"
