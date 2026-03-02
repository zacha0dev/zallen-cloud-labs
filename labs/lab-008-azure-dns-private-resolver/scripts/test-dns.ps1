# labs/lab-008-azure-dns-private-resolver/scripts/test-dns.ps1
# Generic DNS test harness for lab-008
# Runs nslookup/dig via az vm run-command and captures structured results
#
# Usage:
#   .\test-dns.ps1 -ResourceGroup rg-lab-008-dns-resolver -VmName vm-spoke-008 -QueryName app.internal.lab
#   .\test-dns.ps1 ... -QueryType A -ResolverIp 10.80.2.4 -Iterations 5 -Label "before-policy"
#
# Output:
#   Returns a PowerShell object (and optionally writes JSON) with:
#   { label, queryName, queryType, resolverIp, iterations: [ { answer, ttl, resolverSeen, timestamp } ], summary }

[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$ResourceGroup,
  [Parameter(Mandatory)][string]$VmName,
  [Parameter(Mandatory)][string]$QueryName,
  [string]$QueryType    = "A",
  [string]$ResolverIp   = "",        # If set, query this specific resolver; else use default
  [int]$Iterations      = 3,
  [int]$SleepSeconds    = 2,         # Seconds between iterations
  [string]$Label        = "dns-test",
  [string]$OutputPath   = ""         # If set, writes JSON to this path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"  # Don't halt on individual test failures

function Invoke-VmDnsQuery {
  param([string]$Rg, [string]$Vm, [string]$Script)
  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $result = az vm run-command invoke `
    -g $Rg -n $Vm `
    --command-id RunShellScript `
    --scripts $Script `
    -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP
  if ($result -and $result.value -and $result.value.Count -gt 0) {
    return $result.value[0].message
  }
  return $null
}

function Parse-NslookupOutput {
  param([string]$Output)
  $parsed = @{
    answer      = $null
    ttl         = $null
    nxdomain    = $false
    servfail    = $false
    rawOutput   = $Output
  }
  if (-not $Output) { return $parsed }

  if ($Output -match "NXDOMAIN|Non-existent domain|can't find") { $parsed.nxdomain = $true }
  if ($Output -match "SERVFAIL|timed out|no servers could be reached") { $parsed.servfail = $true }

  # Extract first Address answer line
  if ($Output -match "Address:\s*([\d\.]+)" ) {
    $parsed.answer = $Matches[1]
  }
  # Extract TTL if dig output present
  if ($Output -match "\s+(\d+)\s+IN\s+A\s+([\d\.]+)") {
    $parsed.ttl    = [int]$Matches[1]
    $parsed.answer = $Matches[2]
  }
  return $parsed
}

# ============================================
# Build the query script
# ============================================
$resolverArg = if ($ResolverIp) { " $ResolverIp" } else { "" }
$queryScript = @"
for i in `$(seq 1 $Iterations); do
  echo "--- iter:`$i ts:`$(date -u +%Y-%m-%dT%H:%M:%SZ) ---"
  nslookup -type=$QueryType $QueryName$resolverArg 2>&1
  echo "---end---"
  sleep $SleepSeconds
done
"@

Write-Host "  [dns-test] label=$Label query=$QueryName type=$QueryType iterations=$Iterations" -ForegroundColor DarkGray

# ============================================
# Execute
# ============================================
$rawOutput = Invoke-VmDnsQuery -Rg $ResourceGroup -Vm $VmName -Script $queryScript

$results = @()
$successCount = 0
$nxdomainCount = 0
$servfailCount = 0

if ($rawOutput) {
  # Split by iter blocks
  $blocks = $rawOutput -split '--- iter:\d+ ts:[^\-]+ ---'
  foreach ($block in $blocks) {
    $block = $block.Trim()
    if (-not $block) { continue }

    # Extract timestamp from next block header... approximate from sequence
    $tsMatch = [regex]::Match($rawOutput, "ts:(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)")

    $parsed = Parse-NslookupOutput -Output $block
    $record = [pscustomobject]@{
      timestamp   = if ($tsMatch.Success) { $tsMatch.Value -replace "ts:",""} else { (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") }
      answer      = $parsed.answer
      ttl         = $parsed.ttl
      nxdomain    = $parsed.nxdomain
      servfail    = $parsed.servfail
      raw         = ($block -replace "`n"," ").Substring(0, [Math]::Min(200, $block.Length))
    }
    $results += $record

    if ($parsed.answer)     { $successCount++ }
    if ($parsed.nxdomain)   { $nxdomainCount++ }
    if ($parsed.servfail)   { $servfailCount++ }
  }
}

$summary = [pscustomobject]@{
  totalIterations = $Iterations
  successCount    = $successCount
  nxdomainCount   = $nxdomainCount
  servfailCount   = $servfailCount
  resolved        = ($successCount -gt 0)
  consistent      = ($successCount -eq $Iterations -or $nxdomainCount -eq $Iterations)
}

$output = [pscustomobject]@{
  label       = $Label
  queryName   = $QueryName
  queryType   = $QueryType
  resolverIp  = $ResolverIp
  vmName      = $VmName
  iterations  = $results
  summary     = $summary
  capturedAt  = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
}

# Print summary
$resolvedStr = if ($summary.resolved) { "[PASS]" } else { "[FAIL]" }
Write-Host "  $resolvedStr $Label : $QueryName -> answer=$($results[0].answer) success=$successCount/$Iterations nxdomain=$nxdomainCount servfail=$servfailCount" -ForegroundColor $(if ($summary.resolved) { "Green" } else { "Yellow" })

if ($OutputPath) {
  $output | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8
}

return $output
