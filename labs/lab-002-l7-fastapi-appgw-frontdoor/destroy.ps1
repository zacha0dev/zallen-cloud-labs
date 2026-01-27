# labs/lab-002-l7-fastapi-appgw-frontdoor/destroy.ps1
param(
  [string]$Sub,
  [string]$RgName = "rg-azure-labs-lab-002",
  [switch]$Wait
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Sub) { az account set --subscription $Sub | Out-Null }

Write-Host "Deleting RG: $RgName" -ForegroundColor Yellow
az group delete --name $RgName --yes --no-wait | Out-Null
Write-Host "Delete started (no-wait)." -ForegroundColor Green

if ($Wait) {
  Write-Host "Waiting for deletion..." -ForegroundColor Cyan
  az group wait --name $RgName --deleted
  Write-Host "Deleted." -ForegroundColor Green
}
