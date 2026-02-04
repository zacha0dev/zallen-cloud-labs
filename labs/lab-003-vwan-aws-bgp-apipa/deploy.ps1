# labs/lab-003-vwan-aws-bgp-apipa/deploy.ps1
# Deploys Azure vWAN S2S VPN Gateway with BGP over APIPA to AWS VGW
#
# This lab proves:
# - vWAN S2S Gateway dual-instance behavior (Instance 0 vs Instance 1)
# - Deterministic APIPA /30 mapping per VPN site link
# - Fail-forward phased deployment with validation between steps
# - Cross-cloud BGP peering between Azure and AWS

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [string]$AwsProfile = "aws-labs",
  [string]$AwsRegion = "us-east-2",
  [string]$Location = "centralus",
  [string]$Owner = "",
  [int]$AwsBgpAsn = 65001,
  [switch]$Force
)

# ============================================
# GUARDRAILS
# ============================================
$AllowedAzureLocations = @("centralus", "eastus", "eastus2", "westus2")
$AllowedAwsRegions = @("us-east-1", "us-east-2", "us-west-2", "eu-west-1")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path
$LogsDir = Join-Path $LabRoot "logs"
$OutputsPath = Join-Path $RepoRoot ".data\lab-003\outputs.json"

# Load shared helpers
. (Join-Path $RepoRoot "scripts\labs-common.ps1")
. (Join-Path $RepoRoot "scripts\aws\aws-common.ps1")

# Lab configuration
$ResourceGroup = "rg-lab-003-vwan-aws"
$VwanName = "vwan-lab-003"
$VhubName = "vhub-lab-003"
$VhubPrefix = "10.0.0.0/24"
$VpnGwName = "vpngw-lab-003"
$AzureBgpAsn = 65515

# AWS VPC configuration
$AwsVpcCidr = "10.20.0.0/16"
$AwsSubnetCidr = "10.20.1.0/24"

# VPN Sites configuration - 2 sites, 2 links each (4 tunnels total)
# Site 1 -> Azure Instance 0, Site 2 -> Azure Instance 1
# APIPA Layout:
#   Instance 0: 169.254.21.0/30, 169.254.21.4/30
#   Instance 1: 169.254.22.0/30, 169.254.22.4/30
$VpnSites = @(
  @{
    Name = "aws-site-1"
    Instance = 0
    Links = @(
      @{ Name = "link-1"; Apipa = "169.254.21.0/30"; TunnelIndex = 1 }
      @{ Name = "link-2"; Apipa = "169.254.21.4/30"; TunnelIndex = 2 }
    )
  },
  @{
    Name = "aws-site-2"
    Instance = 1
    Links = @(
      @{ Name = "link-3"; Apipa = "169.254.22.0/30"; TunnelIndex = 3 }
      @{ Name = "link-4"; Apipa = "169.254.22.4/30"; TunnelIndex = 4 }
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

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function New-RandomPsk {
  # AWS VPN PSK requirements: 8-64 chars, alphanumeric only, cannot start with zero
  # First char must be a letter to avoid starting with zero
  $firstChar = (65..90) + (97..122) | Get-Random | ForEach-Object { [char]$_ }
  $restChars = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 31 | ForEach-Object { [char]$_ })
  return "$firstChar$restChars"
}

function Get-ApipaAddress {
  # Given a /30 CIDR, return the two usable addresses
  # e.g., 169.254.21.0/30 -> .1 (AWS/remote), .2 (Azure)
  param([string]$Cidr)
  $parts = $Cidr -split "/"
  $ip = $parts[0]
  $octets = $ip -split "\."
  $lastOctet = [int]$octets[3]
  $remote = "$($octets[0]).$($octets[1]).$($octets[2]).$($lastOctet + 1)"
  $azure = "$($octets[0]).$($octets[1]).$($octets[2]).$($lastOctet + 2)"
  return @{ Remote = $remote; Azure = $azure; Cidr = $Cidr }
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
  param([string]$Location, [string[]]$AllowedLocations, [string]$Cloud = "Azure")
  if ($AllowedLocations -notcontains $Location) {
    Write-Host ""
    Write-Host "HARD STOP: $Cloud location '$Location' is not in the allowlist." -ForegroundColor Red
    Write-Host "Allowed locations: $($AllowedLocations -join ', ')" -ForegroundColor Yellow
    throw "$Cloud location '$Location' not allowed."
  }
}

function Get-ElapsedTime {
  param([datetime]$StartTime)
  $elapsed = (Get-Date) - $StartTime
  return "$([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
}

# ============================================
# AWS HELPER FUNCTIONS (Windows-safe)
# ============================================

<#
.SYNOPSIS
  Invokes AWS CLI and throws on error with detailed output.
.DESCRIPTION
  Captures both stdout and stderr, checks exit code, and throws
  with full error details if the command fails.
#>
function Invoke-AwsCli {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,
    [string]$ErrorMessage = "AWS CLI command failed"
  )

  $pinfo = New-Object System.Diagnostics.ProcessStartInfo
  $pinfo.FileName = "aws"
  $pinfo.RedirectStandardOutput = $true
  $pinfo.RedirectStandardError = $true
  $pinfo.UseShellExecute = $false
  $pinfo.CreateNoWindow = $true
  $pinfo.Arguments = $Arguments -join " "

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $pinfo
  $process.Start() | Out-Null

  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  $process.WaitForExit()

  if ($process.ExitCode -ne 0) {
    $fullError = "$ErrorMessage`nCommand: aws $($Arguments -join ' ')`nStderr: $stderr`nStdout: $stdout"
    Write-Log $fullError "ERROR"
    throw $fullError
  }

  return $stdout.Trim()
}

<#
.SYNOPSIS
  Returns AWS EC2 TagSpecifications argument for create-* commands.
.DESCRIPTION
  Builds the --tag-specifications argument string for EC2 create commands.
  Format: ResourceType=xxx,Tags=[{Key=k1,Value=v1},{Key=k2,Value=v2}]
#>
function Get-AwsTagSpecification {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceType,
    [string]$Name = "",
    [string]$OwnerTag = ""
  )

  $tags = @(
    "{Key=project,Value=azure-labs}"
    "{Key=lab,Value=lab-003}"
    "{Key=env,Value=lab}"
  )

  if ($Name) {
    $tags += "{Key=Name,Value=$Name}"
  }

  if ($OwnerTag) {
    $tags += "{Key=owner,Value=$OwnerTag}"
  }

  $tagsStr = $tags -join ","
  return "ResourceType=$ResourceType,Tags=[$tagsStr]"
}

<#
.SYNOPSIS
  Returns AWS tags array for create-tags command.
.DESCRIPTION
  Returns an array of tag arguments for use with aws ec2 create-tags.
#>
function Get-AwsTagsArray {
  param(
    [string]$Name = "",
    [string]$OwnerTag = ""
  )

  $tags = @(
    "Key=project,Value=azure-labs"
    "Key=lab,Value=lab-003"
    "Key=env,Value=lab"
  )

  if ($Name) {
    $tags += "Key=Name,Value=$Name"
  }

  if ($OwnerTag) {
    $tags += "Key=owner,Value=$OwnerTag"
  }

  return $tags
}

<#
.SYNOPSIS
  Writes JSON to file without BOM (Windows-safe).
.DESCRIPTION
  Uses .NET methods to write JSON without Byte Order Mark,
  which causes AWS CLI parsing errors on Windows.
#>
function Write-JsonWithoutBom {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Content
  )

  # Use UTF8 encoding without BOM
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

<#
.SYNOPSIS
  Validates that a resource ID is not null or empty.
#>
function Assert-AwsResourceId {
  param(
    [string]$ResourceId,
    [string]$ResourceType,
    [string]$Context = ""
  )

  if ([string]::IsNullOrWhiteSpace($ResourceId) -or $ResourceId -eq "None") {
    $msg = "Failed to create or retrieve $ResourceType"
    if ($Context) { $msg += ": $Context" }
    Write-Log $msg "ERROR"
    throw $msg
  }
}

# ============================================
# MAIN DEPLOYMENT
# ============================================

Write-Host ""
Write-Host "Lab 003: Azure vWAN <-> AWS VPN with BGP over APIPA" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Purpose: Prove Azure vWAN S2S VPN Gateway dual-instance behavior" -ForegroundColor White
Write-Host "         with deterministic APIPA /30 allocations to AWS VGW." -ForegroundColor White
Write-Host ""

$deploymentStartTime = Get-Date

# ============================================
# PHASE 0: Preflight
# ============================================
Write-Phase -Number 0 -Title "Preflight Checks"

$phase0Start = Get-Date

# Initialize log directory and file
Ensure-Directory $LogsDir
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$script:LogFile = Join-Path $LogsDir "lab-003-$timestamp.log"
Write-Log "Deployment started"
Write-Log "Azure Location: $Location"
Write-Log "AWS Region: $AwsRegion"

# Check Azure CLI
Require-Command az "Install Azure CLI: https://aka.ms/installazurecli"
Write-Validation -Check "Azure CLI installed" -Passed $true

# Check AWS CLI
Ensure-AwsCli
Write-Validation -Check "AWS CLI installed" -Passed $true

# Check Azure location
Assert-LocationAllowed -Location $Location -AllowedLocations $AllowedAzureLocations -Cloud "Azure"
Write-Validation -Check "Azure location '$Location' allowed" -Passed $true

# Check AWS region
Assert-LocationAllowed -Location $AwsRegion -AllowedLocations $AllowedAwsRegions -Cloud "AWS"
Write-Validation -Check "AWS region '$AwsRegion' allowed" -Passed $true

# Load config
Show-ConfigPreflight -RepoRoot $RepoRoot
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Write-Validation -Check "Azure subscription resolved" -Passed $true -Details $SubscriptionId

# Azure auth
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null
Write-Validation -Check "Azure authenticated" -Passed $true

# AWS auth
Require-AwsProfile -Profile $AwsProfile
Ensure-AwsAuth -Profile $AwsProfile -DoLogin
$awsIdentity = Get-AwsIdentity -Profile $AwsProfile
Write-Validation -Check "AWS authenticated" -Passed $true -Details "Account: $($awsIdentity.Account)"

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
  Write-Host "  Azure:" -ForegroundColor White
  Write-Host "    - vWAN Hub: ~`$0.25/hr" -ForegroundColor Gray
  Write-Host "    - S2S VPN Gateway (2 scale units): ~`$0.36/hr" -ForegroundColor Gray
  Write-Host "  AWS:" -ForegroundColor White
  Write-Host "    - VPN Connection (2x): ~`$0.10/hr" -ForegroundColor Gray
  Write-Host "    - VGW: included with VPN" -ForegroundColor Gray
  Write-Host ""
  Write-Host "  Estimated total: ~`$0.71/hr" -ForegroundColor Yellow
  Write-Host ""
  $confirm = Read-Host "Type DEPLOY to proceed"
  if ($confirm -ne "DEPLOY") { throw "Cancelled." }
}

# Portal links
$portalUrl = "https://portal.azure.com/#@/resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/deployments"
$awsConsoleUrl = "https://$AwsRegion.console.aws.amazon.com/vpc/home?region=$AwsRegion#VpnConnections:"
Write-Host ""
Write-Host "Monitor in Azure Portal:" -ForegroundColor Yellow
Write-Host "  $portalUrl" -ForegroundColor Cyan
Write-Host ""
Write-Host "Monitor in AWS Console:" -ForegroundColor Yellow
Write-Host "  $awsConsoleUrl" -ForegroundColor Cyan
Write-Host ""
Write-Host "Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host ""

$phase0Elapsed = Get-ElapsedTime -StartTime $phase0Start
Write-Log "Phase 0 completed in $phase0Elapsed" "SUCCESS"

# ============================================
# PHASE 1: Core Fabric (vWAN + vHub)
# ============================================
Write-Phase -Number 1 -Title "Core Fabric (vWAN + vHub)"

$phase1Start = Get-Date

# Build tags string (handle empty Owner)
$baseTags = "project=azure-labs lab=lab-003 env=lab"
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

# Extract public IPs and BGP settings
$azureVpnIps = @()
$instance0BgpIps = @()
$instance1BgpIps = @()

if ($gw.bgpSettings -and $gw.bgpSettings.bgpPeeringAddresses) {
  foreach ($peerAddr in $gw.bgpSettings.bgpPeeringAddresses) {
    $instanceId = if ($peerAddr.ipconfigurationId -match "Instance0") { "0" } else { "1" }
    $defaultAddrs = $peerAddr.defaultBgpIpAddresses
    $customAddrs = $peerAddr.customBgpIpAddresses
    $tunnelIps = $peerAddr.tunnelIpAddresses

    Write-Host "  Instance $instanceId BGP:" -ForegroundColor DarkGray
    Write-Host "    Default: $($defaultAddrs -join ', ')" -ForegroundColor DarkGray
    Write-Host "    Custom:  $($customAddrs -join ', ')" -ForegroundColor DarkGray
    Write-Host "    Tunnel:  $($tunnelIps -join ', ')" -ForegroundColor DarkGray

    # Collect public IPs
    foreach ($ip in $tunnelIps) {
      $isPrivate = $ip -match "^10\." -or $ip -match "^172\.(1[6-9]|2[0-9]|3[01])\." -or $ip -match "^192\.168\."
      if ($ip -and $ip -ne "None" -and -not $isPrivate -and $azureVpnIps -notcontains $ip) {
        $azureVpnIps += $ip
      }
    }

    if ($instanceId -eq "0") {
      $instance0BgpIps = $defaultAddrs
    } else {
      $instance1BgpIps = $defaultAddrs
    }
  }
}

if ($azureVpnIps.Count -lt 2) {
  throw "Expected 2 VPN Gateway public IPs, got $($azureVpnIps.Count). Gateway may not be fully provisioned."
}

Write-Host ""
Write-Host "VPN Gateway Public IPs:" -ForegroundColor Yellow
Write-Host "  Instance 0: $($azureVpnIps[0])" -ForegroundColor Green
Write-Host "  Instance 1: $($azureVpnIps[1])" -ForegroundColor Green

# Configure custom APIPA addresses on the gateway
Write-Host ""
Write-Host "Configuring custom APIPA addresses on gateway..." -ForegroundColor Gray

# Collect all APIPA addresses for each instance from our VPN Sites config
$instance0Apipas = @()
$instance1Apipas = @()
foreach ($site in $VpnSites) {
  foreach ($link in $site.Links) {
    $apipa = Get-ApipaAddress -Cidr $link.Apipa
    if ($site.Instance -eq 0) {
      $instance0Apipas += $apipa.Azure
    } else {
      $instance1Apipas += $apipa.Azure
    }
  }
}

# Check if custom addresses are already configured
$existingCustom0 = @($gw.bgpSettings.bgpPeeringAddresses | Where-Object { $_.ipconfigurationId -match "Instance0" } | ForEach-Object { $_.customBgpIpAddresses } | Where-Object { $_ })
$existingCustom1 = @($gw.bgpSettings.bgpPeeringAddresses | Where-Object { $_.ipconfigurationId -match "Instance1" } | ForEach-Object { $_.customBgpIpAddresses } | Where-Object { $_ })

$needsUpdate = ($existingCustom0.Count -lt $instance0Apipas.Count) -or ($existingCustom1.Count -lt $instance1Apipas.Count)

if ($needsUpdate) {
  Write-Host "  Updating gateway BGP settings with custom APIPA addresses..." -ForegroundColor Gray
  Write-Host "    Instance 0: $($instance0Apipas -join ', ')" -ForegroundColor DarkGray
  Write-Host "    Instance 1: $($instance1Apipas -join ', ')" -ForegroundColor DarkGray

  # Build updated BGP peering addresses
  $updatedBgpPeeringAddresses = @()
  foreach ($peerAddr in $gw.bgpSettings.bgpPeeringAddresses) {
    $newPeerAddr = @{
      ipconfigurationId = $peerAddr.ipconfigurationId
      customBgpIpAddresses = if ($peerAddr.ipconfigurationId -match "Instance0") { $instance0Apipas } else { $instance1Apipas }
    }
    $updatedBgpPeeringAddresses += $newPeerAddr
  }

  # Update gateway via ARM REST API
  $gwUpdateBody = @{
    location = $Location
    properties = @{
      virtualHub = @{ id = $gw.virtualHub.id }
      bgpSettings = @{
        asn = $AzureBgpAsn
        bgpPeeringAddresses = $updatedBgpPeeringAddresses
      }
    }
  } | ConvertTo-Json -Depth 10

  $gwUri = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/vpnGateways/$VpnGwName`?api-version=2023-09-01"
  $tempDir = Join-Path $RepoRoot ".data\lab-003"
  Ensure-Directory $tempDir
  $tempGwFile = Join-Path $tempDir "gw-update-body.json"
  Write-JsonWithoutBom -Path $tempGwFile -Content $gwUpdateBody

  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  az rest --method PUT --uri $gwUri --body "@$tempGwFile" --output none 2>&1 | Out-Null
  $ErrorActionPreference = $oldErrPref

  # Wait for gateway update to complete
  Write-Host "  Waiting for gateway update to complete..." -ForegroundColor Gray
  $maxAttempts = 60
  $attempt = 0
  while ($attempt -lt $maxAttempts) {
    $attempt++
    Start-Sleep -Seconds 10
    $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $gw = az network vpn-gateway show -g $ResourceGroup -n $VpnGwName -o json 2>$null | ConvertFrom-Json
    $ErrorActionPreference = $oldErrPref

    if ($gw.provisioningState -eq "Succeeded") {
      Write-Host "  Gateway BGP settings updated successfully" -ForegroundColor Green
      break
    } elseif ($gw.provisioningState -eq "Failed") {
      Write-Host "  WARNING: Gateway update may have failed, continuing..." -ForegroundColor Yellow
      break
    }
    Write-Host "    Gateway state: $($gw.provisioningState) (attempt $attempt/$maxAttempts)" -ForegroundColor DarkGray
  }
} else {
  Write-Host "  Custom APIPA addresses already configured on gateway" -ForegroundColor Green
}

$phase2Elapsed = Get-ElapsedTime -StartTime $phase2Start
Write-Host ""
Write-Host "Phase 2 Validation:" -ForegroundColor Yellow
Write-Validation -Check "VPN Gateway provisioningState = Succeeded" -Passed ($gw.provisioningState -eq "Succeeded")
Write-Validation -Check "2 gateway instances present" -Passed ($gw.bgpSettings.bgpPeeringAddresses.Count -ge 2) -Details "Found $($gw.bgpSettings.bgpPeeringAddresses.Count) instances"
Write-Validation -Check "2 public IPs available" -Passed ($azureVpnIps.Count -ge 2) -Details "$($azureVpnIps[0]), $($azureVpnIps[1])"
Write-Log "Phase 2 completed in $phase2Elapsed" "SUCCESS"

# ============================================
# PHASE 3: Azure VPN Sites + Links
# ============================================
Write-Phase -Number 3 -Title "VPN Sites + Links (2 sites, 4 links)"

$phase3Start = Get-Date

# Get vWAN ID
$vwanId = az network vwan show -g $ResourceGroup -n $VwanName --query id -o tsv

# Temp directory for ARM REST API body files
$tempDir = Join-Path $RepoRoot ".data\lab-003"
Ensure-Directory $tempDir

# PSK storage (generate now, will use after AWS deployment)
$pskPath = Join-Path $tempDir "psk-secrets.json"
$psks = @{}

# Check if PSKs already exist (resume scenario)
if (Test-Path $pskPath) {
  try {
    $existingPsks = Get-Content $pskPath -Raw | ConvertFrom-Json
    $existingPsks.PSObject.Properties | ForEach-Object { $psks[$_.Name] = $_.Value }
    Write-Host "Reusing existing pre-shared keys (resume scenario)" -ForegroundColor Gray
  } catch {
    $psks = @{}
  }
}

# Sites will be created as placeholders first (IPs will be updated after AWS deployment)
# This is a placeholder phase - actual site creation with real IPs happens after Phase 5
Write-Host "VPN Sites will be created after AWS deployment provides tunnel IPs" -ForegroundColor Gray
Write-Host "  Site 1: aws-site-1 (2 links -> Instance 0)" -ForegroundColor DarkGray
Write-Host "  Site 2: aws-site-2 (2 links -> Instance 1)" -ForegroundColor DarkGray

# Generate PSKs if not already existing, or regenerate invalid ones (starting with 0)
foreach ($site in $VpnSites) {
  foreach ($link in $site.Links) {
    $pskKey = "$($site.Name)-$($link.Name)"
    $existingPsk = $psks[$pskKey]
    if (-not $existingPsk -or $existingPsk.StartsWith("0")) {
      if ($existingPsk -and $existingPsk.StartsWith("0")) {
        Write-Host "  Regenerating invalid PSK for $pskKey (cannot start with 0)" -ForegroundColor Yellow
      }
      $psks[$pskKey] = New-RandomPsk
    }
  }
}

# Save PSKs (without BOM)
$pskJson = $psks | ConvertTo-Json
Write-JsonWithoutBom -Path $pskPath -Content $pskJson
Write-Host "Pre-shared keys generated and saved" -ForegroundColor Gray

$phase3Elapsed = Get-ElapsedTime -StartTime $phase3Start
Write-Host ""
Write-Host "Phase 3 Validation:" -ForegroundColor Yellow
Write-Validation -Check "PSKs generated for 4 tunnels" -Passed ($psks.Count -ge 4) -Details "$($psks.Count) PSKs stored"
Write-Log "Phase 3 completed in $phase3Elapsed" "SUCCESS"

# ============================================
# PHASE 4: Azure VPN Connections
# ============================================
Write-Phase -Number 4 -Title "VPN Connections (deferred until Phase 5)"

$phase4Start = Get-Date

Write-Host "VPN connections require AWS tunnel IPs, deferring to after Phase 5..." -ForegroundColor Gray

$phase4Elapsed = Get-ElapsedTime -StartTime $phase4Start
Write-Log "Phase 4 (placeholder) completed in $phase4Elapsed" "SUCCESS"

# ============================================
# PHASE 5: AWS Deployment
# ============================================
Write-Phase -Number 5 -Title "AWS Deployment (VPC, VGW, CGW, VPN)"

$phase5Start = Get-Date

# Set AWS profile
$env:AWS_PROFILE = $AwsProfile
$env:AWS_DEFAULT_REGION = $AwsRegion

# Check for existing VPC
Write-Host "Checking for existing AWS resources..." -ForegroundColor Gray
$existingVpc = $null
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vpcJson = aws ec2 describe-vpcs --filters "Name=tag:lab,Values=lab-003" --query "Vpcs[0]" --output json 2>$null
$ErrorActionPreference = $oldErrPref
if ($vpcJson -and $vpcJson -ne "null") {
  $existingVpc = $vpcJson | ConvertFrom-Json
  if ($existingVpc -and $existingVpc.VpcId) {
    Write-Host "  Found existing VPC: $($existingVpc.VpcId)" -ForegroundColor Yellow
  }
}

# Create or reuse VPC
if (-not $existingVpc -or -not $existingVpc.VpcId) {
  Write-Host "Creating AWS VPC: $AwsVpcCidr" -ForegroundColor Gray

  # Build tag specification for VPC
  $vpcTagSpec = Get-AwsTagSpecification -ResourceType "vpc" -Name "lab-003-vpc" -OwnerTag $Owner

  $vpcResult = Invoke-AwsCli -Arguments @(
    "ec2", "create-vpc",
    "--cidr-block", $AwsVpcCidr,
    "--tag-specifications", $vpcTagSpec,
    "--query", "Vpc.VpcId",
    "--output", "text"
  ) -ErrorMessage "Failed to create VPC"

  $vpcId = $vpcResult.Trim()
  Assert-AwsResourceId -ResourceId $vpcId -ResourceType "VPC"

  # Enable DNS support (use single quotes for JSON to avoid PowerShell escaping issues)
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  aws ec2 modify-vpc-attribute --vpc-id $vpcId --enable-dns-support
  aws ec2 modify-vpc-attribute --vpc-id $vpcId --enable-dns-hostnames
  $ErrorActionPreference = $oldErrPref

  Write-Log "AWS VPC created: $vpcId"
} else {
  $vpcId = $existingVpc.VpcId
  Write-Host "  Using existing VPC: $vpcId" -ForegroundColor DarkGray
}

# Create or reuse Subnet
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingSubnet = (aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpcId" "Name=tag:lab,Values=lab-003" --query "Subnets[0].SubnetId" --output text 2>$null)
$ErrorActionPreference = $oldErrPref

if (-not $existingSubnet -or $existingSubnet -eq "None" -or [string]::IsNullOrWhiteSpace($existingSubnet)) {
  Write-Host "Creating subnet: $AwsSubnetCidr" -ForegroundColor Gray

  $subnetTagSpec = Get-AwsTagSpecification -ResourceType "subnet" -Name "lab-003-subnet" -OwnerTag $Owner

  $subnetResult = Invoke-AwsCli -Arguments @(
    "ec2", "create-subnet",
    "--vpc-id", $vpcId,
    "--cidr-block", $AwsSubnetCidr,
    "--availability-zone", "${AwsRegion}a",
    "--tag-specifications", $subnetTagSpec,
    "--query", "Subnet.SubnetId",
    "--output", "text"
  ) -ErrorMessage "Failed to create subnet"

  $subnetId = $subnetResult.Trim()
  Assert-AwsResourceId -ResourceId $subnetId -ResourceType "Subnet"
} else {
  $subnetId = $existingSubnet.Trim()
  Write-Host "  Using existing subnet: $subnetId" -ForegroundColor DarkGray
}

# Create or reuse Internet Gateway
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingIgw = (aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpcId" --query "InternetGateways[0].InternetGatewayId" --output text 2>$null)
$ErrorActionPreference = $oldErrPref

if (-not $existingIgw -or $existingIgw -eq "None" -or [string]::IsNullOrWhiteSpace($existingIgw)) {
  Write-Host "Creating Internet Gateway..." -ForegroundColor Gray

  $igwTagSpec = Get-AwsTagSpecification -ResourceType "internet-gateway" -Name "lab-003-igw" -OwnerTag $Owner

  $igwResult = Invoke-AwsCli -Arguments @(
    "ec2", "create-internet-gateway",
    "--tag-specifications", $igwTagSpec,
    "--query", "InternetGateway.InternetGatewayId",
    "--output", "text"
  ) -ErrorMessage "Failed to create Internet Gateway"

  $igwId = $igwResult.Trim()
  Assert-AwsResourceId -ResourceId $igwId -ResourceType "Internet Gateway"

  # Attach to VPC
  aws ec2 attach-internet-gateway --vpc-id $vpcId --internet-gateway-id $igwId 2>$null
} else {
  $igwId = $existingIgw.Trim()
  Write-Host "  Using existing IGW: $igwId" -ForegroundColor DarkGray
}

# Create or reuse Route Table
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRt = (aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpcId" "Name=tag:lab,Values=lab-003" --query "RouteTables[0].RouteTableId" --output text 2>$null)
$ErrorActionPreference = $oldErrPref

if (-not $existingRt -or $existingRt -eq "None" -or [string]::IsNullOrWhiteSpace($existingRt)) {
  Write-Host "Creating Route Table..." -ForegroundColor Gray

  $rtTagSpec = Get-AwsTagSpecification -ResourceType "route-table" -Name "lab-003-rt" -OwnerTag $Owner

  $rtResult = Invoke-AwsCli -Arguments @(
    "ec2", "create-route-table",
    "--vpc-id", $vpcId,
    "--tag-specifications", $rtTagSpec,
    "--query", "RouteTable.RouteTableId",
    "--output", "text"
  ) -ErrorMessage "Failed to create Route Table"

  $rtId = $rtResult.Trim()
  Assert-AwsResourceId -ResourceId $rtId -ResourceType "Route Table"

  # Add default route
  aws ec2 create-route --route-table-id $rtId --destination-cidr-block "0.0.0.0/0" --gateway-id $igwId 2>$null
  # Associate with subnet
  aws ec2 associate-route-table --route-table-id $rtId --subnet-id $subnetId 2>$null
} else {
  $rtId = $existingRt.Trim()
  Write-Host "  Using existing Route Table: $rtId" -ForegroundColor DarkGray
}

# Create or reuse Virtual Private Gateway
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingVgw = (aws ec2 describe-vpn-gateways --filters "Name=tag:lab,Values=lab-003" "Name=state,Values=available" --query "VpnGateways[0].VpnGatewayId" --output text 2>$null)
$ErrorActionPreference = $oldErrPref

if (-not $existingVgw -or $existingVgw -eq "None" -or [string]::IsNullOrWhiteSpace($existingVgw)) {
  Write-Host "Creating Virtual Private Gateway (ASN: $AwsBgpAsn)..." -ForegroundColor Gray

  # VGW doesn't support tag-specifications, use create-tags after
  $vgwResult = Invoke-AwsCli -Arguments @(
    "ec2", "create-vpn-gateway",
    "--type", "ipsec.1",
    "--amazon-side-asn", $AwsBgpAsn.ToString(),
    "--query", "VpnGateway.VpnGatewayId",
    "--output", "text"
  ) -ErrorMessage "Failed to create VPN Gateway"

  $vgwId = $vgwResult.Trim()
  Assert-AwsResourceId -ResourceId $vgwId -ResourceType "VPN Gateway"

  # Tag the VGW
  $vgwTags = Get-AwsTagsArray -Name "lab-003-vgw" -OwnerTag $Owner
  aws ec2 create-tags --resources $vgwId --tags $vgwTags 2>$null

  # Attach to VPC
  aws ec2 attach-vpn-gateway --vpn-gateway-id $vgwId --vpc-id $vpcId 2>$null

  # Wait for VGW to be available
  Write-Host "  Waiting for VGW to attach..." -ForegroundColor DarkGray
  $maxAttempts = 30
  $attempt = 0
  while ($attempt -lt $maxAttempts) {
    $attempt++
    $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $vgwState = (aws ec2 describe-vpn-gateways --vpn-gateway-ids $vgwId --query "VpnGateways[0].VpcAttachments[0].State" --output text 2>$null)
    $ErrorActionPreference = $oldErrPref
    if ($vgwState -eq "attached") { break }
    Start-Sleep -Seconds 10
  }

  # Enable route propagation
  aws ec2 enable-vgw-route-propagation --gateway-id $vgwId --route-table-id $rtId 2>$null
} else {
  $vgwId = $existingVgw.Trim()
  Write-Host "  Using existing VGW: $vgwId" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Creating Customer Gateways for Azure VPN Gateway IPs..." -ForegroundColor Gray

# Customer Gateway 1 (for Azure Instance 0)
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingCgw1 = (aws ec2 describe-customer-gateways --filters "Name=ip-address,Values=$($azureVpnIps[0])" "Name=state,Values=available" --query "CustomerGateways[0].CustomerGatewayId" --output text 2>$null)
$ErrorActionPreference = $oldErrPref

if (-not $existingCgw1 -or $existingCgw1 -eq "None" -or [string]::IsNullOrWhiteSpace($existingCgw1)) {
  Write-Host "  Creating CGW 1 for Azure Instance 0: $($azureVpnIps[0])" -ForegroundColor Gray

  # CGW doesn't support tag-specifications in all regions, use create-tags after
  $cgw1Result = Invoke-AwsCli -Arguments @(
    "ec2", "create-customer-gateway",
    "--type", "ipsec.1",
    "--bgp-asn", $AzureBgpAsn.ToString(),
    "--ip-address", $azureVpnIps[0],
    "--query", "CustomerGateway.CustomerGatewayId",
    "--output", "text"
  ) -ErrorMessage "Failed to create Customer Gateway 1"

  $cgw1Id = $cgw1Result.Trim()
  Assert-AwsResourceId -ResourceId $cgw1Id -ResourceType "Customer Gateway 1"

  # Tag the CGW
  $cgw1Tags = Get-AwsTagsArray -Name "lab-003-cgw-azure-inst0" -OwnerTag $Owner
  aws ec2 create-tags --resources $cgw1Id --tags $cgw1Tags 2>$null
} else {
  $cgw1Id = $existingCgw1.Trim()
  Write-Host "  Using existing CGW 1: $cgw1Id" -ForegroundColor DarkGray
}

# Customer Gateway 2 (for Azure Instance 1)
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingCgw2 = (aws ec2 describe-customer-gateways --filters "Name=ip-address,Values=$($azureVpnIps[1])" "Name=state,Values=available" --query "CustomerGateways[0].CustomerGatewayId" --output text 2>$null)
$ErrorActionPreference = $oldErrPref

if (-not $existingCgw2 -or $existingCgw2 -eq "None" -or [string]::IsNullOrWhiteSpace($existingCgw2)) {
  Write-Host "  Creating CGW 2 for Azure Instance 1: $($azureVpnIps[1])" -ForegroundColor Gray

  $cgw2Result = Invoke-AwsCli -Arguments @(
    "ec2", "create-customer-gateway",
    "--type", "ipsec.1",
    "--bgp-asn", $AzureBgpAsn.ToString(),
    "--ip-address", $azureVpnIps[1],
    "--query", "CustomerGateway.CustomerGatewayId",
    "--output", "text"
  ) -ErrorMessage "Failed to create Customer Gateway 2"

  $cgw2Id = $cgw2Result.Trim()
  Assert-AwsResourceId -ResourceId $cgw2Id -ResourceType "Customer Gateway 2"

  # Tag the CGW
  $cgw2Tags = Get-AwsTagsArray -Name "lab-003-cgw-azure-inst1" -OwnerTag $Owner
  aws ec2 create-tags --resources $cgw2Id --tags $cgw2Tags 2>$null
} else {
  $cgw2Id = $existingCgw2.Trim()
  Write-Host "  Using existing CGW 2: $cgw2Id" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Creating VPN Connections with APIPA tunnels..." -ForegroundColor Gray

# Get PSKs
$psk1 = $psks["aws-site-1-link-1"]
$psk2 = $psks["aws-site-1-link-2"]
$psk3 = $psks["aws-site-2-link-3"]
$psk4 = $psks["aws-site-2-link-4"]

# VPN Connection 1 (to Azure Instance 0 via CGW 1)
# Tunnel 1: 169.254.21.0/30, Tunnel 2: 169.254.21.4/30
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingVpn1 = (aws ec2 describe-vpn-connections --filters "Name=customer-gateway-id,Values=$cgw1Id" "Name=state,Values=available,pending" --query "VpnConnections[0].VpnConnectionId" --output text 2>$null)
$ErrorActionPreference = $oldErrPref

if (-not $existingVpn1 -or $existingVpn1 -eq "None" -or [string]::IsNullOrWhiteSpace($existingVpn1)) {
  Write-Host "  Creating VPN Connection 1 (Azure Instance 0)..." -ForegroundColor Gray

  # Build options JSON as PowerShell object, then serialize without BOM
  $vpn1Options = @{
    TunnelOptions = @(
      @{
        TunnelInsideCidr = "169.254.21.0/30"
        PreSharedKey = $psk1
        IKEVersions = @(@{Value = "ikev2"})
      },
      @{
        TunnelInsideCidr = "169.254.21.4/30"
        PreSharedKey = $psk2
        IKEVersions = @(@{Value = "ikev2"})
      }
    )
  }

  $vpn1OptionsJson = $vpn1Options | ConvertTo-Json -Depth 10 -Compress
  $vpn1TempFile = Join-Path $tempDir "vpn1-options.json"
  Write-JsonWithoutBom -Path $vpn1TempFile -Content $vpn1OptionsJson

  $vpn1Result = Invoke-AwsCli -Arguments @(
    "ec2", "create-vpn-connection",
    "--type", "ipsec.1",
    "--customer-gateway-id", $cgw1Id,
    "--vpn-gateway-id", $vgwId,
    "--options", "file://$vpn1TempFile",
    "--query", "VpnConnection.VpnConnectionId",
    "--output", "text"
  ) -ErrorMessage "Failed to create VPN Connection 1"

  $vpn1Id = $vpn1Result.Trim()
  Assert-AwsResourceId -ResourceId $vpn1Id -ResourceType "VPN Connection 1"

  # Tag the VPN connection
  $vpn1Tags = Get-AwsTagsArray -Name "lab-003-vpn-1" -OwnerTag $Owner
  aws ec2 create-tags --resources $vpn1Id --tags $vpn1Tags 2>$null
} else {
  $vpn1Id = $existingVpn1.Trim()
  Write-Host "  Using existing VPN Connection 1: $vpn1Id" -ForegroundColor DarkGray
}

# VPN Connection 2 (to Azure Instance 1 via CGW 2)
# Tunnel 3: 169.254.22.0/30, Tunnel 4: 169.254.22.4/30
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingVpn2 = (aws ec2 describe-vpn-connections --filters "Name=customer-gateway-id,Values=$cgw2Id" "Name=state,Values=available,pending" --query "VpnConnections[0].VpnConnectionId" --output text 2>$null)
$ErrorActionPreference = $oldErrPref

if (-not $existingVpn2 -or $existingVpn2 -eq "None" -or [string]::IsNullOrWhiteSpace($existingVpn2)) {
  Write-Host "  Creating VPN Connection 2 (Azure Instance 1)..." -ForegroundColor Gray

  $vpn2Options = @{
    TunnelOptions = @(
      @{
        TunnelInsideCidr = "169.254.22.0/30"
        PreSharedKey = $psk3
        IKEVersions = @(@{Value = "ikev2"})
      },
      @{
        TunnelInsideCidr = "169.254.22.4/30"
        PreSharedKey = $psk4
        IKEVersions = @(@{Value = "ikev2"})
      }
    )
  }

  $vpn2OptionsJson = $vpn2Options | ConvertTo-Json -Depth 10 -Compress
  $vpn2TempFile = Join-Path $tempDir "vpn2-options.json"
  Write-JsonWithoutBom -Path $vpn2TempFile -Content $vpn2OptionsJson

  $vpn2Result = Invoke-AwsCli -Arguments @(
    "ec2", "create-vpn-connection",
    "--type", "ipsec.1",
    "--customer-gateway-id", $cgw2Id,
    "--vpn-gateway-id", $vgwId,
    "--options", "file://$vpn2TempFile",
    "--query", "VpnConnection.VpnConnectionId",
    "--output", "text"
  ) -ErrorMessage "Failed to create VPN Connection 2"

  $vpn2Id = $vpn2Result.Trim()
  Assert-AwsResourceId -ResourceId $vpn2Id -ResourceType "VPN Connection 2"

  # Tag the VPN connection
  $vpn2Tags = Get-AwsTagsArray -Name "lab-003-vpn-2" -OwnerTag $Owner
  aws ec2 create-tags --resources $vpn2Id --tags $vpn2Tags 2>$null
} else {
  $vpn2Id = $existingVpn2.Trim()
  Write-Host "  Using existing VPN Connection 2: $vpn2Id" -ForegroundColor DarkGray
}

# Wait for VPN connections to be available
Write-Host "  Waiting for VPN connections to be available..." -ForegroundColor Gray
$maxAttempts = 30
$attempt = 0
$vpn1State = "pending"
$vpn2State = "pending"

while ($attempt -lt $maxAttempts) {
  $attempt++
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $vpn1State = (aws ec2 describe-vpn-connections --vpn-connection-ids $vpn1Id --query "VpnConnections[0].State" --output text 2>$null)
  $vpn2State = (aws ec2 describe-vpn-connections --vpn-connection-ids $vpn2Id --query "VpnConnections[0].State" --output text 2>$null)
  $ErrorActionPreference = $oldErrPref

  if ($vpn1State -eq "available" -and $vpn2State -eq "available") { break }

  $elapsed = Get-ElapsedTime -StartTime $phase5Start
  Write-Host "    [$elapsed] VPN1: $vpn1State, VPN2: $vpn2State (attempt $attempt/$maxAttempts)" -ForegroundColor DarkGray
  Start-Sleep -Seconds 15
}

# Get VPN tunnel details
Write-Host ""
Write-Host "Retrieving AWS VPN tunnel details..." -ForegroundColor Gray

$vpn1DetailsJson = aws ec2 describe-vpn-connections --vpn-connection-ids $vpn1Id --output json
$vpn2DetailsJson = aws ec2 describe-vpn-connections --vpn-connection-ids $vpn2Id --output json

if (-not $vpn1DetailsJson -or -not $vpn2DetailsJson) {
  throw "Failed to retrieve VPN connection details. VPN1: $vpn1Id, VPN2: $vpn2Id"
}

$vpn1Details = $vpn1DetailsJson | ConvertFrom-Json
$vpn2Details = $vpn2DetailsJson | ConvertFrom-Json

# Validate VPN connection data
if (-not $vpn1Details.VpnConnections -or $vpn1Details.VpnConnections.Count -eq 0) {
  throw "VPN Connection 1 not found or has no data: $vpn1Id"
}
if (-not $vpn2Details.VpnConnections -or $vpn2Details.VpnConnections.Count -eq 0) {
  throw "VPN Connection 2 not found or has no data: $vpn2Id"
}

$vpn1Conn = $vpn1Details.VpnConnections[0]
$vpn2Conn = $vpn2Details.VpnConnections[0]

# Validate telemetry data exists
if (-not $vpn1Conn.VgwTelemetry -or $vpn1Conn.VgwTelemetry.Count -lt 2) {
  Write-Host "  WARNING: VPN1 telemetry not fully available yet, continuing..." -ForegroundColor Yellow
}
if (-not $vpn2Conn.VgwTelemetry -or $vpn2Conn.VgwTelemetry.Count -lt 2) {
  Write-Host "  WARNING: VPN2 telemetry not fully available yet, continuing..." -ForegroundColor Yellow
}

# Extract tunnel IPs with null checks
$tunnel1OutsideIp = if ($vpn1Conn.VgwTelemetry -and $vpn1Conn.VgwTelemetry.Count -ge 1) { $vpn1Conn.VgwTelemetry[0].OutsideIpAddress } else { "pending" }
$tunnel1InsideIp = if ($vpn1Conn.Options.TunnelOptions -and $vpn1Conn.Options.TunnelOptions.Count -ge 1) { $vpn1Conn.Options.TunnelOptions[0].TunnelInsideCidr -replace "/30", "" } else { "169.254.21.0" }
$tunnel2OutsideIp = if ($vpn1Conn.VgwTelemetry -and $vpn1Conn.VgwTelemetry.Count -ge 2) { $vpn1Conn.VgwTelemetry[1].OutsideIpAddress } else { "pending" }
$tunnel2InsideIp = if ($vpn1Conn.Options.TunnelOptions -and $vpn1Conn.Options.TunnelOptions.Count -ge 2) { $vpn1Conn.Options.TunnelOptions[1].TunnelInsideCidr -replace "/30", "" } else { "169.254.21.4" }

$tunnel3OutsideIp = if ($vpn2Conn.VgwTelemetry -and $vpn2Conn.VgwTelemetry.Count -ge 1) { $vpn2Conn.VgwTelemetry[0].OutsideIpAddress } else { "pending" }
$tunnel3InsideIp = if ($vpn2Conn.Options.TunnelOptions -and $vpn2Conn.Options.TunnelOptions.Count -ge 1) { $vpn2Conn.Options.TunnelOptions[0].TunnelInsideCidr -replace "/30", "" } else { "169.254.22.0" }
$tunnel4OutsideIp = if ($vpn2Conn.VgwTelemetry -and $vpn2Conn.VgwTelemetry.Count -ge 2) { $vpn2Conn.VgwTelemetry[1].OutsideIpAddress } else { "pending" }
$tunnel4InsideIp = if ($vpn2Conn.Options.TunnelOptions -and $vpn2Conn.Options.TunnelOptions.Count -ge 2) { $vpn2Conn.Options.TunnelOptions[1].TunnelInsideCidr -replace "/30", "" } else { "169.254.22.4" }

# Calculate BGP peer IPs (AWS uses .1 in each /30)
$tunnel1BgpIp = (Get-ApipaAddress -Cidr "169.254.21.0/30").Remote
$tunnel2BgpIp = (Get-ApipaAddress -Cidr "169.254.21.4/30").Remote
$tunnel3BgpIp = (Get-ApipaAddress -Cidr "169.254.22.0/30").Remote
$tunnel4BgpIp = (Get-ApipaAddress -Cidr "169.254.22.4/30").Remote

Write-Host ""
Write-Host "AWS VPN Tunnel Details:" -ForegroundColor Yellow
Write-Host "  VPN Connection 1 (to Azure Instance 0):" -ForegroundColor Green
Write-Host "    Tunnel 1: $tunnel1OutsideIp (BGP: $tunnel1BgpIp, APIPA: 169.254.21.0/30)" -ForegroundColor Gray
Write-Host "    Tunnel 2: $tunnel2OutsideIp (BGP: $tunnel2BgpIp, APIPA: 169.254.21.4/30)" -ForegroundColor Gray
Write-Host "  VPN Connection 2 (to Azure Instance 1):" -ForegroundColor Green
Write-Host "    Tunnel 3: $tunnel3OutsideIp (BGP: $tunnel3BgpIp, APIPA: 169.254.22.0/30)" -ForegroundColor Gray
Write-Host "    Tunnel 4: $tunnel4OutsideIp (BGP: $tunnel4BgpIp, APIPA: 169.254.22.4/30)" -ForegroundColor Gray

$phase5Elapsed = Get-ElapsedTime -StartTime $phase5Start
Write-Host ""
Write-Host "Phase 5 Validation:" -ForegroundColor Yellow
Write-Validation -Check "VPC created" -Passed (-not [string]::IsNullOrWhiteSpace($vpcId)) -Details $vpcId
Write-Validation -Check "VGW created" -Passed (-not [string]::IsNullOrWhiteSpace($vgwId)) -Details $vgwId
Write-Validation -Check "CGW 1 created (Azure Inst 0)" -Passed (-not [string]::IsNullOrWhiteSpace($cgw1Id)) -Details $cgw1Id
Write-Validation -Check "CGW 2 created (Azure Inst 1)" -Passed (-not [string]::IsNullOrWhiteSpace($cgw2Id)) -Details $cgw2Id
Write-Validation -Check "VPN Connection 1 available" -Passed ($vpn1State -eq "available") -Details $vpn1Id
Write-Validation -Check "VPN Connection 2 available" -Passed ($vpn2State -eq "available") -Details $vpn2Id
Write-Log "Phase 5 completed in $phase5Elapsed" "SUCCESS"

# ============================================
# PHASE 5b: Create Azure VPN Sites with real AWS tunnel IPs
# ============================================
Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "PHASE 5b : Azure VPN Sites + Connections" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host ""

$phase5bStart = Get-Date

# Validate we have tunnel IPs before proceeding
if ($tunnel1OutsideIp -eq "pending" -or $tunnel2OutsideIp -eq "pending" -or
    $tunnel3OutsideIp -eq "pending" -or $tunnel4OutsideIp -eq "pending") {
  Write-Host "Waiting for AWS tunnel IPs to be available..." -ForegroundColor Yellow
  Start-Sleep -Seconds 30

  # Refresh VPN details
  $vpn1DetailsJson = aws ec2 describe-vpn-connections --vpn-connection-ids $vpn1Id --output json
  $vpn2DetailsJson = aws ec2 describe-vpn-connections --vpn-connection-ids $vpn2Id --output json
  $vpn1Details = $vpn1DetailsJson | ConvertFrom-Json
  $vpn2Details = $vpn2DetailsJson | ConvertFrom-Json
  $vpn1Conn = $vpn1Details.VpnConnections[0]
  $vpn2Conn = $vpn2Details.VpnConnections[0]

  $tunnel1OutsideIp = $vpn1Conn.VgwTelemetry[0].OutsideIpAddress
  $tunnel2OutsideIp = $vpn1Conn.VgwTelemetry[1].OutsideIpAddress
  $tunnel3OutsideIp = $vpn2Conn.VgwTelemetry[0].OutsideIpAddress
  $tunnel4OutsideIp = $vpn2Conn.VgwTelemetry[1].OutsideIpAddress
}

# Now create VPN Sites with real AWS tunnel IPs
foreach ($site in $VpnSites) {
  $siteName = $site.Name
  Write-Host "Creating VPN Site: $siteName (ASN: $AwsBgpAsn)" -ForegroundColor Gray

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

    # Map tunnel index to AWS tunnel IP
    switch ($link.TunnelIndex) {
      1 { $tunnelIp = $tunnel1OutsideIp; $tunnelBgpIp = $tunnel1BgpIp }
      2 { $tunnelIp = $tunnel2OutsideIp; $tunnelBgpIp = $tunnel2BgpIp }
      3 { $tunnelIp = $tunnel3OutsideIp; $tunnelBgpIp = $tunnel3BgpIp }
      4 { $tunnelIp = $tunnel4OutsideIp; $tunnelBgpIp = $tunnel4BgpIp }
    }

    $siteLinks += @{
      name = $link.Name
      properties = @{
        ipAddress = $tunnelIp
        linkProperties = @{ linkSpeedInMbps = 100 }
        bgpProperties = @{
          asn = $AwsBgpAsn
          bgpPeeringAddress = $tunnelBgpIp
        }
      }
    }

    Write-Host "    $($link.Name): IP=$tunnelIp, BGP=$tunnelBgpIp, APIPA=$($link.Apipa) (Instance $($site.Instance))" -ForegroundColor DarkGray
  }

  # Create VPN Site with links via ARM REST API
  $siteBody = @{
    location = $Location
    tags = @{
      project = "azure-labs"
      lab = "lab-003"
      env = "lab"
      owner = $Owner
    }
    properties = @{
      virtualWan = @{ id = $vwanId }
      deviceProperties = @{
        deviceVendor = "AWS"
        deviceModel = "VGW"
      }
      vpnSiteLinks = $siteLinks
    }
  } | ConvertTo-Json -Depth 10

  $siteUri = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/vpnSites/$siteName`?api-version=2023-09-01"
  $tempFile = Join-Path $tempDir "$siteName-body.json"
  Write-JsonWithoutBom -Path $tempFile -Content $siteBody

  az rest --method PUT --uri $siteUri --body "@$tempFile" --output none 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Log "Failed to create VPN Site: $siteName" "ERROR"
    throw "Failed to create VPN Site: $siteName"
  }

  Write-Log "VPN Site created: $siteName with $($siteLinks.Count) links"
}

# Wait for sites to provision
Write-Host "Waiting for VPN Sites to provision..." -ForegroundColor Gray
Start-Sleep -Seconds 10

# Create VPN Connections
Write-Host ""
Write-Host "Creating VPN Gateway connections..." -ForegroundColor Gray

foreach ($site in $VpnSites) {
  $siteName = $site.Name
  $connName = "conn-$siteName"

  Write-Host "Creating connection: $connName" -ForegroundColor Gray

  # Check if connection exists - we'll update/replace it (idempotent deploy)
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $existingConn = az network vpn-gateway connection show -g $ResourceGroup --gateway-name $VpnGwName -n $connName -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldErrPref

  if ($existingConn) {
    if ($existingConn.provisioningState -eq "Updating") {
      Write-Host "  Connection is currently updating, waiting..." -ForegroundColor Yellow
      Start-Sleep -Seconds 30
    }
    Write-Host "  Updating existing connection..." -ForegroundColor DarkGray
  }

  # Get site details
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $siteObj = az network vpn-site show -g $ResourceGroup -n $siteName -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldErrPref
  $siteId = $siteObj.id

  # Refresh gateway info
  $gw = az network vpn-gateway show -g $ResourceGroup -n $VpnGwName -o json | ConvertFrom-Json

  # Build link connections with APIPA custom BGP addresses
  $linkConnections = @()
  $linkIndex = 0
  foreach ($link in $site.Links) {
    $apipa = Get-ApipaAddress -Cidr $link.Apipa
    $pskKey = "$siteName-$($link.Name)"
    $psk = $psks[$pskKey]

    # Azure requires customBgpAddresses for ALL gateway instances
    # For target instance: use THIS link's specific APIPA
    # For other instance: use a valid APIPA from that instance's configured addresses
    $customBgpAddresses = @()
    $targetInstance = $site.Instance

    # Get configured APIPA addresses for each instance
    $instance0Apipas = @()
    $instance1Apipas = @()
    foreach ($peerAddr in $gw.bgpSettings.bgpPeeringAddresses) {
      if ($peerAddr.ipconfigurationId -match "Instance0") {
        $instance0Apipas = $peerAddr.customBgpIpAddresses
      } else {
        $instance1Apipas = $peerAddr.customBgpIpAddresses
      }
    }

    foreach ($peerAddr in $gw.bgpSettings.bgpPeeringAddresses) {
      $isInstance0 = $peerAddr.ipconfigurationId -match "Instance0"
      $peerInstance = if ($isInstance0) { 0 } else { 1 }

      if ($peerInstance -eq $targetInstance) {
        # Target instance: use THIS link's specific APIPA
        $customBgpAddresses += @{
          ipConfigurationId = $peerAddr.ipconfigurationId
          customBgpIpAddress = $apipa.Azure
        }
      } else {
        # Other instance: use corresponding APIPA from that instance
        # Use linkIndex to pick first or second APIPA (keeps alignment across links)
        $otherApipas = if ($peerInstance -eq 0) { $instance0Apipas } else { $instance1Apipas }
        $apipaIndex = [Math]::Min($linkIndex, $otherApipas.Count - 1)
        $customBgpAddresses += @{
          ipConfigurationId = $peerAddr.ipconfigurationId
          customBgpIpAddress = $otherApipas[$apipaIndex]
        }
      }
    }

    $linkConnections += @{
      name = "$connName-$($link.Name)"
      properties = @{
        vpnSiteLink = @{ id = "$siteId/vpnSiteLinks/$($link.Name)" }
        sharedKey = $psk
        enableBgp = $true
        vpnConnectionProtocolType = "IKEv2"
        connectionBandwidth = 100
        vpnGatewayCustomBgpAddresses = $customBgpAddresses
      }
    }
    $linkIndex++
  }

  # Create connection via ARM REST API
  $connBody = @{
    properties = @{
      remoteVpnSite = @{ id = $siteId }
      vpnLinkConnections = $linkConnections
    }
  } | ConvertTo-Json -Depth 15

  $connUri = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/vpnGateways/$VpnGwName/vpnConnections/$connName`?api-version=2023-09-01"
  $tempFile = Join-Path $tempDir "$connName-body.json"
  Write-JsonWithoutBom -Path $tempFile -Content $connBody

  az rest --method PUT --uri $connUri --body "@$tempFile" --output none 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Log "Failed to create connection: $connName" "WARN"
    Write-Host "  WARNING: Connection may have failed, continuing..." -ForegroundColor Yellow
  }

  Write-Host "  Created with APIPA assignments:" -ForegroundColor DarkGray
  foreach ($link in $site.Links) {
    $apipa = Get-ApipaAddress -Cidr $link.Apipa
    Write-Host "    $($link.Name) -> Instance $($site.Instance): Azure BGP = $($apipa.Azure)" -ForegroundColor DarkGray
  }

  # Wait for this connection to provision before creating the next one
  # (Azure doesn't allow concurrent VPN gateway operations)
  Write-Host "  Waiting for connection to provision..." -ForegroundColor DarkGray
  $maxWaitAttempts = 30
  $waitAttempt = 0
  while ($waitAttempt -lt $maxWaitAttempts) {
    $waitAttempt++
    Start-Sleep -Seconds 10
    $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $connCheck = az network vpn-gateway connection show -g $ResourceGroup --gateway-name $VpnGwName -n $connName -o json 2>$null | ConvertFrom-Json
    $ErrorActionPreference = $oldErrPref

    if ($connCheck.provisioningState -eq "Succeeded") {
      Write-Host "  Connection provisioned successfully" -ForegroundColor Green
      break
    } elseif ($connCheck.provisioningState -eq "Failed") {
      Write-Host "  Connection provisioning failed!" -ForegroundColor Red
      break
    }
    Write-Host "    [$waitAttempt/$maxWaitAttempts] State: $($connCheck.provisioningState)..." -ForegroundColor DarkGray
  }

  Write-Log "Connection created: $connName"
}

# Wait for connections to provision
Write-Host ""
Write-Host "Waiting for connections to provision (60s)..." -ForegroundColor Gray
Start-Sleep -Seconds 60

# Validate sites and connections
Write-Host ""
Write-Host "Phase 5b Validation:" -ForegroundColor Yellow
$allSitesValid = $true
$allConnectionsValid = $true
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"

foreach ($site in $VpnSites) {
  $siteObj = az network vpn-site show -g $ResourceGroup -n $site.Name -o json 2>$null | ConvertFrom-Json
  $linksOk = ($siteObj -and $siteObj.vpnSiteLinks.Count -eq 2)
  Write-Validation -Check "Site $($site.Name) has 2 links" -Passed $linksOk
  if (-not $linksOk) { $allSitesValid = $false }

  $connName = "conn-$($site.Name)"
  $conn = az network vpn-gateway connection show -g $ResourceGroup --gateway-name $VpnGwName -n $connName -o json 2>$null | ConvertFrom-Json
  $connOk = ($conn -and $conn.provisioningState -eq "Succeeded")
  Write-Validation -Check "Connection $connName provisioned" -Passed $connOk -Details "State: $($conn.provisioningState)"
  if (-not $connOk) { $allConnectionsValid = $false }
}
$ErrorActionPreference = $oldErrPref

$phase5bElapsed = Get-ElapsedTime -StartTime $phase5bStart
Write-Log "Phase 5b completed in $phase5bElapsed" "SUCCESS"

# ============================================
# PHASE 6: Final Validation
# ============================================
Write-Phase -Number 6 -Title "Final Validation"

$phase6Start = Get-Date

# Get final gateway state
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$gw = az network vpn-gateway show -g $ResourceGroup -n $VpnGwName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref

Write-Host "Azure VPN Gateway BGP Summary:" -ForegroundColor Yellow
Write-Host ""
Write-Host "Instance 0 BGP Peers:" -ForegroundColor Yellow
$instance0Peers = @()
foreach ($site in $VpnSites | Where-Object { $_.Instance -eq 0 }) {
  foreach ($link in $site.Links) {
    $apipa = Get-ApipaAddress -Cidr $link.Apipa
    $instance0Peers += "$($site.Name)/$($link.Name): Azure=$($apipa.Azure), AWS=$($apipa.Remote)"
    Write-Host "  $($site.Name)/$($link.Name): Azure=$($apipa.Azure), AWS=$($apipa.Remote)" -ForegroundColor Gray
  }
}

Write-Host ""
Write-Host "Instance 1 BGP Peers:" -ForegroundColor Yellow
$instance1Peers = @()
foreach ($site in $VpnSites | Where-Object { $_.Instance -eq 1 }) {
  foreach ($link in $site.Links) {
    $apipa = Get-ApipaAddress -Cidr $link.Apipa
    $instance1Peers += "$($site.Name)/$($link.Name): Azure=$($apipa.Azure), AWS=$($apipa.Remote)"
    Write-Host "  $($site.Name)/$($link.Name): Azure=$($apipa.Azure), AWS=$($apipa.Remote)" -ForegroundColor Gray
  }
}

# AWS tunnel status
Write-Host ""
Write-Host "AWS VPN Tunnel Status:" -ForegroundColor Yellow
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vpn1StatusJson = aws ec2 describe-vpn-connections --vpn-connection-ids $vpn1Id --query "VpnConnections[0].VgwTelemetry[*].{IP:OutsideIpAddress,Status:Status}" --output json 2>$null
$vpn2StatusJson = aws ec2 describe-vpn-connections --vpn-connection-ids $vpn2Id --query "VpnConnections[0].VgwTelemetry[*].{IP:OutsideIpAddress,Status:Status}" --output json 2>$null
$ErrorActionPreference = $oldErrPref

$vpn1Status = if ($vpn1StatusJson) { $vpn1StatusJson | ConvertFrom-Json } else { @() }
$vpn2Status = if ($vpn2StatusJson) { $vpn2StatusJson | ConvertFrom-Json } else { @() }

Write-Host "  VPN Connection 1 (Azure Instance 0):" -ForegroundColor Gray
foreach ($t in $vpn1Status) {
  $statusColor = if ($t.Status -eq "UP") { "Green" } else { "Yellow" }
  Write-Host "    $($t.IP): $($t.Status)" -ForegroundColor $statusColor
}
Write-Host "  VPN Connection 2 (Azure Instance 1):" -ForegroundColor Gray
foreach ($t in $vpn2Status) {
  $statusColor = if ($t.Status -eq "UP") { "Green" } else { "Yellow" }
  Write-Host "    $($t.IP): $($t.Status)" -ForegroundColor $statusColor
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
Write-Host ""
Write-Host "  Azure:" -ForegroundColor Cyan
Write-Host "    Resource Group: $ResourceGroup" -ForegroundColor Gray
Write-Host "    Location: $Location" -ForegroundColor Gray
Write-Host "    VPN Sites: 2" -ForegroundColor Gray
Write-Host "    VPN Links: 4" -ForegroundColor Gray
Write-Host "    Instance 0 links: 2" -ForegroundColor Gray
Write-Host "    Instance 1 links: 2" -ForegroundColor Gray
Write-Host ""
Write-Host "  AWS:" -ForegroundColor Cyan
Write-Host "    Region: $AwsRegion" -ForegroundColor Gray
Write-Host "    VPC: $vpcId" -ForegroundColor Gray
Write-Host "    VGW: $vgwId" -ForegroundColor Gray
Write-Host "    VPN Connections: 2" -ForegroundColor Gray
Write-Host "    Tunnels: 4" -ForegroundColor Gray

# Determine overall status
$overallPass = $allSitesValid -and $allConnectionsValid

Write-Host ""
if ($overallPass) {
  Write-Host "STATUS: PASS" -ForegroundColor Green
  Write-Host "  All resources created successfully." -ForegroundColor Green
  Write-Host "  BGP may take 5-10 minutes to fully establish." -ForegroundColor Yellow
} else {
  Write-Host "STATUS: PARTIAL" -ForegroundColor Yellow
  Write-Host "  Some validations failed. Check above for details." -ForegroundColor Yellow
}

# Save outputs
Ensure-Directory (Split-Path -Parent $OutputsPath)

$outputs = [pscustomobject]@{
  metadata = [pscustomobject]@{
    lab = "lab-003"
    deployedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    deploymentTime = $totalElapsed
    status = if ($overallPass) { "PASS" } else { "PARTIAL" }
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
    vwan = $VwanName
    vhub = $VhubName
    vhubPrefix = $VhubPrefix
    vpnGateway = $VpnGwName
    bgpAsn = $AzureBgpAsn
    vpnGatewayIps = $azureVpnIps
    sites = $VpnSites
    instance0Peers = $instance0Peers
    instance1Peers = $instance1Peers
  }
  aws = [pscustomobject]@{
    profile = $AwsProfile
    region = $AwsRegion
    vpcId = $vpcId
    subnetId = $subnetId
    igwId = $igwId
    routeTableId = $rtId
    vgwId = $vgwId
    cgw1Id = $cgw1Id
    cgw2Id = $cgw2Id
    vpnConnection1Id = $vpn1Id
    vpnConnection2Id = $vpn2Id
    bgpAsn = $AwsBgpAsn
    tunnels = @(
      @{ index = 1; outsideIp = $tunnel1OutsideIp; bgpIp = $tunnel1BgpIp; apipa = "169.254.21.0/30"; azureInstance = 0 }
      @{ index = 2; outsideIp = $tunnel2OutsideIp; bgpIp = $tunnel2BgpIp; apipa = "169.254.21.4/30"; azureInstance = 0 }
      @{ index = 3; outsideIp = $tunnel3OutsideIp; bgpIp = $tunnel3BgpIp; apipa = "169.254.22.0/30"; azureInstance = 1 }
      @{ index = 4; outsideIp = $tunnel4OutsideIp; bgpIp = $tunnel4BgpIp; apipa = "169.254.22.4/30"; azureInstance = 1 }
    )
  }
  apipaMapping = [pscustomobject]@{
    instance0 = @(
      @{ cidr = "169.254.21.0/30"; azureIp = "169.254.21.2"; awsIp = "169.254.21.1" }
      @{ cidr = "169.254.21.4/30"; azureIp = "169.254.21.6"; awsIp = "169.254.21.5" }
    )
    instance1 = @(
      @{ cidr = "169.254.22.0/30"; azureIp = "169.254.22.2"; awsIp = "169.254.22.1" }
      @{ cidr = "169.254.22.4/30"; azureIp = "169.254.22.6"; awsIp = "169.254.22.5" }
    )
  }
}

$outputsJson = $outputs | ConvertTo-Json -Depth 10
Write-JsonWithoutBom -Path $OutputsPath -Content $outputsJson

Write-Host ""
Write-Host "Outputs saved to: $OutputsPath" -ForegroundColor Gray
Write-Host "Log saved to: $script:LogFile" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  - Wait 5-10 minutes for BGP to establish" -ForegroundColor Gray
Write-Host "  - Review APIPA mappings: docs/apipa-mapping.md" -ForegroundColor Gray
Write-Host "  - Validation commands: docs/validation.md" -ForegroundColor Gray
Write-Host "  - Cleanup: ./destroy.ps1" -ForegroundColor Gray
Write-Host ""

Write-Log "Deployment completed with status: $(if ($overallPass) { 'PASS' } else { 'PARTIAL' })" "SUCCESS"
