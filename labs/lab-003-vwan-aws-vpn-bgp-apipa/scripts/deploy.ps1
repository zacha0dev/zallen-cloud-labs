# labs/lab-003-vwan-aws-vpn-bgp-apipa/scripts/deploy.ps1
# Deploys Azure vWAN + AWS VPN with BGP over APIPA

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [string]$AwsProfile = "aws-labs",
  [string]$AwsRegion = "us-east-2",
  [string]$Location = "eastus2",
  [string]$AdminPassword,
  [string]$Owner = "",
  [switch]$Force
)

# ============================================
# GUARDRAILS: Region and Account Allowlists
# ============================================
$AllowedAwsRegions = @("us-east-1", "us-east-2", "us-west-2", "eu-west-1")
$AllowedAzureLocations = @("eastus", "eastus2", "westus2", "northeurope", "westeurope")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..")
$OutputsPath = Join-Path $RepoRoot ".data\lab-003\outputs.json"
$AzureDir = Join-Path $LabRoot "azure"
$AwsDir = Join-Path $LabRoot "aws"

# Load shared helpers
. (Join-Path $RepoRoot "scripts\labs-common.ps1")
. (Join-Path $RepoRoot "scripts\aws\aws-common.ps1")

# Lab defaults
$ResourceGroup = "rg-lab-003-vwan-aws"
$AzureBgpAsn = 65515
$AwsBgpAsn = 65001

function Require-Command($name, $installHint) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $name. $installHint"
  }
}

function New-RandomPsk {
  # Generate 32-char alphanumeric PSK
  -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
}

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Assert-RegionAllowed {
  param(
    [string]$AwsRegion,
    [string]$AzureLocation,
    [string[]]$AllowedAwsRegions,
    [string[]]$AllowedAzureLocations
  )

  if ($AllowedAwsRegions -notcontains $AwsRegion) {
    Write-Host ""
    Write-Host "HARD STOP: AWS region '$AwsRegion' is not in the allowlist." -ForegroundColor Red
    Write-Host "Allowed regions: $($AllowedAwsRegions -join ', ')" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To use a different region, update the allowlist in this script." -ForegroundColor Gray
    throw "AWS region '$AwsRegion' not allowed. Allowed: $($AllowedAwsRegions -join ', ')"
  }

  if ($AllowedAzureLocations -notcontains $AzureLocation) {
    Write-Host ""
    Write-Host "HARD STOP: Azure location '$AzureLocation' is not in the allowlist." -ForegroundColor Red
    Write-Host "Allowed locations: $($AllowedAzureLocations -join ', ')" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To use a different location, update the allowlist in this script." -ForegroundColor Gray
    throw "Azure location '$AzureLocation' not allowed. Allowed: $($AllowedAzureLocations -join ', ')"
  }
}

function Assert-AccountMatch {
  param(
    [string]$AwsProfile,
    [string]$SubscriptionId,
    [string]$RepoRoot
  )

  # Verify AWS account matches expected profile
  $awsIdentity = aws sts get-caller-identity --profile $AwsProfile --output json 2>$null | ConvertFrom-Json
  if (-not $awsIdentity) {
    throw "Could not verify AWS account for profile '$AwsProfile'."
  }

  # Verify Azure subscription is the one we set
  $azAccount = az account show --query id -o tsv 2>$null
  if ($azAccount -ne $SubscriptionId) {
    throw "Azure CLI is using subscription '$azAccount' but expected '$SubscriptionId'. Run: az account set --subscription $SubscriptionId"
  }

  Write-Host "  Account validation: OK" -ForegroundColor Green
  Write-Host "    AWS Account: $($awsIdentity.Account)" -ForegroundColor DarkGray
  Write-Host "    Azure Sub:   $SubscriptionId" -ForegroundColor DarkGray
}

function Write-InventoryReport {
  param(
    [string]$OutputsPath,
    [hashtable]$AzureResources,
    [hashtable]$AwsResources,
    [string]$AwsRegion,
    [string]$AzureLocation
  )

  $inventory = [pscustomobject]@{
    metadata = [pscustomobject]@{
      lab = "lab-003"
      deployedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
      tags = @{
        project = "azure-labs"
        lab = "lab-003"
        env = "lab"
      }
    }
    azure = [pscustomobject]@{
      location = $AzureLocation
      resources = $AzureResources
    }
    aws = [pscustomobject]@{
      region = $AwsRegion
      resources = $AwsResources
    }
  }

  return $inventory
}

if (-not $AdminPassword) { throw "Provide -AdminPassword (temp lab password for VM)." }

Write-Host ""
Write-Host "Lab 003: Azure vWAN <-> AWS VPN with BGP over APIPA" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""

# Preflight checks
Write-Host "==> Preflight checks" -ForegroundColor Yellow

Require-Command az "Install Azure CLI: https://aka.ms/installazurecli"
Require-Command terraform "Install Terraform: https://developer.hashicorp.com/terraform/downloads"
Ensure-AwsCli
Require-AwsProfile -Profile $AwsProfile
$AwsRegion = Require-AwsRegion -Region $AwsRegion

# GUARDRAIL: Validate regions are in allowlist
Write-Host "==> Region validation" -ForegroundColor Yellow
Assert-RegionAllowed -AwsRegion $AwsRegion -AzureLocation $Location `
  -AllowedAwsRegions $AllowedAwsRegions -AllowedAzureLocations $AllowedAzureLocations
Write-Host "  AWS Region: $AwsRegion (allowed)" -ForegroundColor Green
Write-Host "  Azure Location: $Location (allowed)" -ForegroundColor Green

# Load config with preflight
Show-ConfigPreflight -RepoRoot $RepoRoot
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot

# Azure auth check
az account get-access-token 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Azure CLI not authenticated. Run: az login" }
az account set --subscription $SubscriptionId | Out-Null
Write-Host "  Azure: $SubscriptionKey ($SubscriptionId)" -ForegroundColor Gray

# AWS auth check
Ensure-AwsAuth -Profile $AwsProfile -DoLogin
Write-Host "  AWS: $AwsProfile ($AwsRegion)" -ForegroundColor Gray

# GUARDRAIL: Validate accounts match config
Write-Host "==> Account validation" -ForegroundColor Yellow
Assert-AccountMatch -AwsProfile $AwsProfile -SubscriptionId $SubscriptionId -RepoRoot $RepoRoot

if (-not $Force) {
  Write-Host ""
  Write-Host "This creates billable resources:" -ForegroundColor Yellow
  Write-Host "  Azure: vWAN hub (~`$0.25/hr), VPN Gateway, VM" -ForegroundColor Gray
  Write-Host "  AWS: VPN Connection (~`$0.05/hr), VGW" -ForegroundColor Gray
  $confirm = Read-Host "Type DEPLOY to proceed"
  if ($confirm -ne "DEPLOY") { throw "Cancelled." }
}

# ============================================
# PHASE 1: Deploy Azure infrastructure
# ============================================
Write-Host ""
Write-Host "==> Phase 1: Azure deployment" -ForegroundColor Cyan

az group create --name $ResourceGroup --location $Location --output none

$deploymentName = "lab-003-azure-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Write-Host "Deploying Bicep template (this takes 20-30 min for VPN Gateway)..." -ForegroundColor Gray

$ownerParam = if ($Owner) { "owner=$Owner" } else { "" }
az deployment group create `
  --resource-group $ResourceGroup `
  --name $deploymentName `
  --template-file "$AzureDir\main.bicep" `
  --parameters "$AzureDir\main.parameters.json" `
  --parameters location=$Location adminPassword=$AdminPassword azureBgpAsn=$AzureBgpAsn $ownerParam `
  --output none

if ($LASTEXITCODE -ne 0) { throw "Azure deployment failed." }

# Get VPN Gateway details
$vpnGwName = "vpngw-lab-003"
Write-Host "Waiting for VPN Gateway IPs..." -ForegroundColor Gray

# Poll for VPN gateway to be ready with IPs
$maxAttempts = 30
$attempt = 0
$azureVpnIps = @()

while ($attempt -lt $maxAttempts) {
  $attempt++
  $gw = az network vpn-gateway show -g $ResourceGroup -n $vpnGwName -o json 2>$null | ConvertFrom-Json

  if ($gw -and $gw.bgpSettings -and $gw.bgpSettings.bgpPeeringAddresses) {
    # vWAN VPN Gateway exposes public IPs through bgpSettings.bgpPeeringAddresses[].tunnelIpAddresses
    foreach ($peerAddr in $gw.bgpSettings.bgpPeeringAddresses) {
      if ($peerAddr.PSObject.Properties['tunnelIpAddresses'] -and $peerAddr.tunnelIpAddresses) {
        foreach ($ip in $peerAddr.tunnelIpAddresses) {
          # Filter to only public IPs (exclude 10.x, 172.16-31.x, 192.168.x)
          $isPrivate = $ip -match "^10\." -or $ip -match "^172\.(1[6-9]|2[0-9]|3[01])\." -or $ip -match "^192\.168\."
          if ($ip -and $ip -ne "None" -and $ip -notmatch "^$" -and -not $isPrivate -and $azureVpnIps -notcontains $ip) {
            $azureVpnIps += $ip
          }
        }
      }
    }
  }

  if ($azureVpnIps.Count -ge 1) { break }

  Write-Host "  Waiting for VPN Gateway IPs (attempt $attempt/$maxAttempts)..." -ForegroundColor DarkGray
  Start-Sleep -Seconds 30
}

if ($azureVpnIps.Count -eq 0) {
  throw "Could not retrieve Azure VPN Gateway public IPs. Check deployment in portal."
}

$azureVpnIp1 = $azureVpnIps[0]
$azureVpnIp2 = if ($azureVpnIps.Count -ge 2) { $azureVpnIps[1] } else { "" }

Write-Host "  Azure VPN Gateway IP 1: $azureVpnIp1" -ForegroundColor Green
if ($azureVpnIp2) {
  Write-Host "  Azure VPN Gateway IP 2: $azureVpnIp2" -ForegroundColor Green
}

# Get spoke VM IP
$spokeVmIp = az vm list-ip-addresses -g $ResourceGroup -n "vm-spoke-lab-003" --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv 2>$null

# ============================================
# PHASE 2: Deploy AWS infrastructure
# ============================================
Write-Host ""
Write-Host "==> Phase 2: AWS deployment (Terraform)" -ForegroundColor Cyan

# Generate PSKs locally
$psk1 = New-RandomPsk
$psk2 = New-RandomPsk

Write-Host "Generated pre-shared keys for VPN tunnels" -ForegroundColor Gray

# Create tfvars file (gitignored)
$tfvarsPath = Join-Path $AwsDir "terraform.tfvars"
$ownerLine = if ($Owner) { "owner                  = `"$Owner`"" } else { "# owner not specified" }
$tfvarsContent = @"
aws_region             = "$AwsRegion"
azure_vpn_gateway_ip_1 = "$azureVpnIp1"
azure_vpn_gateway_ip_2 = "$azureVpnIp2"
azure_bgp_asn          = $AzureBgpAsn
aws_bgp_asn            = $AwsBgpAsn
psk_vpn1_tunnel1       = "$psk1"
psk_vpn1_tunnel2       = "$psk2"
$ownerLine
"@
Set-Content -Path $tfvarsPath -Value $tfvarsContent -Encoding UTF8

# Set AWS profile for Terraform
$env:AWS_PROFILE = $AwsProfile

Push-Location $AwsDir
try {
  Write-Host "Running terraform init..." -ForegroundColor Gray
  terraform init -input=false | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Terraform init failed." }

  Write-Host "Running terraform apply..." -ForegroundColor Gray
  terraform apply -auto-approve -input=false
  if ($LASTEXITCODE -ne 0) { throw "Terraform apply failed." }

  # Capture outputs
  $tfOutput = terraform output -json | ConvertFrom-Json
}
finally {
  Pop-Location
}

$awsTunnel1Ip = $tfOutput.tunnel1_outside_ip.value
$awsTunnel2Ip = $tfOutput.tunnel2_outside_ip.value
$awsTunnel1BgpIp = $tfOutput.tunnel1_cgw_inside_ip.value
$awsTunnel2BgpIp = $tfOutput.tunnel2_cgw_inside_ip.value

Write-Host "  AWS Tunnel 1 IP: $awsTunnel1Ip (BGP: $awsTunnel1BgpIp)" -ForegroundColor Green
Write-Host "  AWS Tunnel 2 IP: $awsTunnel2Ip (BGP: $awsTunnel2BgpIp)" -ForegroundColor Green

# ============================================
# PHASE 3: Configure Azure VPN Site
# ============================================
Write-Host ""
Write-Host "==> Phase 3: Azure VPN Site configuration" -ForegroundColor Cyan

$vpnSiteName = "lab-003-aws-site"
$vwanName = "vwan-lab-003"

# Check if site exists
$existingSite = az network vpn-site show -g $ResourceGroup -n $vpnSiteName --query name -o tsv 2>$null

if (-not $existingSite) {
  Write-Host "Creating VPN Site..." -ForegroundColor Gray

  # Create site with address-prefix (required when using BGP on links)
  # The address-prefix is the AWS VPC CIDR that will be reachable via this site
  az network vpn-site create `
    --resource-group $ResourceGroup `
    --name $vpnSiteName `
    --location $Location `
    --virtual-wan $vwanName `
    --ip-address $awsTunnel1Ip `
    --address-prefixes "10.20.0.0/16" `
    --device-vendor "AWS" `
    --device-model "VGW" `
    --output none

  if ($LASTEXITCODE -ne 0) { throw "VPN Site creation failed." }

  Write-Host "Adding VPN Site links..." -ForegroundColor Gray

  # Add link 1 (tunnel 1)
  az network vpn-site link add `
    --resource-group $ResourceGroup `
    --site-name $vpnSiteName `
    --name "link-tunnel1" `
    --ip-address $awsTunnel1Ip `
    --asn $AwsBgpAsn `
    --bgp-peering-address $awsTunnel1BgpIp `
    --output none

  if ($LASTEXITCODE -ne 0) { throw "VPN Site link 1 creation failed." }

  # Add link 2 (tunnel 2)
  az network vpn-site link add `
    --resource-group $ResourceGroup `
    --site-name $vpnSiteName `
    --name "link-tunnel2" `
    --ip-address $awsTunnel2Ip `
    --asn $AwsBgpAsn `
    --bgp-peering-address $awsTunnel2BgpIp `
    --output none

  if ($LASTEXITCODE -ne 0) { throw "VPN Site link 2 creation failed." }
}

# Create VPN connection to the site
$vpnConnName = "conn-$vpnSiteName"
$existingConn = az network vpn-gateway connection show -g $ResourceGroup --gateway-name $vpnGwName -n $vpnConnName --query name -o tsv 2>$null

if (-not $existingConn) {
  Write-Host "Creating VPN Gateway connection..." -ForegroundColor Gray

  $siteId = az network vpn-site show -g $ResourceGroup -n $vpnSiteName --query id -o tsv

  # Get site link IDs
  $siteLinks = az network vpn-site show -g $ResourceGroup -n $vpnSiteName --query "links[].id" -o json | ConvertFrom-Json

  # Create connection with links
  az network vpn-gateway connection create `
    --resource-group $ResourceGroup `
    --gateway-name $vpnGwName `
    --name $vpnConnName `
    --remote-vpn-site $siteId `
    --enable-bgp true `
    --shared-key $psk1 `
    --vpn-site-link $siteLinks[0] `
    --output none

  if ($LASTEXITCODE -ne 0) {
    Write-Host "  Warning: VPN connection may need manual configuration in portal" -ForegroundColor Yellow
  }
}

# ============================================
# Save outputs + Inventory Report
# ============================================
Ensure-Directory (Split-Path -Parent $OutputsPath)

# Get full Azure resource IDs for inventory
$vwanId = az network vwan show -g $ResourceGroup -n "vwan-lab-003" --query id -o tsv 2>$null
$vhubId = az network vhub show -g $ResourceGroup -n "vhub-lab-003" --query id -o tsv 2>$null
$vpnGwId = az network vpn-gateway show -g $ResourceGroup -n $vpnGwName --query id -o tsv 2>$null
$spokeVnetId = az network vnet show -g $ResourceGroup -n "vnet-spoke-lab-003" --query id -o tsv 2>$null
$vmId = az vm show -g $ResourceGroup -n "vm-spoke-lab-003" --query id -o tsv 2>$null
$nicId = az network nic show -g $ResourceGroup -n "nic-vm-spoke-lab-003" --query id -o tsv 2>$null
$vpnSiteId = az network vpn-site show -g $ResourceGroup -n $vpnSiteName --query id -o tsv 2>$null

$outputs = [pscustomobject]@{
  metadata = [pscustomobject]@{
    lab = "lab-003"
    deployedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    tags = @{
      project = "azure-labs"
      lab = "lab-003"
      env = "lab"
      owner = $Owner
    }
  }
  azure = [pscustomobject]@{
    location = $Location
    resourceGroup = $ResourceGroup
    subscriptionId = $SubscriptionId
    resources = [pscustomobject]@{
      vwan = $vwanId
      vhub = $vhubId
      vpnGateway = $vpnGwId
      spokeVnet = $spokeVnetId
      vm = $vmId
      nic = $nicId
      vpnSite = $vpnSiteId
    }
    vpnGatewayName = $vpnGwName
    vpnGatewayIps = $azureVpnIps
    vpnSiteName = $vpnSiteName
    spokeVmPrivateIp = $spokeVmIp
    bgpAsn = $AzureBgpAsn
  }
  aws = [pscustomobject]@{
    profile = $AwsProfile
    region = $AwsRegion
    resources = [pscustomobject]@{
      vpc = $tfOutput.vpc_id.value
      subnet = $tfOutput.subnet_id.value
      igw = $tfOutput.igw_id.value
      routeTable = $tfOutput.route_table_id.value
      vgw = $tfOutput.vgw_id.value
      cgw = $tfOutput.cgw_id.value
      vpnConnection = $tfOutput.vpn_connection_id.value
    }
    vpnConnectionId = $tfOutput.vpn_connection_id.value
    vgwId = $tfOutput.vgw_id.value
    vpcId = $tfOutput.vpc_id.value
    tunnel1OutsideIp = $awsTunnel1Ip
    tunnel2OutsideIp = $awsTunnel2Ip
    tunnel1BgpIp = $awsTunnel1BgpIp
    tunnel2BgpIp = $awsTunnel2BgpIp
    bgpAsn = $AwsBgpAsn
  }
}

$outputs | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputsPath -Encoding UTF8

Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "==> Inventory Report" -ForegroundColor Yellow
Write-Host "Outputs saved to: $OutputsPath" -ForegroundColor Gray
Write-Host ""
Write-Host "Azure Resources (location: $Location):" -ForegroundColor White
Write-Host "  Resource Group: $ResourceGroup" -ForegroundColor Gray
Write-Host "  Virtual WAN:    vwan-lab-003" -ForegroundColor Gray
Write-Host "  Virtual Hub:    vhub-lab-003" -ForegroundColor Gray
Write-Host "  VPN Gateway:    $vpnGwName" -ForegroundColor Gray
Write-Host "  Spoke VNet:     vnet-spoke-lab-003" -ForegroundColor Gray
Write-Host "  Test VM:        vm-spoke-lab-003" -ForegroundColor Gray
Write-Host "  VPN Site:       $vpnSiteName" -ForegroundColor Gray
Write-Host ""
Write-Host "AWS Resources (region: $AwsRegion):" -ForegroundColor White
Write-Host "  VPC:            $($tfOutput.vpc_id.value)" -ForegroundColor Gray
Write-Host "  Subnet:         $($tfOutput.subnet_id.value)" -ForegroundColor Gray
Write-Host "  VGW:            $($tfOutput.vgw_id.value)" -ForegroundColor Gray
Write-Host "  CGW:            $($tfOutput.cgw_id.value)" -ForegroundColor Gray
Write-Host "  VPN Connection: $($tfOutput.vpn_connection_id.value)" -ForegroundColor Gray
Write-Host ""
Write-Host "Tags applied: project=azure-labs, lab=lab-003, env=lab$(if($Owner){", owner=$Owner"})" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Wait 5-10 min for BGP to establish" -ForegroundColor Gray
Write-Host "  2. Run: .\scripts\validate.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "Tunnel IPs for reference:" -ForegroundColor White
Write-Host "  AWS Tunnel 1: $awsTunnel1Ip -> Azure: $azureVpnIp1" -ForegroundColor Gray
Write-Host "  AWS Tunnel 2: $awsTunnel2Ip -> Azure: $azureVpnIp1" -ForegroundColor Gray
