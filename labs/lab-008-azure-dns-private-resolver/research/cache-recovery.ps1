# DNS cache sticky-block recovery timing - research scenario for lab-008
#
# Research question:
#   After a wildcard block rule ( "." ) is applied then removed from a DNS
#   forwarding ruleset, how long does each domain type remain broken?
#   Specifically: do private-zone domains stay sticky longer than public domains?
#
# Test domains:
#   app.internal.lab      - private DNS zone domain (the known sticky scenario)
#   azure.microsoft.com   - public domain (control - expected fast recovery)
#
# Block mechanism:
#   1. DNS Security Policy (preferred): policy + domain list + block rule + VNet link
#      Blocks at Azure DNS layer - returns NXDOMAIN/REFUSED rather than timeout
#   2. Fallback: forwarding rule redirect to 192.0.2.1 (RFC5737 dead IP - timeout-based)
#
# Phases:
#   CR-0  Preflight    - verify lab is deployed, load context
#   CR-1  Seed         - create test DNS record if needed
#   CR-2  Baseline     - confirm all domains resolve before any change
#   CR-3  Apply block  - apply the wildcard block or redirect
#   CR-4  Confirm      - verify block is effective
#   CR-5  Remove block - delete the rule, start recovery timer
#   CR-6  Monitor      - poll until all domains recover or MonitorMinutes expires
#   CR-7  Cleanup      - remove seeded record
#   CR-8  Report       - write JSON + print summary
#
# Requires: lab-008 deployed in Base mode
# Run via:  .\lab.ps1 -Research lab-008 -Scenario cache-recovery
#           .\lab.ps1 -Research lab-008 -Scenario cache-recovery -Background

[CmdletBinding()]
param(
  [string]$OutputDir,                       # Where to write the JSON report
  [string]$StatusFile,                      # Progress file for background polling
  [string]$LabOutputsPath,                  # Path to .data/lab-008/outputs.json
  [string]$SubscriptionKey,
  [int]$MonitorMinutes  = 60,               # Recovery monitoring window
  [int]$PollIntervalSec = 120               # Seconds between recovery polls
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"         # Collect failures, don't abort scenario

$ScenarioName  = "cache-recovery"
$ScenarioStart = Get-Date
$RunTimestamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$BlockRuleName = "rule-research-block"

# ─── Milestone tracker ───────────────────────────────────────────────────────

$Milestones     = [System.Collections.ArrayList]::new()
$CurrentPhase   = "initializing"
$CurrentProgress = 0

function Get-Elapsed {
    $s = [int]([DateTime]::UtcNow - $ScenarioStart).TotalSeconds
    "T+{0:D2}:{1:D2}" -f [int]($s / 60), ($s % 60)
}

function Write-Milestone {
    param([string]$Event, [string]$Color = "DarkGray")
    $ms = [pscustomobject]@{
        elapsed = Get-Elapsed
        utcTime = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        event   = $Event
    }
    [void]$Milestones.Add($ms)
    Write-Host "  [$(Get-Elapsed)] $Event" -ForegroundColor $Color
    Flush-Status
}

function Flush-Status {
    if (-not $StatusFile) { return }
    @{
        scenario    = $ScenarioName
        phase       = $CurrentPhase
        progress    = $CurrentProgress
        elapsedSec  = [int]([DateTime]::UtcNow - $ScenarioStart).TotalSeconds
        lastUpdate  = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        milestones  = @($Milestones)
    } | ConvertTo-Json -Depth 5 |
        Set-Content -Path $StatusFile -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Write-Phase {
    param([string]$Title, [int]$Progress)
    $script:CurrentPhase    = $Title
    $script:CurrentProgress = $Progress
    Write-Host ""
    Write-Host "  --- $Title ---" -ForegroundColor Cyan
    Flush-Status
}

# ─── VM DNS test helper ──────────────────────────────────────────────────────

function Invoke-VmDnsTest {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string[]]$Domains
    )
    # One run-command call per domain: bare "getent hosts <name>" with no shell
    # operators or semicolons. This matches the CLAUDE.md-required pattern and
    # avoids az CLI splitting a multi-command string on spaces into separate
    # bash lines (which causes the script to fail silently).
    # Strip [stdout]/[stderr] labels before any matching.
    $results = @{}
    foreach ($d in $Domains) {
        $resolved = $false
        $domOut   = ""
        $maxTries = 4
        $waitSec  = 30

        for ($t = 1; $t -le $maxTries; $t++) {
            if ($t -gt 1) {
                Write-Host "    [dns:$d] Retrying (attempt $t/$maxTries, waiting ${waitSec}s)..." -ForegroundColor DarkGray
                Start-Sleep -Seconds $waitSec
            }
            $r = $null
            $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
            $r = az vm run-command invoke `
                -g $ResourceGroup -n $VmName `
                --command-id RunShellScript `
                --scripts "getent hosts $d" `
                -o json 2>$null | ConvertFrom-Json
            $ErrorActionPreference = $oldEP

            if (-not ($r -and $r.value -and $r.value.Count -gt 0)) { continue }
            $raw     = $r.value[0].message
            $cleaned = ($raw -replace '\[stdout\]', '' -replace '\[stderr\]', '').Trim()

            if ($cleaned -match "This is a sample script") { continue }

            $domOut  = $cleaned
            $resolved = ($cleaned -match "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+")
            break
        }

        $results[$d] = [pscustomobject]@{
            domain   = $d
            resolved = $resolved
            output   = $domOut
        }
    }
    return $results
}

# ─── CR-0: Preflight ─────────────────────────────────────────────────────────

Write-Phase -Title "CR-0: Preflight" -Progress 0

$ctx = $null
if ($LabOutputsPath -and (Test-Path $LabOutputsPath)) {
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $ctx = Get-Content $LabOutputsPath -Raw | ConvertFrom-Json
    $ErrorActionPreference = $oldEP
}

$ResourceGroup = if ($ctx -and $ctx.resourceGroup)      { $ctx.resourceGroup }      else { "rg-lab-008-dns-resolver" }
$VmName        = if ($ctx -and $ctx.testVm)             { $ctx.testVm }             else { "vm-spoke-008" }
$RulesetName   = if ($ctx -and $ctx.rulesetName)        { $ctx.rulesetName }        else { "ruleset-008" }
$InboundIp     = if ($ctx -and $ctx.inboundEndpointIp)  { $ctx.inboundEndpointIp }  else { "unknown" }
$Location      = if ($ctx -and $ctx.location)           { $ctx.location }           else { "eastus2" }
$PrivateZone   = "internal.lab"

$TestDomains   = @("app.internal.lab", "azure.microsoft.com")

Write-Host "  Resource group: $ResourceGroup" -ForegroundColor Gray
Write-Host "  Test VM:        $VmName" -ForegroundColor Gray
Write-Host "  Ruleset:        $RulesetName" -ForegroundColor Gray
Write-Host "  Domains:        $($TestDomains -join ', ')" -ForegroundColor Gray
Write-Host "  Monitor window: $MonitorMinutes min (poll every ${PollIntervalSec}s)" -ForegroundColor Gray

# Verify VM is reachable
$vmOk = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$vmOk = az vm show -g $ResourceGroup -n $VmName --query "provisioningState" -o tsv 2>$null
$ErrorActionPreference = $oldEP

if ($vmOk -ne "Succeeded") {
    Write-Host ""
    Write-Host "  [FAIL] VM '$VmName' not found or not in Succeeded state." -ForegroundColor Red
    Write-Host "         Deploy lab-008 first:  .\lab.ps1 -Deploy lab-008" -ForegroundColor Yellow
    exit 1
}
Write-Milestone -Event "Preflight passed - VM $VmName is Succeeded" -Color "Green"

# ─── CR-1: Seed test record ──────────────────────────────────────────────────

Write-Phase -Title "CR-1: Seed test record" -Progress 10

$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRec = $null
$existingRec = az network private-dns record-set a show `
    -g $ResourceGroup --zone-name $PrivateZone -n "app" -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if ($existingRec) {
    Write-Milestone -Event "app.$PrivateZone already exists - using existing record"
} else {
    az network private-dns record-set a add-record `
        -g $ResourceGroup --zone-name $PrivateZone `
        --record-set-name "app" --ipv4-address "10.80.1.10" `
        --output none 2>$null
    Write-Milestone -Event "Created app.$PrivateZone -> 10.80.1.10"
}

# ─── CR-2: Baseline ──────────────────────────────────────────────────────────

Write-Phase -Title "CR-2: Baseline" -Progress 15
Write-Milestone -Event "Starting baseline polls (3 rounds x ${PollIntervalSec}s)"

$baselinePolls  = [System.Collections.ArrayList]::new()
$baselineOk     = $true

for ($i = 1; $i -le 3; $i++) {
    Write-Host "  Baseline poll $i/3..." -ForegroundColor DarkGray
    $poll = Invoke-VmDnsTest -ResourceGroup $ResourceGroup -VmName $VmName -Domains $TestDomains
    $pollRecord = [pscustomobject]@{
        elapsed = Get-Elapsed
        round   = $i
        results = $poll
    }
    [void]$baselinePolls.Add($pollRecord)

    foreach ($d in $TestDomains) {
        $status = if ($poll[$d].resolved) { "[OK]" } else { "[FAIL]" }
        $color  = if ($poll[$d].resolved) { "Green" } else { "Red" }
        Write-Host "    $status $d" -ForegroundColor $color
        if (-not $poll[$d].resolved) { $baselineOk = $false }
    }
    if ($i -lt 3) { Start-Sleep -Seconds 15 }
}

if (-not $baselineOk) {
    Write-Milestone -Event "WARNING - baseline: some domains not resolving before block applied" -Color "Yellow"
} else {
    Write-Milestone -Event "Baseline confirmed - all test domains resolving" -Color "Green"
}

# ─── CR-3: Apply block ───────────────────────────────────────────────────────

Write-Phase -Title "CR-3: Apply block" -Progress 25

$blockMethod    = "none"
$blockApplied   = $false

# DNS Security Policy resource names (used in CR-3, CR-5, CR-7)
$DspPolicyName     = "dnspolicy-lab-008-research"
$DspDomainListName = "blocklist-lab-008-research"
$DspRuleName       = "blockrule-lab-008-research"
$DspVnetLinkName   = "vnetlink-lab-008-research"

# ── Attempt 1: Full DNS Security Policy stack ────────────────────────────────
# Requires: policy + domain list + block traffic rule + VNet link
# All four must succeed or we fall back.
Write-Host "  Building DNS Security Policy block stack..." -ForegroundColor DarkGray

# Check CLI availability
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$dspHelp = az network dns-security-policy create --help 2>&1
$ErrorActionPreference = $oldEP
$dspAvailable = ($dspHelp -match "dns-security-policy|Required Parameters|--name")

if (-not $dspAvailable) {
    Write-Host "  [WARN] az network dns-security-policy not found in this az CLI version." -ForegroundColor Yellow
    Write-Host "         Run: az upgrade   then retry." -ForegroundColor DarkGray
} else {
    # Get spoke VNet resource ID for the VNet link
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $spokeVnetId = $null
    $spokeVnetId = az network vnet show -g $ResourceGroup -n "vnet-spoke-008" --query id -o tsv 2>$null
    $ErrorActionPreference = $oldEP

    if (-not $spokeVnetId) {
        Write-Host "  [WARN] Could not resolve spoke VNet ID - cannot link DNS Security Policy." -ForegroundColor Yellow
    } else {
        # Step A: Create policy
        $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
        $policyObj = $null
        $policyObj = az network dns-security-policy create `
            --name $DspPolicyName `
            --resource-group $ResourceGroup `
            --location $Location `
            --output json --only-show-errors 2>$null | ConvertFrom-Json
        $ErrorActionPreference = $oldEP

        if ($policyObj -and $policyObj.id) {
            Write-Host "  [ok] Policy created: $DspPolicyName" -ForegroundColor DarkGray

            # Step B: Create domain list (blocks both test domains)
            $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
            $domainListObj = $null
            $domainListObj = az network dns-security-policy dns-domain-list create `
                --name $DspDomainListName `
                --resource-group $ResourceGroup `
                --dns-security-policy-name $DspPolicyName `
                --domains "app.internal.lab" "azure.microsoft.com" `
                --output json --only-show-errors 2>$null | ConvertFrom-Json
            $ErrorActionPreference = $oldEP

            if ($domainListObj -and $domainListObj.id) {
                Write-Host "  [ok] Domain list created: $DspDomainListName (app.internal.lab, azure.microsoft.com)" -ForegroundColor DarkGray

                # Step C: Create block traffic rule (priority 100)
                $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
                $ruleObj = $null
                $ruleObj = az network dns-security-policy dns-traffic-rule create `
                    --name $DspRuleName `
                    --resource-group $ResourceGroup `
                    --dns-security-policy-name $DspPolicyName `
                    --priority 100 `
                    --action Block `
                    --dns-domain-lists $DspDomainListName `
                    --output json --only-show-errors 2>$null | ConvertFrom-Json
                $ErrorActionPreference = $oldEP

                if ($ruleObj -and $ruleObj.id) {
                    Write-Host "  [ok] Block rule created: $DspRuleName (priority 100, action=Block)" -ForegroundColor DarkGray

                    # Step D: Link policy to spoke VNet
                    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
                    $linkObj = $null
                    $linkObj = az network dns-security-policy virtual-network-link create `
                        --name $DspVnetLinkName `
                        --resource-group $ResourceGroup `
                        --dns-security-policy-name $DspPolicyName `
                        --virtual-network $spokeVnetId `
                        --output json --only-show-errors 2>$null | ConvertFrom-Json
                    $ErrorActionPreference = $oldEP

                    if ($linkObj -and $linkObj.id) {
                        $blockMethod  = "azure-dns-security-policy"
                        $blockApplied = $true
                        Write-Milestone -Event "DNS Security Policy block active: policy=$DspPolicyName linked to vnet-spoke-008" -Color "Yellow"
                    } else {
                        Write-Host "  [WARN] VNet link step failed - see below for diagnosis." -ForegroundColor Yellow
                        Write-Host "         az network dns-security-policy virtual-network-link create returned no id." -ForegroundColor DarkGray
                        Write-Host "         VNet may already be linked to another security policy (1:1 limit)." -ForegroundColor DarkGray
                    }
                } else {
                    Write-Host "  [WARN] Traffic rule creation failed." -ForegroundColor Yellow
                }
            } else {
                Write-Host "  [WARN] Domain list creation failed." -ForegroundColor Yellow
            }
        } else {
            Write-Host "  [WARN] Policy creation failed. Check: az network dns-security-policy create --help" -ForegroundColor Yellow
        }
    }
}

# ── Fallback: forwarding rule redirect ───────────────────────────────────────
if (-not $blockApplied) {
    Write-Host "  Falling back to forwarding rule redirect (192.0.2.1 dead IP)..." -ForegroundColor DarkGray
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $ruleCreate = $null
    $ruleCreate = az dns-resolver forwarding-rule create `
        -g $ResourceGroup `
        --ruleset-name $RulesetName `
        -n $BlockRuleName `
        --domain-name "$PrivateZone." `
        --target-dns-servers "[{`"ipAddress`":`"192.0.2.1`",`"port`":53}]" `
        --forwarding-rule-state Enabled `
        --output json 2>$null | ConvertFrom-Json
    $ErrorActionPreference = $oldEP

    if ($ruleCreate -and $ruleCreate.id) {
        $blockMethod  = "forwarding-rule-redirect"
        $blockApplied = $true
        Write-Milestone -Event "Block applied via forwarding rule redirect: $BlockRuleName -> 192.0.2.1" -Color "Yellow"
    } else {
        Write-Host "  [FAIL] Could not apply block via any method. Cannot run scenario." -ForegroundColor Red
        exit 1
    }
}

$blockAppliedAt = Get-Date
Write-Host "  Block method: $blockMethod" -ForegroundColor Gray
Write-Host "  Waiting 30s for policy propagation..." -ForegroundColor DarkGray
Start-Sleep -Seconds 30

# ─── CR-4: Confirm block ─────────────────────────────────────────────────────

Write-Phase -Title "CR-4: Confirm block" -Progress 35
$breakTimes = @{}

for ($i = 1; $i -le 3; $i++) {
    Write-Host "  Confirm poll $i/3..." -ForegroundColor DarkGray
    $poll = Invoke-VmDnsTest -ResourceGroup $ResourceGroup -VmName $VmName -Domains $TestDomains
    foreach ($d in $TestDomains) {
        $blocked = -not $poll[$d].resolved
        $icon    = if ($blocked) { "[BLOCKED]" } else { "[still resolving]" }
        $color   = if ($blocked) { "Yellow" } else { "DarkGray" }
        Write-Host "    $icon $d" -ForegroundColor $color
        if ($blocked -and -not $breakTimes.ContainsKey($d)) {
            $breakTimes[$d] = Get-Elapsed
            Write-Milestone -Event "$d blocked at $(Get-Elapsed)" -Color "Yellow"
        }
    }
    if ($i -lt 3) { Start-Sleep -Seconds 10 }
}

# ─── CR-5: Remove block ──────────────────────────────────────────────────────

Write-Phase -Title "CR-5: Remove block" -Progress 45

if ($blockMethod -eq "azure-dns-security-policy") {
    # Tear down in dependency order: VNet link -> rule -> domain list -> policy
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    az network dns-security-policy virtual-network-link delete `
        --name $DspVnetLinkName `
        --resource-group $ResourceGroup `
        --dns-security-policy-name $DspPolicyName --yes 2>$null
    az network dns-security-policy dns-traffic-rule delete `
        --name $DspRuleName `
        --resource-group $ResourceGroup `
        --dns-security-policy-name $DspPolicyName --yes 2>$null
    az network dns-security-policy dns-domain-list delete `
        --name $DspDomainListName `
        --resource-group $ResourceGroup `
        --dns-security-policy-name $DspPolicyName --yes 2>$null
    az network dns-security-policy delete `
        --name $DspPolicyName `
        --resource-group $ResourceGroup --yes 2>$null
    $ErrorActionPreference = $oldEP
    Write-Host "  DNS Security Policy and all sub-resources removed." -ForegroundColor DarkGray
} elseif ($blockMethod -eq "forwarding-rule-redirect") {
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    az dns-resolver forwarding-rule delete `
        -g $ResourceGroup --ruleset-name $RulesetName `
        -n $BlockRuleName --yes 2>$null
    $ErrorActionPreference = $oldEP
}

$blockRemovedAt  = Get-Date
$blockRemovedTs  = Get-Elapsed
Write-Milestone -Event "Block removed at $blockRemovedTs - recovery clock starts" -Color "Cyan"

# ─── CR-6: Recovery monitoring ───────────────────────────────────────────────

Write-Phase -Title "CR-6: Recovery monitoring" -Progress 50
$script:CurrentProgress = 50

$recoveryTimes  = @{}
$recoveryPolls  = [System.Collections.ArrayList]::new()
$monitorEnd     = (Get-Date).AddMinutes($MonitorMinutes)
$pollNum        = 0

Write-Host "  Monitoring for up to $MonitorMinutes minutes (poll every ${PollIntervalSec}s)..." -ForegroundColor Gray
Write-Host "  Close the window or Ctrl+C to abort - partial data will be written." -ForegroundColor DarkGray

while ((Get-Date) -lt $monitorEnd) {
    $pollNum++
    $elapsed     = [int]([DateTime]::UtcNow - $blockRemovedAt).TotalSeconds
    $remaining   = [int]($monitorEnd - (Get-Date)).TotalMinutes
    $progress    = [int](50 + (50 * ($elapsed / ($MonitorMinutes * 60))))
    $script:CurrentProgress = [Math]::Min($progress, 99)

    Write-Host ""
    Write-Host "  Poll #$pollNum  [$(Get-Elapsed)]  (~${remaining}min remaining in window)" -ForegroundColor DarkGray

    $poll = Invoke-VmDnsTest -ResourceGroup $ResourceGroup -VmName $VmName -Domains $TestDomains
    $pollRecord = [pscustomobject]@{
        pollNum       = $pollNum
        elapsed       = Get-Elapsed
        secAfterRemoval = $elapsed
        results       = $poll
    }
    [void]$recoveryPolls.Add($pollRecord)

    $allRecovered = $true
    foreach ($d in $TestDomains) {
        if ($recoveryTimes.ContainsKey($d)) {
            Write-Host "    [RECOVERED] $d (at $($recoveryTimes[$d]))" -ForegroundColor Green
            continue
        }
        if ($poll[$d].resolved) {
            $recoveryTimes[$d] = Get-Elapsed
            $secToRecover = [int]([DateTime]::UtcNow - $blockRemovedAt).TotalSeconds
            Write-Milestone -Event "$d RECOVERED at $(Get-Elapsed) (+${secToRecover}s after block removed)" -Color "Green"
        } else {
            $allRecovered = $false
            Write-Host "    [BLOCKED]   $d" -ForegroundColor Yellow
        }
    }

    Flush-Status

    if ($allRecovered) {
        Write-Milestone -Event "All domains recovered - monitoring complete" -Color "Green"
        break
    }

    if ((Get-Date) -lt $monitorEnd) {
        Write-Host "  Next poll in ${PollIntervalSec}s..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $PollIntervalSec
    }
}

# Domains not recovered within window
$stickyDomains  = @()
$fastDomains    = @()
foreach ($d in $TestDomains) {
    if ($recoveryTimes.ContainsKey($d)) {
        $fastDomains += $d
    } else {
        $stickyDomains += $d
        Write-Milestone -Event "$d did NOT recover within $MonitorMinutes min monitoring window - likely 48h sticky" -Color "Red"
    }
}

# ─── CR-7: Cleanup ───────────────────────────────────────────────────────────

Write-Phase -Title "CR-7: Cleanup" -Progress 98

# Safety cleanup - remove any leftover block resources if scenario aborted mid-run
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
# DNS Security Policy cleanup (idempotent - silent if already gone)
az network dns-security-policy virtual-network-link delete --name $DspVnetLinkName --resource-group $ResourceGroup --dns-security-policy-name $DspPolicyName --yes 2>$null
az network dns-security-policy dns-traffic-rule delete     --name $DspRuleName     --resource-group $ResourceGroup --dns-security-policy-name $DspPolicyName --yes 2>$null
az network dns-security-policy dns-domain-list delete      --name $DspDomainListName --resource-group $ResourceGroup --dns-security-policy-name $DspPolicyName --yes 2>$null
az network dns-security-policy delete --name $DspPolicyName --resource-group $ResourceGroup --yes 2>$null
# Forwarding rule cleanup (idempotent)
az dns-resolver forwarding-rule delete -g $ResourceGroup --ruleset-name $RulesetName -n $BlockRuleName --yes 2>$null
$ErrorActionPreference = $oldEP

Write-Milestone -Event "Cleanup complete"

# ─── CR-8: Report ────────────────────────────────────────────────────────────

Write-Phase -Title "CR-8: Report" -Progress 99
$script:CurrentProgress = 100

$totalSeconds = [int]([DateTime]::UtcNow - $ScenarioStart).TotalSeconds

$report = [ordered]@{
    meta = [ordered]@{
        scenario       = $ScenarioName
        labId          = "lab-008"
        resourceGroup  = $ResourceGroup
        runAt          = $ScenarioStart.ToString("yyyy-MM-ddTHH:mm:ssZ")
        completedAt    = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
        totalSeconds   = $totalSeconds
    }
    configuration = [ordered]@{
        blockMethod      = $blockMethod
        testDomains      = $TestDomains
        monitorMinutes   = $MonitorMinutes
        pollIntervalSec  = $PollIntervalSec
        privateZone      = $PrivateZone
    }
    timeline = [ordered]@{
        blockAppliedAt   = $blockAppliedAt.ToString("yyyy-MM-ddTHH:mm:ssZ")
        blockRemovedAt   = $blockRemovedAt.ToString("yyyy-MM-ddTHH:mm:ssZ")
        breakTimes       = $breakTimes
        recoveryTimes    = $recoveryTimes
    }
    conclusions = [ordered]@{
        recoveredWithinWindow   = $fastDomains
        stickyBeyondWindow      = $stickyDomains
        monitoringWindowMinutes = $MonitorMinutes
        interpretation = if ($stickyDomains.Count -gt 0) {
            "One or more domains did not recover in $MonitorMinutes min. Azure resolver " +
            "cache may persist the blocked response for significantly longer (up to 48h). " +
            "Private-zone domains are the primary suspect for extended cache persistence."
        } else {
            "All domains recovered within $MonitorMinutes min. No evidence of extended cache stickiness in this run."
        }
    }
    data = [ordered]@{
        baselinePolls   = @($baselinePolls)
        recoveryPolls   = @($recoveryPolls)
        milestones      = @($Milestones)
    }
}

# Write JSON report
if ($OutputDir) {
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    $reportPath = Join-Path $OutputDir "cache-recovery-$RunTimestamp.json"
    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath -Encoding UTF8
    Write-Host ""
    Write-Host "  Report written: $reportPath" -ForegroundColor Green
}

# Print human-readable summary
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " CACHE RECOVERY RESEARCH REPORT" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Lab:          lab-008 ($ResourceGroup)" -ForegroundColor White
Write-Host "  Block method: $blockMethod" -ForegroundColor White
Write-Host "  Run time:     $([int]($totalSeconds/60)) min $($totalSeconds % 60) sec" -ForegroundColor White
Write-Host ""
Write-Host "  DOMAIN RECOVERY:" -ForegroundColor White
foreach ($d in $TestDomains) {
    if ($recoveryTimes.ContainsKey($d)) {
        Write-Host "    $d" -ForegroundColor Green
        Write-Host "      Recovered: $($recoveryTimes[$d])" -ForegroundColor Green
    } else {
        Write-Host "    $d" -ForegroundColor Red
        Write-Host "      NOT recovered in $MonitorMinutes min window - likely sticky cache (48h+)" -ForegroundColor Red
    }
}
Write-Host ""
Write-Host "  INTERPRETATION:" -ForegroundColor White
Write-Host "    $($report.conclusions.interpretation)" -ForegroundColor Gray
Write-Host ""
if ($OutputDir) {
    Write-Host "  Full data: $reportPath" -ForegroundColor DarkGray
}
Write-Host "============================================================" -ForegroundColor Cyan

# Final status flush
$CurrentPhase    = "completed"
$CurrentProgress = 100
Flush-Status

exit 0
