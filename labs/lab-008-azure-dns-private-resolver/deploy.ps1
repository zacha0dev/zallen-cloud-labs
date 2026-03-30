# labs/lab-008-azure-dns-private-resolver/deploy.ps1
# Azure DNS Private Resolver + DNS Security Policy
#
# Deploys:
#   - Resource Group
#   - Hub VNet (10.80.0.0/16) with workload + resolver subnets
#   - Spoke VNet (10.81.0.0/16) with workload subnet
#   - VNet Peering (hub <-> spoke, bidirectional)
#   - DNS Private Resolver (hub)
#       Inbound endpoint  (snet-dns-inbound)
#       Outbound endpoint (snet-dns-outbound)
#   - DNS Forwarding Ruleset (linked to spoke VNet)
#       Rule: internal.lab         -> inbound endpoint
#       Rule: onprem.example.com   -> 10.0.0.1 (simulated)
#   - Private DNS Zone: internal.lab (linked to hub, auto-reg OFF)
#   - Static A record: app.internal.lab -> 10.80.1.10
#   - DNS Security Policy (linked to spoke VNet)
#       Domain list: blocked.lab., malware.internal.lab.
#       Block rule: SERVFAIL
#   - Test VM in spoke (Standard_B1s, no public IP, serial console)
#
# Explore results in the Azure portal after deployment.
# Use .\lab.ps1 -Inspect lab-008 for a resource health summary.

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [string]$Location     = "eastus2",
  [string]$Owner        = "",
  [string]$AdminPassword,
  [string]$AdminUser    = "azureuser",
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot  = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path
$InfraDir = Join-Path $LabRoot "infra"
$DataDir  = Join-Path $RepoRoot ".data\lab-008"
$OutputsPath = Join-Path $DataDir "outputs.json"

. (Join-Path $RepoRoot "scripts\labs-common.ps1")

$ResourceGroup    = "rg-lab-008-dns-resolver"
$HubVnetName      = "vnet-hub-008"
$SpokeVnetName    = "vnet-spoke-008"
$ResolverName     = "dnsresolver-008"
$InboundEpName    = "ep-inbound-008"
$OutboundEpName   = "ep-outbound-008"
$RulesetName      = "ruleset-008"
$DnsZoneName      = "internal.lab"
$VmSpokeName      = "vm-spoke-008"
$SecurityPolicyName = "dnspolicy-lab-008"
$DomainListName     = "domainlist-lab-008-blocked"
$SecurityRuleName   = "rule-block-lab-domains"
$DeploymentName   = "lab-008-deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

# ============================================
# HELPERS
# ============================================

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
    Write-Host "  [WARN] $Check" -ForegroundColor Yellow
  }
  if ($Details) {
    Write-Host "         $Details" -ForegroundColor DarkGray
  }
}

function Get-ElapsedTime {
  param([datetime]$StartTime)
  $elapsed = (Get-Date) - $StartTime
  return "$([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
}

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

# ============================================
# MAIN
# ============================================

Write-Host ""
Write-Host "Lab 008: Azure DNS Private Resolver + Security Policy" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Deploys a hub-spoke DNS architecture with Private Resolver" -ForegroundColor White
Write-Host "and DNS Security Policy for portal exploration." -ForegroundColor White
Write-Host ""

$deploymentStartTime = Get-Date

# ============================================
# PHASE 0: Preflight
# ============================================
Write-Phase -Number 0 -Title "Preflight"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw "Azure CLI not found. Install from https://aka.ms/installazurecli"
}
Write-Host "  [PASS] Azure CLI installed" -ForegroundColor Green

if (-not $AdminPassword) {
  throw "Provide -AdminPassword (VM login password)."
}
Write-Host "  [PASS] AdminPassword provided" -ForegroundColor Green

Show-ConfigPreflight -RepoRoot $RepoRoot
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Write-Host "  [PASS] Subscription resolved: $SubscriptionId" -ForegroundColor Green

Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null
$subName = az account show --query name -o tsv
Write-Host "  [PASS] Authenticated: $subName" -ForegroundColor Green

if (-not $Owner) {
  $Owner = $env:USERNAME
  if (-not $Owner) { $Owner = $env:USER }
  if (-not $Owner) { $Owner = "unknown" }
}

Write-Host ""
Write-Host "Cost estimate: ~`$0.03/hr while running" -ForegroundColor Yellow
Write-Host "  VM (Standard_B1s):         ~`$0.01/hr" -ForegroundColor Gray
Write-Host "  DNS Private Resolver:      ~`$0.014/hr (2 endpoints)" -ForegroundColor Gray
Write-Host "  Private DNS Zone:          ~`$0.004/hr" -ForegroundColor Gray
Write-Host "  DNS Security Policy:       no additional cost at lab scale" -ForegroundColor Gray
Write-Host ""

if (-not $Force) {
  $confirm = Read-Host "Type DEPLOY to proceed"
  if ($confirm -ne "DEPLOY") { throw "Cancelled." }
}

$portalUrl = "https://portal.azure.com/#@/resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/overview"
Write-Host ""
Write-Host "Portal: $portalUrl" -ForegroundColor Cyan

# ============================================
# PHASE 1: Deploy Bicep
# ============================================
Write-Phase -Number 1 -Title "Deploy Infrastructure"

$tagArgs = @("project=azure-labs", "lab=lab-008", "owner=$Owner", "environment=lab", "cost-center=learning")

$existingRg = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if ($existingRg) {
  Write-Host "  Resource group exists, updating tags..." -ForegroundColor DarkGray
  az group update --name $ResourceGroup --tags @tagArgs --output none 2>$null
} else {
  az group create --name $ResourceGroup --location $Location --tags @tagArgs --output none
  Write-Host "  Created resource group: $ResourceGroup" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  Deploying Bicep template..." -ForegroundColor Gray
Write-Host "    Hub VNet + Spoke VNet + peering" -ForegroundColor DarkGray
Write-Host "    DNS Private Resolver (inbound + outbound endpoints)" -ForegroundColor DarkGray
Write-Host "    DNS Forwarding Ruleset -> linked to spoke" -ForegroundColor DarkGray
Write-Host "    Private DNS Zone (internal.lab) + A record" -ForegroundColor DarkGray
Write-Host "    DNS Security Policy -> domain list -> block rule -> linked to spoke" -ForegroundColor DarkGray
Write-Host "    Test VM (vm-spoke-008, no public IP)" -ForegroundColor DarkGray
Write-Host ""

$bicepResult = az deployment group create `
  --resource-group $ResourceGroup `
  --name $DeploymentName `
  --template-file (Join-Path $InfraDir "main.bicep") `
  --parameters `
      location=$Location `
      adminUser=$AdminUser `
      adminPassword=$AdminPassword `
      owner=$Owner `
  --output json `
  --only-show-errors 2>&1

if ($LASTEXITCODE -ne 0) {
  $bicepOutput = $bicepResult -join "`n"
  Write-Host $bicepOutput -ForegroundColor Red
  Write-Host ""
  if ($bicepOutput -match "DnsResolverLimitExceeded|resolver.*limit") {
    Write-Host "[ERROR] DNS Private Resolver limit exceeded (1 per VNet)." -ForegroundColor Red
    Write-Host "        az dns-resolver list --query '[].{name:name,vnet:virtualNetwork.id}' -o table" -ForegroundColor Yellow
  } elseif ($bicepOutput -match "dnsResolverPolicies.*not.*supported|SubscriptionNotRegistered.*Microsoft.Network") {
    Write-Host "[ERROR] DNS Security Policy not available in this subscription/region." -ForegroundColor Red
    Write-Host "        Try: az feature register --namespace Microsoft.Network --name dnsResolverPolicies" -ForegroundColor Yellow
  } elseif ($bicepOutput -match "AuthorizationFailed|does not have authorization") {
    Write-Host "[ERROR] Authorization failure - need Contributor or Network Contributor." -ForegroundColor Red
    Write-Host "        Principal: $(az account show --query user.name -o tsv 2>$null)" -ForegroundColor Yellow
  } elseif ($bicepOutput -match "NetworkSecurityGroup.*not.*allowed|NSG.*resolver") {
    Write-Host "[ERROR] NSG on resolver subnet - endpoint subnets cannot have NSGs." -ForegroundColor Red
  }
  throw "Bicep deployment failed."
}

$bicepText  = $bicepResult -join "`n"
$jsonStart  = $bicepText.IndexOf('{')
if ($jsonStart -lt 0) { throw "Bicep succeeded but no JSON in output." }
$deployOutput = $bicepText.Substring($jsonStart) | ConvertFrom-Json

$inboundIp          = $deployOutput.properties.outputs.inboundEndpointIp.value
$hubVnetId          = $deployOutput.properties.outputs.hubVnetId.value
$vmSerialConsoleUrl = $deployOutput.properties.outputs.vmSpokeSerialConsoleUrl.value
$securityPolicyId   = $deployOutput.properties.outputs.securityPolicyId.value
$domainListId       = $deployOutput.properties.outputs.domainListId.value

Write-Host ""
Write-Host "  [PASS] Bicep deployment succeeded: $DeploymentName" -ForegroundColor Green
Write-Host "         Inbound endpoint IP: $inboundIp" -ForegroundColor DarkGray

# ============================================
# PHASE 2: Verify Resources Exist
# ============================================
Write-Phase -Number 2 -Title "Verify Resources"

# VNets
$hubVnet = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$hubVnet = az network vnet show -g $ResourceGroup -n $HubVnetName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
Write-Validation -Check "Hub VNet" -Passed ($null -ne $hubVnet) -Details $HubVnetName

$spokeVnet = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$spokeVnet = az network vnet show -g $ResourceGroup -n $SpokeVnetName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
Write-Validation -Check "Spoke VNet" -Passed ($null -ne $spokeVnet) -Details $SpokeVnetName

# Peering
$peering = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$peering = az network vnet peering show -g $ResourceGroup --vnet-name $HubVnetName -n "peer-hub-to-spoke" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
$peeringState = if ($peering) { $peering.peeringState } else { "not found" }
Write-Validation -Check "VNet peering" -Passed ($peeringState -eq "Connected") -Details "state: $peeringState"

# DNS Resolver
$resolver = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$resolver = az dns-resolver show -g $ResourceGroup -n $ResolverName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
Write-Validation -Check "DNS Private Resolver" -Passed ($resolver -and $resolver.provisioningState -eq "Succeeded") -Details $ResolverName

# Inbound endpoint
$inboundEp = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$inboundEp = az dns-resolver inbound-endpoint show -g $ResourceGroup --dns-resolver-name $ResolverName -n $InboundEpName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
$resolvedInboundIp = if ($inboundEp -and $inboundEp.ipConfigurations) { $inboundEp.ipConfigurations[0].privateIpAddress } else { $inboundIp }
Write-Validation -Check "Inbound endpoint" -Passed ($inboundEp -and $inboundEp.provisioningState -eq "Succeeded") -Details "IP: $resolvedInboundIp"

# Outbound endpoint
$outboundEp = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$outboundEp = az dns-resolver outbound-endpoint show -g $ResourceGroup --dns-resolver-name $ResolverName -n $OutboundEpName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
Write-Validation -Check "Outbound endpoint" -Passed ($outboundEp -and $outboundEp.provisioningState -eq "Succeeded")

# Forwarding ruleset
$ruleset = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$ruleset = az dns-resolver forwarding-ruleset show -g $ResourceGroup -n $RulesetName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
Write-Validation -Check "Forwarding ruleset" -Passed ($ruleset -and $ruleset.provisioningState -eq "Succeeded") -Details $RulesetName

# DNS Zone
$zone = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$zone = az network private-dns zone show -g $ResourceGroup -n $DnsZoneName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
Write-Validation -Check "Private DNS Zone" -Passed ($null -ne $zone) -Details $DnsZoneName

# A record
$appRecord = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$appRecord = az network private-dns record-set a show -g $ResourceGroup --zone-name $DnsZoneName -n "app" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
$appRecordIp = if ($appRecord -and $appRecord.aRecords -and $appRecord.aRecords.Count -gt 0) { $appRecord.aRecords[0].ipv4Address } else { "not found" }
Write-Validation -Check "A record: app.internal.lab" -Passed ($appRecord -and $appRecordIp -eq "10.80.1.10") -Details "-> $appRecordIp"

# DNS Security Policy
$secPol = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$secPol = az network dns-security-policy show -g $ResourceGroup -n $SecurityPolicyName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
Write-Validation -Check "DNS Security Policy" -Passed ($secPol -and $secPol.provisioningState -eq "Succeeded") -Details $SecurityPolicyName

# Domain list
$domainListsResult = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$domainListsResult = az resource list -g $ResourceGroup --resource-type "Microsoft.Network/dnsResolverDomainLists" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
$domainListFound = $null
$domainListFound = @($domainListsResult) | Where-Object { $_.name -eq $DomainListName }
Write-Validation -Check "Domain list" -Passed ($null -ne $domainListFound) -Details $DomainListName

# Test VM
$vm = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vm = az vm show -g $ResourceGroup -n $VmSpokeName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
Write-Validation -Check "Test VM" -Passed ($null -ne $vm) -Details $VmSpokeName

# ============================================
# PHASE 3: Write Outputs
# ============================================
Write-Phase -Number 3 -Title "Outputs"

$totalElapsed = Get-ElapsedTime -StartTime $deploymentStartTime

$vmPrivateIp = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vmPrivateIp = az vm list-ip-addresses -g $ResourceGroup -n $VmSpokeName `
  --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv 2>$null
$ErrorActionPreference = $oldEP

if (-not $resolvedInboundIp) { $resolvedInboundIp = $inboundIp }
if (-not $vmSerialConsoleUrl) { $vmSerialConsoleUrl = "" }

Ensure-Directory $DataDir

$outputs = [pscustomobject]@{
  metadata = [pscustomobject]@{
    lab            = "lab-008"
    deployedAt     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    deploymentTime = $totalElapsed
    location       = $Location
    resourceGroup  = $ResourceGroup
    bicepDeployment = $DeploymentName
  }
  azure = [pscustomobject]@{
    subscriptionId   = $SubscriptionId
    subscriptionName = $subName
    resourceGroup    = $ResourceGroup
    location         = $Location
    hubVnet = [pscustomobject]@{
      name = $HubVnetName
      cidr = "10.80.0.0/16"
      id   = $hubVnetId
    }
    spokeVnet = [pscustomobject]@{
      name = $SpokeVnetName
      cidr = "10.81.0.0/16"
    }
    dnsResolver = [pscustomobject]@{
      name            = $ResolverName
      inboundEndpoint = [pscustomobject]@{
        name = $InboundEpName
        ip   = $resolvedInboundIp
      }
      outboundEndpoint = [pscustomobject]@{
        name = $OutboundEpName
      }
    }
    forwardingRuleset = [pscustomobject]@{
      name        = $RulesetName
      linkedVnets = @($SpokeVnetName)
    }
    dns = [pscustomobject]@{
      zoneName         = $DnsZoneName
      linkedTo         = $HubVnetName
      autoRegistration = $false
      aRecord          = [pscustomobject]@{
        fqdn = "app.internal.lab"
        ip   = "10.80.1.10"
      }
    }
    dnsSecurityPolicy = [pscustomobject]@{
      name        = $SecurityPolicyName
      id          = if ($securityPolicyId) { $securityPolicyId } else { "" }
      domainList  = [pscustomobject]@{
        name    = $DomainListName
        id      = if ($domainListId) { $domainListId } else { "" }
        domains = @("blocked.lab.", "malware.internal.lab.")
      }
      rule        = $SecurityRuleName
      linkedVnets = @($SpokeVnetName)
      note        = "Spoke queries for blocked.lab. and malware.internal.lab. return SERVFAIL"
    }
    vm = [pscustomobject]@{
      name             = $VmSpokeName
      vnet             = $SpokeVnetName
      privateIp        = $vmPrivateIp
      noPublicIp       = $true
      serialConsoleUrl = $vmSerialConsoleUrl
      loginUser        = $AdminUser
    }
  }
}

$outputs | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputsPath -Encoding UTF8
Write-Host "  [PASS] outputs.json written: $OutputsPath" -ForegroundColor Green

# ============================================
# SUMMARY
# ============================================
Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "DEPLOYMENT COMPLETE  ($totalElapsed)" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host ""
Write-Host "Hub VNet:               $HubVnetName (10.80.0.0/16)" -ForegroundColor Gray
Write-Host "Spoke VNet:             $SpokeVnetName (10.81.0.0/16)" -ForegroundColor Gray
Write-Host "DNS Private Resolver:   $ResolverName" -ForegroundColor Gray
Write-Host "  Inbound endpoint IP:  $resolvedInboundIp" -ForegroundColor Gray
Write-Host "Forwarding Ruleset:     $RulesetName (linked to spoke)" -ForegroundColor Gray
Write-Host "  internal.lab.      -> inbound EP ($resolvedInboundIp)" -ForegroundColor DarkGray
Write-Host "  onprem.example.com -> 10.0.0.1 (simulated)" -ForegroundColor DarkGray
Write-Host "Private DNS Zone:       $DnsZoneName (linked to hub)" -ForegroundColor Gray
Write-Host "  app.internal.lab   -> 10.80.1.10" -ForegroundColor DarkGray
Write-Host "DNS Security Policy:    $SecurityPolicyName (linked to spoke)" -ForegroundColor Gray
Write-Host "  Domain list:          $DomainListName" -ForegroundColor DarkGray
Write-Host "  Block rule:           $SecurityRuleName -> SERVFAIL" -ForegroundColor DarkGray
Write-Host "  Blocked domains:      blocked.lab., malware.internal.lab." -ForegroundColor DarkGray
Write-Host "Test VM:                $VmSpokeName (spoke, no public IP)" -ForegroundColor Gray
Write-Host "  Serial console:       $vmSerialConsoleUrl" -ForegroundColor DarkGray
Write-Host "  Login:                $AdminUser / <password you provided>" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Portal: $portalUrl" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  .\lab.ps1 -Inspect lab-008   # verify all resources" -ForegroundColor DarkGray
Write-Host "  .\lab.ps1 -Destroy lab-008   # clean up when done" -ForegroundColor DarkGray
Write-Host ""
