# labs/lab-010-vwan-route-maps/inspect.ps1
# Post-deploy inspection: show all Route Maps, their rules, and effective routes

[CmdletBinding()]
param(
  [string]$SubscriptionKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path

. (Join-Path $RepoRoot "scripts\labs-common.ps1")

$ResourceGroup = "rg-lab-010-vwan-route-maps"
$VhubName      = "vhub-lab-010"
$ConnAName     = "conn-spoke-a"
$ConnBName     = "conn-spoke-b"

function Write-Section {
  param([string]$Title)
  Write-Host ""
  Write-Host ("=" * 65) -ForegroundColor Cyan
  Write-Host "  $Title" -ForegroundColor Cyan
  Write-Host ("=" * 65) -ForegroundColor Cyan
}

function Show-RouteMapDetail {
  param([string]$MapName)
  Write-Host ""
  Write-Host "  Route Map: $MapName" -ForegroundColor White

  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $rm = $null
  $rm = az network vhub route-map show `
    -g $ResourceGroup `
    --vhub-name $VhubName `
    -n $MapName `
    -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP

  if (-not $rm) {
    Write-Host "    [not found]" -ForegroundColor Red
    return
  }

  Write-Host "    Provisioning: $($rm.provisioningState)" -ForegroundColor Gray

  if ($rm.rules -and $rm.rules.Count -gt 0) {
    foreach ($rule in $rm.rules) {
      Write-Host ""
      Write-Host "    Rule: $($rule.name)" -ForegroundColor Yellow
      if ($rule.matchCriteria -and $rule.matchCriteria.Count -gt 0) {
        foreach ($mc in $rule.matchCriteria) {
          $prefixes = if ($mc.routePrefix) { $mc.routePrefix -join ", " } else { "(any)" }
          Write-Host "      Match:  [$($mc.matchCondition)] prefix=$prefixes" -ForegroundColor Gray
        }
      }
      if ($rule.actions -and $rule.actions.Count -gt 0) {
        foreach ($action in $rule.actions) {
          $paramStr = ""
          if ($action.parameters -and $action.parameters.Count -gt 0) {
            foreach ($p in $action.parameters) {
              if ($p.community -and $p.community.Count -gt 0) { $paramStr += " community=$($p.community -join ',')" }
              if ($p.asPath    -and $p.asPath.Count    -gt 0) { $paramStr += " asPath=$($p.asPath -join ',')" }
            }
          }
          Write-Host "      Action: $($action.type)$paramStr" -ForegroundColor Green
        }
      } else {
        Write-Host "      Action: (pass-through)" -ForegroundColor DarkGray
      }
      Write-Host "      Next:   $($rule.nextStepIfMatched)" -ForegroundColor DarkGray
    }
  } else {
    Write-Host "    (no rules configured)" -ForegroundColor DarkGray
  }
}

function Show-ConnectionRouteMaps {
  param([string]$ConnName)
  Write-Host ""
  Write-Host "  Connection: $ConnName" -ForegroundColor White

  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $conn = $null
  $conn = az network vhub connection show `
    -g $ResourceGroup `
    --vhub-name $VhubName `
    -n $ConnName `
    -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP

  if (-not $conn) {
    Write-Host "    [not found]" -ForegroundColor Red
    return
  }

  # PSObject.Properties check required under Set-StrictMode when inbound/outboundRouteMap
  # may not be present on the routingConfiguration object (e.g. conn has no route map assigned)
  $rcObj = $conn.routingConfiguration
  $inboundMap  = "(none)"
  $outboundMap = "(none)"
  if ($rcObj) {
    if (($rcObj.PSObject.Properties.Name -contains "inboundRouteMap")  -and $rcObj.inboundRouteMap)  { $inboundMap  = $rcObj.inboundRouteMap.id }
    if (($rcObj.PSObject.Properties.Name -contains "outboundRouteMap") -and $rcObj.outboundRouteMap) { $outboundMap = $rcObj.outboundRouteMap.id }
  }

  # Shorten IDs for display
  if ($inboundMap -ne "(none)") {
    $inboundMap = $inboundMap.Split("/")[-1]
  }
  if ($outboundMap -ne "(none)") {
    $outboundMap = $outboundMap.Split("/")[-1]
  }

  Write-Host "    State:    $($conn.provisioningState)" -ForegroundColor Gray
  Write-Host "    Inbound:  $inboundMap" -ForegroundColor Gray
  Write-Host "    Outbound: $outboundMap" -ForegroundColor Gray
}

function Show-EffectiveRoutes {
  param([string]$ConnName, [string]$ConnId, [string]$Note)
  Write-Host ""
  Write-Host "  Effective Routes for: $ConnName" -ForegroundColor White
  if ($Note) { Write-Host "  Note: $Note" -ForegroundColor DarkGray }

  $oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $routes = $null
  $routes = az network vhub get-effective-routes `
    --resource-group $ResourceGroup `
    --name $VhubName `
    --resource-type VirtualNetworkConnection `
    --resource-id $ConnId `
    --query "value[].{prefix:addressPrefixes[0], nextHop:nextHopType, origin:routeOrigin, asPath:asPath}" `
    -o json 2>$null | ConvertFrom-Json
  $ErrorActionPreference = $oldEP

  if ($routes -and $routes.Count -gt 0) {
    Write-Host ""
    Write-Host "    Prefix               NextHop                    Origin" -ForegroundColor DarkGray
    Write-Host "    " + ("-" * 60) -ForegroundColor DarkGray
    foreach ($r in $routes) {
      $prefix  = if ($r.prefix)  { $r.prefix.PadRight(22) }  else { "(unknown)".PadRight(22) }
      $nexthop = if ($r.nextHop) { $r.nextHop.PadRight(26) } else { "".PadRight(26) }
      $origin  = if ($r.origin)  { $r.origin } else { "" }
      Write-Host "    $prefix $nexthop $origin" -ForegroundColor Gray
    }
  } else {
    Write-Host "    (no routes found - may take a few minutes after provisioning)" -ForegroundColor DarkGray
  }
}

# ============================================
# MAIN
# ============================================

Write-Host ""
Write-Host "Lab 010: Route Maps Inspection" -ForegroundColor Cyan
Write-Host "==============================" -ForegroundColor Cyan

$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null

# Check lab is deployed
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$rg = $null
$rg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
if (-not $rg) {
  Write-Host ""
  Write-Host "Resource group '$ResourceGroup' not found." -ForegroundColor Red
  Write-Host "Deploy the lab first: .\lab.ps1 -Deploy lab-010" -ForegroundColor Yellow
  exit 1
}

# -----------------------------------------------
Write-Section "Route Map Definitions"
Write-Host ""
Write-Host "Each Route Map below is a policy attached to a hub connection." -ForegroundColor DarkGray
Write-Host "Rules are evaluated top-to-bottom; nextStepIfMatched controls flow." -ForegroundColor DarkGray

Show-RouteMapDetail -MapName "rm-community-tag"
Show-RouteMapDetail -MapName "rm-route-filter"
Show-RouteMapDetail -MapName "rm-as-prepend"

# -----------------------------------------------
Write-Section "Route Map Assignments on Connections"
Write-Host ""
Write-Host "Shows which Route Maps are attached (inbound/outbound) on each connection." -ForegroundColor DarkGray

Show-ConnectionRouteMaps -ConnName $ConnAName
Show-ConnectionRouteMaps -ConnName $ConnBName

# -----------------------------------------------
Write-Section "Effective Routes (Route Filter Demo)"
Write-Host ""
Write-Host "Key question: does rm-route-filter prevent 10.61.0.0/16 reaching Spoke-B?" -ForegroundColor DarkGray

# Get connection IDs
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$connA = $null
$connB = $null
$connA = az network vhub connection show -g $ResourceGroup --vhub-name $VhubName -n $ConnAName -o json 2>$null | ConvertFrom-Json
$connB = az network vhub connection show -g $ResourceGroup --vhub-name $VhubName -n $ConnBName -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP

if ($connA -and $connA.id) {
  Show-EffectiveRoutes `
    -ConnName $ConnAName `
    -ConnId $connA.id `
    -Note "rm-as-prepend outbound: routes hub sends to Spoke-A have AS 65010 prepended twice"
}

if ($connB -and $connB.id) {
  Show-EffectiveRoutes `
    -ConnName $ConnBName `
    -ConnId $connB.id `
    -Note "rm-route-filter outbound: 10.61.0.0/16 should NOT appear here"
}

# -----------------------------------------------
Write-Section "What to Look For"

Write-Host ""
Write-Host "  [rm-community-tag] Routes from Spoke-A now carry community 65010:100." -ForegroundColor White
Write-Host "  This tag travels with the route inside the hub and can be matched" -ForegroundColor Gray
Write-Host "  by downstream route maps or policies on other connections." -ForegroundColor Gray
Write-Host ""
Write-Host "  [rm-route-filter] Spoke-B's effective route table should NOT contain" -ForegroundColor White
Write-Host "  10.61.0.0/16. This proves the outbound drop rule is working." -ForegroundColor Gray
Write-Host "  Any VM in Spoke-B cannot reach Spoke-A because the route was filtered." -ForegroundColor Gray
Write-Host ""
Write-Host "  [rm-as-prepend] Routes arriving at Spoke-A have AS 65010 twice in" -ForegroundColor White
Write-Host "  the AS path. In a BGP environment with multiple paths, the longer" -ForegroundColor Gray
Write-Host "  AS path makes these routes less preferred (higher BGP path length)." -ForegroundColor Gray
Write-Host ""
Write-Host "Useful CLI commands:" -ForegroundColor Yellow
Write-Host "  az network vhub route-map list -g $ResourceGroup --vhub-name $VhubName -o table" -ForegroundColor Gray
Write-Host "  az network vhub connection list -g $ResourceGroup --vhub-name $VhubName -o table" -ForegroundColor Gray
Write-Host ""
