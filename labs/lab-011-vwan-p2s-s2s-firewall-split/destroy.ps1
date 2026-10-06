# labs/lab-011-vwan-p2s-s2s-firewall-split/destroy.ps1
# Destroys everything lab-011 created (one resource group). Idempotent.
# Keeps .data\lab-011\inspect-*.json (your measured results); removes the S2S key
# and outputs.

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
. (Join-Path (Join-Path $RepoRoot "scripts") "labs-common.ps1")
. (Join-Path (Join-Path $LabRoot "scripts") "lab-011-helpers.ps1")

Write-Host ""
Write-Host "Lab 011: Destroy Resources" -ForegroundColor Cyan
Write-Host "==========================" -ForegroundColor Cyan
Write-Host ""

$destroyStart = Get-Date
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null

$rg = Invoke-AzJson -AzArgs @("group", "show", "-n", $script:ResourceGroup)
if (-not $rg) {
  Write-Host "Resource group '$($script:ResourceGroup)' does not exist. Nothing to delete." -ForegroundColor Yellow
  exit 0
}

Write-Host "Resources to delete:" -ForegroundColor Yellow
Write-Host "  Resource Group: $($script:ResourceGroup)" -ForegroundColor Gray
Write-Host "  Subscription:   $SubscriptionId" -ForegroundColor Gray
$resources = Invoke-AzJson -AzArgs @("resource", "list", "-g", $script:ResourceGroup, "--query", "[].{Name:name, Type:type}")
if ($resources) {
  foreach ($r in @($resources)) { Write-Host "  - $($r.Name) ($($r.Type))" -ForegroundColor DarkGray }
}
Write-Host ""

if (-not $Force) {
  Write-Host "WARNING: This permanently deletes the vWAN, hub, 3 VPN gateways, 2 firewalls and all VMs." -ForegroundColor Red
  $confirm = Read-Host "Type DELETE to confirm"
  if ($confirm -ne "DELETE") { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
}

Write-Host "Deleting resource group: $($script:ResourceGroup)" -ForegroundColor Yellow
Write-Host "vWAN hubs with gateways and a firewall take 20-40 minutes to delete." -ForegroundColor Gray
$deleteStart = Get-Date
az group delete --name $script:ResourceGroup --yes --no-wait

$gone = $false
for ($i = 1; $i -le 300; $i++) {
  $exists = $null
  $oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $exists = az group exists -n $script:ResourceGroup 2>$null
  $ErrorActionPreference = $oldEap
  if ($exists -eq "false") { $gone = $true; break }
  if ($i % 6 -eq 0) { Write-Host "  [$(Get-ElapsedTime -StartTime $deleteStart)] still deleting..." -ForegroundColor DarkGray }
  Start-Sleep -Seconds 10
}

Write-Host ""
Write-Host "Cleaning up local data..." -ForegroundColor Gray
$labData = Join-Path (Join-Path $RepoRoot ".data") "lab-011"
if (Test-Path $labData) {
  foreach ($f in @(Get-ChildItem -Path $labData -File | Where-Object { $_.Name -notlike "inspect-*.json" })) {
    Remove-Item -Path $f.FullName -Force
    Write-Host "  Removed: $($f.Name)" -ForegroundColor DarkGray
  }
  Write-Host "  Kept measured results: $labData\inspect-*.json" -ForegroundColor DarkGray
}
if (-not $KeepLogs) {
  $logsDir = Join-Path $LabRoot "logs"
  if (Test-Path $logsDir) {
    $logFiles = @(Get-ChildItem -Path $logsDir -Filter "lab-011-*.log" -ErrorAction SilentlyContinue)
    if ($logFiles.Count -gt 0) { $logFiles | Remove-Item -Force; Write-Host "  Removed $($logFiles.Count) log file(s)" -ForegroundColor DarkGray }
  }
}

Write-Host ""
Write-Host "Cleanup verification:" -ForegroundColor Yellow
$check = Invoke-AzJson -AzArgs @("group", "show", "-n", $script:ResourceGroup)
if ($check) {
  Write-Host "  [WARN] Resource group still exists (deletion can outlast this wait)." -ForegroundColor Yellow
  Write-Host "         Check: az group show -n $($script:ResourceGroup) --query properties.provisioningState" -ForegroundColor Yellow
  Write-Host "         If a delete failed on the hub, re-run: .\lab.ps1 -Destroy lab-011" -ForegroundColor Yellow
} else {
  Write-Host "  [PASS] Resource group deleted" -ForegroundColor Green
}

Write-Host ""
Write-Host "Total cleanup time: $(Get-ElapsedTime -StartTime $destroyStart)" -ForegroundColor Gray
Write-Host "Confirm nothing billable remains:  .\lab.ps1 -Cost   (or .\tools\cost-check.ps1)" -ForegroundColor Yellow
Write-Host ""
if (-not $gone) { exit 1 }
exit 0
