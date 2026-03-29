# labs/lab-008-azure-dns-private-resolver/destroy.ps1
# Destroys all resources created by lab-008 (any mode)
# Idempotent: safe to run multiple times
#
# Cleans up all resources regardless of which -Mode was used during deploy:
#   - Base:               resource group (all VNets, resolver, ruleset, zone, VM)
#   - StickyBlock:        above + DNS Security Policy (if any remains)
#   - ForwardingVariants: above + any leftover variant rules/zones/links

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [switch]$Force,
  [switch]$KeepLogs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot  = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path

. (Join-Path $RepoRoot "scripts\labs-common.ps1")

$ResourceGroup    = "rg-lab-008-dns-resolver"
$RulesetName      = "ruleset-008"
$DnsZoneName      = "internal.lab"

# Mode-specific resource names (cleaned up if present)
$StickyPolicyName   = "dnspolicy-lab-008-stickyblock"
$StickyBlockRule    = "rule-sticky-block-test"
$VariantAZone       = "variant-a.lab"
$VariantARule       = "rule-variant-a-lab"
$VariantALink       = "link-hub-variant-a"
$VariantBLink       = "link-hub-variant-b"

function Get-ElapsedTime {
  param([datetime]$StartTime)
  $elapsed = (Get-Date) - $StartTime
  return "$([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s"
}

function Remove-IfExists {
  param([string]$Label, [scriptblock]$CheckCmd, [scriptblock]$DeleteCmd)
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $exists = & $CheckCmd
  $ErrorActionPreference = $oldEP
  if ($exists) {
    Write-Host "  Removing: $Label" -ForegroundColor DarkGray
    $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    & $DeleteCmd 2>$null
    $ErrorActionPreference = $oldEP
    Write-Host "  [PASS] Removed: $Label" -ForegroundColor Green
  } else {
    Write-Host "  [SKIP] Not found (already gone): $Label" -ForegroundColor DarkGray
  }
}

Write-Host ""
Write-Host "Lab 008: Destroy Resources" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Cleans up all resources for any deployment mode (Base, StickyBlock, ForwardingVariants)." -ForegroundColor DarkGray
Write-Host ""

$destroyStartTime = Get-Date

$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null

$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if (-not $existingRg) {
  Write-Host "Resource group '$ResourceGroup' does not exist. Nothing to delete." -ForegroundColor Yellow
  exit 0
}

Write-Host "Resources to delete:" -ForegroundColor Yellow
Write-Host "  Resource Group: $ResourceGroup" -ForegroundColor Gray
Write-Host "  Subscription:   $SubscriptionId" -ForegroundColor Gray
Write-Host ""

$resources = az resource list -g $ResourceGroup --query "[].{Name:name, Type:type}" -o json 2>$null | ConvertFrom-Json
if ($resources) {
  Write-Host "Resources in group:" -ForegroundColor White
  foreach ($r in $resources) {
    Write-Host "  - $($r.Name) ($($r.Type))" -ForegroundColor DarkGray
  }
  Write-Host ""
}

if (-not $Force) {
  Write-Host "WARNING: This will permanently delete all resources!" -ForegroundColor Red
  Write-Host "  Includes: DNS Private Resolver, both VNets, peerings, ruleset, zone, VM." -ForegroundColor Yellow
  Write-Host "  Also removes any StickyBlock policies and ForwardingVariants leftovers." -ForegroundColor Yellow
  $confirm = Read-Host "Type DELETE to confirm"
  if ($confirm -ne "DELETE") {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 0
  }
}

# ============================================
# Pre-deletion: clean up mode-specific resources
# These are cleaned up explicitly first because some have dependencies
# that can block resource group deletion if left dangling.
# ============================================
Write-Host ""
Write-Host "Pre-deletion cleanup (mode-specific resources)..." -ForegroundColor Yellow

# StickyBlock: DNS Security Policy
Remove-IfExists -Label "DNS Security Policy: $StickyPolicyName" `
  -CheckCmd  { az network dns-security-policy show --name $StickyPolicyName --resource-group $ResourceGroup -o json 2>$null | ConvertFrom-Json } `
  -DeleteCmd { az network dns-security-policy delete --name $StickyPolicyName --resource-group $ResourceGroup --yes 2>$null }

# StickyBlock: block forwarding rule (in case it wasn't cleaned up)
Remove-IfExists -Label "StickyBlock forwarding rule: $StickyBlockRule" `
  -CheckCmd  { az dns-resolver forwarding-rule show -g $ResourceGroup --forwarding-ruleset-name $RulesetName -n $StickyBlockRule -o json 2>$null | ConvertFrom-Json } `
  -DeleteCmd { az dns-resolver forwarding-rule delete -g $ResourceGroup --forwarding-ruleset-name $RulesetName -n $StickyBlockRule --yes 2>$null }

# StickyBlock: seeded test record (sticky.internal.lab)
Remove-IfExists -Label "StickyBlock DNS record: sticky.$DnsZoneName" `
  -CheckCmd  { az network private-dns record-set a show -g $ResourceGroup --zone-name $DnsZoneName -n "sticky" -o json 2>$null | ConvertFrom-Json } `
  -DeleteCmd { az network private-dns record-set a delete -g $ResourceGroup --zone-name $DnsZoneName -n "sticky" --yes 2>$null }

# ForwardingVariants: Variant A rule
Remove-IfExists -Label "Variant A forwarding rule: $VariantARule" `
  -CheckCmd  { az dns-resolver forwarding-rule show -g $ResourceGroup --forwarding-ruleset-name $RulesetName -n $VariantARule -o json 2>$null | ConvertFrom-Json } `
  -DeleteCmd { az dns-resolver forwarding-rule delete -g $ResourceGroup --forwarding-ruleset-name $RulesetName -n $VariantARule --yes 2>$null }

# ForwardingVariants: Variant A DNS zone link
Remove-IfExists -Label "Variant A zone link: $VariantALink" `
  -CheckCmd  { az network private-dns link vnet show -g $ResourceGroup -n $VariantALink --zone-name $VariantAZone -o json 2>$null | ConvertFrom-Json } `
  -DeleteCmd { az network private-dns link vnet delete -g $ResourceGroup -n $VariantALink --zone-name $VariantAZone --yes 2>$null }

# ForwardingVariants: Variant A DNS zone
Remove-IfExists -Label "Variant A DNS zone: $VariantAZone" `
  -CheckCmd  { az network private-dns zone show -g $ResourceGroup -n $VariantAZone -o json 2>$null | ConvertFrom-Json } `
  -DeleteCmd { az network private-dns zone delete -g $ResourceGroup -n $VariantAZone --yes 2>$null }

# ForwardingVariants: Variant B ruleset link to hub
Remove-IfExists -Label "Variant B hub VNet link: $VariantBLink" `
  -CheckCmd  { az dns-resolver vnet-link show -g $ResourceGroup --forwarding-ruleset-name $RulesetName -n $VariantBLink -o json 2>$null | ConvertFrom-Json } `
  -DeleteCmd { az dns-resolver vnet-link delete -g $ResourceGroup --forwarding-ruleset-name $RulesetName -n $VariantBLink --yes 2>$null }

# ============================================
# Main resource group deletion
# ============================================
Write-Host ""
Write-Host "Deleting resource group: $ResourceGroup" -ForegroundColor Yellow
Write-Host "This may take 5-8 minutes..." -ForegroundColor Gray

$deleteStartTime = Get-Date
az group delete --name $ResourceGroup --yes --no-wait

Write-Host "Waiting for deletion to complete..." -ForegroundColor Gray
$maxAttempts = 72   # 12 minutes max (resolver teardown can be slow)
$attempt     = 0

while ($attempt -lt $maxAttempts) {
  $attempt++
  $rgExists = az group exists -n $ResourceGroup 2>$null
  if ($rgExists -eq "false") { break }

  $elapsed = Get-ElapsedTime -StartTime $deleteStartTime
  Write-Host "  [$elapsed] Still deleting... (attempt $attempt/$maxAttempts)" -ForegroundColor DarkGray
  Start-Sleep -Seconds 10
}

$deleteElapsed = Get-ElapsedTime -StartTime $deleteStartTime

$rgStillExists = (az group exists -n $ResourceGroup 2>$null) -eq "true"
if (-not $rgStillExists) {
  Write-Host "  [PASS] Resource group deleted: $ResourceGroup" -ForegroundColor Green
} else {
  Write-Host "  [FAIL] Resource group may still exist  -  check Azure Portal" -ForegroundColor Yellow
  Write-Host "         az group show -n $ResourceGroup" -ForegroundColor DarkGray
}

# ============================================
# Local cleanup
# ============================================
Write-Host ""
Write-Host "Cleaning up local data..." -ForegroundColor Gray

$dataDir = Join-Path $RepoRoot ".data/lab-008"
if (Test-Path $dataDir) {
  Remove-Item -Path $dataDir -Recurse -Force
  Write-Host "  Removed: $dataDir" -ForegroundColor DarkGray
}

if (-not $KeepLogs) {
  $logsDir  = Join-Path $LabRoot "logs"
  if (Test-Path $logsDir) {
    $logFiles = @(Get-ChildItem -Path $logsDir -Filter "lab-008-*.log" -ErrorAction SilentlyContinue)
    if ($logFiles.Count -gt 0) {
      Write-Host "  Removing $($logFiles.Count) log file(s)..." -ForegroundColor DarkGray
      $logFiles | Remove-Item -Force
    }
  }
}

$totalElapsed = Get-ElapsedTime -StartTime $destroyStartTime

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "Cleanup complete!" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host ""
Write-Host "Deletion time:  $deleteElapsed" -ForegroundColor Gray
Write-Host "Total time:     $totalElapsed" -ForegroundColor Gray
Write-Host ""
Write-Host "Cost check (confirm no billable resources remain):" -ForegroundColor Yellow
Write-Host "  .\..\..\tools\cost-check.ps1 -Lab lab-008" -ForegroundColor Gray
Write-Host ""
