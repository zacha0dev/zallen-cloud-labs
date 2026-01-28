# labs/lab-003-vwan-aws-vpn-bgp-apipa/destroy.ps1

[CmdletBinding()]
param(
  [switch]$Force
)

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

function Invoke-Aws([string]$Cmd) {
  Write-Host "aws $Cmd" -ForegroundColor DarkGray
  & aws @($Cmd -split ' ')
  if ($LASTEXITCODE -ne 0) { throw "AWS CLI failed: aws $Cmd" }
}

if (-not (Test-Path $ConfigPath)) {
  throw "Missing config: $ConfigPath"
}

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$azure = $cfg.azure
$aws = $cfg.aws

$resourceGroup = Require-ConfigField $azure "resourceGroup" "azure"
$subscriptionId = Require-ConfigField $azure "subscriptionId" "azure"

$awsProfile = Require-ConfigField $aws "profile" "aws"
$awsRegion = Require-ConfigField $aws "region" "aws"

Require-Command az
Require-AwsCli
Require-AwsProfile -Profile $awsProfile
$awsRegion = Require-AwsRegion -Region $awsRegion
Confirm-AwsBudgetWarning -Message "This will delete AWS resources for lab-003." -Force:$Force

Write-Host "";
Write-Host "==> AWS teardown" -ForegroundColor Cyan

$NamePrefix = "lab-003"
$vpcName = "$NamePrefix-vpc"
$subnetName = "$NamePrefix-subnet"
$igwName = "$NamePrefix-igw"
$routeTableName = "$NamePrefix-rt"
$vgwName = "$NamePrefix-vgw"
$cgwName = "$NamePrefix-cgw"
$vpnConnOne = "$NamePrefix-vpn-1"
$vpnConnTwo = "$NamePrefix-vpn-2"

$vpnConnId1 = aws ec2 describe-vpn-connections --profile $awsProfile --region $awsRegion --filters Name=tag:Name,Values=$vpnConnOne --query "VpnConnections[0].VpnConnectionId" -o text
if ($vpnConnId1 -and $vpnConnId1 -ne "None") {
  Invoke-Aws "ec2 delete-vpn-connection --profile $awsProfile --region $awsRegion --vpn-connection-id $vpnConnId1"
}

$vpnConnId2 = aws ec2 describe-vpn-connections --profile $awsProfile --region $awsRegion --filters Name=tag:Name,Values=$vpnConnTwo --query "VpnConnections[0].VpnConnectionId" -o text
if ($vpnConnId2 -and $vpnConnId2 -ne "None") {
  Invoke-Aws "ec2 delete-vpn-connection --profile $awsProfile --region $awsRegion --vpn-connection-id $vpnConnId2"
}

$cgwId = aws ec2 describe-customer-gateways --profile $awsProfile --region $awsRegion --filters Name=tag:Name,Values=$cgwName --query "CustomerGateways[0].CustomerGatewayId" -o text
if ($cgwId -and $cgwId -ne "None") {
  Invoke-Aws "ec2 delete-customer-gateway --profile $awsProfile --region $awsRegion --customer-gateway-id $cgwId"
}

$vgwId = aws ec2 describe-vpn-gateways --profile $awsProfile --region $awsRegion --filters Name=tag:Name,Values=$vgwName --query "VpnGateways[0].VpnGatewayId" -o text
$vpcId = aws ec2 describe-vpcs --profile $awsProfile --region $awsRegion --filters Name=tag:Name,Values=$vpcName --query "Vpcs[0].VpcId" -o text
if ($vgwId -and $vgwId -ne "None") {
  if ($vpcId -and $vpcId -ne "None") {
    Invoke-Aws "ec2 detach-vpn-gateway --profile $awsProfile --region $awsRegion --vpn-gateway-id $vgwId --vpc-id $vpcId"
  }
  Invoke-Aws "ec2 delete-vpn-gateway --profile $awsProfile --region $awsRegion --vpn-gateway-id $vgwId"
}

$routeTableId = aws ec2 describe-route-tables --profile $awsProfile --region $awsRegion --filters Name=tag:Name,Values=$routeTableName --query "RouteTables[0].RouteTableId" -o text
if ($routeTableId -and $routeTableId -ne "None") {
  $assocId = aws ec2 describe-route-tables --profile $awsProfile --region $awsRegion --route-table-ids $routeTableId --query "RouteTables[0].Associations[0].RouteTableAssociationId" -o text
  if ($assocId -and $assocId -ne "None") {
    Invoke-Aws "ec2 disassociate-route-table --profile $awsProfile --region $awsRegion --association-id $assocId"
  }
  Invoke-Aws "ec2 delete-route-table --profile $awsProfile --region $awsRegion --route-table-id $routeTableId"
}

$igwId = aws ec2 describe-internet-gateways --profile $awsProfile --region $awsRegion --filters Name=tag:Name,Values=$igwName --query "InternetGateways[0].InternetGatewayId" -o text
if ($igwId -and $igwId -ne "None" -and $vpcId -and $vpcId -ne "None") {
  Invoke-Aws "ec2 detach-internet-gateway --profile $awsProfile --region $awsRegion --internet-gateway-id $igwId --vpc-id $vpcId"
  Invoke-Aws "ec2 delete-internet-gateway --profile $awsProfile --region $awsRegion --internet-gateway-id $igwId"
}

$subnetId = aws ec2 describe-subnets --profile $awsProfile --region $awsRegion --filters Name=tag:Name,Values=$subnetName --query "Subnets[0].SubnetId" -o text
if ($subnetId -and $subnetId -ne "None") {
  Invoke-Aws "ec2 delete-subnet --profile $awsProfile --region $awsRegion --subnet-id $subnetId"
}

if ($vpcId -and $vpcId -ne "None") {
  Invoke-Aws "ec2 delete-vpc --profile $awsProfile --region $awsRegion --vpc-id $vpcId"
}

Write-Host "";
Write-Host "==> Azure teardown" -ForegroundColor Cyan

az account show 1>$null 2>$null
if ($LASTEXITCODE -ne 0) { throw "Azure CLI not authenticated. Run: az login" }
& az account set --subscription $subscriptionId | Out-Null
& az group delete --name $resourceGroup --yes --no-wait

Write-Host "Azure resource group deletion started." -ForegroundColor Green
