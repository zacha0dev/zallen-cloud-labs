# labs/lab-007-azure-dns-foundations/destroy.ps1
# Destroys all resources created by lab-007
# Idempotent: safe to run multiple times

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

$ResourceGroup = "rg-lab-007-dns-foundations"

function Get-ElapsedTime {
  param([datetime]$StartTime)
  $elapsed = (Get-Date) - $StartTime
  return "$([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
}

Write-Host ""
Write-Host "Lab 007: Destroy Resources" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan
Write-Host ""

$destroyStartTime = Get-Date

$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null

$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if (-not $existingRg) {
  Write-Host "Resource group '$ResourceGroup' does not exist. Nothing to delete." -ForegroundColor Yellow
  exit 0
}

Write-Host "Resources to delete:" -ForegroundColor Yellow
Write-Host "  Resource Group: $ResourceGroup" -ForegroundColor Gray
Write-Host "  Subscription:   $SubscriptionId" -ForegroundColor Gray
Write-Host ""

$resources = az resource list -g $ResourceGroup --query "[].{Name:name, Type:type}" -o json 2>$null | ConvertFrom-Json
if ($resources) {
  Write-Host "Resources in group:" -ForegroundColor White
  foreach ($r in $resources) {
    Write-Host "  - $($r.Name) ($($r.Type))" -ForegroundColor DarkGray
  }
  Write-Host ""
}

if (-not $Force) {
  Write-Host "WARNING: This will permanently delete all resources!" -ForegroundColor Red
  $confirm = Read-Host "Type DELETE to confirm"
  if ($confirm -ne "DELETE") {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 0
  }
}

Write-Host ""
Write-Host "Deleting resource group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "This may take 3-5 minutes..." -ForegroundColor Gray

$deleteStartTime = Get-Date
az group delete --name $ResourceGroup --yes --no-wait

Write-Host "Waiting for deletion to complete..." -ForegroundColor Gray
$maxAttempts = 60
$attempt     = 0

while ($attempt -lt $maxAttempts) {
  $attempt++
  $rgExists = az group exists -n $ResourceGroup 2>$null
  if ($rgExists -eq "false") { break }

  $elapsed = Get-ElapsedTime -StartTime $deleteStartTime
  Write-Host "  [$elapsed] Still deleting... (attempt $attempt/$maxAttempts)" -ForegroundColor DarkGray
  Start-Sleep -Seconds 10
}

$deleteElapsed = Get-ElapsedTime -StartTime $deleteStartTime

$rgStillExists = (az group exists -n $ResourceGroup 2>$null) -eq "true"
if (-not $rgStillExists) {
  Write-Host "  [PASS] Resource group deleted: $ResourceGroup" -ForegroundColor Green
} else {
  Write-Host "  [FAIL] Resource group may still exist — check Azure Portal" -ForegroundColor Yellow
  Write-Host "         az group show -n $ResourceGroup" -ForegroundColor DarkGray
}

# Clean up local data
Write-Host ""
Write-Host "Cleaning up local data..." -ForegroundColor Gray

$dataDir = Join-Path $RepoRoot ".data/lab-007"
if (Test-Path $dataDir) {
  Remove-Item -Path $dataDir -Recurse -Force
  Write-Host "  Removed: $dataDir" -ForegroundColor DarkGray
}

if (-not $KeepLogs) {
  $logsDir  = Join-Path $LabRoot "logs"
  if (Test-Path $logsDir) {
    $logFiles = @(Get-ChildItem -Path $logsDir -Filter "lab-007-*.log" -ErrorAction SilentlyContinue)
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
Write-Host "Deletion time:  $deleteElapsed" -ForegroundColor Gray
Write-Host "Total time:     $totalElapsed" -ForegroundColor Gray
Write-Host ""
Write-Host "Cost check (confirm no billable resources remain):" -ForegroundColor Yellow
Write-Host "  .\..\..\tools\cost-check.ps1 -Lab lab-007" -ForegroundColor Gray
Write-Host ""
