# labs/lab-002-l7-fastapi-appgw-frontdoor/deploy.ps1
param(
  [string]$Sub,
  [string]$Location = "centralus",

  [string]$RgName = "rg-azure-labs-lab-002",
  [string]$VnetName = "vnet-lab-002",
  [string]$AgwName  = "agw-lab-002",
  [string]$VmName   = "vm-fastapi-002",

  [string]$VnetCidr = "10.72.0.0/16",
  [string]$SubnetAgwCidr = "10.72.1.0/24",
  [string]$SubnetVmCidr  = "10.72.2.0/24",

  [string]$AdminUser = "azureuser",
  [string]$AdminPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "Missing required command: $name" }
}
function Invoke-Az([string]$cmd) {
  Write-Host "az $cmd" -ForegroundColor DarkGray
  & az @($cmd -split ' ') | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: az $cmd" }
}

Require-Command az
if (-not $AdminPassword) { throw "Provide -AdminPassword (temp lab password)." }
if ($Sub) { Invoke-Az "account set --subscription $Sub" }

# RG
Invoke-Az "group create --name $RgName --location $Location --tags owner=$env:USERNAME project=azure-labs lab=lab-002 ttlHours=8"

# VNet + subnets
Invoke-Az "network vnet create --resource-group $RgName --name $VnetName --location $Location --address-prefixes $VnetCidr"
Invoke-Az "network vnet subnet create --resource-group $RgName --vnet-name $VnetName --name snet-agw --address-prefixes $SubnetAgwCidr"
Invoke-Az "network vnet subnet create --resource-group $RgName --vnet-name $VnetName --name snet-vm  --address-prefixes $SubnetVmCidr"

# NSG for VM subnet (we’ll later auto-add your IP for SSH via allow-myip.ps1)
Invoke-Az "network nsg create --resource-group $RgName --name nsg-lab-002-vm --location $Location"
Invoke-Az "network vnet subnet update --resource-group $RgName --vnet-name $VnetName --name snet-vm --network-security-group nsg-lab-002-vm"

# Public IP for App Gateway
Invoke-Az "network public-ip create --resource-group $RgName --name pip-$AgwName --sku Standard --allocation-method Static"

# VM cloud-init (FastAPI on port 8000 with /health)
$cloudInit = @"
#cloud-config
package_update: true
packages:
  - python3-pip
  - python3-venv

runcmd:
  - bash -lc 'mkdir -p /opt/fastapi'
  - bash -lc 'cat > /opt/fastapi/main.py << "PY"
from fastapi import FastAPI
app = FastAPI()

@app.get("/health")
def health():
    return {"ok": True}

@app.get("/")
def root():
    return {"message": "Hello from FastAPI behind App Gateway + Front Door"}
PY'
  - bash -lc 'python3 -m venv /opt/fastapi/.venv'
  - bash -lc '/opt/fastapi/.venv/bin/pip install --upgrade pip'
  - bash -lc '/opt/fastapi/.venv/bin/pip install fastapi uvicorn'
  - bash -lc 'cat > /etc/systemd/system/fastapi.service << "SVC"
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
SVC'
  - bash -lc 'systemctl daemon-reload'
  - bash -lc 'systemctl enable fastapi'
  - bash -lc 'systemctl restart fastapi'
"@

$tmp = Join-Path $env:TEMP "lab-002-cloudinit.yml"
Set-Content -Path $tmp -Value $cloudInit -Encoding UTF8

# VM (no inbound NSG rule yet; we’ll add your IP with allow-myip.ps1)
Invoke-Az "vm create --resource-group $RgName --name $VmName --image Ubuntu2204 --size Standard_B1s --vnet-name $VnetName --subnet snet-vm --admin-username $AdminUser --admin-password $AdminPassword --authentication-type password --custom-data $tmp --nsg-rule NONE"

# Get VM private IP for App Gateway backend
$vmNicId = az vm show -g $RgName -n $VmName --query "networkProfile.networkInterfaces[0].id" -o tsv
$vmNicName = ($vmNicId.Split("/") | Select-Object -Last 1)
$vmPrivateIp = az network nic show -g $RgName -n $vmNicName --query "ipConfigurations[0].privateIPAddress" -o tsv
if (-not $vmPrivateIp) { throw "Could not resolve VM private IP." }

# --- Application Gateway (Standard_v2) - create minimal, then define rule w/ priority ---

# 1) Create AGW skeleton (avoid auto-created rule priority issues)
Invoke-Az "network application-gateway create --resource-group $RgName --name $AgwName --location $Location --sku Standard_v2 --capacity 1 --vnet-name $VnetName --subnet snet-agw --public-ip-address pip-$AgwName"

# 2) Backend pool -> VM private IP
Invoke-Az "network application-gateway address-pool create --resource-group $RgName --gateway-name $AgwName --name pool-fastapi --servers $vmPrivateIp"

# 3) Health probe
Invoke-Az "network application-gateway probe create --resource-group $RgName --gateway-name $AgwName --name probe-fastapi --protocol Http --host 127.0.0.1 --path /health --interval 30 --timeout 30 --threshold 3"

# 4) HTTP settings -> port 8000 + probe
Invoke-Az "network application-gateway http-settings create --resource-group $RgName --gateway-name $AgwName --name hs-fastapi --port 8000 --protocol Http --probe probe-fastapi --timeout 30"

# 5) Frontend port 80
Invoke-Az "network application-gateway frontend-port create --resource-group $RgName --gateway-name $AgwName --name feport-80 --port 80"

# 6) Listener on 80 (use existing frontend IP config)
$feIpName = az network application-gateway show -g $RgName -n $AgwName --query "frontendIPConfigurations[0].name" -o tsv
if (-not $feIpName) { throw "Could not resolve App Gateway frontend IP config name." }

Invoke-Az "network application-gateway http-listener create --resource-group $RgName --gateway-name $AgwName --name listener-80 --frontend-ip $feIpName --frontend-port feport-80 --protocol Http"

# 7) Routing rule with explicit priority (required)
Invoke-Az "network application-gateway rule create --resource-group $RgName --gateway-name $AgwName --name rule-fastapi --http-listener listener-80 --rule-type Basic --address-pool pool-fastapi --http-settings hs-fastapi --priority 100"

# Front Door (Standard) pointing to App Gateway public IP
$agwPublicIp = az network public-ip show -g $RgName -n pip-$AgwName --query ipAddress -o tsv
if (-not $agwPublicIp) { throw "Could not resolve App Gateway public IP." }

$profile = "afd-lab-002"
$endpoint = "afd-endpoint-lab-002-$((Get-Random -Minimum 10000 -Maximum 99999))"
$originGroup = "og-lab-002"
$origin = "origin-agw-lab-002"
$route = "route-lab-002"

Invoke-Az "afd profile create --resource-group $RgName --profile-name $profile --sku Standard_AzureFrontDoor"
Invoke-Az "afd endpoint create --resource-group $RgName --profile-name $profile --endpoint-name $endpoint"
Invoke-Az "afd origin-group create --resource-group $RgName --profile-name $profile --origin-group-name $originGroup --probe-request-type GET --probe-protocol Http --probe-path /health --probe-interval-in-seconds 30"
Invoke-Az "afd origin create --resource-group $RgName --profile-name $profile --origin-group-name $originGroup --origin-name $origin --host-name $agwPublicIp --http-port 80 --https-port 443 --origin-host-header $agwPublicIp --priority 1 --weight 100"
Invoke-Az "afd route create --resource-group $RgName --profile-name $profile --endpoint-name $endpoint --route-name $route --origin-group $originGroup --supported-protocols Http --patterns-to-match /* --forwarding-protocol HttpOnly --https-redirect Disabled"

$afdHost = az afd endpoint show -g $RgName --profile-name $profile --endpoint-name $endpoint --query hostName -o tsv

Write-Host ""
Write-Host "Deployed OK (Lab-002)" -ForegroundColor Green
Write-Host "App Gateway Public IP: $agwPublicIp" -ForegroundColor Cyan
Write-Host "Front Door Hostname:   http://$afdHost" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next:" -ForegroundColor Yellow
Write-Host "  1) Run .\allow-myip.ps1 to enable SSH from your current public IP"
Write-Host "  2) Test: curl http://$afdHost/health"

