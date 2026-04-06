# labs/lab-010-vwan-route-maps/destroy.ps1
# Destroys all resources created by lab-010

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

. (Join-Path $RepoRoot "scripts\labs-common.ps1")

$ResourceGroup = "rg-lab-010-vwan-route-maps"

function Get-ElapsedTime {
  param([datetime]$StartTime)
  $elapsed = (Get-Date) - $StartTime
  return "$([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
}

Write-Host ""
Write-Host "Lab 010: Destroy Resources" -ForegroundColor Cyan
Write-Host "==========================" -ForegroundColor Cyan
Write-Host ""

$destroyStartTime = Get-Date

$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null

# Check resource group
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRg = $null
$existingRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if (-not $existingRg) {
  Write-Host "Resource group '$ResourceGroup' does not exist. Nothing to delete." -ForegroundColor Yellow
  exit 0
}

# Show what will be deleted
Write-Host "Resources to delete:" -ForegroundColor Yellow
Write-Host "  Resource Group: $ResourceGroup" -ForegroundColor Gray
Write-Host "  Subscription:   $SubscriptionId" -ForegroundColor Gray
Write-Host ""

$resources = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$resources = az resource list -g $ResourceGroup --query "[].{Name:name, Type:type}" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

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
  Write-Host "This includes the vWAN Hub (10-20 min to recreate) and all Route Maps." -ForegroundColor Yellow
  $confirm = Read-Host "Type DELETE to confirm"
  if ($confirm -ne "DELETE") {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 0
  }
}

# Delete
Write-Host ""
Write-Host "Deleting resource group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "This may take 5-10 minutes..." -ForegroundColor Gray

$deleteStart = Get-Date
az group delete --name $ResourceGroup --yes --no-wait

# Wait for deletion
Write-Host "Waiting for deletion to complete..." -ForegroundColor Gray
$maxAttempts = 60
$attempt = 0
while ($attempt -lt $maxAttempts) {
  $attempt++
  $rgExists = az group exists -n $ResourceGroup 2>$null
  if ($rgExists -eq "false") { break }
  $elapsed = Get-ElapsedTime -StartTime $deleteStart
  Write-Host "  [$elapsed] Still deleting... ($attempt/$maxAttempts)" -ForegroundColor DarkGray
  Start-Sleep -Seconds 10
}

# Clean up local data
Write-Host ""
Write-Host "Cleaning up local data..." -ForegroundColor Gray

$dataDir = Join-Path $RepoRoot ".data"
$labDataDir = Join-Path $dataDir "lab-010"
if (Test-Path $labDataDir) {
  Remove-Item -Path $labDataDir -Recurse -Force
  Write-Host "  Removed: $labDataDir" -ForegroundColor DarkGray
}

if (-not $KeepLogs) {
  $logsDir = Join-Path $LabRoot "logs"
  if (Test-Path $logsDir) {
    $logFiles = @(Get-ChildItem -Path $logsDir -Filter "lab-010-*.log" -ErrorAction SilentlyContinue)
    if ($logFiles.Count -gt 0) {
      Write-Host "  Removing $($logFiles.Count) log file(s)..." -ForegroundColor DarkGray
      $logFiles | Remove-Item -Force
    }
  }
}

$totalElapsed = Get-ElapsedTime -StartTime $destroyStartTime

# Cleanup verification
Write-Host ""
Write-Host "Cleanup verification:" -ForegroundColor Yellow
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$checkRg = $null
$checkRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if ($checkRg) {
  Write-Host "  [WARN] Resource group still exists (may still be deleting)" -ForegroundColor Yellow
} else {
  Write-Host "  [PASS] Resource group deleted" -ForegroundColor Green
}

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "Cleanup complete!" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host ""
Write-Host "Total cleanup time: $totalElapsed" -ForegroundColor Gray
Write-Host ""
Write-Host "Run cost audit to confirm no billable resources remain:" -ForegroundColor Yellow
Write-Host "  .\lab.ps1 -Cost" -ForegroundColor Gray
Write-Host ""
