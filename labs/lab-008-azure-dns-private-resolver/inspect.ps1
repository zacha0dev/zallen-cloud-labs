# labs/lab-008-azure-dns-private-resolver/inspect.ps1
# Post-deploy validation for lab-008 (DNS Private Resolver + Forwarding Ruleset)
#
# Runs against an already-deployed lab - no Bicep, no 60s VM-agent wait.
# Use this for fast iteration: deploy once, then re-validate quickly.
#
# Usage:
#   .\lab.ps1 -Inspect lab-008
#   .\inspect.ps1 [-SubscriptionKey <key>]
#
# Checks:
#   1. Resource group + tags
#   2. Hub VNet / Spoke VNet
#   3. VNet peering (Connected)
#   4. DNS Private Resolver + inbound/outbound endpoints
#   5. Forwarding ruleset + rules + VNet link
#   6. Private DNS zone + A record (app.internal.lab)
#   7. Test VM running (spoke)
#   8. Live DNS resolution via VM run-command (getent hosts)

[CmdletBinding()]
param(
  [string]$SubscriptionKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot  = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path
$DataDir  = Join-Path $RepoRoot ".data\lab-008"

. (Join-Path $RepoRoot "scripts\labs-common.ps1")

# ── Lab constants (must match deploy.ps1) ────────────────────────────────────
$ResourceGroup  = "rg-lab-008-dns-resolver"
$HubVnetName    = "vnet-hub-008"
$SpokeVnetName  = "vnet-spoke-008"
$ResolverName   = "dnsresolver-008"
$InboundEpName  = "ep-inbound-008"
$OutboundEpName = "ep-outbound-008"
$RulesetName    = "ruleset-008"
$DnsZoneName    = "internal.lab"
$VmSpokeName    = "vm-spoke-008"
$ExpectedAppIp  = "10.80.1.10"

# ── Helpers ──────────────────────────────────────────────────────────────────
function Write-Section {
  param([string]$Msg)
  Write-Host ""
  Write-Host $Msg -ForegroundColor Cyan
  Write-Host ("-" * $Msg.Length) -ForegroundColor DarkCyan
}

function Write-Pass {
  param([string]$Msg, [string]$Detail = "")
  Write-Host "  [PASS] $Msg" -ForegroundColor Green
  if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
}

function Write-Fail {
  param([string]$Msg, [string]$Detail = "")
  Write-Host "  [FAIL] $Msg" -ForegroundColor Red
  if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
}

function Write-Warn {
  param([string]$Msg, [string]$Detail = "")
  Write-Host "  [WARN] $Msg" -ForegroundColor Yellow
  if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
}

function Write-Info {
  param([string]$Msg)
  Write-Host "  $Msg" -ForegroundColor Gray
}

# ── Header ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Lab 008: DNS Private Resolver - Inspection Report" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "  Resource group : $ResourceGroup" -ForegroundColor Gray
Write-Host "  Run time       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray

# ── Auth ─────────────────────────────────────────────────────────────────────
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null
$subName = az account show --query name -o tsv 2>$null
Write-Host "  Subscription   : $subName" -ForegroundColor Gray

# ── Load outputs.json if available ───────────────────────────────────────────
$outputs = $null
$outputsPath = Join-Path $DataDir "outputs.json"
if (Test-Path $outputsPath) {
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $outputs = Get-Content $outputsPath -Raw 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP
}

$passCount = 0
$failCount = 0

# ── SECTION 1: Resource Group ─────────────────────────────────────────────────
Write-Section "1. Resource Group + Tags"

$rg = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$rg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if ($rg) {
  Write-Pass "Resource group exists" $ResourceGroup
  $passCount++

  $tagsOk = ($rg.tags.project -eq "azure-labs" -and $rg.tags.lab -eq "lab-008")
  if ($tagsOk) {
    Write-Pass "Tags correct" "project=azure-labs, lab=lab-008"
    $passCount++
  } else {
    Write-Fail "Tags missing or incorrect" "project=$($rg.tags.project), lab=$($rg.tags.lab)"
    $failCount++
  }
} else {
  Write-Fail "Resource group not found: $ResourceGroup" "Has the lab been deployed? Run: .\lab.ps1 -Deploy lab-008"
  $failCount++
  Write-Host ""
  Write-Host "Cannot continue - resource group missing." -ForegroundColor Red
  exit 1
}

# ── SECTION 2: VNets + Peering ───────────────────────────────────────────────
Write-Section "2. VNets + Peering"

$hubVnet = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$hubVnet = az network vnet show -g $ResourceGroup -n $HubVnetName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
if ($hubVnet) {
  Write-Pass "Hub VNet exists" "$HubVnetName ($($hubVnet.addressSpace.addressPrefixes -join ', '))"
  $passCount++
} else {
  Write-Fail "Hub VNet not found" $HubVnetName
  $failCount++
}

$spokeVnet = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$spokeVnet = az network vnet show -g $ResourceGroup -n $SpokeVnetName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
if ($spokeVnet) {
  Write-Pass "Spoke VNet exists" "$SpokeVnetName ($($spokeVnet.addressSpace.addressPrefixes -join ', '))"
  $passCount++
} else {
  Write-Fail "Spoke VNet not found" $SpokeVnetName
  $failCount++
}

if ($hubVnet) {
  $peering = $null
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $peering = az network vnet peering show -g $ResourceGroup --vnet-name $HubVnetName -n "peer-hub-to-spoke" -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP
  if ($peering -and $peering.peeringState -eq "Connected") {
    Write-Pass "VNet peering Connected (hub -> spoke)"
    $passCount++
  } else {
    $state = if ($peering) { $peering.peeringState } else { "not found" }
    Write-Fail "VNet peering not Connected" "state: $state"
    $failCount++
  }
}

# ── SECTION 3: DNS Private Resolver ──────────────────────────────────────────
Write-Section "3. DNS Private Resolver"

$resolver = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$resolver = az dns-resolver show -g $ResourceGroup -n $ResolverName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
if ($resolver -and $resolver.provisioningState -eq "Succeeded") {
  Write-Pass "Resolver provisioned" $ResolverName
  $passCount++
} else {
  $state = if ($resolver) { $resolver.provisioningState } else { "not found" }
  Write-Fail "Resolver not ready" "state: $state"
  $failCount++
}

$inboundEp = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$inboundEp = az dns-resolver inbound-endpoint show -g $ResourceGroup --dns-resolver-name $ResolverName -n $InboundEpName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
$inboundIp = if ($inboundEp -and $inboundEp.ipConfigurations) { $inboundEp.ipConfigurations[0].privateIpAddress } else { "" }
if ($inboundEp -and $inboundEp.provisioningState -eq "Succeeded") {
  Write-Pass "Inbound endpoint provisioned" "IP: $inboundIp"
  $passCount++
} else {
  $state = if ($inboundEp) { $inboundEp.provisioningState } else { "not found" }
  Write-Fail "Inbound endpoint not ready" "state: $state"
  $failCount++
}

$outboundEp = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$outboundEp = az dns-resolver outbound-endpoint show -g $ResourceGroup --dns-resolver-name $ResolverName -n $OutboundEpName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
if ($outboundEp -and $outboundEp.provisioningState -eq "Succeeded") {
  Write-Pass "Outbound endpoint provisioned"
  $passCount++
} else {
  $state = if ($outboundEp) { $outboundEp.provisioningState } else { "not found" }
  Write-Fail "Outbound endpoint not ready" "state: $state"
  $failCount++
}

# ── SECTION 4: Forwarding Ruleset ────────────────────────────────────────────
Write-Section "4. Forwarding Ruleset + Rules + VNet Link"

$ruleset = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$ruleset = az dns-resolver forwarding-ruleset show -g $ResourceGroup -n $RulesetName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
if ($ruleset -and $ruleset.provisioningState -eq "Succeeded") {
  Write-Pass "Forwarding ruleset provisioned" $RulesetName
  $passCount++
} else {
  $state = if ($ruleset) { $ruleset.provisioningState } else { "not found" }
  Write-Fail "Forwarding ruleset not ready" "state: $state"
  $failCount++
}

if ($ruleset) {
  $rules = $null
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $rules = az dns-resolver forwarding-rule list --ruleset-name $RulesetName -g $ResourceGroup -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP
  $rules = @($rules)

  $ruleInternal = $rules | Where-Object { $_.name -eq "rule-internal-lab" }
  $ruleOnprem   = $rules | Where-Object { $_.name -eq "rule-onprem-example" }

  if ($ruleInternal) {
    $ruleTargetIp  = $ruleInternal.targetDnsServers[0].ipAddress
    $targetMatches = ($ruleTargetIp -eq $inboundIp) -and ($inboundIp -ne "")
    if ($targetMatches) {
      Write-Pass "Rule: internal.lab. -> inbound EP ($ruleTargetIp)" "domain: $($ruleInternal.domainName)"
      $passCount++
    } else {
      Write-Fail "Rule target IP mismatch" "rule target=$ruleTargetIp  inbound EP=$inboundIp"
      $failCount++
    }
  } else {
    Write-Fail "Forwarding rule 'rule-internal-lab' not found"
    $failCount++
  }

  if ($ruleOnprem) {
    Write-Pass "Rule: onprem.example.com. -> 10.0.0.1" "domain: $($ruleOnprem.domainName)"
    $passCount++
  } else {
    Write-Fail "Forwarding rule 'rule-onprem-example' not found"
    $failCount++
  }

  # Wildcard rule detection - would break Azure platform DNS
  $wildcardRule = $rules | Where-Object { $_.domainName -eq "." -or $_.domainName -eq "'.'"}
  if ($wildcardRule) {
    Write-Fail "Wildcard '.' rule detected - breaks Azure DNS for all VMs in linked VNets" `
      "Remove: az dns-resolver forwarding-rule delete --ruleset-name $RulesetName -g $ResourceGroup -n '$($wildcardRule.name)'"
    $failCount++
  }

  # VNet link to spoke
  $links = $null
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $links = az dns-resolver vnet-link list --ruleset-name $RulesetName -g $ResourceGroup -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP
  $links = @($links)
  if ($links.Count -gt 0) {
    Write-Pass "Ruleset linked to spoke VNet" "$($links.Count) link(s)"
    $passCount++
  } else {
    Write-Fail "No VNet links found on ruleset"
    $failCount++
  }
}

# ── SECTION 5: Private DNS Zone + Record ─────────────────────────────────────
Write-Section "5. Private DNS Zone + A Record"

$zone = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$zone = az network private-dns zone show -g $ResourceGroup -n $DnsZoneName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
if ($zone) {
  Write-Pass "Private DNS Zone exists" $DnsZoneName
  $passCount++
} else {
  Write-Fail "Private DNS Zone not found" $DnsZoneName
  $failCount++
}

$appRecord = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$appRecord = az network private-dns record-set a show -g $ResourceGroup --zone-name $DnsZoneName -n "app" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
$appRecordIp = if ($appRecord -and $appRecord.aRecords -and $appRecord.aRecords.Count -gt 0) { $appRecord.aRecords[0].ipv4Address } else { "" }
if ($appRecord -and $appRecordIp -eq $ExpectedAppIp) {
  Write-Pass "A record: app.$DnsZoneName -> $appRecordIp"
  $passCount++
} else {
  Write-Fail "A record missing or wrong IP" "expected $ExpectedAppIp, got '$appRecordIp'"
  $failCount++
}

# ── SECTION 6: Test VM ───────────────────────────────────────────────────────
Write-Section "6. Test VM (spoke)"

$vm = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vm = az vm show -g $ResourceGroup -n $VmSpokeName --show-details -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
if ($vm) {
  $vmRunning = ($vm.powerState -eq "VM running")
  $stateText = if ($vm.powerState) { $vm.powerState } else { "unknown" }
  if ($vmRunning) {
    Write-Pass "VM running: $VmSpokeName" "private IP: $($vm.privateIps)"
    $passCount++
  } else {
    Write-Warn "VM exists but not running: $VmSpokeName" "power state: $stateText"
  }
} else {
  Write-Fail "Test VM not found" $VmSpokeName
  $failCount++
}

# ── SECTION 7: Live DNS resolution (VM run-command) ──────────────────────────
Write-Section "7. Live DNS Resolution (spoke VM run-command)"
Write-Info "Running getent hosts app.$DnsZoneName from spoke VM..."

$dnsCmd    = "getent hosts app.$DnsZoneName"
$maxTries  = 5
$retryWait = 30
$cleanOut  = ""
$appResolved = $false

for ($attempt = 1; $attempt -le $maxTries; $attempt++) {
  if ($attempt -gt 1) {
    Write-Info "  Retry $attempt of $maxTries (waiting ${retryWait}s)..."
    Start-Sleep -Seconds $retryWait
  }

  $runResult = $null
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $runResult = az vm run-command invoke `
    -g $ResourceGroup -n $VmSpokeName `
    --command-id RunShellScript `
    --scripts $dnsCmd `
    -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP

  if (-not ($runResult -and $runResult.value -and $runResult.value.Count -gt 0)) { continue }

  $raw      = $runResult.value[0].message
  $cleanOut = ($raw -replace '\[stdout\]', '' -replace '\[stderr\]', '').Trim()

  if ($cleanOut -match "This is a sample script") {
    Write-Info "  Extension still initializing (test.sh health check running) - will retry..."
    continue
  }

  $appResolved = ($cleanOut -match [regex]::Escape($ExpectedAppIp))
  break
}

if ($appResolved) {
  $firstLine = ($cleanOut -split "`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1)
  Write-Pass "app.$DnsZoneName resolves to $ExpectedAppIp" $firstLine.Trim()
  Write-Info "  Resolution path: spoke VM -> Azure DNS -> ruleset -> inbound EP -> private zone"
  $passCount++
} elseif ($cleanOut -ne "") {
  Write-Fail "app.$DnsZoneName did NOT resolve to $ExpectedAppIp"
  $failCount++
  Write-Info "  Raw output from VM:"
  $lines = @($cleanOut -split "`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -First 8)
  foreach ($line in $lines) { Write-Info "    $($line.Trim())" }
  Write-Info ""
  Write-Info "  Diagnosis tips:"
  Write-Info "    dig app.$DnsZoneName @$inboundIp   # direct inbound EP query"
  Write-Info "    resolvectl dns                       # confirm upstream = 168.63.129.16"
  Write-Info "    az dns-resolver vnet-link list --ruleset-name $RulesetName -g $ResourceGroup -o table"
} else {
  Write-Warn "Run-command returned no output after $maxTries attempts"
  Write-Info "  VM agent or extension may be busy. Try manually:"
  Write-Info "  az vm run-command invoke -g $ResourceGroup -n $VmSpokeName --command-id RunShellScript --scripts 'getent hosts app.$DnsZoneName'"
}

# ── SUMMARY ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
$total   = $passCount + $failCount
$status  = if ($failCount -eq 0) { "PASS" } else { "FAIL" }
$color   = if ($failCount -eq 0) { "Green" } else { "Red" }
Write-Host "Result: $status  ($passCount passed, $failCount failed, $total total)" -ForegroundColor $color
Write-Host "=================================================" -ForegroundColor Cyan

if ($failCount -eq 0) {
  Write-Host ""
  Write-Host "All checks passed. Lab is healthy and ready for research scenarios." -ForegroundColor Green
  Write-Host ""
  Write-Host "Next steps:" -ForegroundColor Gray
  Write-Host "  .\lab.ps1 -Research lab-008 -Scenario cache-recovery" -ForegroundColor DarkGray
  Write-Host "  .\lab.ps1 -Deploy lab-008 -Mode StickyBlock [-Force]" -ForegroundColor DarkGray
  Write-Host "  .\lab.ps1 -Deploy lab-008 -Mode ForwardingVariants [-Force]" -ForegroundColor DarkGray
} else {
  Write-Host ""
  Write-Host "Some checks failed. Review [FAIL] items above." -ForegroundColor Yellow
  Write-Host "Re-deploy to fix:  .\lab.ps1 -Deploy lab-008" -ForegroundColor DarkGray
}

Write-Host ""
exit $(if ($failCount -eq 0) { 0 } else { 1 })
