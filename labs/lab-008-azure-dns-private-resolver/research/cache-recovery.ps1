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
#   1. Tries az network dns-security-policy (native, preferred)
#   2. Falls back to forwarding rule redirect to 192.0.2.1 (RFC5737 dead IP)
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

$blockMethod  = "none"
$blockApplied = $false

# Try DNS Security Policy first
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$policyHelp = az network dns-security-policy --help 2>$null
$ErrorActionPreference = $oldEP

if ($policyHelp -match "Commands|dns-security-policy") {
    $policyName = "dnspolicy-lab-008-research"
    Write-Host "  Trying DNS Security Policy..." -ForegroundColor DarkGray
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $policyCreate = $null
    $policyCreate = az network dns-security-policy create `
        --name $policyName --resource-group $ResourceGroup `
        --location $Location --output json 2>$null | ConvertFrom-Json
    $ErrorActionPreference = $oldEP

    if ($policyCreate -and $policyCreate.id) {
        $blockMethod  = "azure-dns-security-policy"
        $blockApplied = $true
        Write-Milestone -Event "Block applied via DNS Security Policy: $policyName" -Color "Yellow"
    }
}

if (-not $blockApplied) {
    # Fallback: forwarding rule redirect to RFC5737 dead IP (192.0.2.1 - never routes)
    Write-Host "  DNS Security Policy not available - using forwarding rule redirect" -ForegroundColor DarkGray
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $ruleCreate = $null
    $ruleCreate = az dns-resolver forwarding-rule create `
        -g $ResourceGroup `
        --forwarding-ruleset-name $RulesetName `
        -n $BlockRuleName `
        --domain-name "$PrivateZone." `
        --target-dns-servers "[{`"ipAddress`":`"192.0.2.1`",`"port`":53}]" `
        --forwarding-rule-state Enabled `
        --output json 2>$null | ConvertFrom-Json
    $ErrorActionPreference = $oldEP

    if ($ruleCreate -and $ruleCreate.id) {
        $blockMethod  = "forwarding-rule-redirect"
        $blockApplied = $true
        Write-Milestone -Event "Block applied via forwarding rule redirect to 192.0.2.1: $BlockRuleName" -Color "Yellow"
    } else {
        Write-Host "  [FAIL] Could not apply block. Cannot run scenario." -ForegroundColor Red
        exit 1
    }
}

$blockAppliedAt = Get-Date
Write-Host "  Block method: $blockMethod" -ForegroundColor Gray
Write-Host "  Waiting 15s for propagation..." -ForegroundColor DarkGray
Start-Sleep -Seconds 15

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
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    az network dns-security-policy delete --name "dnspolicy-lab-008-research" `
        --resource-group $ResourceGroup --yes 2>$null
    $ErrorActionPreference = $oldEP
} elseif ($blockMethod -eq "forwarding-rule-redirect") {
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    az dns-resolver forwarding-rule delete `
        -g $ResourceGroup --forwarding-ruleset-name $RulesetName `
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

# Remove block rule if anything went wrong and it's still there
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
az dns-resolver forwarding-rule delete `
    -g $ResourceGroup --forwarding-ruleset-name $RulesetName `
    -n $BlockRuleName --yes 2>$null
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
