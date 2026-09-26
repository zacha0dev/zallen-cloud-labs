# labs/lab-002-l7-fastapi-appgw-frontdoor/deploy.ps1
# L7 Load Balancing: FastAPI behind Application Gateway and Azure Front Door
#
# This lab creates:
# - VNet with subnets for AGW and VM
# - FastAPI VM with health endpoint
# - Application Gateway (Standard_v2)
# - Azure Front Door (Standard)

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [string]$Location = "centralus",
  [string]$Owner = "",
  [string]$AdminPassword,
  [string]$AdminUser = "azureuser",
  [switch]$Force
)

# ============================================
# GUARDRAILS
# ============================================
$AllowedLocations = @("centralus", "eastus", "eastus2", "westus2", "westus3", "northeurope", "westeurope")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path
$LogsDir = Join-Path $LabRoot "logs"
$OutputsPath = Join-Path $RepoRoot ".data\lab-002\outputs.json"

# Load shared helpers
. (Join-Path $RepoRoot "scripts\labs-common.ps1")

# Lab configuration
$ResourceGroup = "rg-lab-002-l7-lb"
$VnetName = "vnet-lab-002"
$VnetCidr = "10.72.0.0/16"
$SubnetAgwName = "snet-agw"
$SubnetAgwCidr = "10.72.1.0/24"
$SubnetVmName = "snet-workload"
$SubnetVmCidr = "10.72.2.0/24"
$AgwName = "agw-lab-002"
$VmName = "vm-fastapi-002"
$NsgName = "nsg-lab-002-vm"
$AfdProfile = "afd-lab-002"

# ============================================
# HELPER FUNCTIONS
# ============================================

function Require-Command($name, $installHint) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $name. $installHint"
  }
}

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Write-Phase {
  param([int]$Number, [string]$Title)
  Write-Host ""
  Write-Host ("=" * 60) -ForegroundColor Cyan
  Write-Host "PHASE $Number : $Title" -ForegroundColor Cyan
  Write-Host ("=" * 60) -ForegroundColor Cyan
  Write-Host ""
}

function Write-Validation {
  param([string]$Check, [bool]$Passed, [string]$Details = "")
  if ($Passed) {
    Write-Host "  [PASS] $Check" -ForegroundColor Green
  } else {
    Write-Host "  [FAIL] $Check" -ForegroundColor Red
  }
  if ($Details) {
    Write-Host "         $Details" -ForegroundColor DarkGray
  }
}

function Write-Log {
  param([string]$Message, [string]$Level = "INFO")
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $logLine = "[$timestamp] [$Level] $Message"
  Add-Content -Path $script:LogFile -Value $logLine

  switch ($Level) {
    "ERROR" { Write-Host $Message -ForegroundColor Red }
    "WARN"  { Write-Host $Message -ForegroundColor Yellow }
    "SUCCESS" { Write-Host $Message -ForegroundColor Green }
    default { Write-Host $Message }
  }
}

function Get-ElapsedTime {
  param([datetime]$StartTime)
  $elapsed = (Get-Date) - $StartTime
  return "$([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
}

function Assert-LocationAllowed {
  param([string]$Location, [string[]]$AllowedLocations)
  if ($AllowedLocations -notcontains $Location) {
    Write-Host ""
    Write-Host "HARD STOP: Location '$Location' is not in the allowlist." -ForegroundColor Red
    Write-Host "Allowed locations: $($AllowedLocations -join ', ')" -ForegroundColor Yellow
    throw "Location '$Location' not allowed."
  }
}

# ============================================
# MAIN DEPLOYMENT
# ============================================

Write-Host ""
Write-Host "Lab 002: L7 Load Balancing (FastAPI + AGW + Front Door)" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Purpose: Deploy FastAPI app behind Application Gateway and Front Door." -ForegroundColor White
Write-Host ""

$deploymentStartTime = Get-Date

# ============================================
# PHASE 0: Preflight
# ============================================
Write-Phase -Number 0 -Title "Preflight Checks"

$phase0Start = Get-Date

# Initialize log directory and file
Ensure-Directory $LogsDir
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$script:LogFile = Join-Path $LogsDir "lab-002-$timestamp.log"
Write-Log "Deployment started"
Write-Log "Location: $Location"

# Check Azure CLI
Require-Command az "Install Azure CLI: https://aka.ms/installazurecli"
Write-Validation -Check "Azure CLI installed" -Passed $true

# Check location
Assert-LocationAllowed -Location $Location -AllowedLocations $AllowedLocations
Write-Validation -Check "Location '$Location' allowed" -Passed $true

# Check AdminPassword
if (-not $AdminPassword) {
  throw "Provide -AdminPassword (temporary lab password for VM)."
}
Write-Validation -Check "AdminPassword provided" -Passed $true

# Load config
Show-ConfigPreflight -RepoRoot $RepoRoot
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Write-Validation -Check "Subscription resolved" -Passed $true -Details $SubscriptionId

# Azure auth
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null
$subName = az account show --query name -o tsv
Write-Validation -Check "Azure authenticated" -Passed $true -Details $subName

# Set owner from environment if not provided
if (-not $Owner) {
  $Owner = $env:USERNAME
  if (-not $Owner) { $Owner = $env:USER }
  if (-not $Owner) { $Owner = "unknown" }
}

Write-Log "Preflight checks passed" "SUCCESS"

# Cost warning
Write-Host ""
Write-Host "Cost estimate: ~`$0.31/hour" -ForegroundColor Yellow
Write-Host "  Application Gateway (Standard_v2): ~`$0.25/hr" -ForegroundColor Gray
Write-Host "  Azure Front Door (Standard): ~`$0.05/hr (`$35/month base fee) + requests/data" -ForegroundColor Gray
Write-Host "  VM (Standard_B1s): ~`$0.01/hr" -ForegroundColor Gray
Write-Host "  VNets: minimal" -ForegroundColor Gray
Write-Host ""

if (-not $Force) {
  $confirm = Read-Host "Type DEPLOY to proceed"
  if ($confirm -ne "DEPLOY") { throw "Cancelled." }
}

# Portal link
$portalUrl = "https://portal.azure.com/#@/resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/overview"
Write-Host ""
Write-Host "Azure Portal:" -ForegroundColor Yellow
Write-Host "  $portalUrl" -ForegroundColor Cyan
Write-Host ""
Write-Host "Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host ""

$phase0Elapsed = Get-ElapsedTime -StartTime $phase0Start
Write-Log "Phase 0 completed in $phase0Elapsed" "SUCCESS"

# ============================================
# PHASE 1: Core Fabric (RG + VNet + Subnets)
# ============================================
Write-Phase -Number 1 -Title "Core Fabric (VNet + Subnets)"

$phase1Start = Get-Date

# Build tags
# Standard tags (project, lab, owner, environment, cost-center) from labs-common.ps1
$labTags = Get-LabTags -LabId "lab-002" -Owner $Owner
$tagArgs = Get-LabTagArgs -Tags $labTags

# Create Resource Group
Write-Host "Creating resource group: $ResourceGroup" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if ($existingRg) {
  Write-Host "  Resource group already exists, skipping..." -ForegroundColor DarkGray
} else {
  az group create --name $ResourceGroup --location $Location --tags @tagArgs --output none
  Write-Log "Resource group created: $ResourceGroup"
}

# Create VNet
Write-Host "Creating VNet: $VnetName" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingVnet = az network vnet show -g $ResourceGroup -n $VnetName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if ($existingVnet) {
  Write-Host "  VNet already exists, skipping..." -ForegroundColor DarkGray
} else {
  az network vnet create `
    --resource-group $ResourceGroup `
    --name $VnetName `
    --location $Location `
    --address-prefixes $VnetCidr `
    --tags @tagArgs `
    --output none
  Write-Log "VNet created: $VnetName"
}

# Create AGW subnet
Write-Host "Creating subnet: $SubnetAgwName" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingAgwSnet = az network vnet subnet show -g $ResourceGroup --vnet-name $VnetName -n $SubnetAgwName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if ($existingAgwSnet) {
  Write-Host "  Subnet already exists, skipping..." -ForegroundColor DarkGray
} else {
  az network vnet subnet create `
    --resource-group $ResourceGroup `
    --vnet-name $VnetName `
    --name $SubnetAgwName `
    --address-prefixes $SubnetAgwCidr `
    --output none
  Write-Log "Subnet created: $SubnetAgwName"
}

# Create VM subnet
Write-Host "Creating subnet: $SubnetVmName" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingVmSnet = az network vnet subnet show -g $ResourceGroup --vnet-name $VnetName -n $SubnetVmName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if ($existingVmSnet) {
  Write-Host "  Subnet already exists, skipping..." -ForegroundColor DarkGray
} else {
  az network vnet subnet create `
    --resource-group $ResourceGroup `
    --vnet-name $VnetName `
    --name $SubnetVmName `
    --address-prefixes $SubnetVmCidr `
    --output none
  Write-Log "Subnet created: $SubnetVmName"
}

# Create NSG
Write-Host "Creating NSG: $NsgName" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingNsg = az network nsg show -g $ResourceGroup -n $NsgName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if ($existingNsg) {
  Write-Host "  NSG already exists, skipping..." -ForegroundColor DarkGray
} else {
  az network nsg create `
    --resource-group $ResourceGroup `
    --name $NsgName `
    --location $Location `
    --tags @tagArgs `
    --output none
  az network vnet subnet update `
    --resource-group $ResourceGroup `
    --vnet-name $VnetName `
    --name $SubnetVmName `
    --network-security-group $NsgName `
    --output none
  Write-Log "NSG created and attached: $NsgName"
}

# Create Public IP for AGW
$pipName = "pip-$AgwName"
Write-Host "Creating Public IP: $pipName" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingPip = az network public-ip show -g $ResourceGroup -n $pipName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if ($existingPip) {
  Write-Host "  Public IP already exists, skipping..." -ForegroundColor DarkGray
} else {
  az network public-ip create `
    --resource-group $ResourceGroup `
    --name $pipName `
    --sku Standard `
    --allocation-method Static `
    --tags @tagArgs `
    --output none
  Write-Log "Public IP created: $pipName"
}

$phase1Elapsed = Get-ElapsedTime -StartTime $phase1Start
Write-Log "Phase 1 completed in $phase1Elapsed" "SUCCESS"

# ============================================
# PHASE 2: Primary Feature Resources (App Gateway)
# ============================================
Write-Phase -Number 2 -Title "Primary Feature Resources (Application Gateway)"

$phase2Start = Get-Date

# Create Application Gateway
Write-Host "Creating Application Gateway: $AgwName (5-10 minutes)" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingAgw = az network application-gateway show -g $ResourceGroup -n $AgwName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if ($existingAgw -and $existingAgw.provisioningState -eq "Succeeded") {
  Write-Host "  Application Gateway already exists, skipping..." -ForegroundColor DarkGray
} else {
  az network application-gateway create `
    --resource-group $ResourceGroup `
    --name $AgwName `
    --location $Location `
    --sku Standard_v2 `
    --capacity 1 `
    --vnet-name $VnetName `
    --subnet $SubnetAgwName `
    --public-ip-address $pipName `
    --tags @tagArgs `
    --output none
  Write-Log "Application Gateway created: $AgwName"
}

$phase2Elapsed = Get-ElapsedTime -StartTime $phase2Start
Write-Log "Phase 2 completed in $phase2Elapsed" "SUCCESS"

# ============================================
# PHASE 3: Secondary Resources (FastAPI VM)
# ============================================
Write-Phase -Number 3 -Title "Secondary Resources (FastAPI VM)"

$phase3Start = Get-Date

# Create VM with cloud-init for FastAPI
Write-Host "Creating FastAPI VM: $VmName" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingVm = az vm show -g $ResourceGroup -n $VmName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if ($existingVm) {
  Write-Host "  VM already exists, skipping..." -ForegroundColor DarkGray
} else {
  # Create cloud-init file
  $cloudInit = @"
#cloud-config
package_update: true
packages:
  - python3-pip
  - python3-venv

runcmd:
  - mkdir -p /opt/fastapi
  - |
    cat > /opt/fastapi/main.py << 'PYEOF'
from fastapi import FastAPI
app = FastAPI()

@app.get("/health")
def health():
    return {"ok": True}

@app.get("/")
def root():
    return {"message": "Hello from FastAPI behind App Gateway + Front Door"}
PYEOF
  - python3 -m venv /opt/fastapi/.venv
  - /opt/fastapi/.venv/bin/pip install --upgrade pip
  - /opt/fastapi/.venv/bin/pip install fastapi uvicorn
  - |
    cat > /etc/systemd/system/fastapi.service << 'SVCEOF'
[Unit]
Description=FastAPI (uvicorn)
After=network.target

[Service]
WorkingDirectory=/opt/fastapi
ExecStart=/opt/fastapi/.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000
Restart=always
User=root

[Install]
WantedBy=multi-user.target
SVCEOF
  - systemctl daemon-reload
  - systemctl enable fastapi
  - systemctl start fastapi
"@

  $tempDir = Join-Path $RepoRoot ".data\lab-002"
  Ensure-Directory $tempDir
  $cloudInitPath = Join-Path $tempDir "cloud-init.yml"
  $cloudInit | Out-File -FilePath $cloudInitPath -Encoding utf8

  az vm create `
    --resource-group $ResourceGroup `
    --name $VmName `
    --image Ubuntu2204 `
    --size Standard_B1s `
    --vnet-name $VnetName `
    --subnet $SubnetVmName `
    --admin-username $AdminUser `
    --admin-password $AdminPassword `
    --authentication-type password `
    --custom-data $cloudInitPath `
    --nsg-rule NONE `
    --tags @tagArgs `
    --output none
  Write-Log "FastAPI VM created: $VmName"
}

# Get VM private IP
$vmNicId = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vmNicId = az vm show -g $ResourceGroup -n $VmName --query "networkProfile.networkInterfaces[0].id" -o tsv
$ErrorActionPreference = $oldEap
if (-not $vmNicId) { throw "Could not resolve NIC for VM $VmName." }
$vmNicName = ($vmNicId.Split("/") | Select-Object -Last 1)
$vmPrivateIp = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vmPrivateIp = az network nic show -g $ResourceGroup -n $vmNicName --query "ipConfigurations[0].privateIPAddress" -o tsv
$ErrorActionPreference = $oldEap
if (-not $vmPrivateIp) { throw "Could not resolve VM private IP." }

Write-Host "  VM Private IP: $vmPrivateIp" -ForegroundColor Gray

$phase3Elapsed = Get-ElapsedTime -StartTime $phase3Start
Write-Log "Phase 3 completed in $phase3Elapsed" "SUCCESS"

# ============================================
# PHASE 4: Connections / Bindings (AGW + Front Door)
# ============================================
Write-Phase -Number 4 -Title "Connections (AGW Backend + Front Door)"

$phase4Start = Get-Date

# Configure Application Gateway backend
Write-Host "Configuring Application Gateway backend pool..." -ForegroundColor Gray

# Check if backend pool exists
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingPool = az network application-gateway address-pool show -g $ResourceGroup --gateway-name $AgwName -n pool-fastapi -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if (-not $existingPool) {
  az network application-gateway address-pool create `
    --resource-group $ResourceGroup `
    --gateway-name $AgwName `
    --name pool-fastapi `
    --servers $vmPrivateIp `
    --output none
  Write-Log "AGW backend pool created: pool-fastapi"
}

# Health probe
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingProbe = az network application-gateway probe show -g $ResourceGroup --gateway-name $AgwName -n probe-fastapi -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if (-not $existingProbe) {
  az network application-gateway probe create `
    --resource-group $ResourceGroup `
    --gateway-name $AgwName `
    --name probe-fastapi `
    --protocol Http `
    --host 127.0.0.1 `
    --path /health `
    --interval 30 `
    --timeout 30 `
    --threshold 3 `
    --output none
  Write-Log "AGW health probe created: probe-fastapi"
}

# HTTP settings
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingSettings = az network application-gateway http-settings show -g $ResourceGroup --gateway-name $AgwName -n hs-fastapi -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if (-not $existingSettings) {
  az network application-gateway http-settings create `
    --resource-group $ResourceGroup `
    --gateway-name $AgwName `
    --name hs-fastapi `
    --port 8000 `
    --protocol Http `
    --probe probe-fastapi `
    --timeout 30 `
    --output none
  Write-Log "AGW HTTP settings created: hs-fastapi"
}

# Frontend port 80
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingFePort = az network application-gateway frontend-port show -g $ResourceGroup --gateway-name $AgwName -n feport-80 -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if (-not $existingFePort) {
  az network application-gateway frontend-port create `
    --resource-group $ResourceGroup `
    --gateway-name $AgwName `
    --name feport-80 `
    --port 80 `
    --output none
  Write-Log "AGW frontend port created: feport-80"
}

# Listener
$feIpName = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$feIpName = az network application-gateway show -g $ResourceGroup -n $AgwName --query "frontendIPConfigurations[0].name" -o tsv
$ErrorActionPreference = $oldEap
if (-not $feIpName) { throw "Could not resolve frontend IP config for $AgwName." }
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingListener = az network application-gateway http-listener show -g $ResourceGroup --gateway-name $AgwName -n listener-80 -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if (-not $existingListener) {
  az network application-gateway http-listener create `
    --resource-group $ResourceGroup `
    --gateway-name $AgwName `
    --name listener-80 `
    --frontend-ip $feIpName `
    --frontend-port feport-80 `
    --protocol Http `
    --output none
  Write-Log "AGW listener created: listener-80"
}

# Routing rule
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRule = az network application-gateway rule show -g $ResourceGroup --gateway-name $AgwName -n rule-fastapi -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if (-not $existingRule) {
  az network application-gateway rule create `
    --resource-group $ResourceGroup `
    --gateway-name $AgwName `
    --name rule-fastapi `
    --http-listener listener-80 `
    --rule-type Basic `
    --address-pool pool-fastapi `
    --http-settings hs-fastapi `
    --priority 100 `
    --output none
  Write-Log "AGW routing rule created: rule-fastapi"
}

# Get AGW public IP
$agwPublicIp = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$agwPublicIp = az network public-ip show -g $ResourceGroup -n $pipName --query ipAddress -o tsv
$ErrorActionPreference = $oldEap
Write-Host "  Application Gateway Public IP: $agwPublicIp" -ForegroundColor Gray

# Create Azure Front Door
Write-Host ""
Write-Host "Creating Azure Front Door: $AfdProfile" -ForegroundColor Gray

$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingAfd = az afd profile show -g $ResourceGroup --profile-name $AfdProfile -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

$endpointName = "afd-endpoint-lab-002"

if (-not $existingAfd) {
  az afd profile create `
    --resource-group $ResourceGroup `
    --profile-name $AfdProfile `
    --sku Standard_AzureFrontDoor `
    --output none
  Write-Log "Front Door profile created: $AfdProfile"
}

# Endpoint
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingEndpoint = az afd endpoint show -g $ResourceGroup --profile-name $AfdProfile --endpoint-name $endpointName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if (-not $existingEndpoint) {
  az afd endpoint create `
    --resource-group $ResourceGroup `
    --profile-name $AfdProfile `
    --endpoint-name $endpointName `
    --output none
  Write-Log "Front Door endpoint created: $endpointName"
}

# Origin group
$originGroupName = "og-lab-002"
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingOg = az afd origin-group show -g $ResourceGroup --profile-name $AfdProfile --origin-group-name $originGroupName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if (-not $existingOg) {
  az afd origin-group create `
    --resource-group $ResourceGroup `
    --profile-name $AfdProfile `
    --origin-group-name $originGroupName `
    --probe-request-type GET `
    --probe-protocol Http `
    --probe-path /health `
    --probe-interval-in-seconds 30 `
    --output none
  Write-Log "Front Door origin group created: $originGroupName"
}

# Origin
$originName = "origin-agw"
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingOrigin = az afd origin show -g $ResourceGroup --profile-name $AfdProfile --origin-group-name $originGroupName --origin-name $originName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if (-not $existingOrigin) {
  az afd origin create `
    --resource-group $ResourceGroup `
    --profile-name $AfdProfile `
    --origin-group-name $originGroupName `
    --origin-name $originName `
    --host-name $agwPublicIp `
    --http-port 80 `
    --https-port 443 `
    --origin-host-header $agwPublicIp `
    --priority 1 `
    --weight 100 `
    --output none
  Write-Log "Front Door origin created: $originName"
}

# Route
$routeName = "route-lab-002"
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRoute = az afd route show -g $ResourceGroup --profile-name $AfdProfile --endpoint-name $endpointName --route-name $routeName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

if (-not $existingRoute) {
  az afd route create `
    --resource-group $ResourceGroup `
    --profile-name $AfdProfile `
    --endpoint-name $endpointName `
    --route-name $routeName `
    --origin-group $originGroupName `
    --supported-protocols Http `
    --patterns-to-match "/*" `
    --forwarding-protocol HttpOnly `
    --https-redirect Disabled `
    --output none
  Write-Log "Front Door route created: $routeName"
}

# Get Front Door hostname
$afdHost = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$afdHost = az afd endpoint show -g $ResourceGroup --profile-name $AfdProfile --endpoint-name $endpointName --query hostName -o tsv
$ErrorActionPreference = $oldEap

$phase4Elapsed = Get-ElapsedTime -StartTime $phase4Start
Write-Log "Phase 4 completed in $phase4Elapsed" "SUCCESS"

# ============================================
# PHASE 5: Validation
# ============================================
Write-Phase -Number 5 -Title "Validation"

$phase5Start = Get-Date

Write-Host "Validating deployed resources..." -ForegroundColor Gray
Write-Host ""

$allValid = $true

# Validate VNet
$vnet = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vnet = az network vnet show -g $ResourceGroup -n $VnetName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEap
$vnetValid = ($vnet -ne $null)
Write-Validation -Check "VNet exists" -Passed $vnetValid -Details $VnetName
if (-not $vnetValid) { $allValid = $false }

# Validate Application Gateway
$agw = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$agw = az network application-gateway show -g $ResourceGroup -n $AgwName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEap
$agwValid = ($agw -ne $null -and $agw.provisioningState -eq "Succeeded")
Write-Validation -Check "Application Gateway provisioned" -Passed $agwValid -Details "$AgwName (Standard_v2)"
if (-not $agwValid) { $allValid = $false }

# Validate VM
$vm = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vm = az vm show -g $ResourceGroup -n $VmName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEap
$vmValid = ($vm -ne $null)
Write-Validation -Check "FastAPI VM exists" -Passed $vmValid -Details "$VmName (IP: $vmPrivateIp)"
if (-not $vmValid) { $allValid = $false }

# Validate Front Door
$afd = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$afd = az afd profile show -g $ResourceGroup --profile-name $AfdProfile -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEap
$afdValid = ($afd -ne $null)
Write-Validation -Check "Front Door profile exists" -Passed $afdValid -Details $AfdProfile
if (-not $afdValid) { $allValid = $false }

# Validate tags
$rg = $null
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$rg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEap
$rgTags = $rg.tags
$tagsValid = ($rgTags.project -eq "azure-labs" -and $rgTags.lab -eq "lab-002")
Write-Validation -Check "Tags applied correctly" -Passed $tagsValid -Details "project=azure-labs, lab=lab-002"
if (-not $tagsValid) { $allValid = $false }

$phase5Elapsed = Get-ElapsedTime -StartTime $phase5Start
Write-Log "Phase 5 completed in $phase5Elapsed" "SUCCESS"

# ============================================
# PHASE 6: Summary + Cleanup Guidance
# ============================================
Write-Phase -Number 6 -Title "Summary + Cleanup Guidance"

$phase6Start = Get-Date
$totalElapsed = Get-ElapsedTime -StartTime $deploymentStartTime

# Save outputs
Ensure-Directory (Split-Path -Parent $OutputsPath)

$outputs = [pscustomobject]@{
  metadata = [pscustomobject]@{
    lab = "lab-002"
    deployedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    deploymentTime = $totalElapsed
    status = if ($allValid) { "PASS" } else { "PARTIAL" }
    tags = @{
      project = "azure-labs"
      lab = "lab-002"
      owner = $Owner
      environment = "lab"
      "cost-center" = "learning"
    }
  }
  azure = [pscustomobject]@{
    subscriptionId = $SubscriptionId
    location = $Location
    resourceGroup = $ResourceGroup
    vnet = $VnetName
    appGateway = [pscustomobject]@{
      name = $AgwName
      publicIp = $agwPublicIp
    }
    vm = [pscustomobject]@{
      name = $VmName
      privateIp = $vmPrivateIp
    }
    frontDoor = [pscustomobject]@{
      profile = $AfdProfile
      endpoint = $endpointName
      hostname = $afdHost
    }
  }
  endpoints = [pscustomobject]@{
    appGateway = "http://$agwPublicIp"
    frontDoor = "http://$afdHost"
  }
}

$outputs | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputsPath -Encoding UTF8

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "DEPLOYMENT SUMMARY" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host ""
Write-Host "Results:" -ForegroundColor Yellow
Write-Host "  Total deployment time: $totalElapsed" -ForegroundColor White
Write-Host "  Resource Group: $ResourceGroup" -ForegroundColor Gray
Write-Host "  Location: $Location" -ForegroundColor Gray
Write-Host ""
Write-Host "  Application Gateway: $AgwName" -ForegroundColor Gray
Write-Host "  VM: $VmName (FastAPI on port 8000)" -ForegroundColor Gray
Write-Host "  Front Door: $AfdProfile" -ForegroundColor Gray
Write-Host ""
Write-Host "Endpoints:" -ForegroundColor Yellow
Write-Host "  App Gateway:  http://$agwPublicIp" -ForegroundColor Cyan
Write-Host "  Front Door:   http://$afdHost" -ForegroundColor Cyan
Write-Host ""

if ($allValid) {
  Write-Host "STATUS: PASS" -ForegroundColor Green
  Write-Host "  All resources created and validated successfully." -ForegroundColor Green
} else {
  Write-Host "STATUS: PARTIAL" -ForegroundColor Yellow
  Write-Host "  Some validations failed. Check above for details." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Test the deployment:" -ForegroundColor Yellow
Write-Host "  curl http://$afdHost/health" -ForegroundColor Gray
Write-Host "  curl http://$afdHost/" -ForegroundColor Gray
Write-Host ""
Write-Host "Outputs saved to: $OutputsPath" -ForegroundColor Gray
Write-Host "Log saved to: $script:LogFile" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  - Run ./allow-myip.ps1 to enable SSH access" -ForegroundColor Gray
Write-Host "  - Review validation: docs/validation.md" -ForegroundColor Gray
Write-Host "  - Cleanup: ./destroy.ps1" -ForegroundColor Gray
Write-Host ""

$phase6Elapsed = Get-ElapsedTime -StartTime $phase6Start
Write-Log "Phase 6 completed in $phase6Elapsed" "SUCCESS"
Write-Log "Deployment completed with status: $(if ($allValid) { 'PASS' } else { 'PARTIAL' })" "SUCCESS"
