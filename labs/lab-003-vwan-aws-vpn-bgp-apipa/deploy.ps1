# labs/lab-003-vwan-aws-vpn-bgp-apipa/deploy.ps1

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
$OutputsPath = Join-Path $RepoRoot ".data\lab-003\outputs.json"

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

function Invoke-Az([string]$Cmd) {
  Write-Host "az $Cmd" -ForegroundColor DarkGray
  & az @($Cmd -split ' ')
  if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: az $Cmd" }
}

function Invoke-Aws([string]$Cmd) {
  Write-Host "aws $Cmd" -ForegroundColor DarkGray
  & aws @($Cmd -split ' ')
  if ($LASTEXITCODE -ne 0) { throw "AWS CLI failed: aws $Cmd" }
}

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
  }
}

if (-not (Test-Path $ConfigPath)) {
  throw "Missing config: $ConfigPath. Copy and edit it before running this lab."
}

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$azure = $cfg.azure
$aws = $cfg.aws

$subscriptionId = Require-ConfigField $azure "subscriptionId" "azure"
$location = Require-ConfigField $azure "location" "azure"
$resourceGroup = Require-ConfigField $azure "resourceGroup" "azure"
$vwanName = Require-ConfigField $azure "vwanName" "azure"
$vhubName = Require-ConfigField $azure "vhubName" "azure"
$vhubPrefix = Require-ConfigField $azure "vhubAddressPrefix" "azure"
$vpnGatewayName = Require-ConfigField $azure "vpnGatewayName" "azure"
$spokeVnetName = Require-ConfigField $azure "spokeVnetName" "azure"
$spokeCidr = Require-ConfigField $azure "spokeAddressPrefix" "azure"
$spokeSubnet = Require-ConfigField $azure "spokeSubnetPrefix" "azure"
$vmName = Require-ConfigField $azure "vmName" "azure"
$adminUsername = Require-ConfigField $azure "adminUsername" "azure"
$adminPassword = Require-ConfigField $azure "adminPassword" "azure"

$awsProfile = Require-ConfigField $aws "profile" "aws"
$awsRegion = Require-ConfigField $aws "region" "aws"
$bgpAsnAws = Require-ConfigField $aws "bgpAsnAws" "aws"
$bgpAsnAzure = Require-ConfigField $aws "bgpAsnAzure" "aws"
$vpcCidr = Require-ConfigField $aws "vpcCidr" "aws"
$publicSubnetCidr = Require-ConfigField $aws "publicSubnetCidr" "aws"

if ($adminPassword -eq "CHANGE_ME") {
  throw "Update azure.adminPassword in .data/lab-003/config.json before deploying."
}

if (-not $aws.apipaPairs -or $aws.apipaPairs.Count -lt 4) {
  throw "Config requires 4 APIPA pairs in aws.apipaPairs."
}

Require-Command az
Require-AwsCli
Require-AwsProfile -Profile $awsProfile
$awsRegion = Require-AwsRegion -Region $awsRegion
Confirm-AwsBudgetWarning -Force:$Force

az account show 1>$null 2>$null
if ($LASTEXITCODE -ne 0) { throw "Azure CLI not authenticated. Run: az login" }
Invoke-Az "account set --subscription $subscriptionId"

Write-Host "";
Write-Host "==> Azure deployment" -ForegroundColor Cyan

Invoke-Az "group create --name $resourceGroup --location $location --tags owner=$env:USERNAME project=azure-labs lab=lab-003 ttlHours=8"

$existingVwan = az network vwan show --resource-group $resourceGroup --name $vwanName --query name -o tsv 2>$null
if (-not $existingVwan) {
  Invoke-Az "network vwan create --resource-group $resourceGroup --name $vwanName --location $location --type Standard"
}

$existingHub = az network vhub show --resource-group $resourceGroup --name $vhubName --query name -o tsv 2>$null
if (-not $existingHub) {
  Invoke-Az "network vhub create --resource-group $resourceGroup --name $vhubName --location $location --vwan $vwanName --address-prefix $vhubPrefix"
}

$existingGateway = az network vpn-gateway show --resource-group $resourceGroup --name $vpnGatewayName --query name -o tsv 2>$null
if (-not $existingGateway) {
  Invoke-Az "network vpn-gateway create --resource-group $resourceGroup --name $vpnGatewayName --location $location --vhub $vhubName --asn $bgpAsnAzure"
}

$existingVnet = az network vnet show --resource-group $resourceGroup --name $spokeVnetName --query name -o tsv 2>$null
if (-not $existingVnet) {
  Invoke-Az "network vnet create --resource-group $resourceGroup --name $spokeVnetName --location $location --address-prefixes $spokeCidr --subnet-name default --subnet-prefixes $spokeSubnet"
}

$vnetId = az network vnet show -g $resourceGroup -n $spokeVnetName --query id -o tsv
$existingConn = az network vhub connection show --resource-group $resourceGroup --name conn-$spokeVnetName --vhub-name $vhubName --query name -o tsv 2>$null
if (-not $existingConn) {
  Invoke-Az "network vhub connection create --resource-group $resourceGroup --name conn-$spokeVnetName --vhub-name $vhubName --remote-vnet $vnetId"
}

$existingVm = az vm show --resource-group $resourceGroup --name $vmName --query name -o tsv 2>$null
if (-not $existingVm) {
  Invoke-Az "vm create --resource-group $resourceGroup --name $vmName --image Ubuntu2204 --size Standard_B1s --vnet-name $spokeVnetName --subnet default --nsg-rule NONE --admin-username $adminUsername --admin-password $adminPassword --authentication-type password"
}

$gw = az network vpn-gateway show --resource-group $resourceGroup --name $vpnGatewayName -o json | ConvertFrom-Json
$publicIpIds = @($gw.ipConfigurations | ForEach-Object { $_.publicIpAddress.id })
$azurePublicIps = @()
foreach ($id in $publicIpIds) {
  $ip = az network public-ip show --ids $id --query ipAddress -o tsv
  if ($ip) { $azurePublicIps += $ip }
}

$spokeVmPrivateIp = az vm list-ip-addresses -g $resourceGroup -n $vmName --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv

Write-Host "";
Write-Host "==> AWS deployment" -ForegroundColor Cyan

$NamePrefix = "lab-003"
$vpcName = "$NamePrefix-vpc"
$subnetName = "$NamePrefix-subnet"
$igwName = "$NamePrefix-igw"
$routeTableName = "$NamePrefix-rt"
$vgwName = "$NamePrefix-vgw"
$cgwName = "$NamePrefix-cgw"
$vpnConnOne = "$NamePrefix-vpn-1"
$vpnConnTwo = "$NamePrefix-vpn-2"

$vpcId = aws ec2 describe-vpcs --profile $awsProfile --region $awsRegion --filters Name=tag:Name,Values=$vpcName --query "Vpcs[0].VpcId" -o text
if (-not $vpcId -or $vpcId -eq "None") {
  $vpcId = aws ec2 create-vpc --profile $awsProfile --region $awsRegion --cidr-block $vpcCidr --query "Vpc.VpcId" -o text
  Invoke-Aws "ec2 create-tags --profile $awsProfile --region $awsRegion --resources $vpcId --tags Key=Name,Value=$vpcName"
}

$subnetId = aws ec2 describe-subnets --profile $awsProfile --region $awsRegion --filters Name=tag:Name,Values=$subnetName --query "Subnets[0].SubnetId" -o text
if (-not $subnetId -or $subnetId -eq "None") {
  $subnetId = aws ec2 create-subnet --profile $awsProfile --region $awsRegion --vpc-id $vpcId --cidr-block $publicSubnetCidr --query "Subnet.SubnetId" -o text
  Invoke-Aws "ec2 create-tags --profile $awsProfile --region $awsRegion --resources $subnetId --tags Key=Name,Value=$subnetName"
}

$igwId = aws ec2 describe-internet-gateways --profile $awsProfile --region $awsRegion --filters Name=tag:Name,Values=$igwName --query "InternetGateways[0].InternetGatewayId" -o text
if (-not $igwId -or $igwId -eq "None") {
  $igwId = aws ec2 create-internet-gateway --profile $awsProfile --region $awsRegion --query "InternetGateway.InternetGatewayId" -o text
  Invoke-Aws "ec2 create-tags --profile $awsProfile --region $awsRegion --resources $igwId --tags Key=Name,Value=$igwName"
  Invoke-Aws "ec2 attach-internet-gateway --profile $awsProfile --region $awsRegion --internet-gateway-id $igwId --vpc-id $vpcId"
}

$routeTableId = aws ec2 describe-route-tables --profile $awsProfile --region $awsRegion --filters Name=tag:Name,Values=$routeTableName --query "RouteTables[0].RouteTableId" -o text
if (-not $routeTableId -or $routeTableId -eq "None") {
  $routeTableId = aws ec2 create-route-table --profile $awsProfile --region $awsRegion --vpc-id $vpcId --query "RouteTable.RouteTableId" -o text
  Invoke-Aws "ec2 create-tags --profile $awsProfile --region $awsRegion --resources $routeTableId --tags Key=Name,Value=$routeTableName"
  Invoke-Aws "ec2 create-route --profile $awsProfile --region $awsRegion --route-table-id $routeTableId --destination-cidr-block 0.0.0.0/0 --gateway-id $igwId"
  Invoke-Aws "ec2 associate-route-table --profile $awsProfile --region $awsRegion --route-table-id $routeTableId --subnet-id $subnetId"
}

$vgwId = aws ec2 describe-vpn-gateways --profile $awsProfile --region $awsRegion --filters Name=tag:Name,Values=$vgwName --query "VpnGateways[0].VpnGatewayId" -o text
if (-not $vgwId -or $vgwId -eq "None") {
  $vgwId = aws ec2 create-vpn-gateway --profile $awsProfile --region $awsRegion --type ipsec.1 --amazon-side-asn $bgpAsnAws --query "VpnGateway.VpnGatewayId" -o text
  Invoke-Aws "ec2 create-tags --profile $awsProfile --region $awsRegion --resources $vgwId --tags Key=Name,Value=$vgwName"
  Invoke-Aws "ec2 attach-vpn-gateway --profile $awsProfile --region $awsRegion --vpn-gateway-id $vgwId --vpc-id $vpcId"
}

if (-not $azurePublicIps -or $azurePublicIps.Count -eq 0) {
  throw "Unable to resolve Azure VPN gateway public IP. Check Azure deployment and retry."
}

$azureCgwIp = $azurePublicIps[0]
$cgwId = aws ec2 describe-customer-gateways --profile $awsProfile --region $awsRegion --filters Name=tag:Name,Values=$cgwName --query "CustomerGateways[0].CustomerGatewayId" -o text
if (-not $cgwId -or $cgwId -eq "None") {
  $cgwId = aws ec2 create-customer-gateway --profile $awsProfile --region $awsRegion --type ipsec.1 --public-ip $azureCgwIp --bgp-asn $bgpAsnAzure --query "CustomerGateway.CustomerGatewayId" -o text
  Invoke-Aws "ec2 create-tags --profile $awsProfile --region $awsRegion --resources $cgwId --tags Key=Name,Value=$cgwName"
}

$vpnConnId1 = aws ec2 describe-vpn-connections --profile $awsProfile --region $awsRegion --filters Name=tag:Name,Values=$vpnConnOne --query "VpnConnections[0].VpnConnectionId" -o text
if (-not $vpnConnId1 -or $vpnConnId1 -eq "None") {
  $vpnConnId1 = aws ec2 create-vpn-connection --profile $awsProfile --region $awsRegion --type ipsec.1 --customer-gateway-id $cgwId --vpn-gateway-id $vgwId --options "StaticRoutesOnly=false" --query "VpnConnection.VpnConnectionId" -o text
  Invoke-Aws "ec2 create-tags --profile $awsProfile --region $awsRegion --resources $vpnConnId1 --tags Key=Name,Value=$vpnConnOne"
}

$vpnConnId2 = aws ec2 describe-vpn-connections --profile $awsProfile --region $awsRegion --filters Name=tag:Name,Values=$vpnConnTwo --query "VpnConnections[0].VpnConnectionId" -o text
if (-not $vpnConnId2 -or $vpnConnId2 -eq "None") {
  $vpnConnId2 = aws ec2 create-vpn-connection --profile $awsProfile --region $awsRegion --type ipsec.1 --customer-gateway-id $cgwId --vpn-gateway-id $vgwId --options "StaticRoutesOnly=false" --query "VpnConnection.VpnConnectionId" -o text
  Invoke-Aws "ec2 create-tags --profile $awsProfile --region $awsRegion --resources $vpnConnId2 --tags Key=Name,Value=$vpnConnTwo"
}

$vpnConnections = aws ec2 describe-vpn-connections --profile $awsProfile --region $awsRegion --vpn-connection-ids $vpnConnId1 $vpnConnId2 --output json | ConvertFrom-Json
$awsOutsideIps = @($vpnConnections.VpnConnections | ForEach-Object { $_.VgwTelemetry | ForEach-Object { $_.OutsideIpAddress } })

Write-Host "";
Write-Host "==> Azure VPN sites & connections" -ForegroundColor Cyan

if ($awsOutsideIps.Count -ge 4) {
  $siteOneName = "$NamePrefix-site-1"
  $siteTwoName = "$NamePrefix-site-2"
  $ip1 = $awsOutsideIps[0]
  $ip2 = $awsOutsideIps[1]
  $ip3 = $awsOutsideIps[2]
  $ip4 = $awsOutsideIps[3]

  $siteOne = az network vpn-site show --resource-group $resourceGroup --name $siteOneName --query name -o tsv 2>$null
  if (-not $siteOne) {
    $apipaOne = $aws.apipaPairs[0].aws
    $apipaTwo = $aws.apipaPairs[1].aws
    Invoke-Az "network vpn-site create --resource-group $resourceGroup --name $siteOneName --location $location --vwan $vwanName --asn $bgpAsnAws --link-1-name link-1 --link-1-ip-address $ip1 --link-1-bgp-peering-address $apipaOne --link-2-name link-2 --link-2-ip-address $ip2 --link-2-bgp-peering-address $apipaTwo"
  }

  $siteTwo = az network vpn-site show --resource-group $resourceGroup --name $siteTwoName --query name -o tsv 2>$null
  if (-not $siteTwo) {
    $apipaThree = $aws.apipaPairs[2].aws
    $apipaFour = $aws.apipaPairs[3].aws
    Invoke-Az "network vpn-site create --resource-group $resourceGroup --name $siteTwoName --location $location --vwan $vwanName --asn $bgpAsnAws --link-1-name link-1 --link-1-ip-address $ip3 --link-1-bgp-peering-address $apipaThree --link-2-name link-2 --link-2-ip-address $ip4 --link-2-bgp-peering-address $apipaFour"
  }

  $siteOneId = az network vpn-site show --resource-group $resourceGroup --name $siteOneName --query id -o tsv
  $siteTwoId = az network vpn-site show --resource-group $resourceGroup --name $siteTwoName --query id -o tsv

  $connOne = az network vpn-gateway connection show --resource-group $resourceGroup --gateway-name $vpnGatewayName --name conn-$siteOneName --query name -o tsv 2>$null
  if (-not $connOne) {
    Invoke-Az "network vpn-gateway connection create --resource-group $resourceGroup --gateway-name $vpnGatewayName --name conn-$siteOneName --remote-vpn-site $siteOneId"
  }

  $connTwo = az network vpn-gateway connection show --resource-group $resourceGroup --gateway-name $vpnGatewayName --name conn-$siteTwoName --query name -o tsv 2>$null
  if (-not $connTwo) {
    Invoke-Az "network vpn-gateway connection create --resource-group $resourceGroup --gateway-name $vpnGatewayName --name conn-$siteTwoName --remote-vpn-site $siteTwoId"
  }
} else {
  Write-Host "AWS tunnel outside IPs not available yet. VPN sites were not created." -ForegroundColor Yellow
}

Ensure-Directory (Split-Path -Parent $OutputsPath)

$outputs = [pscustomobject]@{
  azure = [pscustomobject]@{
    publicIps = $azurePublicIps
    spokeVmPrivateIp = $spokeVmPrivateIp
  }
  aws = [pscustomobject]@{
    profile = $awsProfile
    region = $awsRegion
    vpnConnectionIds = @($vpnConnId1, $vpnConnId2)
    tunnelOutsideIps = $awsOutsideIps
  }
}

$outputs | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputsPath -Encoding UTF8

Write-Host "";
Write-Host "Deployment complete." -ForegroundColor Green
Write-Host "Outputs: $OutputsPath" -ForegroundColor Gray
Write-Host "";
Write-Host "Manual steps (APIPA BGP tunnel options):" -ForegroundColor Yellow
Write-Host "  Update AWS VPN tunnel options with APIPA pairs if needed." -ForegroundColor Yellow
Write-Host "  Example: aws ec2 modify-vpn-tunnel-options --vpn-connection-id <id> --tunnel-outside-ip-address <ip> --tunnel-options TunnelInsideCidr=<aws-apipa>" -ForegroundColor Gray
