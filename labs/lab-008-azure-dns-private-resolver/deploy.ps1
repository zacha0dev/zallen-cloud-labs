# labs/lab-008-azure-dns-private-resolver/deploy.ps1
# Azure DNS Private Resolver + Controlled Forwarding Lab
#
# This lab creates:
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
#   - Test VM in spoke (Standard_B1s, no public IP)
#
# Security model:
#   - No "deny all '.'   " wildcard rule (avoids blocking Azure DNS)
#   - Controlled forwarding: explicit domain rules only
#   - Resolution path isolation: spoke resolves via ruleset -> resolver
#   - Hub resolves internal.lab directly via zone link
#
# Deployment modes (-Mode):
#   Base               - Deploy base infra only (default, always stable)
#   StickyBlock        - Base + DNS Security Policy cache persistence test
#   ForwardingVariants - Base + forwarding rule variation tests
#
# Flags:
#   -SkipTests         - Skip validation and mode test phases (infra-only)

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [string]$Location     = "eastus2",
  [string]$Owner        = "",
  [string]$AdminPassword,
  [string]$AdminUser    = "azureuser",
  [switch]$Force,
  [ValidateSet("Base","StickyBlock","ForwardingVariants")]
  [string]$Mode         = "Base",
  [switch]$SkipTests
)

# ============================================
# GUARDRAILS
# ============================================
# DNS Private Resolver is not available in all regions.
# eastus2 and centralus are safe choices.
$AllowedLocations = @("eastus","eastus2","centralus","westus2","northeurope","westeurope")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot    = $PSScriptRoot
$RepoRoot   = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path
$LogsDir    = Join-Path $LabRoot "logs"
$InfraDir   = Join-Path $LabRoot "infra"
$ScriptsDir = Join-Path $LabRoot "scripts"
$DataDir    = Join-Path $RepoRoot ".data\lab-008"
$OutputsPath     = Join-Path $DataDir "outputs.json"
$TestResultsPath = Join-Path $DataDir "test-results.json"

. (Join-Path $RepoRoot "scripts\labs-common.ps1")

# Lab configuration
$ResourceGroup    = "rg-lab-008-dns-resolver"
$HubVnetName      = "vnet-hub-008"
$SpokeVnetName    = "vnet-spoke-008"
$ResolverName     = "dnsresolver-008"
$InboundEpName    = "ep-inbound-008"
$OutboundEpName   = "ep-outbound-008"
$RulesetName      = "ruleset-008"
$DnsZoneName      = "internal.lab"
$VmSpokeName      = "vm-spoke-008"
$DeploymentName   = "lab-008-deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

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
  $logLine   = "[$timestamp] [$Level] $Message"
  Add-Content -Path $script:LogFile -Value $logLine
  switch ($Level) {
    "ERROR"   { Write-Host $Message -ForegroundColor Red }
    "WARN"    { Write-Host $Message -ForegroundColor Yellow }
    "SUCCESS" { Write-Host $Message -ForegroundColor Green }
    default   { Write-Host $Message }
  }
}

function Get-ElapsedTime {
  param([datetime]$StartTime)
  $elapsed = (Get-Date) - $StartTime
  return "$([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
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

# ============================================
# MAIN DEPLOYMENT
# ============================================

Write-Host ""
Write-Host "Lab 008: Azure DNS Private Resolver + Controlled Forwarding" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Mode: $Mode" -ForegroundColor White
if ($SkipTests) {
  Write-Host "SkipTests: ON (infra-only deployment; validation and test phases skipped)" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Purpose: Deploy a DNS Private Resolver in a hub VNet, link a" -ForegroundColor White
Write-Host "         forwarding ruleset to a spoke VNet, and validate that" -ForegroundColor White
Write-Host "         the spoke can resolve private zones via the resolver." -ForegroundColor White
Write-Host ""

$deploymentStartTime = Get-Date

# ============================================
# PHASE 0: Preflight
# ============================================
Write-Phase -Number 0 -Title "Preflight Checks"
$phase0Start = Get-Date

Ensure-Directory $LogsDir
$ts             = Get-Date -Format "yyyyMMdd-HHmmss"
$script:LogFile = Join-Path $LogsDir "lab-008-$ts.log"
Write-Log "Deployment started | Mode=$Mode SkipTests=$SkipTests"
Write-Log "Location: $Location"

Require-Command az "Install Azure CLI: https://aka.ms/installazurecli"
Write-Validation -Check "Azure CLI installed" -Passed $true

Assert-LocationAllowed -Location $Location -AllowedLocations $AllowedLocations
Write-Validation -Check "Location '$Location' allowed" -Passed $true

if (-not $AdminPassword) {
  throw "Provide -AdminPassword (temporary lab password for VM)."
}
Write-Validation -Check "AdminPassword provided" -Passed $true

Show-ConfigPreflight -RepoRoot $RepoRoot
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Write-Validation -Check "Subscription resolved" -Passed $true -Details $SubscriptionId

Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null
$subName = az account show --query name -o tsv
Write-Validation -Check "Azure authenticated" -Passed $true -Details $subName

if (-not $Owner) {
  $Owner = $env:USERNAME
  if (-not $Owner) { $Owner = $env:USER }
  if (-not $Owner) { $Owner = "unknown" }
}

Write-Validation -Check "Mode = $Mode" -Passed $true
if ($SkipTests) {
  Write-Validation -Check "SkipTests flag active (validation + mode phases will be skipped)" -Passed $true
}

Write-Log "Preflight checks passed" "SUCCESS"

# Cost warning
Write-Host ""
Write-Host "Cost estimate: ~`$0.03/hour" -ForegroundColor Yellow
Write-Host "  VM (Standard_B1s):         ~`$0.01/hr" -ForegroundColor Gray
Write-Host "  DNS Private Resolver:      ~`$0.007/hr per endpoint" -ForegroundColor Gray
Write-Host "  Private DNS Zone:          ~`$0.004/hr" -ForegroundColor Gray
Write-Host "  VNet peering (2 links):    minimal" -ForegroundColor Gray
Write-Host ""
Write-Host "Note: DNS Private Resolver must be supported in $Location." -ForegroundColor Yellow
Write-Host "  Supported regions: eastus, eastus2, westus2, centralus, etc." -ForegroundColor Gray
Write-Host ""

if (-not $Force) {
  $confirm = Read-Host "Type DEPLOY to proceed"
  if ($confirm -ne "DEPLOY") { throw "Cancelled." }
}

$portalUrl = "https://portal.azure.com/#@/resource/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/overview"
Write-Host ""
Write-Host "Azure Portal:  $portalUrl" -ForegroundColor Cyan
Write-Host ""

$phase0Elapsed = Get-ElapsedTime -StartTime $phase0Start
Write-Log "Phase 0 completed in $phase0Elapsed" "SUCCESS"

# ============================================
# PHASE 1: Deploy Base Infra (RG + Bicep)
# ============================================
Write-Phase -Number 1 -Title "Deploy Base Infra"
$phase1Start = Get-Date

# --- 1a: Resource Group ---
$tagsString = "project=azure-labs lab=lab-008 owner=$Owner environment=lab cost-center=learning"

$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if ($existingRg) {
  Write-Host "  Resource group already exists, skipping..." -ForegroundColor DarkGray
} else {
  az group create --name $ResourceGroup --location $Location --tags $tagsString --output none
  Write-Log "Resource group created: $ResourceGroup"
}
Write-Validation -Check "Resource group exists" -Passed $true -Details $ResourceGroup

# --- 1b: Bicep Deployment ---
Write-Host ""
Write-Host "Deploying Bicep template..." -ForegroundColor Gray
Write-Host "  Hub VNet ($HubVnetName) + resolver subnets" -ForegroundColor DarkGray
Write-Host "  Spoke VNet ($SpokeVnetName) + workload subnet" -ForegroundColor DarkGray
Write-Host "  VNet peering (bidirectional)" -ForegroundColor DarkGray
Write-Host "  DNS Private Resolver ($ResolverName)" -ForegroundColor DarkGray
Write-Host "    Inbound endpoint  -> snet-dns-inbound" -ForegroundColor DarkGray
Write-Host "    Outbound endpoint -> snet-dns-outbound" -ForegroundColor DarkGray
Write-Host "  DNS Forwarding Ruleset ($RulesetName) -> linked to spoke" -ForegroundColor DarkGray
Write-Host "    Rule: internal.lab       -> inbound endpoint" -ForegroundColor DarkGray
Write-Host "    Rule: onprem.example.com -> 10.0.0.1 (simulated)" -ForegroundColor DarkGray
Write-Host "  Private DNS Zone ($DnsZoneName) -> linked to hub" -ForegroundColor DarkGray
Write-Host "  A record: app.internal.lab -> 10.80.1.10" -ForegroundColor DarkGray
Write-Host "  Test VM ($VmSpokeName, no public IP)" -ForegroundColor DarkGray
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
  --output json 2>&1

if ($LASTEXITCODE -ne 0) {
  $bicepOutput = $bicepResult -join "`n"
  Write-Host $bicepOutput -ForegroundColor Red
  Write-Host ""
  if ($bicepOutput -match "DnsResolverLimitExceeded|resolver.*limit|quota.*dnsResolver") {
    Write-Host "[ERROR] DNS Private Resolver limit exceeded." -ForegroundColor Red
    Write-Host "        Azure allows 1 resolver per VNet. Check for existing resolvers:" -ForegroundColor Red
    Write-Host "        az dns-resolver list --query '[].{name:name,vnet:virtualNetwork.id}' -o table" -ForegroundColor Yellow
  } elseif ($bicepOutput -match "SubnetNotDelegated|delegation.*Microsoft.Network/dnsResolvers") {
    Write-Host "[ERROR] Resolver subnet delegation missing." -ForegroundColor Red
    Write-Host "        Endpoint subnets must be delegated to 'Microsoft.Network/dnsResolvers'." -ForegroundColor Red
    Write-Host "        This is set in main.bicep — check subnet delegation config." -ForegroundColor Yellow
  } elseif ($bicepOutput -match "NetworkSecurityGroup.*not.*allowed|NSG.*resolver|subnet.*nsg") {
    Write-Host "[ERROR] NSG attached to resolver subnet." -ForegroundColor Red
    Write-Host "        Resolver endpoint subnets must NOT have an NSG." -ForegroundColor Red
    Write-Host "        Remove the NSG from snet-dns-inbound and snet-dns-outbound." -ForegroundColor Yellow
  } elseif ($bicepOutput -match "PrivateDnsZone.*Conflict|ZoneName.*already exist") {
    Write-Host "[ERROR] DNS zone conflict: '$DnsZoneName' already exists or has a conflicting link." -ForegroundColor Red
    Write-Host "        Check:  az network private-dns zone show -g $ResourceGroup -n $DnsZoneName" -ForegroundColor Yellow
  } elseif ($bicepOutput -match "AuthorizationFailed|does not have authorization|Forbidden") {
    Write-Host "[ERROR] Authorization failure: current principal lacks required RBAC permissions." -ForegroundColor Red
    Write-Host "        Required: Contributor or Network Contributor on the subscription/RG." -ForegroundColor Red
    Write-Host "        Principal: $(az account show --query user.name -o tsv 2>$null)" -ForegroundColor Yellow
  } elseif ($bicepOutput -match "locationNotAvailableForResourceType|feature.*not.*supported.*region") {
    Write-Host "[ERROR] DNS Private Resolver is not available in '$Location'." -ForegroundColor Red
    Write-Host "        Supported regions: eastus, eastus2, westus2, centralus, northeurope, westeurope" -ForegroundColor Yellow
    Write-Host "        Re-run with: -Location eastus2" -ForegroundColor Yellow
  }
  throw "Bicep deployment failed. See output above."
}

# az output may include WARNING/progress lines before the JSON block (due to 2>&1).
# Extract the JSON object directly to avoid ConvertFrom-Json choking on non-JSON lines.
$bicepText = $bicepResult -join "`n"
$jsonStart  = $bicepText.IndexOf('{')
if ($jsonStart -lt 0) {
  throw "Bicep deployment succeeded but output contained no JSON.`nRaw output:`n$bicepText"
}
$deployOutput = $bicepText.Substring($jsonStart) | ConvertFrom-Json
Write-Log "Bicep deployment succeeded: $DeploymentName" "SUCCESS"
Write-Validation -Check "Bicep deployment succeeded" -Passed $true -Details $DeploymentName

# Capture inbound endpoint IP from deployment outputs
$inboundIp = $deployOutput.properties.outputs.inboundEndpointIp.value
Write-Host ""
Write-Host "  Inbound endpoint IP: $inboundIp" -ForegroundColor Green

# Capture hub VNet ID for mode scripts
$hubVnetId = $deployOutput.properties.outputs.hubVnetId.value

# Capture serial console URL for test VM
$vmSerialConsoleUrl = $deployOutput.properties.outputs.vmSpokeSerialConsoleUrl.value

$phase1Elapsed = Get-ElapsedTime -StartTime $phase1Start
Write-Log "Phase 1 completed in $phase1Elapsed" "SUCCESS"

# ============================================
# PHASE 2: Base Validation (unless -SkipTests)
# ============================================
Write-Phase -Number 2 -Title "Base Validation"

$allValid = $true

if ($SkipTests) {
  Write-Host "  [SKIP] -SkipTests flag set — skipping all validation checks." -ForegroundColor Yellow
  Write-Log "Phase 2 skipped (-SkipTests)" "WARN"
} else {
  $phase2Start = Get-Date

  # Hub VNet
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $hubVnet = az network vnet show -g $ResourceGroup -n $HubVnetName -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP
  $hubValid = ($null -ne $hubVnet)
  Write-Validation -Check "Hub VNet exists" -Passed $hubValid -Details "$HubVnetName (10.80.0.0/16)"
  if (-not $hubValid) { $allValid = $false }

  # Spoke VNet
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $spokeVnet = az network vnet show -g $ResourceGroup -n $SpokeVnetName -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP
  $spokeValid = ($null -ne $spokeVnet)
  Write-Validation -Check "Spoke VNet exists" -Passed $spokeValid -Details "$SpokeVnetName (10.81.0.0/16)"
  if (-not $spokeValid) { $allValid = $false }

  # VNet Peering
  if ($hubValid) {
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $peering = az network vnet peering show -g $ResourceGroup --vnet-name $HubVnetName -n "peer-hub-to-spoke" -o json 2>$null | ConvertFrom-Json
    $ErrorActionPreference = $oldEP
    $peeringValid = ($null -ne $peering -and $peering.peeringState -eq "Connected")
    Write-Validation -Check "VNet peering Connected (hub -> spoke)" -Passed $peeringValid -Details $peering.peeringState
    if (-not $peeringValid) { $allValid = $false }
  }

  # DNS Resolver
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $resolver = az dns-resolver show -g $ResourceGroup -n $ResolverName -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP
  $resolverValid = ($null -ne $resolver -and $resolver.provisioningState -eq "Succeeded")
  Write-Validation -Check "DNS Private Resolver provisioned" -Passed $resolverValid -Details $ResolverName
  if (-not $resolverValid) { $allValid = $false }

  # Inbound Endpoint
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $inboundEp = az dns-resolver inbound-endpoint show -g $ResourceGroup --dns-resolver-name $ResolverName -n $InboundEpName -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP
  $inboundValid = ($null -ne $inboundEp -and $inboundEp.provisioningState -eq "Succeeded")
  $resolvedInboundIp = if ($inboundEp) { $inboundEp.ipConfigurations[0].privateIpAddress } else { $inboundIp }
  Write-Validation -Check "Inbound endpoint provisioned" -Passed $inboundValid -Details "IP: $resolvedInboundIp"
  if (-not $inboundValid) { $allValid = $false }

  # Outbound Endpoint
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $outboundEp = az dns-resolver outbound-endpoint show -g $ResourceGroup --dns-resolver-name $ResolverName -n $OutboundEpName -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP
  $outboundValid = ($null -ne $outboundEp -and $outboundEp.provisioningState -eq "Succeeded")
  Write-Validation -Check "Outbound endpoint provisioned" -Passed $outboundValid
  if (-not $outboundValid) { $allValid = $false }

  # Forwarding Ruleset
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $ruleset = az dns-resolver forwarding-ruleset show -g $ResourceGroup -n $RulesetName -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP
  $rulesetValid = ($null -ne $ruleset -and $ruleset.provisioningState -eq "Succeeded")
  Write-Validation -Check "Forwarding ruleset provisioned" -Passed $rulesetValid -Details $RulesetName
  if (-not $rulesetValid) { $allValid = $false }

  # Forwarding rules
  if ($rulesetValid) {
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $rules = az dns-resolver forwarding-rule list -g $ResourceGroup --forwarding-ruleset-name $RulesetName -o json 2>$null | ConvertFrom-Json
    $ErrorActionPreference = $oldEP
    $ruleInternalLab = $rules | Where-Object { $_.name -eq "rule-internal-lab" }
    $ruleOnprem      = $rules | Where-Object { $_.name -eq "rule-onprem-example" }

    $ruleInternalLabExists = ($null -ne $ruleInternalLab)
    $ruleOnpremExists      = ($null -ne $ruleOnprem)

    $ruleTargetIp = if ($ruleInternalLab) { $ruleInternalLab.targetDnsServers[0].ipAddress } else { "unknown" }
    $ruleTargetMatches = ($ruleTargetIp -eq $resolvedInboundIp) -and ($resolvedInboundIp -ne "unknown")

    Write-Validation -Check "Forwarding rule: internal.lab. -> inbound EP" -Passed $ruleInternalLabExists `
      -Details "domain: $($ruleInternalLab.domainName)"
    Write-Validation -Check "Rule target IP matches inbound endpoint" -Passed $ruleTargetMatches `
      -Details "rule target=$ruleTargetIp  inbound EP=$resolvedInboundIp"
    Write-Validation -Check "Forwarding rule: onprem.example.com. -> 10.0.0.1" -Passed $ruleOnpremExists

    if (-not $ruleInternalLabExists) { $allValid = $false }
    if (-not $ruleTargetMatches)     { $allValid = $false }
    if (-not $ruleOnpremExists)      { $allValid = $false }

    $wildcardRule = $rules | Where-Object { $_.domainName -eq "." -or $_.domainName -eq "'.'"}
    if ($wildcardRule) {
      Write-Host ""
      Write-Host "  [WARN] Wildcard '.' forwarding rule detected in ruleset!" -ForegroundColor Red
      Write-Host "         This will break Azure platform DNS for all VMs linked to this ruleset." -ForegroundColor Red
      Write-Host "         Remove it: az dns-resolver forwarding-rule delete -g $ResourceGroup --forwarding-ruleset-name $RulesetName -n '$($wildcardRule.name)'" -ForegroundColor Yellow
      $allValid = $false
    }
  }

  # Ruleset linked to spoke
  if ($rulesetValid) {
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $rulesetLinks = az dns-resolver vnet-link list -g $ResourceGroup --forwarding-ruleset-name $RulesetName -o json 2>$null | ConvertFrom-Json
    $ErrorActionPreference = $oldEP
    $rulesetLinkValid = ($rulesetLinks -and $rulesetLinks.Count -gt 0)
    Write-Validation -Check "Ruleset linked to spoke VNet" -Passed $rulesetLinkValid
    if (-not $rulesetLinkValid) { $allValid = $false }
  }

  # Private DNS Zone
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $zone = az network private-dns zone show -g $ResourceGroup -n $DnsZoneName -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP
  $zoneValid = ($null -ne $zone)
  Write-Validation -Check "Private DNS Zone exists" -Passed $zoneValid -Details $DnsZoneName
  if (-not $zoneValid) { $allValid = $false }

  # app A record
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $appRecord = az network private-dns record-set a show -g $ResourceGroup --zone-name $DnsZoneName -n "app" -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP
  $appRecordValid = ($null -ne $appRecord -and $appRecord.aRecords.Count -gt 0)
  Write-Validation -Check "A record exists (app.internal.lab)" -Passed $appRecordValid `
    -Details "IP: $($appRecord.aRecords[0].ipv4Address)"
  if (-not $appRecordValid) { $allValid = $false }

  # Test VM
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $vm = az vm show -g $ResourceGroup -n $VmSpokeName -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP
  $vmValid = ($null -ne $vm)
  Write-Validation -Check "Test VM exists (spoke)" -Passed $vmValid -Details $VmSpokeName
  if (-not $vmValid) { $allValid = $false }

  # Tags
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $rg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP
  $tagsValid = ($rg.tags.project -eq "azure-labs" -and $rg.tags.lab -eq "lab-008")
  Write-Validation -Check "Tags applied correctly" -Passed $tagsValid -Details "project=azure-labs, lab=lab-008"
  if (-not $tagsValid) { $allValid = $false }

  # Resolution path summary
  Write-Host ""
  Write-Host "DNS Resolution Path (spoke VM):" -ForegroundColor Yellow
  Write-Host "  Query: app.internal.lab" -ForegroundColor Gray
  Write-Host "  1. Spoke VM -> Azure DNS (168.63.129.16)" -ForegroundColor Gray
  Write-Host "  2. Azure DNS sees ruleset linked to spoke VNet" -ForegroundColor Gray
  Write-Host "  3. Rule matches 'internal.lab.' -> forwards to inbound EP ($resolvedInboundIp:53)" -ForegroundColor Gray
  Write-Host "  4. Inbound EP -> Azure resolves against private zone" -ForegroundColor Gray
  Write-Host "  5. Returns: 10.80.1.10" -ForegroundColor Gray

  # Cross-VNet DNS test via Run-Command
  Write-Host ""
  Write-Host "Attempting cross-VNet DNS validation from spoke VM via Run-Command..." -ForegroundColor Yellow
  Write-Host "  (Validates the full forwarding path: spoke -> ruleset -> inbound EP -> zone)" -ForegroundColor DarkGray

  $testScript008 = "nslookup app.$DnsZoneName 168.63.129.16 ; echo '###' ; nslookup azure.microsoft.com ; echo '###' ; cat /etc/resolv.conf"

  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $runCmdResult = az vm run-command invoke `
    -g $ResourceGroup -n $VmSpokeName `
    --command-id RunShellScript `
    --scripts $testScript008 `
    -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP

  if ($runCmdResult -and $runCmdResult.value -and $runCmdResult.value.Count -gt 0) {
    $rawOutput = $runCmdResult.value[0].message
    $sections  = $rawOutput -split '###'

    $appOutput     = if ($sections.Count -ge 1) { $sections[0].Trim() } else { "" }
    $publicOutput  = if ($sections.Count -ge 2) { $sections[1].Trim() } else { "" }
    $resolvOutput  = if ($sections.Count -ge 3) { $sections[2].Trim() } else { "" }

    $appResolved      = ($appOutput    -match "10\.80\.1\.10")
    $publicResolved   = ($publicOutput -match "Address" -and $publicOutput -notmatch "SERVFAIL")
    $platformResolver = ($resolvOutput -match "168\.63\.129\.16")

    Write-Validation -Check "Cross-VNet: app.internal.lab resolves to 10.80.1.10" -Passed $appResolved `
      -Details "via ruleset -> inbound EP -> private zone"
    Write-Validation -Check "Azure DNS unbroken: azure.microsoft.com resolves (no wildcard deny)" -Passed $publicResolved
    Write-Validation -Check "Platform resolver 168.63.129.16 present in resolv.conf" -Passed $platformResolver

    if (-not $appResolved)    { $allValid = $false }
    if (-not $publicResolved) { $allValid = $false }
  } else {
    Write-Host "  [WARN] Run-Command did not return output (VM may still be booting or peering settling)." -ForegroundColor Yellow
    Write-Host "         Re-run manually after ~2 min:" -ForegroundColor DarkGray
    Write-Host "         az vm run-command invoke -g $ResourceGroup -n $VmSpokeName --command-id RunShellScript --scripts 'nslookup app.internal.lab'" -ForegroundColor DarkGray
  }

  $phase2Elapsed = Get-ElapsedTime -StartTime $phase2Start
  $baseStatus = if ($allValid) { "PASS" } else { "PARTIAL" }
  Write-Host ""
  Write-Host "  Base validation status: $baseStatus" -ForegroundColor $(if ($allValid) { "Green" } else { "Yellow" })
  Write-Log "Phase 2 completed in $phase2Elapsed — Base: $baseStatus" "SUCCESS"
}

# ============================================
# PHASE 3: Mode-specific execution
# ============================================
Write-Phase -Number 3 -Title "Mode: $Mode"

$modeResults = $null

if ($SkipTests) {
  Write-Host "  [SKIP] -SkipTests flag set — skipping mode phase." -ForegroundColor Yellow
  Write-Log "Phase 3 skipped (-SkipTests)" "WARN"
} elseif ($Mode -eq "Base") {
  Write-Host "  Mode=Base: no additional phases to run." -ForegroundColor DarkGray
  Write-Host "  Re-run with -Mode StickyBlock or -Mode ForwardingVariants for extended testing." -ForegroundColor DarkGray

} elseif ($Mode -eq "StickyBlock") {
  Write-Host "  Running StickyBlock test harness..." -ForegroundColor Yellow
  Write-Host "  This tests DNS Security Policy (or forwarding rule) cache persistence behavior." -ForegroundColor DarkGray
  Write-Host ""

  $phase3Start = Get-Date
  $stickyScript = Join-Path $ScriptsDir "test-stickyblock.ps1"

  if (-not (Test-Path $stickyScript)) {
    Write-Host "  [FAIL] test-stickyblock.ps1 not found at: $stickyScript" -ForegroundColor Red
  } else {
    # If inbound IP wasn't set yet from deployment outputs, fall back to resolved value
    $effectiveInboundIp = if ($resolvedInboundIp -and $resolvedInboundIp -ne "unknown") { $resolvedInboundIp } else { $inboundIp }

    $ErrorActionPreference = "Continue"
    try {
      $modeResults = & $stickyScript `
        -ResourceGroup $ResourceGroup `
        -VmName $VmSpokeName `
        -RulesetName $RulesetName `
        -InboundIp $effectiveInboundIp `
        -Location $Location `
        -ZoneName $DnsZoneName `
        -OutputPath ""
    } catch {
      Write-Host "  [FAIL] StickyBlock mode unavailable (feature not supported in region/subscription)" -ForegroundColor Red
      Write-Host "         Error: $_" -ForegroundColor DarkGray
      $modeResults = [pscustomobject]@{ error = $_.ToString(); status = "unavailable" }
    }
    $ErrorActionPreference = "Stop"
  }

  $phase3Elapsed = Get-ElapsedTime -StartTime $phase3Start
  Write-Log "Phase 3 (StickyBlock) completed in $phase3Elapsed" "SUCCESS"

} elseif ($Mode -eq "ForwardingVariants") {
  Write-Host "  Running ForwardingVariants test harness..." -ForegroundColor Yellow
  Write-Host "  This tests adding/removing forwarding rules and VNet links safely." -ForegroundColor DarkGray
  Write-Host ""

  $phase3Start = Get-Date
  $variantsScript = Join-Path $ScriptsDir "test-forwarding-variants.ps1"

  if (-not (Test-Path $variantsScript)) {
    Write-Host "  [FAIL] test-forwarding-variants.ps1 not found at: $variantsScript" -ForegroundColor Red
  } else {
    $effectiveInboundIp = if ($resolvedInboundIp -and $resolvedInboundIp -ne "unknown") { $resolvedInboundIp } else { $inboundIp }
    $effectiveHubVnetId = if ($hubVnetId) { $hubVnetId } else {
      az network vnet show -g $ResourceGroup -n $HubVnetName --query id -o tsv 2>$null
    }

    $ErrorActionPreference = "Continue"
    try {
      $modeResults = & $variantsScript `
        -ResourceGroup $ResourceGroup `
        -VmName $VmSpokeName `
        -RulesetName $RulesetName `
        -HubVnetId $effectiveHubVnetId `
        -InboundIp $effectiveInboundIp `
        -ZoneName $DnsZoneName `
        -OutputPath ""
    } catch {
      Write-Host "  [FAIL] ForwardingVariants mode error: $_" -ForegroundColor Red
      $modeResults = [pscustomobject]@{ error = $_.ToString(); status = "failed" }
    }
    $ErrorActionPreference = "Stop"
  }

  $phase3Elapsed = Get-ElapsedTime -StartTime $phase3Start
  Write-Log "Phase 3 (ForwardingVariants) completed in $phase3Elapsed" "SUCCESS"
}

# ============================================
# PHASE 4: Write Outputs + Evidence Artifacts
# ============================================
Write-Phase -Number 4 -Title "Outputs + Evidence Artifacts"
$phase4Start  = Get-Date
$totalElapsed = Get-ElapsedTime -StartTime $deploymentStartTime

$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vmPrivateIp = az vm list-ip-addresses -g $ResourceGroup -n $VmSpokeName `
  --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv 2>$null
$ErrorActionPreference = $oldEP

# Ensure we have resolvedInboundIp even if validation was skipped
if (-not $resolvedInboundIp) { $resolvedInboundIp = $inboundIp }
# Ensure serial console URL is always defined (set from Bicep output in Phase 1)
if (-not $vmSerialConsoleUrl) { $vmSerialConsoleUrl = "" }

Ensure-Directory $DataDir

# --- outputs.json (base infra snapshot) ---
$outputs = [pscustomobject]@{
  metadata = [pscustomobject]@{
    lab             = "lab-008"
    mode            = $Mode
    skipTests       = $SkipTests.IsPresent
    deployedAt      = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    deploymentTime  = $totalElapsed
    status          = if ($allValid) { "PASS" } else { "PARTIAL" }
    bicepDeployment = $DeploymentName
    tags            = @{
      project       = "azure-labs"
      lab           = "lab-008"
      owner         = $Owner
      environment   = "lab"
      "cost-center" = "learning"
    }
  }
  azure = [pscustomobject]@{
    subscriptionId   = $SubscriptionId
    subscriptionName = $subName
    location         = $Location
    resourceGroup    = $ResourceGroup
    hubVnet = [pscustomobject]@{
      name   = $HubVnetName
      cidr   = "10.80.0.0/16"
      id     = $hubVnetId
    }
    spokeVnet = [pscustomobject]@{
      name   = $SpokeVnetName
      cidr   = "10.81.0.0/16"
    }
    dnsResolver = [pscustomobject]@{
      name             = $ResolverName
      inboundEndpoint  = [pscustomobject]@{
        name = $InboundEpName
        ip   = $resolvedInboundIp
      }
      outboundEndpoint = [pscustomobject]@{
        name = $OutboundEpName
      }
    }
    forwardingRuleset = [pscustomobject]@{
      name  = $RulesetName
      rules = @("internal.lab. -> inbound EP", "onprem.example.com. -> 10.0.0.1")
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
    vm = [pscustomobject]@{
      name             = $VmSpokeName
      vnet             = $SpokeVnetName
      privateIp        = $vmPrivateIp
      noPublicIp       = $true
      serialConsoleUrl = $vmSerialConsoleUrl
      loginUser        = $AdminUser
      dnsToolsInstalled = @("dig", "nslookup", "ping")
    }
  }
  validationTests = [pscustomobject]@{
    fromSpokeVm = @(
      "nslookup app.internal.lab",
      "dig app.internal.lab",
      "nslookup app.internal.lab $resolvedInboundIp"
    )
    viaRunCommand = @(
      "az vm run-command invoke -g $ResourceGroup -n $VmSpokeName --command-id RunShellScript --scripts 'nslookup app.internal.lab'",
      "az vm run-command invoke -g $ResourceGroup -n $VmSpokeName --command-id RunShellScript --scripts 'dig app.internal.lab'"
    )
    expected = @(
      "app.internal.lab -> 10.80.1.10",
      "Azure DNS (168.63.129.16) routes via ruleset -> inbound EP -> private zone"
    )
  }
}

$outputs | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputsPath -Encoding UTF8
Write-Validation -Check "outputs.json written" -Passed $true -Details $OutputsPath

# --- test-results.json (mode + evidence) ---
$testResults = [pscustomobject]@{
  mode        = $Mode
  skipTests   = $SkipTests.IsPresent
  base        = [pscustomobject]@{
    status    = if ($SkipTests) { "skipped" } elseif ($allValid) { "PASS" } else { "PARTIAL" }
    allChecks = $allValid
  }
  modeResults = $modeResults
  notes       = switch ($Mode) {
    "Base"               { "Base deployment only. Run with -Mode StickyBlock or -Mode ForwardingVariants for extended tests." }
    "StickyBlock"        { "DNS Security Policy (or forwarding rule redirect) applied and removed. Check modeResults.persistenceDetected for cache behavior." }
    "ForwardingVariants" { "Forwarding rule variants applied and cleaned up. See modeResults.variants for per-variant outcomes." }
  }
  timestamps  = [pscustomobject]@{
    started   = $deploymentStartTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
    completed = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    elapsed   = $totalElapsed
  }
}

$testResults | ConvertTo-Json -Depth 15 | Set-Content -Path $TestResultsPath -Encoding UTF8
Write-Validation -Check "test-results.json written" -Passed $true -Details $TestResultsPath

# ============================================
# Summary
# ============================================
Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "DEPLOYMENT SUMMARY" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host ""
Write-Host "Total deployment time:  $totalElapsed" -ForegroundColor White
Write-Host "Mode:                   $Mode" -ForegroundColor White
Write-Host "Resource Group:         $ResourceGroup" -ForegroundColor Gray
Write-Host "Location:               $Location" -ForegroundColor Gray
Write-Host ""
Write-Host "Hub VNet:               $HubVnetName (10.80.0.0/16)" -ForegroundColor Gray
Write-Host "Spoke VNet:             $SpokeVnetName (10.81.0.0/16)" -ForegroundColor Gray
Write-Host "DNS Private Resolver:   $ResolverName" -ForegroundColor Gray
Write-Host "  Inbound endpoint IP:  $resolvedInboundIp" -ForegroundColor Gray
Write-Host "Forwarding Ruleset:     $RulesetName (linked to spoke)" -ForegroundColor Gray
Write-Host "Private DNS Zone:       $DnsZoneName -> hub" -ForegroundColor Gray
Write-Host "A record:               app.internal.lab -> 10.80.1.10" -ForegroundColor Gray
Write-Host "Test VM (spoke):        $VmSpokeName (IP: $vmPrivateIp)" -ForegroundColor Gray
Write-Host ""
Write-Host "Serial Console access (no NSG/public IP needed):" -ForegroundColor Yellow
Write-Host "  Portal: $vmSerialConsoleUrl" -ForegroundColor Cyan
Write-Host "  Login:  $AdminUser / <password you provided>" -ForegroundColor Gray
Write-Host "  DNS tools pre-installed: dig, nslookup, ping" -ForegroundColor Gray
Write-Host ""
Write-Host "Quick DNS tests from serial console:" -ForegroundColor Yellow
Write-Host "  dig app.internal.lab                    # resolves via ruleset -> inbound EP -> zone" -ForegroundColor Gray
Write-Host "  nslookup app.internal.lab               # same, alternate tool" -ForegroundColor Gray
Write-Host "  dig app.internal.lab $inboundIp         # query inbound endpoint directly" -ForegroundColor Gray
Write-Host "  resolvectl status                       # show which DNS server the VM is using" -ForegroundColor Gray
Write-Host ""

if ($SkipTests) {
  Write-Host "STATUS: INFRA-ONLY (tests skipped)" -ForegroundColor Yellow
} elseif ($allValid) {
  Write-Host "STATUS: PASS" -ForegroundColor Green
  Write-Host "  All base resources validated successfully." -ForegroundColor Green
} else {
  Write-Host "STATUS: PARTIAL" -ForegroundColor Yellow
  Write-Host "  Some validations failed. Check above for details." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Outputs saved to:  $OutputsPath" -ForegroundColor Gray
Write-Host "Results saved to:  $TestResultsPath" -ForegroundColor Gray
Write-Host "Log saved to:      $script:LogFile" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  - DNS test (Run-Command from spoke VM):" -ForegroundColor Gray
Write-Host "    az vm run-command invoke -g $ResourceGroup -n $VmSpokeName \" -ForegroundColor Gray
Write-Host "      --command-id RunShellScript --scripts 'nslookup app.internal.lab'" -ForegroundColor Gray
Write-Host "  - View forwarding rules:" -ForegroundColor Gray
Write-Host "    az dns-resolver forwarding-rule list -g $ResourceGroup --forwarding-ruleset-name $RulesetName -o table" -ForegroundColor Gray
Write-Host "  - Run StickyBlock mode:         .\deploy.ps1 -Mode StickyBlock -AdminPassword <pw>" -ForegroundColor Gray
Write-Host "  - Run ForwardingVariants mode:  .\deploy.ps1 -Mode ForwardingVariants -AdminPassword <pw>" -ForegroundColor Gray
Write-Host "  - Cost check:  .\..\..\tools\cost-check.ps1 -Lab lab-008" -ForegroundColor Gray
Write-Host "  - Cleanup:     .\destroy.ps1" -ForegroundColor Gray
Write-Host ""

$phase4Elapsed = Get-ElapsedTime -StartTime $phase4Start
Write-Log "Phase 4 completed in $phase4Elapsed" "SUCCESS"
Write-Log "Deployment completed | Mode=$Mode Status=$(if ($allValid) { 'PASS' } else { 'PARTIAL' })" "SUCCESS"
