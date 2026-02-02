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

# Azure auth check (prompts to login if needed)
Ensure-AzureAuth -DoLogin
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

# PSK persistence - reuse existing PSKs to avoid unnecessary VPN connection updates
$pskPath = Join-Path $RepoRoot ".data\lab-003\psk-secrets.json"
$psks = $null
if (Test-Path $pskPath) {
  try {
    $psks = Get-Content $pskPath -Raw | ConvertFrom-Json
    Write-Host "Reusing existing pre-shared keys (faster redeploy)" -ForegroundColor Gray
  } catch {
    $psks = $null
  }
}

if (-not $psks -or -not $psks.psk1) {
  # Generate new PSKs (first deploy or secrets file missing)
  $psk1 = New-RandomPsk  # VPN1 Tunnel 1 (to Azure Instance 0)
  $psk2 = New-RandomPsk  # VPN1 Tunnel 2 (to Azure Instance 0)
  $psk3 = New-RandomPsk  # VPN2 Tunnel 1 (to Azure Instance 1)
  $psk4 = New-RandomPsk  # VPN2 Tunnel 2 (to Azure Instance 1)

  # Save PSKs for future deploys
  $psks = @{ psk1 = $psk1; psk2 = $psk2; psk3 = $psk3; psk4 = $psk4 }
  Ensure-Directory (Split-Path -Parent $pskPath)
  $psks | ConvertTo-Json | Set-Content -Path $pskPath -Encoding UTF8
  Write-Host "Generated and saved new pre-shared keys for 4 VPN tunnels" -ForegroundColor Gray
} else {
  $psk1 = $psks.psk1
  $psk2 = $psks.psk2
  $psk3 = $psks.psk3
  $psk4 = $psks.psk4
}

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
psk_vpn2_tunnel1       = "$psk3"
psk_vpn2_tunnel2       = "$psk4"
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

# VPN Connection 1 tunnels (to Azure Instance 0)
$awsTunnel1Ip = $tfOutput.tunnel1_outside_ip.value
$awsTunnel2Ip = $tfOutput.tunnel2_outside_ip.value
$awsTunnel1BgpIp = $tfOutput.tunnel1_cgw_inside_ip.value
$awsTunnel2BgpIp = $tfOutput.tunnel2_cgw_inside_ip.value

# VPN Connection 2 tunnels (to Azure Instance 1)
$awsTunnel3Ip = $tfOutput.tunnel3_outside_ip.value
$awsTunnel4Ip = $tfOutput.tunnel4_outside_ip.value
$awsTunnel3BgpIp = $tfOutput.tunnel3_cgw_inside_ip.value
$awsTunnel4BgpIp = $tfOutput.tunnel4_cgw_inside_ip.value

Write-Host "  VPN Connection 1 (to Azure Instance 0):" -ForegroundColor Green
Write-Host "    Tunnel 1: $awsTunnel1Ip (BGP: $awsTunnel1BgpIp)" -ForegroundColor DarkGray
Write-Host "    Tunnel 2: $awsTunnel2Ip (BGP: $awsTunnel2BgpIp)" -ForegroundColor DarkGray
Write-Host "  VPN Connection 2 (to Azure Instance 1):" -ForegroundColor Green
Write-Host "    Tunnel 3: $awsTunnel3Ip (BGP: $awsTunnel3BgpIp)" -ForegroundColor DarkGray
Write-Host "    Tunnel 4: $awsTunnel4Ip (BGP: $awsTunnel4BgpIp)" -ForegroundColor DarkGray

# ============================================
# PHASE 3: Configure Azure VPN Sites with Links (ARM REST API)
# Per MS doc: 2 VPN Sites, each with 2 links (4 tunnels total)
# https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-howto-aws-bgp
# ============================================
Write-Host ""
Write-Host "==> Phase 3: Azure VPN Sites configuration (2 sites, 4 tunnels)" -ForegroundColor Cyan

$vpnSite1Name = "aws-site-instance0"
$vpnSite2Name = "aws-site-instance1"
$vwanName = "vwan-lab-003"
$vpnConn1Name = "conn-aws-instance0"
$vpnConn2Name = "conn-aws-instance1"

# Get vWAN ID for reference
$vwanId = az network vwan show -g $ResourceGroup -n $vwanName --query id -o tsv

# Temp directory for ARM REST API body files
$tempDir = Join-Path $RepoRoot ".data\lab-003"
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }

# Helper function to create VPN Site with 2 links
function New-VpnSiteWithLinks {
  param(
    [string]$SiteName,
    [string]$Tunnel1Ip,
    [string]$Tunnel1BgpIp,
    [string]$Tunnel2Ip,
    [string]$Tunnel2BgpIp,
    [string]$LinkSuffix
  )

  Write-Host "  Creating VPN Site: $SiteName" -ForegroundColor Gray

  $siteBody = @{
    location = $Location
    tags = @{
      project = "azure-labs"
      lab = "lab-003"
      env = "lab"
    }
    properties = @{
      virtualWan = @{ id = $vwanId }
      addressSpace = @{ addressPrefixes = @("10.20.0.0/16") }
      deviceProperties = @{ deviceVendor = "AWS"; deviceModel = "VGW" }
      vpnSiteLinks = @(
        @{
          name = $SiteName  # First link MUST have same name as site
          properties = @{
            ipAddress = $Tunnel1Ip
            linkProperties = @{ linkSpeedInMbps = 100 }
            bgpProperties = @{ asn = $AwsBgpAsn; bgpPeeringAddress = $Tunnel1BgpIp }
          }
        },
        @{
          name = "link-$LinkSuffix-2"
          properties = @{
            ipAddress = $Tunnel2Ip
            linkProperties = @{ linkSpeedInMbps = 100 }
            bgpProperties = @{ asn = $AwsBgpAsn; bgpPeeringAddress = $Tunnel2BgpIp }
          }
        }
      )
    }
  } | ConvertTo-Json -Depth 10

  $siteUri = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/vpnSites/$SiteName`?api-version=2023-09-01"
  $tempFile = Join-Path $tempDir "$SiteName-body.json"
  $siteBody | Out-File -FilePath $tempFile -Encoding utf8

  az rest --method PUT --uri $siteUri --body "@$tempFile" --output none 2>&1 | Tee-Object -Variable result
  if ($LASTEXITCODE -ne 0) {
    Write-Host "    ERROR: $result" -ForegroundColor Red
    return $false
  }
  Write-Host "    Created with links: $SiteName, link-$LinkSuffix-2" -ForegroundColor DarkGray
  return $true
}

# Delete old single-site if it exists (migration to 2-site architecture)
$oldSite = az network vpn-site show -g $ResourceGroup -n "lab-003-aws-site" -o json 2>$null | ConvertFrom-Json
if ($oldSite) {
  Write-Host "  Removing old VPN Site (migrating to 2-site architecture)..." -ForegroundColor Yellow
  az network vpn-site delete -g $ResourceGroup -n "lab-003-aws-site" --yes 2>$null
  Start-Sleep -Seconds 5
}

# Check/create VPN Site 1 (Azure Instance 0)
$existingSite1 = az network vpn-site show -g $ResourceGroup -n $vpnSite1Name -o json 2>$null | ConvertFrom-Json
if (-not $existingSite1 -or $existingSite1.vpnSiteLinks.Count -lt 2) {
  if ($existingSite1) {
    az network vpn-site delete -g $ResourceGroup -n $vpnSite1Name --yes 2>$null
    Start-Sleep -Seconds 3
  }
  $site1Created = New-VpnSiteWithLinks -SiteName $vpnSite1Name `
    -Tunnel1Ip $awsTunnel1Ip -Tunnel1BgpIp $awsTunnel1BgpIp `
    -Tunnel2Ip $awsTunnel2Ip -Tunnel2BgpIp $awsTunnel2BgpIp `
    -LinkSuffix "t1"
  if (-not $site1Created) { throw "Failed to create VPN Site 1" }
} else {
  Write-Host "  VPN Site 1 already exists with valid links" -ForegroundColor Green
}

# Check/create VPN Site 2 (Azure Instance 1)
$existingSite2 = az network vpn-site show -g $ResourceGroup -n $vpnSite2Name -o json 2>$null | ConvertFrom-Json
if (-not $existingSite2 -or $existingSite2.vpnSiteLinks.Count -lt 2) {
  if ($existingSite2) {
    az network vpn-site delete -g $ResourceGroup -n $vpnSite2Name --yes 2>$null
    Start-Sleep -Seconds 3
  }
  $site2Created = New-VpnSiteWithLinks -SiteName $vpnSite2Name `
    -Tunnel1Ip $awsTunnel3Ip -Tunnel1BgpIp $awsTunnel3BgpIp `
    -Tunnel2Ip $awsTunnel4Ip -Tunnel2BgpIp $awsTunnel4BgpIp `
    -LinkSuffix "t2"
  if (-not $site2Created) { throw "Failed to create VPN Site 2" }
} else {
  Write-Host "  VPN Site 2 already exists with valid links" -ForegroundColor Green
}

Write-Host "  VPN Sites created:" -ForegroundColor Green
Write-Host "    Site 1 ($vpnSite1Name): Tunnels 1-2 -> Azure Instance 0" -ForegroundColor DarkGray
Write-Host "      Link 1: $awsTunnel1Ip (BGP: $awsTunnel1BgpIp)" -ForegroundColor DarkGray
Write-Host "      Link 2: $awsTunnel2Ip (BGP: $awsTunnel2BgpIp)" -ForegroundColor DarkGray
Write-Host "    Site 2 ($vpnSite2Name): Tunnels 3-4 -> Azure Instance 1" -ForegroundColor DarkGray
Write-Host "      Link 3: $awsTunnel3Ip (BGP: $awsTunnel3BgpIp)" -ForegroundColor DarkGray
Write-Host "      Link 4: $awsTunnel4Ip (BGP: $awsTunnel4BgpIp)" -ForegroundColor DarkGray

Start-Sleep -Seconds 10

# ============================================
# PHASE 4: Create VPN Gateway Connections (2 connections, one per site)
# ============================================
Write-Host ""
Write-Host "==> Phase 4: VPN Gateway connections" -ForegroundColor Cyan

# Helper function to create VPN Gateway connection with 2 link connections
function New-VpnGatewayConnection {
  param(
    [string]$ConnName,
    [string]$SiteName,
    [string]$Psk1,
    [string]$Psk2,
    [string]$Link2Suffix
  )

  $siteObj = az network vpn-site show -g $ResourceGroup -n $SiteName -o json | ConvertFrom-Json
  $siteId = $siteObj.id

  # Check if connection already exists
  $existing = az network vpn-gateway connection show -g $ResourceGroup --gateway-name $vpnGwName -n $ConnName -o json 2>$null | ConvertFrom-Json
  if ($existing) {
    Write-Host "  Connection $ConnName already exists" -ForegroundColor Green
    return $true
  }

  Write-Host "  Creating connection: $ConnName" -ForegroundColor Gray

  $connBody = @{
    properties = @{
      remoteVpnSite = @{ id = $siteId }
      enableBgp = $true
      vpnLinkConnections = @(
        @{
          name = "$ConnName-link1"
          properties = @{
            vpnSiteLink = @{ id = "$siteId/vpnSiteLinks/$SiteName" }
            sharedKey = $Psk1
            enableBgp = $true
            vpnConnectionProtocolType = "IKEv2"
            connectionBandwidth = 100
          }
        },
        @{
          name = "$ConnName-link2"
          properties = @{
            vpnSiteLink = @{ id = "$siteId/vpnSiteLinks/link-$Link2Suffix-2" }
            sharedKey = $Psk2
            enableBgp = $true
            vpnConnectionProtocolType = "IKEv2"
            connectionBandwidth = 100
          }
        }
      )
    }
  } | ConvertTo-Json -Depth 10

  $connUri = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/vpnGateways/$vpnGwName/vpnConnections/$ConnName`?api-version=2023-09-01"
  $tempFile = Join-Path $tempDir "$ConnName-body.json"
  $connBody | Out-File -FilePath $tempFile -Encoding utf8

  az rest --method PUT --uri $connUri --body "@$tempFile" 2>&1 | Tee-Object -Variable result
  if ($LASTEXITCODE -ne 0) {
    Write-Host "    ARM API failed, trying Azure CLI..." -ForegroundColor Yellow
    az network vpn-gateway connection create -g $ResourceGroup --gateway-name $vpnGwName -n $ConnName `
      --remote-vpn-site $siteId --shared-key $Psk1 --enable-bgp true --output none 2>&1 | Tee-Object -Variable cliResult
    if ($LASTEXITCODE -ne 0) {
      Write-Host "    CLI also failed: $cliResult" -ForegroundColor Red
      return $false
    }
  }
  return $true
}

# Create Connection 1 (Site 1 -> Azure Instance 0)
Write-Host "  Connecting Site 1 to VPN Gateway (Azure Instance 0)..." -ForegroundColor Gray
$conn1 = New-VpnGatewayConnection -ConnName $vpnConn1Name -SiteName $vpnSite1Name -Psk1 $psk1 -Psk2 $psk2 -Link2Suffix "t1"
if (-not $conn1) { Write-Host "  WARNING: Connection 1 may have failed" -ForegroundColor Yellow }

# Create Connection 2 (Site 2 -> Azure Instance 1)
Write-Host "  Connecting Site 2 to VPN Gateway (Azure Instance 1)..." -ForegroundColor Gray
$conn2 = New-VpnGatewayConnection -ConnName $vpnConn2Name -SiteName $vpnSite2Name -Psk1 $psk3 -Psk2 $psk4 -Link2Suffix "t2"
if (-not $conn2) { Write-Host "  WARNING: Connection 2 may have failed" -ForegroundColor Yellow }

# Wait for provisioning
Write-Host "  Waiting for connections to provision..." -ForegroundColor Gray
Start-Sleep -Seconds 30

# Verify connections
Write-Host "  Verifying connections..." -ForegroundColor Gray
$verifyConn1 = az network vpn-gateway connection show -g $ResourceGroup --gateway-name $vpnGwName -n $vpnConn1Name -o json 2>$null | ConvertFrom-Json
$verifyConn2 = az network vpn-gateway connection show -g $ResourceGroup --gateway-name $vpnGwName -n $vpnConn2Name -o json 2>$null | ConvertFrom-Json

if ($verifyConn1) {
  Write-Host "  Connection 1: $($verifyConn1.provisioningState)" -ForegroundColor Green
} else {
  Write-Host "  Connection 1: NOT FOUND" -ForegroundColor Red
}
if ($verifyConn2) {
  Write-Host "  Connection 2: $($verifyConn2.provisioningState)" -ForegroundColor Green
} else {
  Write-Host "  Connection 2: NOT FOUND" -ForegroundColor Red
}


# ============================================
# PHASE 5: Save outputs + Inventory Report
# ============================================
Write-Host ""
Write-Host "==> Phase 5: Generating inventory report" -ForegroundColor Cyan

Ensure-Directory (Split-Path -Parent $OutputsPath)

# Get full Azure resource IDs for inventory
$vwanId = az network vwan show -g $ResourceGroup -n "vwan-lab-003" --query id -o tsv 2>$null
$vhubId = az network vhub show -g $ResourceGroup -n "vhub-lab-003" --query id -o tsv 2>$null
$vpnGwId = az network vpn-gateway show -g $ResourceGroup -n $vpnGwName --query id -o tsv 2>$null
$spokeVnetId = az network vnet show -g $ResourceGroup -n "vnet-spoke-lab-003" --query id -o tsv 2>$null
$vmId = az vm show -g $ResourceGroup -n "vm-spoke-lab-003" --query id -o tsv 2>$null
$nicId = az network nic show -g $ResourceGroup -n "nic-vm-spoke-lab-003" --query id -o tsv 2>$null
$vpnSite1IdFull = az network vpn-site show -g $ResourceGroup -n $vpnSite1Name --query id -o tsv 2>$null
$vpnSite2IdFull = az network vpn-site show -g $ResourceGroup -n $vpnSite2Name --query id -o tsv 2>$null

# Get VPN connection IDs
$vpnConn1Id = az network vpn-gateway connection show -g $ResourceGroup --gateway-name $vpnGwName -n $vpnConn1Name --query id -o tsv 2>$null
$vpnConn2Id = az network vpn-gateway connection show -g $ResourceGroup --gateway-name $vpnGwName -n $vpnConn2Name --query id -o tsv 2>$null

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
      vpnSite1 = $vpnSite1IdFull
      vpnSite2 = $vpnSite2IdFull
      vpnConnection1 = $vpnConn1Id
      vpnConnection2 = $vpnConn2Id
    }
    vpnGatewayName = $vpnGwName
    vpnGatewayIps = $azureVpnIps
    # VPN Site 1: Azure Instance 0 (Tunnels 1-2)
    vpnSiteName = $vpnSite1Name
    vpnSite2Name = $vpnSite2Name
    vpnConnectionName = $vpnConn1Name
    vpnConnection2Name = $vpnConn2Name
    vpnSites = @(
      @{
        siteName = $vpnSite1Name
        connectionName = $vpnConn1Name
        azureInstance = 0
        links = @(
          @{
            name = $vpnSite1Name
            ipAddress = $awsTunnel1Ip
            bgpPeeringAddress = $awsTunnel1BgpIp
            apipaCidr = "169.254.21.0/30"
          },
          @{
            name = "link-t1-2"
            ipAddress = $awsTunnel2Ip
            bgpPeeringAddress = $awsTunnel2BgpIp
            apipaCidr = "169.254.22.0/30"
          }
        )
      },
      @{
        siteName = $vpnSite2Name
        connectionName = $vpnConn2Name
        azureInstance = 1
        links = @(
          @{
            name = $vpnSite2Name
            ipAddress = $awsTunnel3Ip
            bgpPeeringAddress = $awsTunnel3BgpIp
            apipaCidr = "169.254.21.4/30"
          },
          @{
            name = "link-t2-2"
            ipAddress = $awsTunnel4Ip
            bgpPeeringAddress = $awsTunnel4BgpIp
            apipaCidr = "169.254.22.4/30"
          }
        )
      }
    )
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
      cgw1 = $tfOutput.cgw_id.value
      cgw2 = $tfOutput.cgw_id_2.value
      vpnConnection1 = $tfOutput.vpn_connection_id.value
      vpnConnection2 = $tfOutput.vpn_connection_2_id.value
    }
    vpnConnectionId = $tfOutput.vpn_connection_id.value
    vpnConnection2Id = $tfOutput.vpn_connection_2_id.value
    vgwId = $tfOutput.vgw_id.value
    vpcId = $tfOutput.vpc_id.value
    # VPN Connection 1 tunnels (to Azure Instance 0)
    tunnel1OutsideIp = $awsTunnel1Ip
    tunnel2OutsideIp = $awsTunnel2Ip
    tunnel1BgpIp = $awsTunnel1BgpIp
    tunnel2BgpIp = $awsTunnel2BgpIp
    # VPN Connection 2 tunnels (to Azure Instance 1)
    tunnel3OutsideIp = $awsTunnel3Ip
    tunnel4OutsideIp = $awsTunnel4Ip
    tunnel3BgpIp = $awsTunnel3BgpIp
    tunnel4BgpIp = $awsTunnel4BgpIp
    bgpAsn = $AwsBgpAsn
  }
}

$outputs | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputsPath -Encoding UTF8

Write-Host ""
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "==> Inventory Report" -ForegroundColor Yellow
Write-Host "Outputs saved to: $OutputsPath" -ForegroundColor Gray
Write-Host ""
Write-Host "Azure Resources (location: $Location):" -ForegroundColor White
Write-Host "  Resource Group:  $ResourceGroup" -ForegroundColor Gray
Write-Host "  Virtual WAN:     vwan-lab-003" -ForegroundColor Gray
Write-Host "  Virtual Hub:     vhub-lab-003" -ForegroundColor Gray
Write-Host "  VPN Gateway:     $vpnGwName" -ForegroundColor Gray
Write-Host "  Spoke VNet:      vnet-spoke-lab-003" -ForegroundColor Gray
Write-Host "  Test VM:         vm-spoke-lab-003" -ForegroundColor Gray
Write-Host ""
Write-Host "VPN Sites (2-site architecture per MS doc):" -ForegroundColor White
Write-Host "  Site 1: $vpnSite1Name (Azure Instance 0)" -ForegroundColor Cyan
Write-Host "    Connection: $vpnConn1Name" -ForegroundColor Gray
Write-Host "    Tunnel 1: $awsTunnel1Ip (BGP: $awsTunnel1BgpIp, APIPA: 169.254.21.0/30)" -ForegroundColor Gray
Write-Host "    Tunnel 2: $awsTunnel2Ip (BGP: $awsTunnel2BgpIp, APIPA: 169.254.22.0/30)" -ForegroundColor Gray
Write-Host "  Site 2: $vpnSite2Name (Azure Instance 1)" -ForegroundColor Cyan
Write-Host "    Connection: $vpnConn2Name" -ForegroundColor Gray
Write-Host "    Tunnel 3: $awsTunnel3Ip (BGP: $awsTunnel3BgpIp, APIPA: 169.254.21.4/30)" -ForegroundColor Gray
Write-Host "    Tunnel 4: $awsTunnel4Ip (BGP: $awsTunnel4BgpIp, APIPA: 169.254.22.4/30)" -ForegroundColor Gray
Write-Host ""
Write-Host "AWS Resources (region: $AwsRegion):" -ForegroundColor White
Write-Host "  VPC:              $($tfOutput.vpc_id.value)" -ForegroundColor Gray
Write-Host "  VGW:              $($tfOutput.vgw_id.value)" -ForegroundColor Gray
Write-Host "  CGW 1 (Inst 0):   $($tfOutput.cgw_id.value)" -ForegroundColor Gray
Write-Host "  CGW 2 (Inst 1):   $($tfOutput.cgw_id_2.value)" -ForegroundColor Gray
Write-Host "  VPN Conn 1:       $($tfOutput.vpn_connection_id.value)" -ForegroundColor Gray
Write-Host "  VPN Conn 2:       $($tfOutput.vpn_connection_2_id.value)" -ForegroundColor Gray
Write-Host ""
Write-Host "Tags applied: project=azure-labs, lab=lab-003, env=lab$(if($Owner){", owner=$Owner"})" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Wait 5-10 min for BGP to establish" -ForegroundColor Gray
Write-Host "  2. Run: .\scripts\validate.ps1" -ForegroundColor Gray
Write-Host ""
Write-Host "Azure <-> AWS Tunnel Mapping:" -ForegroundColor White
Write-Host "  Site 1 (Instance 0):" -ForegroundColor Yellow
Write-Host "    Tunnel 1: $awsTunnel1Ip <-> Azure: $azureVpnIp1" -ForegroundColor Gray
Write-Host "    Tunnel 2: $awsTunnel2Ip <-> Azure: $azureVpnIp1" -ForegroundColor Gray
if ($azureVpnIp2) {
  Write-Host "  Site 2 (Instance 1):" -ForegroundColor Yellow
  Write-Host "    Tunnel 3: $awsTunnel3Ip <-> Azure: $azureVpnIp2" -ForegroundColor Gray
  Write-Host "    Tunnel 4: $awsTunnel4Ip <-> Azure: $azureVpnIp2" -ForegroundColor Gray
}
Write-Host ""
