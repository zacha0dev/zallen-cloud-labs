# labs/lab-006-vwan-spoke-bgp-router-loopback/destroy.ps1
# Destroys all resources created by lab-006

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
$ResourceGroup = "rg-lab-006-vwan-bgp-router"

Write-Host ""
Write-Host "Lab 006: Destroy Resources" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan
Write-Host ""

# Check for Azure CLI
if (-not (Get-Command "az" -ErrorAction SilentlyContinue)) {
  throw "Azure CLI not found. Install from: https://aka.ms/installazurecli"
}

# Get subscription
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null

# Check if resource group exists
$existingRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
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
$resources = az resource list -g $ResourceGroup --query "[].{Name:name, Type:type}" -o json 2>$null | ConvertFrom-Json
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

$startTime = Get-Date

az group delete --name $ResourceGroup --yes --no-wait

# Wait for deletion
Write-Host "Waiting for deletion to complete..." -ForegroundColor Gray
$maxAttempts = 60
$attempt = 0

while ($attempt -lt $maxAttempts) {
  $attempt++
  $rgExists = az group exists -n $ResourceGroup 2>$null
  if ($rgExists -eq "false") {
    break
  }

  $elapsed = (Get-Date) - $startTime
  $elapsedStr = "$([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
  Write-Host "  [$elapsedStr] Still deleting... (attempt $attempt/$maxAttempts)" -ForegroundColor DarkGray
  Start-Sleep -Seconds 15
}

$totalElapsed = (Get-Date) - $startTime
$totalStr = "$([math]::Floor($totalElapsed.TotalMinutes))m $($totalElapsed.Seconds)s"

Write-Host ""
Write-Host "Resource group deleted in $totalStr" -ForegroundColor Green

# Clean up local data
$dataDir = Join-Path $RepoRoot ".data\lab-006"
if (Test-Path $dataDir) {
  Write-Host "Cleaning up local data: $dataDir" -ForegroundColor Gray
  Remove-Item -Path $dataDir -Recurse -Force
}

# Optionally clean up logs
if (-not $KeepLogs) {
  $logsDir = Join-Path $LabRoot "logs"
  if (Test-Path $logsDir) {
    $logFiles = Get-ChildItem -Path $logsDir -Filter "lab-006-*.log"
    if ($logFiles.Count -gt 0) {
      Write-Host "Cleaning up $($logFiles.Count) log file(s)..." -ForegroundColor Gray
      $logFiles | Remove-Item -Force
    }
  }
}

Write-Host ""
Write-Host "Cleanup complete!" -ForegroundColor Green
Write-Host ""
