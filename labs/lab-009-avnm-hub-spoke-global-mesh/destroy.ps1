# labs/lab-009-avnm-hub-spoke-global-mesh/destroy.ps1
# Destroys all resources created by lab-009 (idempotent)
#
# Teardown order (dependencies must be removed first):
#   1. Undeploy AVNM configurations (post-commit with empty config list)
#      This removes all AVNM-managed VNet peerings before we delete VNets.
#   2. Delete resource group (removes VNets, network groups, AVNM, all peerings)
#   3. Clean up local .data/lab-009/

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [switch]$Force,
  [switch]$KeepLogs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot  = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path

. (Join-Path $RepoRoot "scripts\labs-common.ps1")

$ResourceGroup = "rg-lab-009-avnm"
$AvnmName      = "avnm-lab-009"

function Get-ElapsedTime {
  param([datetime]$StartTime)
  $elapsed = (Get-Date) - $StartTime
  return "$([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
}

Write-Host ""
Write-Host "Lab 009: Destroy Resources" -ForegroundColor Cyan
Write-Host "==========================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Removes: AVNM instance, all managed peerings, 4 VNets, resource group." -ForegroundColor DarkGray
Write-Host ""

$destroyStart = Get-Date

$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null

# Check resource group exists
$oldEP = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"
$existingRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if (-not $existingRg) {
  Write-Host "Resource group '$ResourceGroup' does not exist. Nothing to delete." -ForegroundColor Yellow
  exit 0
}

# List current resources for confirmation
$resources = az resource list -g $ResourceGroup --query "[].{Name:name, Type:type}" -o json 2>$null | ConvertFrom-Json
Write-Host "Resources to delete:" -ForegroundColor Yellow
Write-Host "  Resource Group  : $ResourceGroup" -ForegroundColor Gray
Write-Host "  Subscription    : $SubscriptionId" -ForegroundColor Gray
Write-Host ""
if ($resources) {
  Write-Host "Resources in group:" -ForegroundColor White
  foreach ($r in $resources) {
    Write-Host "  - $($r.Name) ($($r.Type))" -ForegroundColor DarkGray
  }
  Write-Host ""
}

if (-not $Force) {
  Write-Host "WARNING: This will permanently delete all resources!" -ForegroundColor Red
  Write-Host "  Includes: AVNM, all managed peerings, 4 VNets, and any Global Mesh config you added." -ForegroundColor Yellow
  $confirm = Read-Host "Type DELETE to confirm"
  if ($confirm -ne "DELETE") {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 0
  }
}

# ============================================
# STEP 1: Undeploy AVNM configurations
# ============================================
# AVNM creates managed peerings on VNets. If we delete the resource group
# without undeploying first, the managed peerings may leave ghost state.
# Sending a post-commit with an empty configuration-ids list removes all
# deployed configurations and their associated peerings cleanly.
# ============================================
Write-Host ""
Write-Host "Step 1: Undeploying AVNM configurations..." -ForegroundColor Yellow

$oldEP = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"
$avnmExists = az network manager show `
  --name $AvnmName `
  --resource-group $ResourceGroup `
  -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if ($avnmExists) {
  # Determine which regions have active deployments
  $activeRegions = @()
  $activeConnConfigs = az network manager list-deploy-status `
    --network-manager-name $AvnmName `
    --resource-group $ResourceGroup `
    --regions "eastus" "westus2" "eastus2" "westeurope" `
    -o json 2>$null | ConvertFrom-Json

  if ($activeConnConfigs -and $activeConnConfigs.value) {
    foreach ($dep in $activeConnConfigs.value) {
      if ($dep.region -and $activeRegions -notcontains $dep.region) {
        $activeRegions += $dep.region
      }
    }
  }

  # Fall back to default regions if we couldn't determine from status
  if ($activeRegions.Count -eq 0) {
    $activeRegions = @("eastus", "westus2")
    Write-Host "  Could not determine active regions; using defaults: $($activeRegions -join ', ')" -ForegroundColor DarkGray
  } else {
    Write-Host "  Found active deployments in: $($activeRegions -join ', ')" -ForegroundColor DarkGray
  }

  Write-Host "  Sending empty post-commit to remove managed peerings..." -ForegroundColor Gray
  $oldEP = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  az network manager post-commit `
    --network-manager-name $AvnmName `
    --resource-group $ResourceGroup `
    --commit-type Connectivity `
    --target-locations $activeRegions `
    --configuration-ids @() 2>$null | Out-Null
  $ErrorActionPreference = $oldEP

  Write-Host "  [PASS] Undeploy committed. Waiting 30s for peerings to be removed..." -ForegroundColor Green
  Start-Sleep -Seconds 30
} else {
  Write-Host "  [SKIP] AVNM instance not found - skipping undeploy." -ForegroundColor DarkGray
}

# ============================================
# STEP 2: Delete resource group
# ============================================
Write-Host ""
Write-Host "Step 2: Deleting resource group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "  This may take 3-6 minutes..." -ForegroundColor Gray

$deleteStart = Get-Date
az group delete --name $ResourceGroup --yes --no-wait

Write-Host "  Waiting for deletion to complete..." -ForegroundColor Gray
$maxAttempts = 60   # 10 minutes max
$attempt     = 0

while ($attempt -lt $maxAttempts) {
  $attempt++
  $rgExists = az group exists -n $ResourceGroup 2>$null
  if ($rgExists -eq "false") { break }

  $elapsed = Get-ElapsedTime -StartTime $deleteStart
  Write-Host "  [$elapsed] Still deleting... (attempt $attempt/$maxAttempts)" -ForegroundColor DarkGray
  Start-Sleep -Seconds 10
}

$deleteElapsed = Get-ElapsedTime -StartTime $deleteStart
$rgStillExists = (az group exists -n $ResourceGroup 2>$null) -eq "true"

if (-not $rgStillExists) {
  Write-Host "  [PASS] Resource group deleted: $ResourceGroup" -ForegroundColor Green
} else {
  Write-Host "  [FAIL] Resource group may still exist - check Azure Portal" -ForegroundColor Yellow
  Write-Host "         az group show -n $ResourceGroup" -ForegroundColor DarkGray
}

# ============================================
# STEP 3: Local cleanup
# ============================================
Write-Host ""
Write-Host "Step 3: Cleaning up local data..." -ForegroundColor Gray

$dataDir = Join-Path $RepoRoot ".data\lab-009"
if (Test-Path $dataDir) {
  Remove-Item -Path $dataDir -Recurse -Force
  Write-Host "  Removed: $dataDir" -ForegroundColor DarkGray
}

# ============================================
# SUMMARY
# ============================================
$totalElapsed = Get-ElapsedTime -StartTime $destroyStart

Write-Host ""
Write-Host ("=" * 55) -ForegroundColor Green
Write-Host " Lab 009 cleanup complete!" -ForegroundColor Green
Write-Host ("=" * 55) -ForegroundColor Green
Write-Host ""
Write-Host "  Deletion time : $deleteElapsed" -ForegroundColor Gray
Write-Host "  Total time    : $totalElapsed" -ForegroundColor Gray
Write-Host ""
Write-Host "Cleanup verification:" -ForegroundColor Yellow
$rgCheck = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
if ($rgCheck) {
  Write-Host "  [WARN] Resource group still exists: $ResourceGroup" -ForegroundColor Yellow
  Write-Host "         Check Azure Portal for remaining resources." -ForegroundColor Gray
} else {
  Write-Host "  [PASS] Resource group deleted: $ResourceGroup" -ForegroundColor Green
}

Write-Host ""
Write-Host "Run to confirm no billable resources remain:" -ForegroundColor DarkGray
Write-Host "  ..\..\tools\cost-check.ps1" -ForegroundColor Gray
Write-Host ""
