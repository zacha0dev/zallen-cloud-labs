# labs/lab-008-azure-dns-private-resolver/scripts/test-forwarding-variants.ps1
# ForwardingVariants mode — tests safe, minimal forwarding rule variations
#
# Variants:
#   A — Conditional forward for a second private suffix (variant-a.lab -> inbound EP)
#   B — Add a temporary VNet link to hub VNet for the ruleset, test resolution, then remove it
#
# Each variant:
#   - Applies the change
#   - Queries a test record
#   - Records result (PASS/FAIL + raw output)
#   - Reverts the change
#
# Usage: Called from deploy.ps1 -Mode ForwardingVariants
#
# Parameters:
#   .\test-forwarding-variants.ps1 `
#     -ResourceGroup rg-lab-008-dns-resolver `
#     -VmName vm-spoke-008 `
#     -RulesetName ruleset-008 `
#     -HubVnetId /subscriptions/.../vnet-hub-008 `
#     -InboundIp 10.80.2.4 `
#     -OutputPath .data/lab-008/test-results.json

[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$ResourceGroup,
  [Parameter(Mandatory)][string]$VmName,
  [Parameter(Mandatory)][string]$RulesetName,
  [Parameter(Mandatory)][string]$HubVnetId,
  [Parameter(Mandatory)][string]$InboundIp,
  [string]$ZoneName         = "internal.lab",
  [string]$OutputPath       = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptsDir = $PSScriptRoot
$testDnsScript = Join-Path $ScriptsDir "test-dns.ps1"

function Write-VariantPhase {
  param([string]$Title)
  Write-Host ""
  Write-Host "  -- ForwardingVariants: $Title --" -ForegroundColor Cyan
}

function Invoke-VmCmd {
  param([string]$Script)
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $r = az vm run-command invoke `
    -g $ResourceGroup -n $VmName `
    --command-id RunShellScript `
    --scripts $Script `
    -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP
  if ($r -and $r.value) { return $r.value[0].message } else { return $null }
}

function Run-DnsTest {
  param([string]$Label, [string]$QueryName, [int]$Iterations = 2)
  if (Test-Path $testDnsScript) {
    return & $testDnsScript `
      -ResourceGroup $ResourceGroup -VmName $VmName `
      -QueryName $QueryName -QueryType A `
      -ResolverIp $InboundIp `
      -Iterations $Iterations -SleepSeconds 2 `
      -Label $Label
  } else {
    $raw = Invoke-VmCmd -Script "nslookup $QueryName $InboundIp 2>&1"
    return [pscustomobject]@{
      label   = $Label
      raw     = $raw
      summary = [pscustomobject]@{ resolved = ($raw -match "Address:") }
    }
  }
}

$results = [ordered]@{
  startedAt   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
  variants    = [ordered]@{}
}

# ============================================
# VARIANT A: Conditional forward for a second suffix
# Add a forwarding rule for "variant-a.lab." pointing to the same inbound endpoint.
# Create a matching private DNS zone record to validate resolution.
# Then remove both.
# ============================================
Write-VariantPhase "Variant A  -  Conditional forward for additional suffix (variant-a.lab)"

$variantAResult = [ordered]@{
  description = "Add forwarding rule for variant-a.lab. -> inbound endpoint; validate resolution; remove"
  ruleCreated = $false
  zoneName    = "variant-a.lab"
  zoneCreated = $false
  queryResult = $null
  cleaned     = $false
}

# Create private DNS zone for variant-a.lab
Write-Host "    Creating private DNS zone: variant-a.lab" -ForegroundColor DarkGray
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$zoneA = az network private-dns zone create `
  -g $ResourceGroup -n "variant-a.lab" `
  --output json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
if ($zoneA -and $zoneA.id) {
  $variantAResult.zoneCreated = $true
  Write-Host "    [PASS] Zone created: variant-a.lab" -ForegroundColor Green

  # Link zone to hub VNet (same pattern as internal.lab)
  $hubVnetName = ($HubVnetId -split "/")[-1]
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  az network private-dns link vnet create `
    -g $ResourceGroup -n "link-hub-variant-a" `
    --zone-name "variant-a.lab" `
    --virtual-network $HubVnetId `
    --registration-enabled false `
    --output none 2>$null
  $ErrorActionPreference = $oldEP

  # Add a test A record
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  az network private-dns record-set a add-record `
    -g $ResourceGroup --zone-name "variant-a.lab" `
    --record-set-name "test" --ipv4-address "10.80.1.98" `
    --output none 2>$null
  $ErrorActionPreference = $oldEP
  Write-Host "    [PASS] A record: test.variant-a.lab -> 10.80.1.98" -ForegroundColor Green
}

# Add forwarding rule for variant-a.lab -> inbound endpoint
Write-Host "    Adding forwarding rule: variant-a.lab. -> $InboundIp" -ForegroundColor DarkGray
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$ruleA = az dns-resolver forwarding-rule create `
  -g $ResourceGroup `
  --forwarding-ruleset-name $RulesetName `
  -n "rule-variant-a-lab" `
  --domain-name "variant-a.lab." `
  --target-dns-servers "[{\"ipAddress\":\"$InboundIp\",\"port\":53}]" `
  --forwarding-rule-state Enabled `
  --output json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if ($ruleA -and $ruleA.id) {
  $variantAResult.ruleCreated = $true
  Write-Host "    [PASS] Forwarding rule created: rule-variant-a-lab" -ForegroundColor Green
  Start-Sleep -Seconds 5  # propagation

  # Query test.variant-a.lab from spoke VM
  $queryA = Run-DnsTest -Label "variant-a-query" -QueryName "test.variant-a.lab" -Iterations 2
  $variantAResult.queryResult = $queryA

  # Remove forwarding rule
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  az dns-resolver forwarding-rule delete `
    -g $ResourceGroup --forwarding-ruleset-name $RulesetName `
    -n "rule-variant-a-lab" --yes 2>$null
  $ErrorActionPreference = $oldEP
  Write-Host "    [PASS] Forwarding rule removed" -ForegroundColor Green
} else {
  Write-Host "    [FAIL] Could not create forwarding rule for Variant A" -ForegroundColor Yellow
  $variantAResult.queryResult = $null
}

# Remove zone and link
if ($variantAResult.zoneCreated) {
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  az network private-dns link vnet delete `
    -g $ResourceGroup -n "link-hub-variant-a" --zone-name "variant-a.lab" --yes 2>$null
  az network private-dns record-set a delete `
    -g $ResourceGroup --zone-name "variant-a.lab" -n "test" --yes 2>$null
  az network private-dns zone delete `
    -g $ResourceGroup -n "variant-a.lab" --yes 2>$null
  $ErrorActionPreference = $oldEP
  $variantAResult.cleaned = $true
  Write-Host "    [PASS] Zone variant-a.lab cleaned up" -ForegroundColor Green
}

$results.variants["variant_a"] = $variantAResult

# ============================================
# VARIANT B: Add/remove ruleset VNet link to hub VNet, test behavior
# The hub VNet already has a direct zone link (internal.lab -> hub).
# Adding the ruleset to hub means hub VMs would use forwarding rules too.
# We add the link, verify the baseline record still resolves, then remove it.
# ============================================
Write-VariantPhase "Variant B  -  Temporary ruleset link to hub VNet"

$variantBResult = [ordered]@{
  description    = "Link forwarding ruleset to hub VNet; verify app.internal.lab still resolves; unlink"
  hubLinkCreated = $false
  queryResult    = $null
  cleaned        = $false
}

Write-Host "    Creating ruleset VNet link to hub VNet..." -ForegroundColor DarkGray
$hubVnetName = ($HubVnetId -split "/")[-1]
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$linkB = az dns-resolver vnet-link create `
  -g $ResourceGroup `
  --forwarding-ruleset-name $RulesetName `
  -n "link-hub-variant-b" `
  --id $HubVnetId `
  --output json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if ($linkB -and $linkB.id) {
  $variantBResult.hubLinkCreated = $true
  Write-Host "    [PASS] Ruleset linked to hub VNet" -ForegroundColor Green
  Start-Sleep -Seconds 5

  # From spoke VM, verify app.internal.lab still resolves correctly
  $queryB = Run-DnsTest -Label "variant-b-hub-linked" -QueryName "app.internal.lab" -Iterations 2
  $variantBResult.queryResult = $queryB

  # Remove the hub VNet link
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  az dns-resolver vnet-link delete `
    -g $ResourceGroup `
    --forwarding-ruleset-name $RulesetName `
    -n "link-hub-variant-b" --yes 2>$null
  $ErrorActionPreference = $oldEP
  $variantBResult.cleaned = $true
  Write-Host "    [PASS] Hub VNet ruleset link removed" -ForegroundColor Green
} else {
  Write-Host "    [WARN] Could not create hub VNet ruleset link for Variant B (may already exist or permission denied)" -ForegroundColor Yellow
}

$results.variants["variant_b"] = $variantBResult

# ============================================
# Summary
# ============================================
$results.completedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")

Write-Host ""
Write-Host "  ForwardingVariants Summary:" -ForegroundColor Cyan
$vA = $results.variants.variant_a
$vB = $results.variants.variant_b
Write-Host "    Variant A (extra suffix rule): ruleCreated=$($vA.ruleCreated)  resolved=$($vA.queryResult.summary.resolved)  cleaned=$($vA.cleaned)" -ForegroundColor Gray
Write-Host "    Variant B (hub VNet link):     hubLinked=$($vB.hubLinkCreated)  resolved=$($vB.queryResult.summary.resolved)  cleaned=$($vB.cleaned)" -ForegroundColor Gray

if ($OutputPath) {
  [pscustomobject]$results | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8
  Write-Host "  Evidence written to: $OutputPath" -ForegroundColor DarkGray
}

return [pscustomobject]$results
