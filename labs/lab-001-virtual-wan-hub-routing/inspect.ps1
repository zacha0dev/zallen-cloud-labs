# labs/lab-001-virtual-wan-hub-routing/inspect.ps1
param(
  [string]$Sub,
  [string]$RgName = "rg-azure-labs-lab-001",
  [string]$VmName = "vm-lab-001"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { throw "Missing required command: $name" }
}
Require-Command az

if ($Sub) { az account set --subscription $Sub | Out-Null }

# Find NIC + IP config
$nicId = az vm show -g $RgName -n $VmName --query "networkProfile.networkInterfaces[0].id" -o tsv
if (-not $nicId) { throw "Could not find NIC for VM $VmName in $RgName" }

$nicName = ($nicId.Split("/") | Select-Object -Last 1)
$rgFromNic = ($nicId.Split("/")[4])

$ipConfigName = az network nic show -g $rgFromNic -n $nicName --query "ipConfigurations[0].name" -o tsv

Write-Host ""
Write-Host "NIC: $nicName" -ForegroundColor Yellow
Write-Host "IP Config: $ipConfigName" -ForegroundColor Yellow
Write-Host ""

Write-Host "Effective Route Table:" -ForegroundColor Cyan
az network nic show-effective-route-table -g $rgFromNic -n $nicName
