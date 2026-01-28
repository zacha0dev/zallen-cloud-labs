# labs/lab-004-vwan-default-route-propagation/scripts/deploy.ps1
# Deploys vWAN with two hubs demonstrating default route propagation

[CmdletBinding()]
param(
  [ValidateSet("lab","prod")]
  [string]$SubscriptionKey = "lab",
  [string]$Location = "eastus2",
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..")
$TemplatePath = Join-Path $LabRoot "infra\main.bicep"
$ParametersPath = Join-Path $LabRoot "infra\main.parameters.json"

# Load shared helpers
. (Join-Path $RepoRoot "scripts\labs-common.ps1")

# Lab defaults - hardcoded for speed (lab environment only)
$ResourceGroup = "rg-lab-004-vwan-route-prop"
$AdminUsername = "azureuser"
$AdminPassword = "Lab004Pass#2026!"

function Require-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $name. Run scripts\setup.ps1 first."
  }
}

Require-Command az

# Get subscription from repo config
Show-ConfigPreflight -RepoRoot $RepoRoot
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot

# Validate Azure auth
az account get-access-token 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Azure CLI not authenticated. Run: az login" }
az account set --subscription $SubscriptionId | Out-Null

Write-Host ""
Write-Host "Lab 004: vWAN Default Route Propagation" -ForegroundColor Cyan
Write-Host "Subscription: $SubscriptionKey ($SubscriptionId)" -ForegroundColor Gray
Write-Host "Location: $Location" -ForegroundColor Gray
Write-Host ""

if (-not $Force) {
  Write-Host "This creates billable resources (~\$0.60/hour)." -ForegroundColor Yellow
  $confirm = Read-Host "Type DEPLOY to proceed"
  if ($confirm -ne "DEPLOY") { throw "Cancelled." }
}

Write-Host ""
Write-Host "==> Creating resource group" -ForegroundColor Cyan
az group create --name $ResourceGroup --location $Location --output none

Write-Host "==> Deploying infrastructure (30-45 min for vWAN)" -ForegroundColor Cyan

$deploymentName = "lab-004-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
az deployment group create `
  --resource-group $ResourceGroup `
  --name $deploymentName `
  --template-file $TemplatePath `
  --parameters $ParametersPath `
  --parameters location=$Location adminUsername=$AdminUsername adminPassword=$AdminPassword `
  --output table

if ($LASTEXITCODE -ne 0) { throw "Deployment failed." }

Write-Host ""
Write-Host "==> Done" -ForegroundColor Green
Write-Host "Run: .\scripts\validate.ps1" -ForegroundColor Cyan
