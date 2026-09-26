# labs/lab-001-virtual-wan-hub-routing/destroy.ps1
# Destroys all resources created by lab-001

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [switch]$Force,
  [switch]$KeepLogs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path

# Load shared helpers
. (Join-Path $RepoRoot "scripts\labs-common.ps1")

# Lab configuration
$ResourceGroup = "rg-lab-001-vwan-routing"

function Get-ElapsedTime {
  param([datetime]$StartTime)
  $elapsed = (Get-Date) - $StartTime
  return "$([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
}

Write-Host ""
Write-Host "Lab 001: Destroy Resources" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan
Write-Host ""

$destroyStartTime = Get-Date

# Check for Azure CLI
if (-not (Get-Command "az" -ErrorAction SilentlyContinue)) {
  throw "Azure CLI not found. Install from: https://aka.ms/installazurecli"
}

# Get subscription
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null

# Check if resource group exists (EAP toggle so a missing group does not throw)
$existingRg = $null
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if (-not $existingRg) {
  Write-Host "Resource group '$ResourceGroup' does not exist. Nothing to delete." -ForegroundColor Yellow
  exit 0
}

# Show what will be deleted
Write-Host "Resources to delete:" -ForegroundColor Yellow
Write-Host "  Resource Group: $ResourceGroup" -ForegroundColor Gray
Write-Host "  Subscription: $SubscriptionId" -ForegroundColor Gray
Write-Host ""

# List resources in the group
$resources = $null
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$resources = az resource list -g $ResourceGroup --query "[].{Name:name, Type:type}" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
if ($resources) {
  Write-Host "Resources in group:" -ForegroundColor White
  foreach ($r in $resources) {
    Write-Host "  - $($r.Name) ($($r.Type))" -ForegroundColor DarkGray
  }
  Write-Host ""
}

# Confirmation
if (-not $Force) {
  Write-Host "WARNING: This will permanently delete all resources!" -ForegroundColor Red
  Write-Host "This includes the vWAN Hub which takes 10-20 min to recreate." -ForegroundColor Yellow
  $confirm = Read-Host "Type DELETE to confirm"
  if ($confirm -ne "DELETE") {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 0
  }
}

# Delete resource group
Write-Host ""
Write-Host "Deleting resource group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "This may take 5-10 minutes..." -ForegroundColor Gray
$deleteStartTime = Get-Date

az group delete --name $ResourceGroup --yes --no-wait

# Wait for deletion
Write-Host "Waiting for deletion to complete..." -ForegroundColor Gray
$maxAttempts = 60
$attempt = 0

while ($attempt -lt $maxAttempts) {
  $attempt++
  $rgExists = $null
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $rgExists = az group exists -n $ResourceGroup 2>$null
  $ErrorActionPreference = $oldErrPref
  if ($rgExists -eq "false") {
    break
  }

  $elapsed = Get-ElapsedTime -StartTime $deleteStartTime
  Write-Host "  [$elapsed] Still deleting... (attempt $attempt/$maxAttempts)" -ForegroundColor DarkGray
  Start-Sleep -Seconds 10
}

$deleteElapsed = Get-ElapsedTime -StartTime $deleteStartTime

# Final verification: only report success and clean up local data once the group is gone
$rgStillExists = $null
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$rgStillExists = az group exists -n $ResourceGroup 2>$null
$ErrorActionPreference = $oldErrPref

if ($rgStillExists -ne "false") {
  Write-Host ""
  Write-Host "  [WAIT] Resource group is still deleting after $deleteElapsed - $ResourceGroup" -ForegroundColor Yellow
  Write-Host "         Azure finishes the delete in the background. Local outputs were kept." -ForegroundColor DarkGray
  Write-Host "         Check progress with:  .\lab.ps1 -Cost -Lab lab-001" -ForegroundColor DarkGray
  Write-Host "         Then re-run destroy to finish local cleanup." -ForegroundColor DarkGray
  Write-Host ""
  exit 1
}

Write-Host "  [PASS] Resource group deleted: $ResourceGroup ($deleteElapsed)" -ForegroundColor Green

# Clean up local data
Write-Host ""
Write-Host "Cleaning up local data..." -ForegroundColor Gray

$dataDir = Join-Path $RepoRoot ".data\lab-001"
if (Test-Path $dataDir) {
  Remove-Item -Path $dataDir -Recurse -Force
  Write-Host "  Removed: $dataDir" -ForegroundColor DarkGray
}

# Optionally clean up logs
if (-not $KeepLogs) {
  $logsDir = Join-Path $LabRoot "logs"
  if (Test-Path $logsDir) {
    $logFiles = @(Get-ChildItem -Path $logsDir -Filter "lab-001-*.log" -ErrorAction SilentlyContinue)
    if ($logFiles.Count -gt 0) {
      Write-Host "  Removing $($logFiles.Count) log file(s)..." -ForegroundColor DarkGray
      $logFiles | Remove-Item -Force
    }
  }
}

$totalElapsed = Get-ElapsedTime -StartTime $destroyStartTime

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "Cleanup complete!" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host ""
Write-Host "Total cleanup time: $totalElapsed" -ForegroundColor Gray
Write-Host ""
