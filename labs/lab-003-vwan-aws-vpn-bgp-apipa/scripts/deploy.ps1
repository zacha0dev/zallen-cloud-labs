# labs/lab-003-vwan-aws-vpn-bgp-apipa/scripts/deploy.ps1
# Deploys Azure vWAN + AWS VPN with BGP over APIPA

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [string]$AwsProfile = "aws-labs",
  [string]$AwsRegion = "us-east-2",
  [string]$Location = "eastus2",
  [switch]$Force
)

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
$AdminPassword = "Lab003Pass#2026!"
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

az deployment group create `
  --resource-group $ResourceGroup `
  --name $deploymentName `
  --template-file "$AzureDir\main.bicep" `
  --parameters "$AzureDir\main.parameters.json" `
  --parameters location=$Location adminPassword=$AdminPassword azureBgpAsn=$AzureBgpAsn `
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
$tfvarsContent = @"
aws_region             = "$AwsRegion"
azure_vpn_gateway_ip_1 = "$azureVpnIp1"
azure_vpn_gateway_ip_2 = "$azureVpnIp2"
azure_bgp_asn          = $AzureBgpAsn
aws_bgp_asn            = $AwsBgpAsn
psk_vpn1_tunnel1       = "$psk1"
psk_vpn1_tunnel2       = "$psk2"
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

  # Create site first (without links)
  az network vpn-site create `
    --resource-group $ResourceGroup `
    --name $vpnSiteName `
    --location $Location `
    --virtual-wan $vwanName `
    --ip-address $awsTunnel1Ip `
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
# Save outputs
# ============================================
Ensure-Directory (Split-Path -Parent $OutputsPath)

$outputs = [pscustomobject]@{
  azure = [pscustomobject]@{
    resourceGroup = $ResourceGroup
    subscriptionId = $SubscriptionId
    vpnGatewayName = $vpnGwName
    vpnGatewayIps = $azureVpnIps
    vpnSiteName = $vpnSiteName
    spokeVmPrivateIp = $spokeVmIp
    bgpAsn = $AzureBgpAsn
  }
  aws = [pscustomobject]@{
    profile = $AwsProfile
    region = $AwsRegion
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
Write-Host "Outputs saved to: $OutputsPath" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Wait 5-10 min for BGP to establish" -ForegroundColor Gray
Write-Host "  2. Run: .\scripts\validate.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "Tunnel IPs for reference:" -ForegroundColor White
Write-Host "  AWS Tunnel 1: $awsTunnel1Ip -> Azure: $azureVpnIp1" -ForegroundColor Gray
Write-Host "  AWS Tunnel 2: $awsTunnel2Ip -> Azure: $azureVpnIp1" -ForegroundColor Gray
