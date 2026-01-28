# labs/lab-004-vwan-default-route-propagation/scripts/destroy.ps1
# Destroys all lab-004 resources

[CmdletBinding()]
param(
  [ValidateSet("lab","prod")]
  [string]$SubscriptionKey = "lab",
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..")

# Load shared helpers
. (Join-Path $RepoRoot "scripts\labs-common.ps1")

$ResourceGroup = "rg-lab-004-vwan-route-prop"

# Setup
Show-ConfigPreflight -RepoRoot $RepoRoot
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
az account get-access-token 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Azure CLI not authenticated. Run: az login" }
az account set --subscription $SubscriptionId | Out-Null

# Check if exists
$exists = az group exists --name $ResourceGroup
if ($exists -eq "false") {
  Write-Host "Resource group '$ResourceGroup' does not exist." -ForegroundColor Yellow
  exit 0
}

if (-not $Force) {
  Write-Host ""
  Write-Host "Delete '$ResourceGroup' and all resources?" -ForegroundColor Yellow
  $confirm = Read-Host "Type DELETE to confirm"
  if ($confirm -ne "DELETE") { throw "Cancelled." }
}

Write-Host ""
Write-Host "==> Deleting resource group (10-20 min)" -ForegroundColor Cyan
az group delete --name $ResourceGroup --yes --no-wait

Write-Host "Deletion started in background." -ForegroundColor Green
Write-Host "Monitor: az group show -n $ResourceGroup --query provisioningState -o tsv" -ForegroundColor Gray
