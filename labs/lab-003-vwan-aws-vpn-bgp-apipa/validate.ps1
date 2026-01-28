# labs/lab-003-vwan-aws-vpn-bgp-apipa/validate.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Clear-Host

$LabRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..")
$ConfigPath = Join-Path $RepoRoot ".data\lab-003\config.json"

. (Join-Path $RepoRoot "scripts\aws\aws-common.ps1")

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

if (-not (Test-Path $ConfigPath)) {
  throw "Missing config: $ConfigPath"
}

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$azure = $cfg.azure
$aws = $cfg.aws

$resourceGroup = Require-ConfigField $azure "resourceGroup" "azure"
$subscriptionId = Require-ConfigField $azure "subscriptionId" "azure"
$vpnGatewayName = Require-ConfigField $azure "vpnGatewayName" "azure"

$awsProfile = Require-ConfigField $aws "profile" "aws"
$awsRegion = Require-ConfigField $aws "region" "aws"

Require-Command az
Require-AwsCli
Require-AwsProfile -Profile $awsProfile
$awsRegion = Require-AwsRegion -Region $awsRegion

az account show 1>$null 2>$null
if ($LASTEXITCODE -ne 0) { throw "Azure CLI not authenticated. Run: az login" }
& az account set --subscription $subscriptionId | Out-Null

Write-Host "Azure VPN gateway connections" -ForegroundColor Cyan
az network vpn-gateway connection list --resource-group $resourceGroup --gateway-name $vpnGatewayName -o table

Write-Host "";
Write-Host "Azure BGP peer status" -ForegroundColor Cyan
az network vpn-gateway list-bgp-peer-status --resource-group $resourceGroup --name $vpnGatewayName -o table

Write-Host "";
Write-Host "AWS VPN connections" -ForegroundColor Cyan
aws ec2 describe-vpn-connections --profile $awsProfile --region $awsRegion --query "VpnConnections[].{Id:VpnConnectionId,State:State}" -o table

Write-Host "";
Write-Host "AWS tunnel telemetry" -ForegroundColor Cyan
aws ec2 describe-vpn-connections --profile $awsProfile --region $awsRegion --query "VpnConnections[].VgwTelemetry[].{OutsideIp:OutsideIpAddress,Status:Status,LastStatusChange:LastStatusChange}" -o table

Write-Host "";
Write-Host "Optional validation:" -ForegroundColor Yellow
Write-Host "- RDP/SSH to the spoke VM and test connectivity across the tunnel." -ForegroundColor Gray
Write-Host "- Use ping/curl between Azure VM and AWS test instances (if added)." -ForegroundColor Gray
