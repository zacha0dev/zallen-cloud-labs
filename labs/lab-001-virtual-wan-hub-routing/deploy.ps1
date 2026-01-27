# labs/lab-001-virtual-wan-hub-routing/deploy.ps1
param(
  [string]$Sub,

  [string]$Location = "centralus",
  [string]$RgName   = "rg-azure-labs-lab-001",

  [string]$VwanName = "vwan-lab-001",
  [string]$HubName  = "vhub-lab-001",
  [string]$VnetName = "vnet-lab-001",
  [string]$VmName   = "vm-lab-001",

  [string]$VhubCidr   = "10.60.0.0/24",
  [string]$VnetCidr   = "10.61.0.0/16",
  [string]$SubnetCidr = "10.61.1.0/24",

  [string]$AdminUser = "azureuser",
  [string]$AdminPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "Missing required command: $name" }
}

function Invoke-Az {
  param([Parameter(Mandatory=$true)][string]$Cmd)
  Write-Host "az $Cmd" -ForegroundColor DarkGray
  & az @($Cmd -split ' ') | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: az $Cmd" }
}

Require-Command az

if (-not $AdminPassword) { throw "Provide -AdminPassword (temp lab password)." }

if ($Sub) {
  Invoke-Az "account set --subscription $Sub"
} else {
  $id = (az account show --query id -o tsv 2>$null)
  if (-not $id) { throw "Not logged in. Run: az login" }
}

# RG
Invoke-Az "group create --name $RgName --location $Location --tags owner=$env:USERNAME project=azure-labs lab=lab-001 ttlHours=8"

# vWAN (Standard)
Invoke-Az "network vwan create --resource-group $RgName --name $VwanName --location $Location --type Standard"

# vHub
Invoke-Az "network vhub create --resource-group $RgName --name $HubName --location $Location --vwan $VwanName --address-prefix $VhubCidr"

# VNet + subnet
Invoke-Az "network vnet create --resource-group $RgName --name $VnetName --location $Location --address-prefixes $VnetCidr --subnet-name default --subnet-prefixes $SubnetCidr"

# Hub connection (needs vnet ID + --vhub-name)
$vnetId = az network vnet show -g $RgName -n $VnetName --query id -o tsv
if (-not $vnetId) { throw "Failed to resolve VNet ID for $VnetName" }

Invoke-Az "network vhub connection create --resource-group $RgName --name conn-$VnetName --vhub-name $HubName --remote-vnet $vnetId"

# VM (leave public IP alone; block inbound with NSG rule NONE)
Invoke-Az "vm create --resource-group $RgName --name $VmName --image Ubuntu2204 --size Standard_B1s --vnet-name $VnetName --subnet default --nsg-rule NONE --admin-username $AdminUser --admin-password $AdminPassword --authentication-type password"

Write-Host ""
Write-Host "Deployed OK: RG, vWAN, vHub, VNet, Hub Connection, VM" -ForegroundColor Green
Write-Host "Next: run .\inspect.ps1" -ForegroundColor Cyan
