# labs/lab-004-vwan-default-route-propagation/scripts/deploy.ps1
# Deploys vWAN with two hubs demonstrating default route propagation

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
$TemplatePath = Join-Path $LabRoot "infra\main.bicep"
$ParametersPath = Join-Path $LabRoot "infra\main.parameters.json"

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

function Invoke-Az([string]$Cmd) {
  Write-Host "az $Cmd" -ForegroundColor DarkGray
  $result = & az @($Cmd -split ' ')
  if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: az $Cmd" }
  return $result
}

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
  }
}

# Load or create config
if (-not (Test-Path $ConfigPath)) {
  $templatePath = Join-Path $RepoRoot ".data\lab-004\config.template.json"
  if (Test-Path $templatePath) {
    $dir = Split-Path -Parent $ConfigPath
    Ensure-Directory $dir
    Copy-Item -Path $templatePath -Destination $ConfigPath
    Write-Host "Created $ConfigPath from template." -ForegroundColor Yellow
    Write-Host "Edit subscriptionId and adminPassword, then re-run." -ForegroundColor Yellow
    exit 1
  }
  # Create default template if missing
  $dir = Split-Path -Parent $ConfigPath
  Ensure-Directory $dir
  $defaultConfig = @{
    azure = @{
      subscriptionId = "YOUR_SUBSCRIPTION_ID"
      location = "eastus2"
      resourceGroup = "rg-lab-004-vwan-route-prop"
      adminUsername = "azureuser"
      adminPassword = "CHANGE_ME"
    }
  }
  $defaultConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8
  Write-Host "Created default config at $ConfigPath" -ForegroundColor Yellow
  Write-Host "Edit subscriptionId and adminPassword, then re-run." -ForegroundColor Yellow
  exit 1
}

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$azure = $cfg.azure

$subscriptionId = Require-ConfigField $azure "subscriptionId" "azure"
$location = Require-ConfigField $azure "location" "azure"
$resourceGroup = Require-ConfigField $azure "resourceGroup" "azure"
$adminUsername = Require-ConfigField $azure "adminUsername" "azure"
$adminPassword = Require-ConfigField $azure "adminPassword" "azure"

if ($subscriptionId -eq "YOUR_SUBSCRIPTION_ID") {
  throw "Update azure.subscriptionId in $ConfigPath before deploying."
}

if ($adminPassword -eq "CHANGE_ME") {
  throw "Update azure.adminPassword in $ConfigPath before deploying."
}

Require-Command az

# Validate Azure auth
az account get-access-token 1>$null 2>$null
if ($LASTEXITCODE -ne 0) { throw "Azure CLI token expired or missing. Run: az login" }
Invoke-Az "account set --subscription $subscriptionId"

if (-not $Force) {
  Write-Host ""
  Write-Host "This lab creates billable Azure resources (vWAN, VMs)." -ForegroundColor Yellow
  Write-Host "vWAN hubs cost ~\$0.25/hour each. VMs cost varies by size." -ForegroundColor Yellow
  $confirm = Read-Host "Type CONTINUE to proceed"
  if ($confirm -ne "CONTINUE") {
    throw "User cancelled."
  }
}

Write-Host ""
Write-Host "==> Creating resource group" -ForegroundColor Cyan
Invoke-Az "group create --name $resourceGroup --location $location --tags owner=$env:USERNAME project=azure-labs lab=lab-004 purpose=vwan-route-propagation ttlHours=8"

Write-Host ""
Write-Host "==> Deploying Bicep template" -ForegroundColor Cyan
Write-Host "This may take 30-45 minutes (vWAN hubs take time to provision)." -ForegroundColor Yellow

$deploymentName = "lab-004-deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
az deployment group create `
  --resource-group $resourceGroup `
  --name $deploymentName `
  --template-file $TemplatePath `
  --parameters $ParametersPath `
  --parameters location=$location adminUsername=$adminUsername adminPassword=$adminPassword `
  --output table

if ($LASTEXITCODE -ne 0) {
  throw "Bicep deployment failed. Check the Azure portal for details."
}

Write-Host ""
Write-Host "==> Deployment complete" -ForegroundColor Green
Write-Host ""
Write-Host "Infrastructure deployed:" -ForegroundColor White
Write-Host "  - vWAN with 2 hubs (Hub A, Hub B)" -ForegroundColor Gray
Write-Host "  - Hub A: custom route table 'rt-fw-default' with 0.0.0.0/0 -> VNet-FW" -ForegroundColor Gray
Write-Host "  - Spoke A1, A2: associated with rt-fw-default (will learn 0/0)" -ForegroundColor Gray
Write-Host "  - Spoke A3, A4: associated with Default route table (no 0/0)" -ForegroundColor Gray
Write-Host "  - Hub B: Spoke B1, B2 on Default route table (no 0/0)" -ForegroundColor Gray
Write-Host ""
Write-Host "Run validate.ps1 to check effective routes on each VM." -ForegroundColor Cyan
