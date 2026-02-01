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

# Generate PSKs locally (4 total - 2 per VPN connection)
$psk1 = New-RandomPsk  # VPN1 Tunnel 1 (to Azure Instance 0)
$psk2 = New-RandomPsk  # VPN1 Tunnel 2 (to Azure Instance 0)
$psk3 = New-RandomPsk  # VPN2 Tunnel 1 (to Azure Instance 1)
$psk4 = New-RandomPsk  # VPN2 Tunnel 2 (to Azure Instance 1)

Write-Host "Generated pre-shared keys for 4 VPN tunnels" -ForegroundColor Gray

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
# PHASE 3: Configure Azure VPN Site with Links (ARM REST API)
# ============================================
Write-Host ""
Write-Host "==> Phase 3: Azure VPN Site configuration" -ForegroundColor Cyan

$vpnSiteName = "lab-003-aws-site"
$vwanName = "vwan-lab-003"
$vpnConnName = "conn-$vpnSiteName"

# Get vWAN ID for reference
$vwanId = az network vwan show -g $ResourceGroup -n $vwanName --query id -o tsv

# Temp directory for ARM REST API body files
$tempDir = Join-Path $RepoRoot ".data\lab-003"
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }

# Check if site exists and has all 4 links
$existingSite = az network vpn-site show -g $ResourceGroup -n $vpnSiteName -o json 2>$null | ConvertFrom-Json
$hasValidLinks = $false
if ($existingSite -and $existingSite.vpnSiteLinks -and $existingSite.vpnSiteLinks.Count -ge 4) {
  # Check if links have BGP properties with APIPA
  $link1Bgp = $existingSite.vpnSiteLinks[0].bgpProperties.bgpPeeringAddress
  if ($link1Bgp -match "^169\.254\.") {
    $hasValidLinks = $true
    Write-Host "  VPN Site already has 4 valid links with APIPA BGP" -ForegroundColor Green
  }
}

if (-not $hasValidLinks) {
  # Delete existing incomplete site if it exists
  if ($existingSite) {
    Write-Host "  Removing incomplete VPN Site..." -ForegroundColor Yellow
    az network vpn-site delete -g $ResourceGroup -n $vpnSiteName --yes 2>$null
    Start-Sleep -Seconds 5
  }

  Write-Host "Creating VPN Site with 4 links using ARM API..." -ForegroundColor Gray

  # Build the full VPN Site resource with 4 links using ARM REST API
  # Links 1-2: Connect to Azure VPN Gateway Instance 0
  # Links 3-4: Connect to Azure VPN Gateway Instance 1
  $vpnSiteBody = @{
    location = $Location
    tags = @{
      project = "azure-labs"
      lab = "lab-003"
      env = "lab"
    }
    properties = @{
      virtualWan = @{
        id = $vwanId
      }
      addressSpace = @{
        addressPrefixes = @("10.20.0.0/16")
      }
      deviceProperties = @{
        deviceVendor = "AWS"
        deviceModel = "VGW"
      }
      vpnSiteLinks = @(
        @{
          name = "link-tunnel1"
          properties = @{
            ipAddress = $awsTunnel1Ip
            linkProperties = @{
              linkSpeedInMbps = 100
            }
            bgpProperties = @{
              asn = $AwsBgpAsn
              bgpPeeringAddress = $awsTunnel1BgpIp
            }
          }
        },
        @{
          name = "link-tunnel2"
          properties = @{
            ipAddress = $awsTunnel2Ip
            linkProperties = @{
              linkSpeedInMbps = 100
            }
            bgpProperties = @{
              asn = $AwsBgpAsn
              bgpPeeringAddress = $awsTunnel2BgpIp
            }
          }
        },
        @{
          name = "link-tunnel3"
          properties = @{
            ipAddress = $awsTunnel3Ip
            linkProperties = @{
              linkSpeedInMbps = 100
            }
            bgpProperties = @{
              asn = $AwsBgpAsn
              bgpPeeringAddress = $awsTunnel3BgpIp
            }
          }
        },
        @{
          name = "link-tunnel4"
          properties = @{
            ipAddress = $awsTunnel4Ip
            linkProperties = @{
              linkSpeedInMbps = 100
            }
            bgpProperties = @{
              asn = $AwsBgpAsn
              bgpPeeringAddress = $awsTunnel4BgpIp
            }
          }
        }
      )
    }
  } | ConvertTo-Json -Depth 10

  $vpnSiteUri = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/vpnSites/$vpnSiteName`?api-version=2023-09-01"

  # Write body to temp file (az rest on Windows needs file input for JSON)
  $vpnSiteTempFile = Join-Path $tempDir "vpnsite-body.json"
  $vpnSiteBody | Out-File -FilePath $vpnSiteTempFile -Encoding utf8

  az rest --method PUT --uri $vpnSiteUri --body "@$vpnSiteTempFile" --output none
  if ($LASTEXITCODE -ne 0) { throw "VPN Site creation failed." }

  Write-Host "  VPN Site created with 4 links" -ForegroundColor Green
  Write-Host "    Link 1: $awsTunnel1Ip (BGP: $awsTunnel1BgpIp) -> Instance 0" -ForegroundColor DarkGray
  Write-Host "    Link 2: $awsTunnel2Ip (BGP: $awsTunnel2BgpIp) -> Instance 0" -ForegroundColor DarkGray
  Write-Host "    Link 3: $awsTunnel3Ip (BGP: $awsTunnel3BgpIp) -> Instance 1" -ForegroundColor DarkGray
  Write-Host "    Link 4: $awsTunnel4Ip (BGP: $awsTunnel4BgpIp) -> Instance 1" -ForegroundColor DarkGray

  # Wait for provisioning
  Start-Sleep -Seconds 10
}

# ============================================
# PHASE 4: Create VPN Gateway Connection
# ============================================
Write-Host ""
Write-Host "==> Phase 4: VPN Gateway connection" -ForegroundColor Cyan

# Get the VPN Site with links
$vpnSite = az network vpn-site show -g $ResourceGroup -n $vpnSiteName -o json | ConvertFrom-Json
$vpnSiteId = $vpnSite.id

# Check if connection exists
$existingConn = az network vpn-gateway connection show -g $ResourceGroup --gateway-name $vpnGwName -n $vpnConnName -o json 2>$null | ConvertFrom-Json

if (-not $existingConn) {
  Write-Host "Creating VPN Gateway connection with 4 link connections..." -ForegroundColor Gray

  # Get site link IDs for all 4 tunnels
  $siteLink1Id = "$vpnSiteId/vpnSiteLinks/link-tunnel1"
  $siteLink2Id = "$vpnSiteId/vpnSiteLinks/link-tunnel2"
  $siteLink3Id = "$vpnSiteId/vpnSiteLinks/link-tunnel3"
  $siteLink4Id = "$vpnSiteId/vpnSiteLinks/link-tunnel4"

  # Build connection with all 4 link connections using ARM REST API
  $vpnConnBody = @{
    properties = @{
      remoteVpnSite = @{
        id = $vpnSiteId
      }
      enableBgp = $true
      vpnLinkConnections = @(
        @{
          name = "link-conn-tunnel1"
          properties = @{
            vpnSiteLink = @{
              id = $siteLink1Id
            }
            sharedKey = $psk1
            enableBgp = $true
            vpnConnectionProtocolType = "IKEv2"
            connectionBandwidth = 100
            usePolicyBasedTrafficSelectors = $false
          }
        },
        @{
          name = "link-conn-tunnel2"
          properties = @{
            vpnSiteLink = @{
              id = $siteLink2Id
            }
            sharedKey = $psk2
            enableBgp = $true
            vpnConnectionProtocolType = "IKEv2"
            connectionBandwidth = 100
            usePolicyBasedTrafficSelectors = $false
          }
        },
        @{
          name = "link-conn-tunnel3"
          properties = @{
            vpnSiteLink = @{
              id = $siteLink3Id
            }
            sharedKey = $psk3
            enableBgp = $true
            vpnConnectionProtocolType = "IKEv2"
            connectionBandwidth = 100
            usePolicyBasedTrafficSelectors = $false
          }
        },
        @{
          name = "link-conn-tunnel4"
          properties = @{
            vpnSiteLink = @{
              id = $siteLink4Id
            }
            sharedKey = $psk4
            enableBgp = $true
            vpnConnectionProtocolType = "IKEv2"
            connectionBandwidth = 100
            usePolicyBasedTrafficSelectors = $false
          }
        }
      )
    }
  } | ConvertTo-Json -Depth 10

  $vpnConnUri = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/vpnGateways/$vpnGwName/vpnConnections/$vpnConnName`?api-version=2023-09-01"

  # Write body to temp file (az rest on Windows needs file input for JSON)
  $vpnConnTempFile = Join-Path $tempDir "vpnconn-body.json"
  $vpnConnBody | Out-File -FilePath $vpnConnTempFile -Encoding utf8

  az rest --method PUT --uri $vpnConnUri --body "@$vpnConnTempFile" --output none
  if ($LASTEXITCODE -ne 0) {
    Write-Host "  Warning: VPN connection creation may have failed" -ForegroundColor Yellow
  } else {
    Write-Host "  VPN Connection created with 4 link connections (BGP enabled)" -ForegroundColor Green
    Write-Host "    Link Connection 1: tunnel1 -> Azure Instance 0" -ForegroundColor DarkGray
    Write-Host "    Link Connection 2: tunnel2 -> Azure Instance 0" -ForegroundColor DarkGray
    Write-Host "    Link Connection 3: tunnel3 -> Azure Instance 1" -ForegroundColor DarkGray
    Write-Host "    Link Connection 4: tunnel4 -> Azure Instance 1" -ForegroundColor DarkGray
  }

  # Wait for connection provisioning
  Write-Host "  Waiting for connection provisioning..." -ForegroundColor Gray
  Start-Sleep -Seconds 30
} else {
  Write-Host "  VPN Connection already exists" -ForegroundColor Green
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
$vpnSiteIdFull = az network vpn-site show -g $ResourceGroup -n $vpnSiteName --query id -o tsv 2>$null

# Get VPN connection ID
$vpnConnId = az network vpn-gateway connection show -g $ResourceGroup --gateway-name $vpnGwName -n $vpnConnName --query id -o tsv 2>$null

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
      vpnSite = $vpnSiteIdFull
      vpnConnection = $vpnConnId
    }
    vpnGatewayName = $vpnGwName
    vpnGatewayIps = $azureVpnIps
    vpnSiteName = $vpnSiteName
    vpnConnectionName = $vpnConnName
    vpnSiteLinks = @(
      @{
        name = "link-tunnel1"
        ipAddress = $awsTunnel1Ip
        bgpPeeringAddress = $awsTunnel1BgpIp
        asn = $AwsBgpAsn
        azureInstance = 0
      },
      @{
        name = "link-tunnel2"
        ipAddress = $awsTunnel2Ip
        bgpPeeringAddress = $awsTunnel2BgpIp
        asn = $AwsBgpAsn
        azureInstance = 0
      },
      @{
        name = "link-tunnel3"
        ipAddress = $awsTunnel3Ip
        bgpPeeringAddress = $awsTunnel3BgpIp
        asn = $AwsBgpAsn
        azureInstance = 1
      },
      @{
        name = "link-tunnel4"
        ipAddress = $awsTunnel4Ip
        bgpPeeringAddress = $awsTunnel4BgpIp
        asn = $AwsBgpAsn
        azureInstance = 1
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
Write-Host "  VPN Site:        $vpnSiteName" -ForegroundColor Gray
Write-Host "  VPN Connection:  $vpnConnName" -ForegroundColor Gray
Write-Host "  Spoke VNet:      vnet-spoke-lab-003" -ForegroundColor Gray
Write-Host "  Test VM:         vm-spoke-lab-003" -ForegroundColor Gray
Write-Host ""
Write-Host "VPN Site Links (APIPA BGP):" -ForegroundColor White
Write-Host "  Link 1: $awsTunnel1Ip -> BGP: $awsTunnel1BgpIp (-> Azure Instance 0)" -ForegroundColor Cyan
Write-Host "  Link 2: $awsTunnel2Ip -> BGP: $awsTunnel2BgpIp (-> Azure Instance 0)" -ForegroundColor Cyan
Write-Host "  Link 3: $awsTunnel3Ip -> BGP: $awsTunnel3BgpIp (-> Azure Instance 1)" -ForegroundColor Cyan
Write-Host "  Link 4: $awsTunnel4Ip -> BGP: $awsTunnel4BgpIp (-> Azure Instance 1)" -ForegroundColor Cyan
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
Write-Host "  AWS Tunnel 1: $awsTunnel1Ip <-> Azure: $azureVpnIp1" -ForegroundColor Gray
Write-Host "  AWS Tunnel 2: $awsTunnel2Ip <-> Azure: $azureVpnIp1" -ForegroundColor Gray
