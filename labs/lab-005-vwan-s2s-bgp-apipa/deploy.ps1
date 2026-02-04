# labs/lab-005-vwan-s2s-bgp-apipa/deploy.ps1
# Deploys Azure vWAN S2S VPN Gateway with BGP over APIPA (Azure-style, no AWS)
#
# This lab proves:
# - vWAN S2S Gateway dual-instance behavior (Instance 0 vs Instance 1)
# - Deterministic APIPA /30 mapping per VPN site link
# - Fail-forward phased deployment with validation between steps

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [string]$Location = "centralus",
  [string]$Owner = "",
  [switch]$Force
)

# ============================================
# GUARDRAILS
# ============================================
$AllowedLocations = @("centralus", "eastus", "eastus2", "westus2")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path
$LogsDir = Join-Path $LabRoot "logs"
$OutputsPath = Join-Path $RepoRoot ".data\lab-005\outputs.json"

# Load shared helpers
. (Join-Path $RepoRoot "scripts\labs-common.ps1")

# Lab configuration
$ResourceGroup = "rg-lab-005-vwan-s2s"
$VwanName = "vwan-lab-005"
$VhubName = "vhub-lab-005"
$VhubPrefix = "10.0.0.0/24"
$VpnGwName = "vpngw-lab-005"
$AzureBgpAsn = 65515

# VPN Sites configuration - 4 sites, 2 links each
# Each site represents a "logical customer gateway"
$VpnSites = @(
  @{
    Name = "site-1"
    Asn = 65001
    Links = @(
      @{ Name = "link-1"; Apipa = "169.254.21.0/30"; Instance = 0 }
      @{ Name = "link-2"; Apipa = "169.254.22.0/30"; Instance = 1 }
    )
  },
  @{
    Name = "site-2"
    Asn = 65002
    Links = @(
      @{ Name = "link-3"; Apipa = "169.254.21.4/30"; Instance = 0 }
      @{ Name = "link-4"; Apipa = "169.254.22.4/30"; Instance = 1 }
    )
  },
  @{
    Name = "site-3"
    Asn = 65003
    Links = @(
      @{ Name = "link-5"; Apipa = "169.254.21.8/30"; Instance = 0 }
      @{ Name = "link-6"; Apipa = "169.254.22.8/30"; Instance = 1 }
    )
  },
  @{
    Name = "site-4"
    Asn = 65004
    Links = @(
      @{ Name = "link-7"; Apipa = "169.254.21.12/30"; Instance = 0 }
      @{ Name = "link-8"; Apipa = "169.254.22.12/30"; Instance = 1 }
    )
  }
)

# ============================================
# HELPER FUNCTIONS
# ============================================

function Require-Command($name, $installHint) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $name. $installHint"
  }
}

function Invoke-AzCommand {
  # Safely run az CLI commands, suppressing stderr errors that PowerShell treats as exceptions
  param([string]$Command)
  $oldErrPref = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  try {
    $result = Invoke-Expression "az $Command 2>`$null"
    $script:LastAzExitCode = $LASTEXITCODE
    return $result
  } finally {
    $ErrorActionPreference = $oldErrPref
  }
}

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function New-RandomPsk {
  -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
}

function Get-ApipaAddress {
  # Given a /30 CIDR, return the two usable addresses
  # e.g., 169.254.21.0/30 -> .1 (remote), .2 (Azure)
  param([string]$Cidr)
  $parts = $Cidr -split "/"
  $ip = $parts[0]
  $octets = $ip -split "\."
  $lastOctet = [int]$octets[3]
  $remote = "$($octets[0]).$($octets[1]).$($octets[2]).$($lastOctet + 1)"
  $azure = "$($octets[0]).$($octets[1]).$($octets[2]).$($lastOctet + 2)"
  return @{ Remote = $remote; Azure = $azure }
}

function Write-Phase {
  param([int]$Number, [string]$Title)
  Write-Host ""
  Write-Host ("=" * 60) -ForegroundColor Cyan
  Write-Host "PHASE $Number : $Title" -ForegroundColor Cyan
  Write-Host ("=" * 60) -ForegroundColor Cyan
  Write-Host ""
}

function Write-Validation {
  param([string]$Check, [bool]$Passed, [string]$Details = "")
  if ($Passed) {
    Write-Host "  [PASS] $Check" -ForegroundColor Green
  } else {
    Write-Host "  [FAIL] $Check" -ForegroundColor Red
  }
  if ($Details) {
    Write-Host "         $Details" -ForegroundColor DarkGray
  }
}

function Write-Log {
  param([string]$Message, [string]$Level = "INFO")
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $logLine = "[$timestamp] [$Level] $Message"
  Add-Content -Path $script:LogFile -Value $logLine

  switch ($Level) {
    "ERROR" { Write-Host $Message -ForegroundColor Red }
    "WARN"  { Write-Host $Message -ForegroundColor Yellow }
    "SUCCESS" { Write-Host $Message -ForegroundColor Green }
    default { Write-Host $Message }
  }
}

function Assert-LocationAllowed {
  param([string]$Location, [string[]]$AllowedLocations)
  if ($AllowedLocations -notcontains $Location) {
    Write-Host ""
    Write-Host "HARD STOP: Location '$Location' is not in the allowlist." -ForegroundColor Red
    Write-Host "Allowed locations: $($AllowedLocations -join ', ')" -ForegroundColor Yellow
    throw "Location '$Location' not allowed."
  }
}

function Get-ElapsedTime {
  param([datetime]$StartTime)
  $elapsed = (Get-Date) - $StartTime
  return "$([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
}

# ============================================
# MAIN DEPLOYMENT
# ============================================

Write-Host ""
Write-Host "Lab 005: vWAN S2S BGP over APIPA (Azure-style)" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Purpose: Prove Azure vWAN S2S VPN Gateway instance 0 vs instance 1" -ForegroundColor White
Write-Host "         behavior with deterministic APIPA /30 allocations." -ForegroundColor White
Write-Host ""

$deploymentStartTime = Get-Date

# ============================================
# PHASE 0: Preflight
# ============================================
Write-Phase -Number 0 -Title "Preflight Checks"

# Initialize log directory and file
Ensure-Directory $LogsDir
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$script:LogFile = Join-Path $LogsDir "lab-005-$timestamp.log"
Write-Log "Deployment started"
Write-Log "Location: $Location"

# Check Azure CLI
Require-Command az "Install Azure CLI: https://aka.ms/installazurecli"
Write-Validation -Check "Azure CLI installed" -Passed $true

# Check location
Assert-LocationAllowed -Location $Location -AllowedLocations $AllowedLocations
Write-Validation -Check "Location '$Location' allowed" -Passed $true

# Load config
Show-ConfigPreflight -RepoRoot $RepoRoot
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Write-Validation -Check "Subscription resolved" -Passed $true -Details $SubscriptionId

# Azure auth
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null
Write-Validation -Check "Azure authenticated" -Passed $true

# Check for existing resource group
$oldErrPref = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"
$existingRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
if ($existingRg) {
  Write-Host ""
  Write-Host "Resource group '$ResourceGroup' already exists." -ForegroundColor Yellow
  Write-Host "This may be a resume from a previous deployment." -ForegroundColor Yellow
  if (-not $Force) {
    $confirm = Read-Host "Continue with existing resources? (y/n)"
    if ($confirm.ToLower() -ne "y") {
      throw "Cancelled. Run destroy.ps1 first to clean up."
    }
  }
}

Write-Log "Preflight checks passed" "SUCCESS"

# Cost confirmation
if (-not $Force) {
  Write-Host ""
  Write-Host "This creates billable resources:" -ForegroundColor Yellow
  Write-Host "  - vWAN Hub: ~`$0.25/hr" -ForegroundColor Gray
  Write-Host "  - S2S VPN Gateway (2 scale units): ~`$0.36/hr" -ForegroundColor Gray
  Write-Host "  - Estimated total: ~`$0.61/hr" -ForegroundColor Gray
  Write-Host ""
  $confirm = Read-Host "Type DEPLOY to proceed"
  if ($confirm -ne "DEPLOY") { throw "Cancelled." }
}

# Portal link
$portalUrl = "https://portal.azure.com/#@/resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/deployments"
Write-Host ""
Write-Host "Monitor in Azure Portal:" -ForegroundColor Yellow
Write-Host "  $portalUrl" -ForegroundColor Cyan
Write-Host ""

# ============================================
# PHASE 1: Core Fabric (vWAN + vHub)
# ============================================
Write-Phase -Number 1 -Title "Core Fabric (vWAN + vHub)"

$phase1Start = Get-Date

# Build tags string (handle empty Owner)
$baseTags = "project=azure-labs lab=lab-005 env=lab"
if ($Owner) { $baseTags += " owner=$Owner" }

# Create Resource Group
Write-Host "Creating resource group: $ResourceGroup" -ForegroundColor Gray
az group create --name $ResourceGroup --location $Location --tags $baseTags --output none
Write-Log "Resource group created: $ResourceGroup"

# Create vWAN
Write-Host "Creating Virtual WAN: $VwanName" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingVwan = az network vwan show -g $ResourceGroup -n $VwanName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
if (-not $existingVwan) {
  az network vwan create `
    --name $VwanName `
    --resource-group $ResourceGroup `
    --location $Location `
    --type Standard `
    --tags $baseTags `
    --output none
  Write-Log "vWAN created: $VwanName"
} else {
  Write-Host "  vWAN already exists, skipping..." -ForegroundColor DarkGray
}

# Create vHub
Write-Host "Creating Virtual Hub: $VhubName (this takes 5-10 minutes)" -ForegroundColor Gray
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingVhub = az network vhub show -g $ResourceGroup -n $VhubName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
if (-not $existingVhub) {
  az network vhub create `
    --name $VhubName `
    --resource-group $ResourceGroup `
    --vwan $VwanName `
    --location $Location `
    --address-prefix $VhubPrefix `
    --tags $baseTags `
    --output none
  Write-Log "vHub created: $VhubName"
} else {
  Write-Host "  vHub already exists, skipping..." -ForegroundColor DarkGray
}

# Wait for vHub provisioning
Write-Host "Waiting for vHub to provision..." -ForegroundColor Gray
$maxAttempts = 60
$attempt = 0
$vhubReady = $false

while ($attempt -lt $maxAttempts) {
  $attempt++
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $vhub = az network vhub show -g $ResourceGroup -n $VhubName -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldErrPref

  if ($vhub.provisioningState -eq "Succeeded") {
    $vhubReady = $true
    break
  } elseif ($vhub.provisioningState -eq "Failed") {
    throw "vHub provisioning failed. Check portal for details."
  }

  $elapsed = Get-ElapsedTime -StartTime $phase1Start
  Write-Host "  [$elapsed] vHub state: $($vhub.provisioningState) (attempt $attempt/$maxAttempts)" -ForegroundColor DarkGray
  Start-Sleep -Seconds 15
}

if (-not $vhubReady) {
  throw "vHub did not provision within timeout. Check portal."
}

$phase1Elapsed = Get-ElapsedTime -StartTime $phase1Start
Write-Host ""
Write-Host "Phase 1 Validation:" -ForegroundColor Yellow
Write-Validation -Check "vHub provisioningState = Succeeded" -Passed $true -Details "Completed in $phase1Elapsed"
Write-Log "Phase 1 completed in $phase1Elapsed" "SUCCESS"

# ============================================
# PHASE 2: S2S VPN Gateway
# ============================================
Write-Phase -Number 2 -Title "S2S VPN Gateway (20-30 minutes)"

$phase2Start = Get-Date

# Check existing gateway state
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingGw = az network vpn-gateway show -g $ResourceGroup -n $VpnGwName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
if ($existingGw) {
  if ($existingGw.provisioningState -eq "Succeeded") {
    Write-Host "VPN Gateway already exists and is healthy - skipping creation" -ForegroundColor Green
  } elseif ($existingGw.provisioningState -eq "Failed") {
    Write-Host "VPN Gateway in FAILED state - deleting before retry..." -ForegroundColor Yellow
    Write-Log "Deleting failed VPN Gateway" "WARN"
    az network vpn-gateway delete -g $ResourceGroup -n $VpnGwName --yes --no-wait 2>$null
    Write-Host "Waiting for deletion (60s)..." -ForegroundColor Gray
    Start-Sleep -Seconds 60
    $existingGw = $null
  } else {
    Write-Host "VPN Gateway is in '$($existingGw.provisioningState)' state - waiting..." -ForegroundColor Yellow
  }
}

if (-not $existingGw -or $existingGw.provisioningState -ne "Succeeded") {
  Write-Host "Creating S2S VPN Gateway: $VpnGwName" -ForegroundColor Gray
  Write-Host "This typically takes 20-30 minutes..." -ForegroundColor DarkGray

  az network vpn-gateway create `
    --name $VpnGwName `
    --resource-group $ResourceGroup `
    --vhub $VhubName `
    --location $Location `
    --scale-unit 1 `
    --tags $baseTags `
    --no-wait `
    --output none

  Write-Log "VPN Gateway creation started: $VpnGwName"

  # Wait for gateway provisioning
  $maxAttempts = 120  # 30 minutes at 15s intervals
  $attempt = 0
  $gwReady = $false

  while ($attempt -lt $maxAttempts) {
    $attempt++
    $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $gw = az network vpn-gateway show -g $ResourceGroup -n $VpnGwName -o json 2>$null | ConvertFrom-Json
    $ErrorActionPreference = $oldErrPref

    if ($gw.provisioningState -eq "Succeeded") {
      $gwReady = $true
      break
    } elseif ($gw.provisioningState -eq "Failed") {
      Write-Log "VPN Gateway provisioning failed" "ERROR"
      throw "VPN Gateway provisioning failed. Check portal for details."
    }

    $elapsed = Get-ElapsedTime -StartTime $phase2Start
    Write-Host "  [$elapsed] Gateway state: $($gw.provisioningState) (attempt $attempt/$maxAttempts)" -ForegroundColor DarkGray
    Start-Sleep -Seconds 15
  }

  if (-not $gwReady) {
    throw "VPN Gateway did not provision within timeout. Check portal."
  }
}

# Get gateway details
$gw = az network vpn-gateway show -g $ResourceGroup -n $VpnGwName -o json | ConvertFrom-Json

# Extract BGP peering addresses for both instances
$instance0BgpIps = @()
$instance1BgpIps = @()

if ($gw.bgpSettings -and $gw.bgpSettings.bgpPeeringAddresses) {
  foreach ($peerAddr in $gw.bgpSettings.bgpPeeringAddresses) {
    $instanceId = $peerAddr.ipconfigurationId -replace ".*Instance", ""
    $defaultAddrs = $peerAddr.defaultBgpIpAddresses
    $customAddrs = $peerAddr.customBgpIpAddresses
    $tunnelIps = $peerAddr.tunnelIpAddresses

    Write-Host "  Instance $instanceId BGP:" -ForegroundColor DarkGray
    Write-Host "    Default: $($defaultAddrs -join ', ')" -ForegroundColor DarkGray
    Write-Host "    Custom:  $($customAddrs -join ', ')" -ForegroundColor DarkGray
    Write-Host "    Tunnel:  $($tunnelIps -join ', ')" -ForegroundColor DarkGray

    if ($instanceId -eq "0" -or $peerAddr.ipconfigurationId -match "Instance0") {
      $instance0BgpIps = $defaultAddrs
    } else {
      $instance1BgpIps = $defaultAddrs
    }
  }
}

$phase2Elapsed = Get-ElapsedTime -StartTime $phase2Start
Write-Host ""
Write-Host "Phase 2 Validation:" -ForegroundColor Yellow
Write-Validation -Check "VPN Gateway provisioningState = Succeeded" -Passed ($gw.provisioningState -eq "Succeeded")
Write-Validation -Check "BGP peering addresses visible" -Passed ($gw.bgpSettings.bgpPeeringAddresses.Count -ge 2) -Details "Found $($gw.bgpSettings.bgpPeeringAddresses.Count) instances"
Write-Log "Phase 2 completed in $phase2Elapsed" "SUCCESS"

# ============================================
# PHASE 3: VPN Sites + Links
# ============================================
Write-Phase -Number 3 -Title "VPN Sites + Links (4 sites, 8 links)"

$phase3Start = Get-Date

# Get vWAN ID
$vwanId = az network vwan show -g $ResourceGroup -n $VwanName --query id -o tsv

# Temp directory for ARM REST API body files
$tempDir = Join-Path $RepoRoot ".data\lab-005"
Ensure-Directory $tempDir

# PSK storage
$pskPath = Join-Path $tempDir "psk-secrets.json"
$psks = @{}

foreach ($site in $VpnSites) {
  $siteName = $site.Name
  Write-Host "Creating VPN Site: $siteName (ASN: $($site.Asn))" -ForegroundColor Gray

  # Check if site exists
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $existingSite = az network vpn-site show -g $ResourceGroup -n $siteName -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldErrPref
  if ($existingSite -and $existingSite.vpnSiteLinks.Count -ge 2) {
    Write-Host "  Site already exists with valid links, skipping..." -ForegroundColor DarkGray
    continue
  }

  # Delete incomplete site if exists
  if ($existingSite) {
    az network vpn-site delete -g $ResourceGroup -n $siteName --yes 2>$null
    Start-Sleep -Seconds 3
  }

  # Build site links array
  $siteLinks = @()
  foreach ($link in $site.Links) {
    $apipa = Get-ApipaAddress -Cidr $link.Apipa

    # Generate and store PSK for this link
    $pskKey = "$siteName-$($link.Name)"
    $psks[$pskKey] = New-RandomPsk

    # For VPN Sites, we use a placeholder IP since there's no real remote device
    # In production, this would be the customer gateway public IP
    $placeholderIp = "192.0.2.$($siteLinks.Count + 1)"  # RFC 5737 TEST-NET-1

    $siteLinks += @{
      name = $link.Name
      properties = @{
        ipAddress = $placeholderIp
        linkProperties = @{ linkSpeedInMbps = 100 }
        bgpProperties = @{
          asn = $site.Asn
          bgpPeeringAddress = $apipa.Remote
        }
      }
    }

    Write-Host "    $($link.Name): APIPA $($link.Apipa) -> Remote: $($apipa.Remote), Azure: $($apipa.Azure) (Instance $($link.Instance))" -ForegroundColor DarkGray
  }

  # Create VPN Site with links via ARM REST API
  $siteBody = @{
    location = $Location
    tags = @{
      project = "azure-labs"
      lab = "lab-005"
      env = "lab"
      owner = $Owner
    }
    properties = @{
      virtualWan = @{ id = $vwanId }
      deviceProperties = @{
        deviceVendor = "Azure-Lab"
        deviceModel = "Simulated"
      }
      vpnSiteLinks = $siteLinks
    }
  } | ConvertTo-Json -Depth 10

  $siteUri = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/vpnSites/$siteName`?api-version=2023-09-01"
  $tempFile = Join-Path $tempDir "$siteName-body.json"
  $siteBody | Out-File -FilePath $tempFile -Encoding utf8

  az rest --method PUT --uri $siteUri --body "@$tempFile" --output none 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Log "Failed to create VPN Site: $siteName" "ERROR"
    throw "Failed to create VPN Site: $siteName"
  }

  Write-Log "VPN Site created: $siteName with $($siteLinks.Count) links"
}

# Save PSKs
$psks | ConvertTo-Json | Set-Content -Path $pskPath -Encoding UTF8

# Validate sites
Write-Host ""
Write-Host "Phase 3 Validation:" -ForegroundColor Yellow
$allSitesValid = $true
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
foreach ($site in $VpnSites) {
  $siteObj = az network vpn-site show -g $ResourceGroup -n $site.Name -o json 2>$null | ConvertFrom-Json
  $linksOk = ($siteObj -and $siteObj.vpnSiteLinks.Count -eq 2)
  Write-Validation -Check "Site $($site.Name) has 2 links" -Passed $linksOk
  if (-not $linksOk) { $allSitesValid = $false }
}
$ErrorActionPreference = $oldErrPref

$phase3Elapsed = Get-ElapsedTime -StartTime $phase3Start
Write-Log "Phase 3 completed in $phase3Elapsed" "SUCCESS"

# ============================================
# PHASE 4: VPN Connections (Instance Split)
# ============================================
Write-Phase -Number 4 -Title "VPN Connections (Instance 0/1 Split)"

$phase4Start = Get-Date

# Load PSKs (convert to hashtable for easier access with hyphenated keys)
$psksJson = Get-Content $pskPath -Raw | ConvertFrom-Json
$psks = @{}
$psksJson.PSObject.Properties | ForEach-Object { $psks[$_.Name] = $_.Value }

foreach ($site in $VpnSites) {
  $siteName = $site.Name
  $connName = "conn-$siteName"

  Write-Host "Creating connection: $connName" -ForegroundColor Gray

  # Check if connection exists
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $existingConn = az network vpn-gateway connection show -g $ResourceGroup --gateway-name $VpnGwName -n $connName -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldErrPref
  if ($existingConn -and $existingConn.provisioningState -eq "Succeeded") {
    Write-Host "  Connection already exists, skipping..." -ForegroundColor DarkGray
    continue
  }

  # Get site details
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $siteObj = az network vpn-site show -g $ResourceGroup -n $siteName -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldErrPref
  $siteId = $siteObj.id

  # Build link connections with APIPA custom BGP addresses
  $linkConnections = @()
  $linkIndex = 0
  foreach ($link in $site.Links) {
    $apipa = Get-ApipaAddress -Cidr $link.Apipa
    $pskKey = "$siteName-$($link.Name)"
    $psk = $psks[$pskKey]

    $linkConnections += @{
      name = "$connName-$($link.Name)"
      properties = @{
        vpnSiteLink = @{ id = "$siteId/vpnSiteLinks/$($link.Name)" }
        sharedKey = $psk
        enableBgp = $true
        vpnConnectionProtocolType = "IKEv2"
        connectionBandwidth = 100
        vpnGatewayCustomBgpAddresses = @(
          @{
            ipConfigurationId = $gw.bgpSettings.bgpPeeringAddresses[$link.Instance].ipconfigurationId
            customBgpIpAddress = $apipa.Azure
          }
        )
      }
    }
    $linkIndex++
  }

  # Create connection via ARM REST API (enableBgp only at link level, not connection level)
  $connBody = @{
    properties = @{
      remoteVpnSite = @{ id = $siteId }
      vpnLinkConnections = $linkConnections
    }
  } | ConvertTo-Json -Depth 15

  $connUri = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/vpnGateways/$VpnGwName/vpnConnections/$connName`?api-version=2023-09-01"
  $tempFile = Join-Path $tempDir "$connName-body.json"
  $connBody | Out-File -FilePath $tempFile -Encoding utf8

  az rest --method PUT --uri $connUri --body "@$tempFile" --output none 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Log "Failed to create connection: $connName" "WARN"
    Write-Host "  WARNING: Connection may have failed, will retry..." -ForegroundColor Yellow
  }

  Write-Host "  Created with APIPA assignments:" -ForegroundColor DarkGray
  foreach ($link in $site.Links) {
    $apipa = Get-ApipaAddress -Cidr $link.Apipa
    Write-Host "    $($link.Name) -> Instance $($link.Instance): Azure BGP = $($apipa.Azure)" -ForegroundColor DarkGray
  }

  Write-Log "Connection created: $connName"
}

# Wait for connections to provision
Write-Host ""
Write-Host "Waiting for connections to provision (60s)..." -ForegroundColor Gray
Start-Sleep -Seconds 60

# Validate connections and instance bindings
Write-Host ""
Write-Host "Phase 4 Validation:" -ForegroundColor Yellow
$allConnectionsValid = $true
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"

foreach ($site in $VpnSites) {
  $connName = "conn-$($site.Name)"
  $conn = az network vpn-gateway connection show -g $ResourceGroup --gateway-name $VpnGwName -n $connName -o json 2>$null | ConvertFrom-Json

  $connOk = ($conn -and $conn.provisioningState -eq "Succeeded")
  Write-Validation -Check "Connection $connName provisioned" -Passed $connOk -Details "State: $($conn.provisioningState)"

  if (-not $connOk) { $allConnectionsValid = $false }

  # Check link connections and instance binding
  if ($conn.vpnLinkConnections) {
    foreach ($linkConn in $conn.vpnLinkConnections) {
      $linkName = $linkConn.name -replace "^$connName-", ""
      $linkConfig = $site.Links | Where-Object { $_.Name -eq $linkName }
      $expectedInstance = $linkConfig.Instance

      # Check if custom BGP address was applied
      if ($linkConn.vpnGatewayCustomBgpAddresses) {
        $actualIpConfig = $linkConn.vpnGatewayCustomBgpAddresses[0].ipConfigurationId
        $actualInstance = if ($actualIpConfig -match "Instance0") { 0 } else { 1 }
        $instanceMatch = ($actualInstance -eq $expectedInstance)
        Write-Validation -Check "  $linkName -> Instance $expectedInstance" -Passed $instanceMatch -Details "Actual: Instance $actualInstance"
        if (-not $instanceMatch) { $allConnectionsValid = $false }
      }
    }
  }
}
$ErrorActionPreference = $oldErrPref

$phase4Elapsed = Get-ElapsedTime -StartTime $phase4Start
Write-Log "Phase 4 completed in $phase4Elapsed" "SUCCESS"

# ============================================
# PHASE 5: Validation Output
# ============================================
Write-Phase -Number 5 -Title "Final Validation"

$phase5Start = Get-Date

# Get final gateway state with all connections
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$gw = az network vpn-gateway show -g $ResourceGroup -n $VpnGwName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

Write-Host "Instance 0 BGP Peers:" -ForegroundColor Yellow
$instance0Peers = @()
foreach ($site in $VpnSites) {
  foreach ($link in $site.Links | Where-Object { $_.Instance -eq 0 }) {
    $apipa = Get-ApipaAddress -Cidr $link.Apipa
    $instance0Peers += "$($site.Name)/$($link.Name): $($apipa.Azure)"
    Write-Host "  $($site.Name)/$($link.Name): Azure=$($apipa.Azure), Remote=$($apipa.Remote)" -ForegroundColor Gray
  }
}

Write-Host ""
Write-Host "Instance 1 BGP Peers:" -ForegroundColor Yellow
$instance1Peers = @()
foreach ($site in $VpnSites) {
  foreach ($link in $site.Links | Where-Object { $_.Instance -eq 1 }) {
    $apipa = Get-ApipaAddress -Cidr $link.Apipa
    $instance1Peers += "$($site.Name)/$($link.Name): $($apipa.Azure)"
    Write-Host "  $($site.Name)/$($link.Name): Azure=$($apipa.Azure), Remote=$($apipa.Remote)" -ForegroundColor Gray
  }
}

# Summary
Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "DEPLOYMENT SUMMARY" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green

$totalElapsed = Get-ElapsedTime -StartTime $deploymentStartTime

Write-Host ""
Write-Host "Results:" -ForegroundColor Yellow
Write-Host "  Total deployment time: $totalElapsed" -ForegroundColor White
Write-Host "  Resource Group: $ResourceGroup" -ForegroundColor Gray
Write-Host "  Location: $Location" -ForegroundColor Gray
Write-Host "  VPN Sites: 4" -ForegroundColor Gray
Write-Host "  VPN Links: 8" -ForegroundColor Gray
Write-Host "  Instance 0 links: 4" -ForegroundColor Gray
Write-Host "  Instance 1 links: 4" -ForegroundColor Gray

# Determine overall status
$overallPass = $allSitesValid -and $allConnectionsValid

Write-Host ""
if ($overallPass) {
  Write-Host "STATUS: PASS" -ForegroundColor Green
  Write-Host "  All sites created with correct instance bindings." -ForegroundColor Green
} else {
  Write-Host "STATUS: PARTIAL" -ForegroundColor Yellow
  Write-Host "  Some validations failed. Check above for details." -ForegroundColor Yellow
}

# Save outputs
Ensure-Directory (Split-Path -Parent $OutputsPath)

$outputs = [pscustomobject]@{
  metadata = [pscustomobject]@{
    lab = "lab-005"
    deployedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    deploymentTime = $totalElapsed
    status = if ($overallPass) { "PASS" } else { "PARTIAL" }
    tags = @{
      project = "azure-labs"
      lab = "lab-005"
      env = "lab"
      owner = $Owner
    }
  }
  azure = [pscustomobject]@{
    location = $Location
    resourceGroup = $ResourceGroup
    subscriptionId = $SubscriptionId
    vwan = $VwanName
    vhub = $VhubName
    vhubPrefix = $VhubPrefix
    vpnGateway = $VpnGwName
    bgpAsn = $AzureBgpAsn
    sites = $VpnSites
    instance0Peers = $instance0Peers
    instance1Peers = $instance1Peers
  }
}

$outputs | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputsPath -Encoding UTF8

Write-Host ""
Write-Host "Outputs saved to: $OutputsPath" -ForegroundColor Gray
Write-Host "Log saved to: $script:LogFile" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  - Review APIPA mappings: docs/apipa-mapping.md" -ForegroundColor Gray
Write-Host "  - Validation commands: docs/validation.md" -ForegroundColor Gray
Write-Host "  - Cleanup: ./destroy.ps1" -ForegroundColor Gray
Write-Host ""

Write-Log "Deployment completed with status: $(if ($overallPass) { 'PASS' } else { 'PARTIAL' })" "SUCCESS"
