# labs/lab-002-l7-fastapi-appgw-frontdoor/allow-myip.ps1
param(
  [string]$Sub,
  [string]$RgName = "rg-azure-labs-lab-002",
  [string]$NsgName = "nsg-lab-002-vm",
  [string]$RuleName = "Allow-SSH-MyIP",
  [int]$Priority = 110,
  [int]$Port = 22
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "Missing required command: $name" }
}
Require-Command az

if ($Sub) { az account set --subscription $Sub | Out-Null }

$myIp = (Invoke-RestMethod -Uri "https://api.ipify.org?format=text").Trim()
if (-not $myIp) { throw "Could not determine public IP." }

Write-Host "My public IP: $myIp" -ForegroundColor Cyan

# Create/update NSG rule
az network nsg rule create `
  --resource-group $RgName `
  --nsg-name $NsgName `
  --name $RuleName `
  --priority $Priority `
  --direction Inbound `
  --access Allow `
  --protocol Tcp `
  --source-address-prefixes "$myIp/32" `
  --source-port-ranges "*" `
  --destination-address-prefixes "*" `
  --destination-port-ranges $Port `
  | Out-Null

Write-Host "Updated NSG rule '$RuleName' to allow $myIp/32 -> TCP/$Port" -ForegroundColor Green
