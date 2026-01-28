# labs/lab-004-vwan-default-route-propagation/scripts/destroy.ps1
# Destroys all lab-004 resources

[CmdletBinding()]
param(
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Clear-Host

$LabRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..")
$ConfigPath = Join-Path $RepoRoot ".data\lab-004\config.json"

function Require-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $name"
  }
}

function Require-ConfigField($obj, [string]$Name, [string]$Path) {
  if (-not $obj.PSObject.Properties[$Name] -or [string]::IsNullOrWhiteSpace("$($obj.$Name)")) {
    throw "Missing config value: $Path.$Name"
  }
  return $obj.$Name
}

# Load config
if (-not (Test-Path $ConfigPath)) {
  throw "Config not found: $ConfigPath. Nothing to destroy."
}

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$azure = $cfg.azure

$subscriptionId = Require-ConfigField $azure "subscriptionId" "azure"
$resourceGroup = Require-ConfigField $azure "resourceGroup" "azure"

Require-Command az

# Validate Azure auth
az account get-access-token 1>$null 2>$null
if ($LASTEXITCODE -ne 0) { throw "Azure CLI token expired or missing. Run: az login" }
& az account set --subscription $subscriptionId | Out-Null

# Check if resource group exists
$rgExists = az group exists --name $resourceGroup
if ($rgExists -eq "false") {
  Write-Host "Resource group '$resourceGroup' does not exist. Nothing to destroy." -ForegroundColor Yellow
  exit 0
}

if (-not $Force) {
  Write-Host ""
  Write-Host "This will delete the resource group '$resourceGroup' and ALL resources in it:" -ForegroundColor Yellow
  Write-Host "  - Virtual WAN and hubs" -ForegroundColor Gray
  Write-Host "  - All VNets and VMs" -ForegroundColor Gray
  Write-Host "  - All route tables and connections" -ForegroundColor Gray
  Write-Host ""
  $confirm = Read-Host "Type DELETE to confirm"
  if ($confirm -ne "DELETE") {
    throw "User cancelled."
  }
}

Write-Host ""
Write-Host "==> Deleting resource group '$resourceGroup'" -ForegroundColor Cyan
Write-Host "This may take 10-20 minutes (vWAN cleanup is slow)." -ForegroundColor Yellow

az group delete --name $resourceGroup --yes --no-wait

Write-Host ""
Write-Host "Resource group deletion initiated (running in background)." -ForegroundColor Green
Write-Host ""
Write-Host "Monitor progress:" -ForegroundColor White
Write-Host "  az group show --name $resourceGroup --query provisioningState -o tsv" -ForegroundColor Gray
Write-Host ""
Write-Host "Or wait synchronously:" -ForegroundColor White
Write-Host "  az group wait --name $resourceGroup --deleted" -ForegroundColor Gray
