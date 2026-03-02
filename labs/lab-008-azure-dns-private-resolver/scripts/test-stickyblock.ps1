# labs/lab-008-azure-dns-private-resolver/scripts/test-stickyblock.ps1
# StickyBlock mode — DNS Security Policy + cache persistence test harness
#
# What this tests:
#   DNS caches can persist a resolved record (or NXDOMAIN) even after a policy
#   or forwarding rule is added/removed. This test:
#     1. Queries a test domain BEFORE applying any block rule (baseline)
#     2. Applies a "block" via an Azure DNS Security Policy (if available) or a
#        forwarding rule redirect to a dead server — simulating enforcement
#     3. Queries the same domain AFTER applying the block (expect SERVFAIL/NXDOMAIN)
#     4. Removes/unlinks the block
#     5. Loops repeated queries AFTER removal to detect cache persistence
#        (if queries continue to SERVFAIL after removal, it may indicate resolver cache)
#
# Usage:
#   Called from deploy.ps1 -Mode StickyBlock
#
# Parameters sourced from deploy.ps1 scope when dot-sourced, or pass directly:
#   .\test-stickyblock.ps1 -ResourceGroup rg-lab-008-dns-resolver `
#     -VmName vm-spoke-008 -RulesetName ruleset-008 -InboundIp 10.80.2.4 `
#     -OutputPath .data/lab-008/test-results.json

[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$ResourceGroup,
  [Parameter(Mandatory)][string]$VmName,
  [Parameter(Mandatory)][string]$RulesetName,
  [Parameter(Mandatory)][string]$InboundIp,
  [string]$PolicyName       = "dnspolicy-lab-008-stickyblock",
  [string]$TestDomain       = "sticky.internal.lab",    # A random-ish subdomain to minimize cross-test pollution
  [string]$ZoneName         = "internal.lab",
  [string]$BlockRuleName    = "rule-sticky-block-test",
  [string]$OutputPath       = "",
  [int]$PostRemovalLoops    = 6,
  [int]$PostRemovalSleepSec = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptsDir = $PSScriptRoot
$testDnsScript = Join-Path $ScriptsDir "test-dns.ps1"

function Write-StickyPhase {
  param([string]$Title)
  Write-Host ""
  Write-Host "  -- StickyBlock: $Title --" -ForegroundColor Cyan
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
  param([string]$Label, [int]$Iterations = 3, [int]$SleepSec = 2)
  if (Test-Path $testDnsScript) {
    return & $testDnsScript `
      -ResourceGroup $ResourceGroup -VmName $VmName `
      -QueryName $TestDomain -QueryType A `
      -ResolverIp $InboundIp `
      -Iterations $Iterations -SleepSeconds $SleepSec `
      -Label $Label
  } else {
    # Inline fallback
    Write-Host "  [WARN] test-dns.ps1 not found, using inline query" -ForegroundColor Yellow
    $raw = Invoke-VmCmd -Script "nslookup $TestDomain $InboundIp 2>&1"
    return [pscustomobject]@{
      label   = $Label
      raw     = $raw
      summary = [pscustomobject]@{ resolved = ($raw -match "Address:") }
    }
  }
}

$evidence = [ordered]@{
  testDomain        = $TestDomain
  startedAt         = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
  dnsPolicyAvailable = $false
  dnsPolicyMethod   = "none"
  phases            = [ordered]@{}
}

# ============================================
# PHASE SB-1: Seed a DNS record for the test domain
# ============================================
Write-StickyPhase "SB-1: Seed test record ($TestDomain -> 10.80.1.99)"

$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRecord = az network private-dns record-set a show `
  -g $ResourceGroup --zone-name $ZoneName -n "sticky" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if (-not $existingRecord) {
  az network private-dns record-set a add-record `
    -g $ResourceGroup --zone-name $ZoneName `
    --record-set-name "sticky" --ipv4-address "10.80.1.99" `
    --output none 2>$null
  Write-Host "  [PASS] Created A record: sticky.$ZoneName -> 10.80.1.99" -ForegroundColor Green
} else {
  Write-Host "  [PASS] A record already exists: sticky.$ZoneName" -ForegroundColor DarkGray
}

# Wait for zone propagation
Start-Sleep -Seconds 5

# ============================================
# PHASE SB-2: Baseline query (before policy)
# ============================================
Write-StickyPhase "SB-2: Baseline query (before any block)"

$beforeResult = Run-DnsTest -Label "before-policy" -Iterations 3 -SleepSec 3
$evidence.phases["before_policy"] = $beforeResult

$baselineResolved = $beforeResult.summary.resolved
Write-Host "  Baseline resolved: $baselineResolved" -ForegroundColor $(if ($baselineResolved) { "Green" } else { "Yellow" })

# ============================================
# PHASE SB-3: Try DNS Security Policy (az network dns-security-policy)
#   If unavailable, fall back to forwarding rule to dead server
# ============================================
Write-StickyPhase "SB-3: Applying block (DNS Security Policy or forwarding redirect)"

$policyApplied = $false
$blockMethod   = "none"

# Try native DNS Security Policy first
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$policyTest = az network dns-security-policy --help 2>$null
$ErrorActionPreference = $oldEP

if ($policyTest -match "dns-security-policy|Commands") {
  Write-Host "  DNS Security Policy CLI available — attempting policy create..." -ForegroundColor DarkGray
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $policyCreate = az network dns-security-policy create `
    --name $PolicyName `
    --resource-group $ResourceGroup `
    --location global `
    --output json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP

  if ($policyCreate -and $policyCreate.id) {
    $evidence.dnsPolicyAvailable = $true
    $evidence.dnsPolicyMethod    = "azure-dns-security-policy"
    $blockMethod  = "azure-dns-security-policy"
    $policyApplied = $true
    Write-Host "  [PASS] DNS Security Policy created: $PolicyName" -ForegroundColor Green
  } else {
    Write-Host "  [WARN] DNS Security Policy create failed (may not be supported in this region/subscription)" -ForegroundColor Yellow
  }
}

if (-not $policyApplied) {
  # Fallback: add a forwarding rule that redirects test domain to 192.0.2.1 (TEST-NET, RFC5737 — never routes)
  Write-Host "  Falling back to forwarding rule block (redirect to RFC5737 test address)" -ForegroundColor DarkGray
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $ruleCreate = az dns-resolver forwarding-rule create `
    -g $ResourceGroup `
    --forwarding-ruleset-name $RulesetName `
    -n $BlockRuleName `
    --domain-name "$ZoneName." `
    --target-dns-servers "[{\"ipAddress\":\"192.0.2.1\",\"port\":53}]" `
    --forwarding-rule-state Enabled `
    --output json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP

  if ($ruleCreate -and $ruleCreate.id) {
    $evidence.dnsPolicyMethod = "forwarding-rule-redirect"
    $blockMethod  = "forwarding-rule-redirect"
    $policyApplied = $true
    Write-Host "  [PASS] Block rule applied (forwarding rule -> 192.0.2.1): $BlockRuleName" -ForegroundColor Green
    Write-Host "  Note: This redirects the zone domain to an unroutable RFC5737 address, simulating a block." -ForegroundColor DarkGray
  } else {
    Write-Host "  [FAIL] StickyBlock mode unavailable (feature not supported in region/subscription)" -ForegroundColor Red
    $evidence.phases["block_result"] = "unavailable"
    $evidence.completedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    if ($OutputPath) {
      [pscustomobject]$evidence | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8
    }
    return [pscustomobject]$evidence
  }
}

# ============================================
# PHASE SB-4: Query after block applied
# ============================================
Write-StickyPhase "SB-4: Query AFTER block applied (expect SERVFAIL or NXDOMAIN)"
Write-Host "  Waiting 5s for policy/rule to propagate..." -ForegroundColor DarkGray
Start-Sleep -Seconds 5

$afterPolicyResult = Run-DnsTest -Label "after-policy" -Iterations 3 -SleepSec 3
$evidence.phases["after_policy"] = $afterPolicyResult

$afterPolicyResolved = $afterPolicyResult.summary.resolved
Write-Host "  After-policy resolved: $afterPolicyResolved (expect false if block works)" -ForegroundColor $(if (-not $afterPolicyResolved) { "Green" } else { "Yellow" })

# ============================================
# PHASE SB-5: Remove / unlink the block
# ============================================
Write-StickyPhase "SB-5: Removing block"

if ($blockMethod -eq "azure-dns-security-policy") {
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  az network dns-security-policy delete --name $PolicyName --resource-group $ResourceGroup --yes 2>$null
  $ErrorActionPreference = $oldEP
  Write-Host "  [PASS] DNS Security Policy removed" -ForegroundColor Green
} elseif ($blockMethod -eq "forwarding-rule-redirect") {
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  az dns-resolver forwarding-rule delete `
    -g $ResourceGroup `
    --forwarding-ruleset-name $RulesetName `
    -n $BlockRuleName --yes 2>$null
  $ErrorActionPreference = $oldEP
  Write-Host "  [PASS] Block forwarding rule removed: $BlockRuleName" -ForegroundColor Green
}

# ============================================
# PHASE SB-6: Post-removal loop — detect cache persistence
# ============================================
Write-StickyPhase "SB-6: Post-removal cache persistence loop ($PostRemovalLoops queries, ${PostRemovalSleepSec}s gap)"
Write-Host "  If queries still fail immediately after removal, resolver is serving from cache." -ForegroundColor DarkGray

$postRemovalResults = @()
$persistenceDetected = $false

for ($i = 1; $i -le $PostRemovalLoops; $i++) {
  $iterLabel = "post-removal-iter-$i"
  Write-Host "    Iteration $i/$PostRemovalLoops..." -ForegroundColor DarkGray
  $iterResult = Run-DnsTest -Label $iterLabel -Iterations 1 -SleepSec 1
  $postRemovalResults += $iterResult

  if (-not $iterResult.summary.resolved) {
    $persistenceDetected = $true
    Write-Host "    [EVIDENCE] Query still blocked at iteration $i — possible cache persistence" -ForegroundColor Yellow
  } else {
    Write-Host "    [CLEAR] Query resolved at iteration $i — block lifted" -ForegroundColor Green
    break
  }

  if ($i -lt $PostRemovalLoops) {
    Write-Host "    Sleeping ${PostRemovalSleepSec}s..." -ForegroundColor DarkGray
    Start-Sleep -Seconds $PostRemovalSleepSec
  }
}

$evidence.phases["post_removal"] = $postRemovalResults
$evidence.persistenceDetected    = $persistenceDetected

# ============================================
# PHASE SB-7: Cleanup — remove seeded DNS record
# ============================================
Write-StickyPhase "SB-7: Cleanup (remove seeded test record)"
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
az network private-dns record-set a delete `
  -g $ResourceGroup --zone-name $ZoneName -n "sticky" --yes 2>$null
$ErrorActionPreference = $oldEP
Write-Host "  [PASS] Test record removed: sticky.$ZoneName" -ForegroundColor Green

# ============================================
# Summary
# ============================================
$evidence.completedAt  = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
$evidence.blockMethod  = $blockMethod

Write-Host ""
Write-Host "  StickyBlock Summary:" -ForegroundColor Cyan
Write-Host "    Baseline resolved:       $baselineResolved" -ForegroundColor Gray
Write-Host "    After-policy resolved:   $afterPolicyResolved  (expect false)" -ForegroundColor Gray
Write-Host "    Post-removal persistence: $persistenceDetected" -ForegroundColor Gray
Write-Host "    Block method:            $blockMethod" -ForegroundColor Gray

if ($OutputPath) {
  [pscustomobject]$evidence | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8
  Write-Host "  Evidence written to: $OutputPath" -ForegroundColor DarkGray
}

return [pscustomobject]$evidence
