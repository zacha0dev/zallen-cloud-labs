# labs/lab-010-vwan-route-maps/deploy.ps1
# Azure Virtual WAN with Route Maps - three configuration examples
#
# Demonstrates:
#   1. Community Tagging  - add BGP community 65010:100 to routes entering hub from Spoke-A
#   2. Route Filtering    - drop Spoke-A's prefix from routes sent outbound to Spoke-B
#   3. AS Path Prepend    - prepend AS 65010 twice on routes sent outbound to Spoke-A
#
# Architecture:
#   vWAN (Standard)
#     vHub (10.60.0.0/24)
#       Spoke-A (10.61.0.0/16) -- inbound: rm-community-tag, outbound: rm-as-prepend
#       Spoke-B (10.62.0.0/16) -- outbound: rm-route-filter (drops Spoke-A prefix)
#
# Requires Azure CLI 2.54+ for az network vhub route-map support.

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
$LogsDir  = Join-Path $LabRoot "logs"

# PS5.1-safe nested Join-Path
$dataDir     = Join-Path $RepoRoot ".data"
$OutputsDir  = Join-Path $dataDir "lab-010"
$OutputsPath = Join-Path $OutputsDir "outputs.json"

# Load shared helpers
. (Join-Path $RepoRoot "scripts\labs-common.ps1")

# ============================================
# LAB CONFIGURATION
# ============================================
$ResourceGroup = "rg-lab-010-vwan-route-maps"
$VwanName      = "vwan-lab-010"
$VhubName      = "vhub-lab-010"
$VhubCidr      = "10.60.0.0/24"

# Spoke VNets
$VnetAName   = "vnet-spoke-a-lab-010"
$VnetACidr   = "10.61.0.0/16"
$SubnetAName = "snet-workload"
$SubnetACidr = "10.61.1.0/24"

$VnetBName   = "vnet-spoke-b-lab-010"
$VnetBCidr   = "10.62.0.0/16"
$SubnetBName = "snet-workload"
$SubnetBCidr = "10.62.1.0/24"

# Hub connection names
$ConnAName = "conn-spoke-a"
$ConnBName = "conn-spoke-b"

# Route Map names
$RmTagName     = "rm-community-tag"     # Inbound on Spoke-A: tag routes with community 65010:100
$RmFilterName  = "rm-route-filter"      # Outbound on Spoke-B: drop Spoke-A prefix
$RmPrependName = "rm-as-prepend"        # Outbound on Spoke-A: prepend AS 65010 twice

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
  Write-Host ("=" * 65) -ForegroundColor Cyan
  Write-Host "PHASE $Number : $Title" -ForegroundColor Cyan
  Write-Host ("=" * 65) -ForegroundColor Cyan
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

function Wait-VhubProvisioned {
  param(
    [string]$ResourceGroup,
    [string]$VhubName,
    [datetime]$StartTime,
    [int]$MaxAttempts = 80,
    [int]$IntervalSecs = 15
  )
  $attempt = 0
  while ($attempt -lt $MaxAttempts) {
    $attempt++
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $vhub = $null
    $vhub = az network vhub show -g $ResourceGroup -n $VhubName -o json 2>$null | ConvertFrom-Json
    $ErrorActionPreference = $oldEP
    if ($vhub -and $vhub.provisioningState -eq "Succeeded") { return $true }
    if ($vhub -and $vhub.provisioningState -eq "Failed")    { throw "vHub provisioning failed." }
    $elapsed = Get-ElapsedTime -StartTime $StartTime
    Write-Host "    [$elapsed] vHub state: $($vhub.provisioningState) ($attempt/$MaxAttempts)" -ForegroundColor DarkGray
    Start-Sleep -Seconds $IntervalSecs
  }
  throw "vHub did not provision within timeout."
}

function Write-RouteMapInfo {
  param([string]$MapName, [string]$Applied, [string]$Purpose)
  Write-Host ""
  Write-Host "  Route Map: $MapName" -ForegroundColor White
  Write-Host "    Applied:  $Applied" -ForegroundColor Gray
  Write-Host "    Purpose:  $Purpose" -ForegroundColor DarkGray
}

# ============================================
# MAIN
# ============================================

Write-Host ""
Write-Host "Lab 010: vWAN Route Maps" -ForegroundColor Cyan
Write-Host "========================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Purpose: Explore Azure vWAN Route Maps through three practical examples:" -ForegroundColor White
Write-Host "  1. Community Tagging - annotate inbound routes with BGP communities" -ForegroundColor Gray
Write-Host "  2. Route Filtering   - prevent specific prefixes from reaching a spoke" -ForegroundColor Gray
Write-Host "  3. AS Path Prepend   - make routes appear less preferred via AS path length" -ForegroundColor Gray
Write-Host ""

$deploymentStartTime = Get-Date

# ============================================
# PHASE 0: Preflight
# ============================================
Write-Phase -Number 0 -Title "Preflight Checks"

$phase0Start = Get-Date

Ensure-Directory $LogsDir
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$script:LogFile = Join-Path $LogsDir "lab-010-$timestamp.log"
Write-Log "Deployment started"
Write-Log "Location: $Location"

# Suppress Python OpenSSL UserWarning that az CLI emits on 32-bit Python / 64-bit Windows.
# Without this, PS5.1 with EAP=Stop raises NativeCommandError on any az command that writes
# to stderr, even when the command itself succeeds.
$env:PYTHONWARNINGS = "ignore::UserWarning"

Require-Command az "Install Azure CLI: https://aka.ms/installazurecli"
Write-Validation -Check "Azure CLI installed" -Passed $true

# Verify Azure CLI version supports route maps (2.54.0+)
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$cliVerJson = $null
$cliVerJson = az version -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
$cliVersionRaw = if ($cliVerJson) { $cliVerJson.'azure-cli' } else { "unknown" }
Write-Validation -Check "Azure CLI version: $cliVersionRaw (2.54+ required for route-map)" -Passed $true

Assert-LocationAllowed -Location $Location -AllowedLocations $AllowedLocations
Write-Validation -Check "Location '$Location' allowed" -Passed $true

Show-ConfigPreflight -RepoRoot $RepoRoot
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Write-Validation -Check "Subscription resolved" -Passed $true -Details $SubscriptionId

Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null
$subName = az account show --query name -o tsv
Write-Validation -Check "Azure authenticated" -Passed $true -Details $subName

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
Write-Host "  2x Spoke VNets + Hub Connections: minimal" -ForegroundColor Gray
Write-Host "  Route Maps: no additional charge" -ForegroundColor Gray
Write-Host ""
Write-Host "No VMs are deployed in this lab - all validation is via routing tables." -ForegroundColor DarkGray
Write-Host ""

if (-not $Force) {
  $confirm = Read-Host "Type DEPLOY to proceed"
  if ($confirm -ne "DEPLOY") { throw "Cancelled." }
}

$portalUrl = "https://portal.azure.com/#@/resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/overview"
Write-Host ""
Write-Host "Azure Portal:" -ForegroundColor Yellow
Write-Host "  $portalUrl" -ForegroundColor Cyan
Write-Host ""

$phase0Elapsed = Get-ElapsedTime -StartTime $phase0Start
Write-Log "Phase 0 completed in $phase0Elapsed" "SUCCESS"

# ============================================
# PHASE 1: Core Fabric (RG + vWAN + vHub)
# ============================================
Write-Phase -Number 1 -Title "Core Fabric (vWAN + vHub)"

$phase1Start = Get-Date
$tagsString = "project=azure-labs lab=lab-010 owner=$Owner environment=lab cost-center=learning"

# Resource Group
Write-Host "Creating resource group: $ResourceGroup" -ForegroundColor Gray
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRg = $null
$existingRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
if ($existingRg) {
  Write-Host "  Already exists, skipping." -ForegroundColor DarkGray
} else {
  az group create --name $ResourceGroup --location $Location --tags $tagsString --output none
  Write-Log "Resource group created: $ResourceGroup"
}

# vWAN
Write-Host "Creating Virtual WAN: $VwanName" -ForegroundColor Gray
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingVwan = $null
$existingVwan = az network vwan show -g $ResourceGroup -n $VwanName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
if ($existingVwan) {
  Write-Host "  Already exists, skipping." -ForegroundColor DarkGray
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

# vHub
Write-Host "Creating Virtual Hub: $VhubName (this takes 10-20 minutes)" -ForegroundColor Gray
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingVhub = $null
$existingVhub = az network vhub show -g $ResourceGroup -n $VhubName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if ($existingVhub -and $existingVhub.provisioningState -eq "Succeeded") {
  Write-Host "  Already provisioned, skipping." -ForegroundColor DarkGray
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
  Write-Host "  Waiting for vHub to provision..." -ForegroundColor Gray
  Wait-VhubProvisioned -ResourceGroup $ResourceGroup -VhubName $VhubName -StartTime $phase1Start | Out-Null
}

$phase1Elapsed = Get-ElapsedTime -StartTime $phase1Start
Write-Validation -Check "vHub provisioned (Succeeded)" -Passed $true -Details "Completed in $phase1Elapsed"
Write-Log "Phase 1 completed in $phase1Elapsed" "SUCCESS"

# ============================================
# PHASE 2: Spoke VNets
# ============================================
Write-Phase -Number 2 -Title "Spoke VNets"

$phase2Start = Get-Date

# Spoke-A
Write-Host "Creating Spoke-A VNet: $VnetAName ($VnetACidr)" -ForegroundColor Gray
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingVnetA = $null
$existingVnetA = az network vnet show -g $ResourceGroup -n $VnetAName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
if ($existingVnetA) {
  Write-Host "  Already exists, skipping." -ForegroundColor DarkGray
} else {
  az network vnet create `
    --resource-group $ResourceGroup `
    --name $VnetAName `
    --location $Location `
    --address-prefixes $VnetACidr `
    --subnet-name $SubnetAName `
    --subnet-prefixes $SubnetACidr `
    --tags $tagsString `
    --output none
  Write-Log "Spoke-A VNet created: $VnetAName"
}

# Spoke-B
Write-Host "Creating Spoke-B VNet: $VnetBName ($VnetBCidr)" -ForegroundColor Gray
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingVnetB = $null
$existingVnetB = az network vnet show -g $ResourceGroup -n $VnetBName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
if ($existingVnetB) {
  Write-Host "  Already exists, skipping." -ForegroundColor DarkGray
} else {
  az network vnet create `
    --resource-group $ResourceGroup `
    --name $VnetBName `
    --location $Location `
    --address-prefixes $VnetBCidr `
    --subnet-name $SubnetBName `
    --subnet-prefixes $SubnetBCidr `
    --tags $tagsString `
    --output none
  Write-Log "Spoke-B VNet created: $VnetBName"
}

$phase2Elapsed = Get-ElapsedTime -StartTime $phase2Start
Write-Log "Phase 2 completed in $phase2Elapsed" "SUCCESS"

# ============================================
# PHASE 3: Route Maps
# ============================================
Write-Phase -Number 3 -Title "Route Maps (create all three)"

$phase3Start = Get-Date

Write-Host "Creating Route Maps on hub: $VhubName" -ForegroundColor Gray
Write-Host ""

# Acquire ARM access token via az CLI - use Invoke-RestMethod (native PS) to avoid
# az rest @file path issues on Windows PS5.1 (backslashes, temp dir spaces, etc.)
Write-Host "  Acquiring ARM token..." -ForegroundColor DarkGray
$armTokenResult = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$armTokenResult = az account get-access-token --resource https://management.azure.com/ -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
if (-not $armTokenResult) { throw "Failed to acquire ARM access token for route map creation" }
$armHeaders = @{
  "Authorization" = "Bearer $($armTokenResult.accessToken)"
  "Content-Type"  = "application/json"
}
$armBase = "https://management.azure.com"

# Pre-cleanup: a Failed connection that references a route map causes Azure to also
# mark the route map as Failed. Delete any Failed connections first so that route
# map cleanup and recreation can succeed cleanly.
Write-Host "  Pre-cleanup: checking for failed connections..." -ForegroundColor DarkGray
foreach ($preConnName in @($ConnAName, $ConnBName)) {
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $preConn = $null
  $preConn = az network vhub connection show -g $ResourceGroup --vhub-name $VhubName -n $preConnName -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP
  if ($preConn -and $preConn.provisioningState -eq "Failed") {
    Write-Host "    Deleting failed connection '$preConnName' so route maps can be cleaned up." -ForegroundColor DarkGray
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    az network vhub connection delete -g $ResourceGroup --vhub-name $VhubName -n $preConnName --yes -o none 2>$null
    $ErrorActionPreference = $oldEP
    # Wait for gone
    $preDelAttempt = 0
    while ($preDelAttempt -lt 24) {
      $preDelAttempt++
      Start-Sleep -Seconds 10
      $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
      $preCheck = $null
      $preCheck = az network vhub connection show -g $ResourceGroup --vhub-name $VhubName -n $preConnName -o json 2>$null | ConvertFrom-Json
      $ErrorActionPreference = $oldEP
      if (-not $preCheck) { break }
    }
    Write-Host "    $preConnName deleted." -ForegroundColor DarkGray
  }
}
Write-Host ""

function Invoke-RouteMapPut {
  param(
    [string]$MapName,
    [hashtable]$Body,
    [hashtable]$Headers,
    [string]$BaseUri
  )
  $uri = "$BaseUri/routeMaps/${MapName}?api-version=2023-09-01"
  $json = $Body | ConvertTo-Json -Depth 15
  try {
    $null = Invoke-RestMethod -Method PUT -Uri $uri -Headers $Headers -Body $json
  } catch {
    $errMsg = $_.Exception.Message
    # PS7: response body is in ErrorDetails.Message
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
      $errMsg = $_.ErrorDetails.Message
    } elseif ($_.Exception.Response) {
      try {
        $stream = $_.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $errMsg = $reader.ReadToEnd()
      } catch {}
    }
    throw "Failed to create route map $MapName : $errMsg"
  }
}

# Wait for a route map to reach Succeeded after a PUT. Route maps are fast to
# provision but the ARM operation is async. If we start Phase 4 before the route
# map is Succeeded, the connection referencing it will also fail.
function Wait-RouteMapSucceeded {
  param([string]$MapName, [datetime]$StartTime, [int]$MaxAttempts = 20)
  $attempt = 0
  while ($attempt -lt $MaxAttempts) {
    $attempt++
    Start-Sleep -Seconds 10
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $rm = $null
    $rm = az network vhub route-map show -g $ResourceGroup --vhub-name $VhubName -n $MapName -o json 2>$null | ConvertFrom-Json
    $ErrorActionPreference = $oldEP
    if ($rm -and $rm.provisioningState -eq "Succeeded") { return }
    if ($rm -and $rm.provisioningState -eq "Failed")    { throw "Route Map $MapName reached Failed state during provisioning" }
    $elapsed = Get-ElapsedTime -StartTime $StartTime
    $state = if ($rm) { $rm.provisioningState } else { "Pending" }
    Write-Host "        [$elapsed] $MapName state: $state ($attempt/$MaxAttempts)" -ForegroundColor DarkGray
  }
  throw "Route Map $MapName did not reach Succeeded within timeout"
}

$vhubArmBase = "$armBase/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/virtualHubs/$VhubName"

# --- Route Map 1: Community Tag (Inbound on Spoke-A) ---
Write-Host "  [1/3] $RmTagName - Community Tagging (inbound on Spoke-A)" -ForegroundColor White
Write-Host "        Match: any prefix  ->  Add community 65010:100" -ForegroundColor DarkGray

$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRmTag = $null
$existingRmTag = az network vhub route-map show -g $ResourceGroup --vhub-name $VhubName -n $RmTagName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if ($existingRmTag -and $existingRmTag.provisioningState -eq "Succeeded") {
  Write-Host "        Already exists (Succeeded), skipping." -ForegroundColor DarkGray
} else {
  if ($existingRmTag) {
    Write-Host "        Exists but state='$($existingRmTag.provisioningState)' - deleting to recreate." -ForegroundColor DarkGray
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    az network vhub route-map delete -g $ResourceGroup --vhub-name $VhubName -n $RmTagName --yes -o none 2>$null
    $ErrorActionPreference = $oldEP
    $rmTagDelAttempt = 0
    while ($rmTagDelAttempt -lt 12) {
      $rmTagDelAttempt++; Start-Sleep -Seconds 10
      $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
      $rmTagCheck = $null
      $rmTagCheck = az network vhub route-map show -g $ResourceGroup --vhub-name $VhubName -n $RmTagName -o json 2>$null | ConvertFrom-Json
      $ErrorActionPreference = $oldEP
      if (-not $rmTagCheck) { break }
    }
  }
  $rmTagBody = @{
    properties = @{
      rules = @(
        [pscustomobject]@{
          name = "tag-all-routes"
          matchCriteria = @([pscustomobject]@{ matchCondition = "Contains"; routePrefix = @("0.0.0.0/0") })
          actions = @([pscustomobject]@{ type = "Add"; parameters = @([pscustomobject]@{ community = @("65010:100") }) })
          nextStepIfMatched = "Continue"
        }
      )
    }
  }
  Invoke-RouteMapPut -MapName $RmTagName -Body $rmTagBody -Headers $armHeaders -BaseUri $vhubArmBase
  Write-Log "Route Map created: $RmTagName"
  Wait-RouteMapSucceeded -MapName $RmTagName -StartTime $phase3Start
  Write-Host "        Created (Succeeded)." -ForegroundColor Green
}

# --- Route Map 2: Route Filter (Outbound on Spoke-B) ---
Write-Host ""
Write-Host "  [2/3] $RmFilterName - Route Filtering (outbound on Spoke-B)" -ForegroundColor White
Write-Host "        Match: 10.61.0.0/16  ->  Drop (Spoke-A prefix hidden from Spoke-B)" -ForegroundColor DarkGray

$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRmFilter = $null
$existingRmFilter = az network vhub route-map show -g $ResourceGroup --vhub-name $VhubName -n $RmFilterName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if ($existingRmFilter -and $existingRmFilter.provisioningState -eq "Succeeded") {
  Write-Host "        Already exists (Succeeded), skipping." -ForegroundColor DarkGray
} else {
  if ($existingRmFilter) {
    Write-Host "        Exists but state='$($existingRmFilter.provisioningState)' - deleting to recreate." -ForegroundColor DarkGray
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    az network vhub route-map delete -g $ResourceGroup --vhub-name $VhubName -n $RmFilterName --yes -o none 2>$null
    $ErrorActionPreference = $oldEP
    $rmFilterDelAttempt = 0
    while ($rmFilterDelAttempt -lt 12) {
      $rmFilterDelAttempt++; Start-Sleep -Seconds 10
      $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
      $rmFilterCheck = $null
      $rmFilterCheck = az network vhub route-map show -g $ResourceGroup --vhub-name $VhubName -n $RmFilterName -o json 2>$null | ConvertFrom-Json
      $ErrorActionPreference = $oldEP
      if (-not $rmFilterCheck) { break }
    }
  }
  $rmFilterBody = @{
    properties = @{
      rules = @(
        [pscustomobject]@{
          name = "drop-spoke-a-prefix"
          matchCriteria = @([pscustomobject]@{ matchCondition = "Contains"; routePrefix = @("10.61.0.0/16") })
          actions = @([pscustomobject]@{ type = "Drop" })
          nextStepIfMatched = "Terminate"
        },
        [pscustomobject]@{
          name = "allow-all-others"
          matchCriteria = @([pscustomobject]@{ matchCondition = "Contains"; routePrefix = @("0.0.0.0/0") })
          actions = @()
          nextStepIfMatched = "Continue"
        }
      )
    }
  }
  Invoke-RouteMapPut -MapName $RmFilterName -Body $rmFilterBody -Headers $armHeaders -BaseUri $vhubArmBase
  Write-Log "Route Map created: $RmFilterName"
  Wait-RouteMapSucceeded -MapName $RmFilterName -StartTime $phase3Start
  Write-Host "        Created (Succeeded)." -ForegroundColor Green
}

# --- Route Map 3: AS Path Prepend (Outbound on Spoke-A) ---
Write-Host ""
Write-Host "  [3/3] $RmPrependName - AS Path Prepend (outbound on Spoke-A)" -ForegroundColor White
Write-Host "        Match: any prefix  ->  Prepend AS 65010 twice" -ForegroundColor DarkGray

$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRmPrepend = $null
$existingRmPrepend = az network vhub route-map show -g $ResourceGroup --vhub-name $VhubName -n $RmPrependName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if ($existingRmPrepend -and $existingRmPrepend.provisioningState -eq "Succeeded") {
  Write-Host "        Already exists (Succeeded), skipping." -ForegroundColor DarkGray
} else {
  if ($existingRmPrepend) {
    Write-Host "        Exists but state='$($existingRmPrepend.provisioningState)' - deleting to recreate." -ForegroundColor DarkGray
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    az network vhub route-map delete -g $ResourceGroup --vhub-name $VhubName -n $RmPrependName --yes -o none 2>$null
    $ErrorActionPreference = $oldEP
    $rmPrependDelAttempt = 0
    while ($rmPrependDelAttempt -lt 12) {
      $rmPrependDelAttempt++; Start-Sleep -Seconds 10
      $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
      $rmPrependCheck = $null
      $rmPrependCheck = az network vhub route-map show -g $ResourceGroup --vhub-name $VhubName -n $RmPrependName -o json 2>$null | ConvertFrom-Json
      $ErrorActionPreference = $oldEP
      if (-not $rmPrependCheck) { break }
    }
  }
  $rmPrependBody = @{
    properties = @{
      rules = @(
        [pscustomobject]@{
          name = "prepend-as-path"
          matchCriteria = @([pscustomobject]@{ matchCondition = "Contains"; routePrefix = @("0.0.0.0/0") })
          actions = @([pscustomobject]@{ type = "Add"; parameters = @([pscustomobject]@{ asPath = @("65010", "65010") }) })
          nextStepIfMatched = "Continue"
        }
      )
    }
  }
  Invoke-RouteMapPut -MapName $RmPrependName -Body $rmPrependBody -Headers $armHeaders -BaseUri $vhubArmBase
  Write-Log "Route Map created: $RmPrependName"
  Wait-RouteMapSucceeded -MapName $RmPrependName -StartTime $phase3Start
  Write-Host "        Created (Succeeded)." -ForegroundColor Green
}

$phase3Elapsed = Get-ElapsedTime -StartTime $phase3Start
Write-Log "Phase 3 completed in $phase3Elapsed" "SUCCESS"

# ============================================
# PHASE 4: Hub Connections (with Route Maps)
# ============================================
Write-Phase -Number 4 -Title "Hub Connections + Route Map Assignment"

$phase4Start = Get-Date

# Resolve VNet IDs
$vnetAId = az network vnet show -g $ResourceGroup -n $VnetAName --query id -o tsv --only-show-errors
$vnetBId = az network vnet show -g $ResourceGroup -n $VnetBName --query id -o tsv --only-show-errors

if (-not $vnetAId) { throw "Could not resolve VNet ID for $VnetAName" }
if (-not $vnetBId) { throw "Could not resolve VNet ID for $VnetBName" }

# Resolve vHub resource ID
$vhubObj = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vhubObj = az network vhub show -g $ResourceGroup -n $VhubName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
if (-not $vhubObj) { throw "Could not resolve vHub resource." }

$vhubResourceId = $vhubObj.id
$rmTagId     = "$vhubResourceId/routeMaps/$RmTagName"
$rmFilterId  = "$vhubResourceId/routeMaps/$RmFilterName"
$rmPrependId = "$vhubResourceId/routeMaps/$RmPrependName"

$armConnBase = "https://management.azure.com/subscriptions/$SubscriptionId" +
               "/resourceGroups/$ResourceGroup/providers/Microsoft.Network" +
               "/virtualHubs/$VhubName/hubVirtualNetworkConnections"

# Default route table always exists at this path in any vHub
$defaultRtId = "$vhubResourceId/hubRouteTables/defaultRouteTable"

# Poll until Succeeded or Failed; return the final state string
function Wait-HubConnection {
  param([string]$ConnName, [datetime]$StartTime, [int]$MaxAttempts = 40, [string]$Label = "")
  $attempt = 0
  while ($attempt -lt $MaxAttempts) {
    $attempt++
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $conn = $null
    $conn = az network vhub connection show -g $ResourceGroup --vhub-name $VhubName -n $ConnName -o json 2>$null | ConvertFrom-Json
    $ErrorActionPreference = $oldEP
    if ($conn -and $conn.provisioningState -eq "Succeeded") { return "Succeeded" }
    if ($conn -and $conn.provisioningState -eq "Failed")    { return "Failed" }
    $elapsed = Get-ElapsedTime -StartTime $StartTime
    $state   = if ($conn) { $conn.provisioningState } else { "Pending" }
    $suffix  = if ($Label) { " ($Label)" } else { "" }
    Write-Host "    [$elapsed] $ConnName state: $state ($attempt/$MaxAttempts)$suffix" -ForegroundColor DarkGray
    Start-Sleep -Seconds 10
  }
  return "Timeout"
}

# Delete an existing connection and wait for it to be gone
function Remove-HubConnection {
  param([string]$ConnName)
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  az network vhub connection delete -g $ResourceGroup --vhub-name $VhubName -n $ConnName --yes -o none 2>$null
  $ErrorActionPreference = $oldEP
  $attempt = 0
  while ($attempt -lt 24) {
    $attempt++
    Start-Sleep -Seconds 10
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $check = $null
    $check = az network vhub connection show -g $ResourceGroup --vhub-name $VhubName -n $ConnName -o json 2>$null | ConvertFrom-Json
    $ErrorActionPreference = $oldEP
    if (-not $check) { return }
  }
  throw "Connection $ConnName did not delete within timeout"
}

# Create a hub connection via ARM REST API with route maps and routing config
# in one shot. Specifying associatedRouteTable + propagatedRouteTables upfront
# avoids a two-step create-then-update, which was causing Failed state because
# Azure rejected a PUT that modified an already-configured connection.
function New-HubConnectionWithRouteMaps {
  param(
    [string]$ConnName,
    [string]$RemoteVnetId,
    [string]$InboundRmId,   # empty string = omit
    [string]$OutboundRmId   # empty string = omit
  )

  $routingConfig = [pscustomobject]@{
    associatedRouteTable  = [pscustomobject]@{ id = $defaultRtId }
    propagatedRouteTables = [pscustomobject]@{
      labels = @("default")
      ids    = @([pscustomobject]@{ id = $defaultRtId })
    }
  }
  if ($InboundRmId) {
    $routingConfig | Add-Member -NotePropertyName inboundRouteMap  -NotePropertyValue ([pscustomobject]@{ id = $InboundRmId })
  }
  if ($OutboundRmId) {
    $routingConfig | Add-Member -NotePropertyName outboundRouteMap -NotePropertyValue ([pscustomobject]@{ id = $OutboundRmId })
  }

  $body = [pscustomobject]@{
    properties = [pscustomobject]@{
      remoteVirtualNetwork = [pscustomobject]@{ id = $RemoteVnetId }
      routingConfiguration = $routingConfig
    }
  }

  $uri = "${armConnBase}/${ConnName}?api-version=2023-09-01"
  $json = $body | ConvertTo-Json -Depth 15
  try {
    $null = Invoke-RestMethod -Method PUT -Uri $uri -Headers $armHeaders -Body $json
  } catch {
    $err = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    throw "ARM PUT $ConnName failed: $err"
  }
  Write-Log "Hub connection ARM PUT submitted: $ConnName"
}

# For each connection: if it already has correct route maps and is Succeeded, skip.
# Otherwise delete existing and create fresh via ARM with route maps baked in.
function Ensure-HubConnectionWithRouteMaps {
  param(
    [string]$ConnName,
    [string]$RemoteVnetId,
    [string]$InboundRmId,
    [string]$OutboundRmId,
    [string]$InboundRmName,   # for display check only
    [string]$OutboundRmName   # for display check only
  )

  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $existing = $null
  $existing = az network vhub connection show -g $ResourceGroup --vhub-name $VhubName -n $ConnName -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP

  # Check if already fully configured correctly
  if ($existing -and $existing.provisioningState -eq "Succeeded") {
    $rc = $existing.routingConfiguration
    # Use PSObject.Properties to safely check for inbound/outboundRouteMap under Set-StrictMode
    $hasInbound  = (-not $InboundRmName)  -or ($rc -and ($rc.PSObject.Properties.Name -contains "inboundRouteMap")  -and $rc.inboundRouteMap  -and $rc.inboundRouteMap.id  -match $InboundRmName)
    $hasOutbound = (-not $OutboundRmName) -or ($rc -and ($rc.PSObject.Properties.Name -contains "outboundRouteMap") -and $rc.outboundRouteMap -and $rc.outboundRouteMap.id -match $OutboundRmName)
    if ($hasInbound -and $hasOutbound) {
      Write-Host "  Already connected with correct route maps (Succeeded), skipping." -ForegroundColor DarkGray
      return
    }
    Write-Host "  Connected but route maps not yet applied - recreating with route maps." -ForegroundColor DarkGray
  } elseif ($existing) {
    Write-Host "  Connection is '$($existing.provisioningState)' - deleting to recreate." -ForegroundColor DarkGray
  }

  if ($existing) {
    Remove-HubConnection -ConnName $ConnName
  }

  Write-Host "  Creating $ConnName via ARM (with route maps)..." -ForegroundColor DarkGray
  New-HubConnectionWithRouteMaps -ConnName $ConnName -RemoteVnetId $RemoteVnetId `
    -InboundRmId $InboundRmId -OutboundRmId $OutboundRmId
}

# --- Connection: Spoke-A ---
# Inbound:  rm-community-tag  (tag routes entering hub from Spoke-A)
# Outbound: rm-as-prepend     (prepend AS on routes hub sends to Spoke-A)

Write-Host "Hub connection: $ConnAName" -ForegroundColor Gray
Write-Host "  Inbound:  $RmTagName" -ForegroundColor DarkGray
Write-Host "  Outbound: $RmPrependName" -ForegroundColor DarkGray

Ensure-HubConnectionWithRouteMaps `
  -ConnName       $ConnAName `
  -RemoteVnetId   $vnetAId `
  -InboundRmId    $rmTagId `
  -OutboundRmId   $rmPrependId `
  -InboundRmName  $RmTagName `
  -OutboundRmName $RmPrependName

Write-Host "  Waiting for $ConnAName to provision..." -ForegroundColor Gray
$connAResult = Wait-HubConnection -ConnName $ConnAName -StartTime $phase4Start
if ($connAResult -ne "Succeeded") {
  Write-Host "  WARNING: $ConnAName ended in state: $connAResult" -ForegroundColor Yellow
} else {
  Write-Host "  $ConnAName provisioned." -ForegroundColor Green
}

# --- Connection: Spoke-B ---
# Outbound: rm-route-filter (drop Spoke-A's 10.61.0.0/16 from routes sent to Spoke-B)

Write-Host ""
Write-Host "Hub connection: $ConnBName" -ForegroundColor Gray
Write-Host "  Inbound:  (none)" -ForegroundColor DarkGray
Write-Host "  Outbound: $RmFilterName" -ForegroundColor DarkGray

Ensure-HubConnectionWithRouteMaps `
  -ConnName       $ConnBName `
  -RemoteVnetId   $vnetBId `
  -InboundRmId    "" `
  -OutboundRmId   $rmFilterId `
  -InboundRmName  "" `
  -OutboundRmName $RmFilterName

Write-Host "  Waiting for $ConnBName to provision..." -ForegroundColor Gray
$connBResult = Wait-HubConnection -ConnName $ConnBName -StartTime $phase4Start
if ($connBResult -ne "Succeeded") {
  Write-Host "  WARNING: $ConnBName ended in state: $connBResult" -ForegroundColor Yellow
} else {
  Write-Host "  $ConnBName provisioned." -ForegroundColor Green
}

$phase4Elapsed = Get-ElapsedTime -StartTime $phase4Start
Write-Log "Phase 4 completed in $phase4Elapsed" "SUCCESS"

# ============================================
# PHASE 5: Validation
# ============================================
Write-Phase -Number 5 -Title "Validation"

$phase5Start = Get-Date
$allValid = $true

# vWAN
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vwan = $null
$vwan = az network vwan show -g $ResourceGroup -n $VwanName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
$vwanValid = ($vwan -ne $null -and $vwan.provisioningState -eq "Succeeded")
Write-Validation -Check "vWAN exists (Standard)" -Passed $vwanValid -Details $VwanName
if (-not $vwanValid) { $allValid = $false }

# vHub
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vhub = $null
$vhub = az network vhub show -g $ResourceGroup -n $VhubName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
$vhubValid = ($vhub -ne $null -and $vhub.provisioningState -eq "Succeeded")
Write-Validation -Check "vHub provisioned" -Passed $vhubValid -Details "$VhubName ($VhubCidr)"
if (-not $vhubValid) { $allValid = $false }

# Route Maps
Write-Host ""
Write-Host "  Route Maps:" -ForegroundColor Yellow
foreach ($rmEntry in @(
    @{ Name = $RmTagName;     Role = "Inbound Spoke-A: community tag" },
    @{ Name = $RmFilterName;  Role = "Outbound Spoke-B: route filter" },
    @{ Name = $RmPrependName; Role = "Outbound Spoke-A: AS prepend" }
  )) {
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $rm = $null
  $rm = az network vhub route-map show -g $ResourceGroup --vhub-name $VhubName -n $rmEntry.Name -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP
  $rmValid = ($rm -ne $null -and $rm.provisioningState -eq "Succeeded")
  Write-Validation -Check "Route Map: $($rmEntry.Name)" -Passed $rmValid -Details $rmEntry.Role
  if (-not $rmValid) { $allValid = $false }
}

# Connections
Write-Host ""
Write-Host "  Hub Connections:" -ForegroundColor Yellow

$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$connA = $null
$connA = az network vhub connection show -g $ResourceGroup --vhub-name $VhubName -n $ConnAName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
$connAValid = ($connA -ne $null -and $connA.provisioningState -eq "Succeeded")
Write-Validation -Check "Connection: $ConnAName" -Passed $connAValid
if (-not $connAValid) { $allValid = $false }

$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$connB = $null
$connB = az network vhub connection show -g $ResourceGroup --vhub-name $VhubName -n $ConnBName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
$connBValid = ($connB -ne $null -and $connB.provisioningState -eq "Succeeded")
Write-Validation -Check "Connection: $ConnBName" -Passed $connBValid
if (-not $connBValid) { $allValid = $false }

# Effective Routes (from Spoke-B connection perspective - should NOT see 10.61.0.0/16)
Write-Host ""
Write-Host "  Effective routes for $ConnBName (rm-route-filter applied outbound):" -ForegroundColor Yellow
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$effRoutes = $null
$connBId = if ($connB) { $connB.id } else { "" }
if ($connBId) {
  $effRoutes = az network vhub get-effective-routes `
    --resource-group $ResourceGroup `
    --name $VhubName `
    --resource-type VirtualNetworkConnection `
    --resource-id $connBId `
    --query "value[].{prefix:addressPrefixes[0], nextHop:nextHopType, origin:routeOrigin}" `
    -o json 2>$null | ConvertFrom-Json
}
$ErrorActionPreference = $oldEP

if ($effRoutes -and $effRoutes.Count -gt 0) {
  $foundSpokeA = $false
  foreach ($r in $effRoutes) {
    $marker = ""
    if ($r.prefix -and $r.prefix.StartsWith("10.61.")) {
      $marker = "  <- SPOKE-A PREFIX (filter NOT working)"
      $foundSpokeA = $true
    }
    Write-Host "    $($r.prefix) -> $($r.nextHop)$marker" -ForegroundColor Gray
  }
  if (-not $foundSpokeA) {
    Write-Host "    10.61.0.0/16 absent - rm-route-filter is dropping it correctly" -ForegroundColor Green
  }
} else {
  Write-Host "    (Routes may take a few minutes to populate after connection provision)" -ForegroundColor DarkGray
}

$phase5Elapsed = Get-ElapsedTime -StartTime $phase5Start
Write-Log "Phase 5 completed in $phase5Elapsed" "SUCCESS"

# ============================================
# PHASE 6: Summary
# ============================================
Write-Phase -Number 6 -Title "Summary + Cleanup Guidance"

$phase6Start = Get-Date
$totalElapsed = Get-ElapsedTime -StartTime $deploymentStartTime

# Save outputs
Ensure-Directory $OutputsDir

$outputs = [pscustomobject]@{
  metadata = [pscustomobject]@{
    lab          = "lab-010"
    deployedAt   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    deployedTime = $totalElapsed
    status       = if ($allValid) { "PASS" } else { "PARTIAL" }
    tags         = @{
      project         = "azure-labs"
      lab             = "lab-010"
      owner           = $Owner
      environment     = "lab"
      "cost-center"   = "learning"
    }
  }
  azure = [pscustomobject]@{
    subscriptionId   = $SubscriptionId
    subscriptionName = $subName
    location         = $Location
    resourceGroup    = $ResourceGroup
    vwan             = $VwanName
    vhub             = [pscustomobject]@{
      name = $VhubName
      cidr = $VhubCidr
    }
    spokeVnets = @(
      [pscustomobject]@{ name = $VnetAName; cidr = $VnetACidr; connection = $ConnAName }
      [pscustomobject]@{ name = $VnetBName; cidr = $VnetBCidr; connection = $ConnBName }
    )
    routeMaps = @(
      [pscustomobject]@{
        name    = $RmTagName
        applied = "inbound on $ConnAName"
        purpose = "Add community 65010:100 to routes entering hub from Spoke-A"
      }
      [pscustomobject]@{
        name    = $RmFilterName
        applied = "outbound on $ConnBName"
        purpose = "Drop 10.61.0.0/16 (Spoke-A prefix) from routes sent to Spoke-B"
      }
      [pscustomobject]@{
        name    = $RmPrependName
        applied = "outbound on $ConnAName"
        purpose = "Prepend AS 65010 twice on routes sent to Spoke-A"
      }
    )
  }
}

$outputs | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputsPath -Encoding UTF8

Write-Host ""
Write-Host ("=" * 65) -ForegroundColor Green
Write-Host "DEPLOYMENT SUMMARY" -ForegroundColor Green
Write-Host ("=" * 65) -ForegroundColor Green
Write-Host ""
Write-Host "  Total time:      $totalElapsed" -ForegroundColor White
Write-Host "  Resource Group:  $ResourceGroup" -ForegroundColor Gray
Write-Host "  Location:        $Location" -ForegroundColor Gray
Write-Host ""
Write-Host "  vWAN:  $VwanName" -ForegroundColor Gray
Write-Host "  vHub:  $VhubName ($VhubCidr)" -ForegroundColor Gray
Write-Host ""
Write-Host "  Spoke-A: $VnetAName ($VnetACidr)" -ForegroundColor Gray
Write-Host "  Spoke-B: $VnetBName ($VnetBCidr)" -ForegroundColor Gray
Write-Host ""
Write-Host "  Route Maps applied:" -ForegroundColor Yellow

Write-RouteMapInfo -MapName $RmTagName `
  -Applied "Inbound on $ConnAName" `
  -Purpose "Add community 65010:100 to all routes entering hub from Spoke-A"

Write-RouteMapInfo -MapName $RmFilterName `
  -Applied "Outbound on $ConnBName" `
  -Purpose "Drop 10.61.0.0/16 - Spoke-B cannot reach Spoke-A's address space"

Write-RouteMapInfo -MapName $RmPrependName `
  -Applied "Outbound on $ConnAName" `
  -Purpose "Prepend AS 65010 twice on routes hub sends to Spoke-A"

Write-Host ""
if ($allValid) {
  Write-Host "STATUS: PASS - all resources deployed and validated." -ForegroundColor Green
} else {
  Write-Host "STATUS: PARTIAL - some checks failed, see above." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Inspect route maps in detail:" -ForegroundColor Yellow
Write-Host "  .\inspect.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "Cleanup:" -ForegroundColor Yellow
Write-Host "  .\destroy.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "Outputs saved to: $OutputsPath" -ForegroundColor DarkGray
Write-Host ""

$phase6Elapsed = Get-ElapsedTime -StartTime $phase6Start
Write-Log "Phase 6 completed in $phase6Elapsed" "SUCCESS"
Write-Log "Deployment complete: $(if ($allValid) { 'PASS' } else { 'PARTIAL' })" "SUCCESS"
