# labs/lab-011-vwan-p2s-s2s-firewall-split/scenario.ps1
# Switches the static routes this lab owns in the hub defaultRouteTable.
# This is a cloud change: it asks for APPLY unless -Force is given.
#
#   Baseline        No lab static routes. The app prefix reaches Default only via
#                   the conn-vnet-fw static route (next hop: spoke firewall).
#   HubFwForP2S     10.112.0.0/24 -> hub Azure Firewall. The design under test:
#                   "push P2S traffic to the hub firewall" on the shared Default RT.
#   HubFwSymmetric  HubFwForP2S plus 172.16.110.0/24 (P2S pool) -> hub firewall,
#                   so the return path from the app spoke also crosses the hub FW.
#   HubFwAggregate  RFC1918 aggregates (10/8, 172.16/12, 192.168/16) -> hub firewall,
#                   the Firewall Manager "private_traffic" pattern. Tests whether a
#                   broader Default static route leaves the more specific propagated
#                   VNet-connection route (10.112.0.0/24 -> spoke FW) in charge.
#
# Static routes in a hub route table win over propagated routes for the same
# prefix, and every branch (S2S, P2S, ER) is associated with Default, so any
# route added here applies to S2S as well. inspect.ps1 measures that.

[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet("Baseline", "HubFwForP2S", "HubFwSymmetric", "HubFwAggregate")]
  [string]$Mode,
  [string]$SubscriptionKey,
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path
. (Join-Path (Join-Path $RepoRoot "scripts") "labs-common.ps1")
. (Join-Path (Join-Path $LabRoot "scripts") "lab-011-helpers.ps1")

$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null
$DataDir = Get-LabDataDir -RepoRoot $RepoRoot

$fw = Invoke-AzJson -AzArgs @("network", "firewall", "show", "-g", $script:ResourceGroup, "-n", $script:HubFwName)
if (-not $fw) { throw "Hub firewall $($script:HubFwName) not found. Deploy lab-011 first." }

$rt = Get-DefaultRouteTable -SubscriptionId $SubscriptionId
if (-not $rt) { throw "Could not read defaultRouteTable on $($script:HubName)." }
$current = Get-ActiveScenario -RouteTable $rt

# Keep any route this lab does not own; replace only lab011-* routes
$routes = @()
foreach ($r in (Get-HubStaticRoutes -RouteTable $rt)) {
  if ($r.name -notlike "$($script:LabRoutePrefix)*") { $routes += $r }
}
if ($Mode -eq "HubFwAggregate") {
  $routes += [ordered]@{
    name            = "lab011-agg-to-hub-fw"
    destinationType = "CIDR"
    destinations    = @("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
    nextHopType     = "ResourceId"
    nextHop         = $fw.id
  }
}
if ($Mode -eq "HubFwForP2S" -or $Mode -eq "HubFwSymmetric") {
  $routes += [ordered]@{
    name            = "lab011-app-to-hub-fw"
    destinationType = "CIDR"
    destinations    = @($script:AppCidr)
    nextHopType     = "ResourceId"
    nextHop         = $fw.id
  }
}
if ($Mode -eq "HubFwSymmetric") {
  $routes += [ordered]@{
    name            = "lab011-pool-to-hub-fw"
    destinationType = "CIDR"
    destinations    = @($script:P2sPool)
    nextHopType     = "ResourceId"
    nextHop         = $fw.id
  }
}

Write-Host ""
Write-Host "Lab 011 scenario switch" -ForegroundColor Cyan
Write-Host "  Current: $current" -ForegroundColor Gray
Write-Host "  Target:  $Mode" -ForegroundColor Gray
Write-Host "  defaultRouteTable static routes after the change:" -ForegroundColor Gray
if ($routes.Count -eq 0) { Write-Host "    (none)" -ForegroundColor DarkGray }
foreach ($r in $routes) {
  $hop = ($r.nextHop -split "/")[-1]
  Write-Host ("    {0,-24} {1,-18} -> {2}" -f $r.name, ($r.destinations -join ","), $hop) -ForegroundColor DarkGray
}
Write-Host ""

if ($current -eq $Mode) {
  Write-Host "Already in $Mode. Nothing to change." -ForegroundColor Green
  exit 0
}

if (-not $Force) {
  $confirm = Read-Host "Type APPLY to change the hub defaultRouteTable"
  if ($confirm -ne "APPLY") { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
}

$labels = @("default")
if (($rt.properties.PSObject.Properties.Name -contains "labels") -and $rt.properties.labels) { $labels = @($rt.properties.labels) }
$body = @{ properties = @{ routes = @($routes); labels = $labels } }
$bodyFile = Join-Path $DataDir "default-rt.json"
Write-LfFile -Path $bodyFile -Content ($body | ConvertTo-Json -Depth 10)

az rest --method put --url (Get-HubRouteTableUrl -SubscriptionId $SubscriptionId) --body "@$bodyFile" -o none
Remove-Item -Path $bodyFile -Force -ErrorAction SilentlyContinue

Write-Host "Waiting for defaultRouteTable to settle..." -ForegroundColor Gray
for ($i = 1; $i -le 60; $i++) {
  Start-Sleep -Seconds 10
  $now = Get-DefaultRouteTable -SubscriptionId $SubscriptionId
  $state = "unknown"
  if ($now -and ($now.properties.PSObject.Properties.Name -contains "provisioningState")) { $state = $now.properties.provisioningState }
  Write-Host "  [$i] provisioningState: $state" -ForegroundColor DarkGray
  if ($state -eq "Succeeded") { break }
  if ($state -eq "Failed") { throw "defaultRouteTable update failed. Check the hub in the portal (Reset router if needed)." }
}

$after = Get-ActiveScenario -RouteTable (Get-DefaultRouteTable -SubscriptionId $SubscriptionId)
if ($after -eq $Mode) {
  Write-Host "[PASS] Scenario now: $after" -ForegroundColor Green
} else {
  Write-Host "[FAIL] Scenario reads back as $after, expected $Mode" -ForegroundColor Red
  exit 1
}
Write-Host ""
Write-Host "Measure it (firewall logs lag ~5-10 min):  .\lab.ps1 -Inspect lab-011" -ForegroundColor Yellow
Write-Host ""
