# labs/lab-009-avnm-hub-spoke-global-mesh/inspect.ps1
# Post-deploy validation for lab-009 (AVNM hub-spoke + Global Mesh)
#
# Checks:
#   - AVNM instance and scope
#   - Network groups and their members
#   - Active connectivity configurations per region
#   - VNet peering state for all 4 VNets
#   - Global Mesh status (if enabled via portal)

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [string]$Location  = "eastus",
  [string]$Location2 = "westus2"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LabRoot  = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path

. (Join-Path $RepoRoot "scripts\labs-common.ps1")

$ResourceGroup = "rg-lab-009-avnm"
$AvnmName      = "avnm-lab-009"
$NgR1          = "ng-hub-spoke-r1"
$NgR2          = "ng-hub-spoke-r2"

$HubVnetR1   = "vnet-hub-lab-009-r1"
$SpokeVnetR1 = "vnet-spoke-lab-009-r1"
$HubVnetR2   = "vnet-hub-lab-009-r2"
$SpokeVnetR2 = "vnet-spoke-lab-009-r2"

function Write-Section { param([string]$Msg) Write-Host ""; Write-Host $Msg -ForegroundColor Cyan; Write-Host ("-" * $Msg.Length) -ForegroundColor DarkCyan }
function Write-Pass { param([string]$Msg) Write-Host "  [PASS] $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "  [WARN] $Msg" -ForegroundColor Yellow }
function Write-Info { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor Gray }

Write-Host ""
Write-Host "Lab 009: AVNM Inspection Report" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan

$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Ensure-AzureAuth -DoLogin
az account set --subscription $SubscriptionId | Out-Null

# ============================================
# SECTION 1: AVNM Instance
# ============================================
Write-Section "1. AVNM Instance"

$avnm = az network manager show `
  --name $AvnmName `
  --resource-group $ResourceGroup `
  -o json 2>$null | ConvertFrom-Json

if ($avnm) {
  Write-Pass "AVNM found: $AvnmName"
  Write-Info "  Location       : $($avnm.location)"
  Write-Info "  Scope accesses : $($avnm.networkManagerScopeAccesses -join ', ')"
  if ($avnm.networkManagerScopes -and $avnm.networkManagerScopes.subscriptions) {
    Write-Info "  Scopes         : $($avnm.networkManagerScopes.subscriptions -join ', ')"
  }
} else {
  Write-Warn "AVNM instance not found: $AvnmName"
  Write-Info "  Has the lab been deployed? Run .\deploy.ps1"
  exit 1
}

# ============================================
# SECTION 2: Network Groups
# ============================================
Write-Section "2. Network Groups"

foreach ($ngName in @($NgR1, $NgR2)) {
  $ng = az network manager group show `
    --name $ngName `
    --network-manager-name $AvnmName `
    --resource-group $ResourceGroup `
    -o json 2>$null | ConvertFrom-Json

  if ($ng) {
    Write-Pass "Network group: $ngName"
    Write-Info "  Description: $($ng.description)"

    $members = az network manager group static-member list `
      --network-group-name $ngName `
      --network-manager-name $AvnmName `
      --resource-group $ResourceGroup `
      -o json 2>$null | ConvertFrom-Json

    if ($members -and $members.Count -gt 0) {
      Write-Info "  Static members ($($members.Count)):"
      foreach ($m in $members) {
        $vnetName = $m.resourceId.Split('/')[-1]
        Write-Info "    - $vnetName"
      }
    } else {
      Write-Warn "  No static members found in $ngName"
    }
  } else {
    Write-Warn "Network group not found: $ngName"
  }
}

# Check for Global Mesh group (may have been created via portal)
$ngMesh = az network manager group show `
  --name "ng-global-mesh" `
  --network-manager-name $AvnmName `
  --resource-group $ResourceGroup `
  -o json 2>$null | ConvertFrom-Json

if ($ngMesh) {
  Write-Pass "Global Mesh network group found: ng-global-mesh"
  $meshMembers = az network manager group static-member list `
    --network-group-name "ng-global-mesh" `
    --network-manager-name $AvnmName `
    --resource-group $ResourceGroup `
    -o json 2>$null | ConvertFrom-Json
  if ($meshMembers -and $meshMembers.Count -gt 0) {
    Write-Info "  Members: $($meshMembers.Count)"
  }
} else {
  Write-Info "  Global Mesh group (ng-global-mesh) not yet created."
  Write-Info "  Create it via the portal - see README.md Section 4."
}

# ============================================
# SECTION 3: Connectivity Configurations
# ============================================
Write-Section "3. Connectivity Configurations"

$configs = az network manager connect-config list `
  --network-manager-name $AvnmName `
  --resource-group $ResourceGroup `
  -o json 2>$null | ConvertFrom-Json

if ($configs -and $configs.Count -gt 0) {
  Write-Pass "Found $($configs.Count) connectivity configuration(s)"
  foreach ($cc in $configs) {
    $ccName = $cc.name
    $topo   = $cc.connectivityTopology
    $isGlobal = $false
    if ($cc.appliesToGroups) {
      foreach ($g in $cc.appliesToGroups) {
        if ($g.isGlobal -eq $true) { $isGlobal = $true }
      }
    }
    $globalLabel = "No"
    if ($isGlobal) { $globalLabel = "YES" }
    Write-Info "  $ccName"
    Write-Info "    Topology   : $topo"
    Write-Info "    Global Mesh: $globalLabel"
    if ($cc.hubs -and $cc.hubs.Count -gt 0) {
      foreach ($h in $cc.hubs) {
        Write-Info "    Hub        : $($h.resourceId.Split('/')[-1])"
      }
    }
  }
} else {
  Write-Warn "No connectivity configurations found"
}

# ============================================
# SECTION 4: Active Deployments
# ============================================
Write-Section "4. Active AVNM Deployments"

$activeDeps = az network manager list-active-connectivity-config `
  --name $AvnmName `
  --resource-group $ResourceGroup `
  --regions $Location $Location2 `
  -o json 2>$null | ConvertFrom-Json

if ($activeDeps -and $activeDeps.value -and $activeDeps.value.Count -gt 0) {
  Write-Pass "Active deployment(s): $($activeDeps.value.Count)"
  foreach ($dep in $activeDeps.value) {
    $configName = $dep.id.Split('/')[-1]
    Write-Info "  Config: $configName"
  }
} else {
  Write-Warn "No active deployments found. Has post-commit been applied?"
  Write-Info "  The lab post-commit was submitted during deploy."
  Write-Info "  If you just deployed, wait 1-2 minutes and run inspect.ps1 again."
}

# ============================================
# SECTION 5: VNet Peering State
# ============================================
Write-Section "5. VNet Peering State"

$allVnets = @(
  @{ Name=$HubVnetR1;   Region=$Location  },
  @{ Name=$SpokeVnetR1; Region=$Location  },
  @{ Name=$HubVnetR2;   Region=$Location2 },
  @{ Name=$SpokeVnetR2; Region=$Location2 }
)

$connectedCount = 0
$totalCount     = 0

foreach ($v in $allVnets) {
  $peerings = az network vnet peering list `
    --resource-group $ResourceGroup `
    --vnet-name $v.Name `
    -o json 2>$null | ConvertFrom-Json

  if ($peerings -and $peerings.Count -gt 0) {
    foreach ($p in $peerings) {
      $totalCount++
      $remote = $p.remoteVirtualNetwork.id.Split('/')[-1]
      $state  = $p.peeringState
      $sync   = $p.peeringSyncLevel
      if ($state -eq "Connected") {
        $connectedCount++
        Write-Pass "$($v.Name) <-> $remote : $state ($sync)"
      } else {
        Write-Warn "$($v.Name) <-> $remote : $state ($sync)"
      }
    }
  } else {
    Write-Warn "$($v.Name) ($($v.Region)) : no peerings found"
  }
}

Write-Host ""
Write-Info "Peering summary: $connectedCount / $totalCount Connected"
if ($connectedCount -eq $totalCount -and $totalCount -ge 4) {
  Write-Pass "All peerings Connected. Hub-spoke connectivity is active."
} elseif ($totalCount -eq 0) {
  Write-Warn "No peerings yet. AVNM may still be reconciling (try again in 2 min)."
} else {
  Write-Warn "Some peerings not yet Connected. AVNM reconciliation may be in progress."
}

# ============================================
# SECTION 6: Global Mesh Connectivity Check
# ============================================
Write-Section "6. Global Mesh Status"

# Look for a mesh-type connectivity config
$meshConfig = $null
if ($configs) {
  foreach ($cc in $configs) {
    if ($cc.connectivityTopology -eq "Mesh") {
      $meshConfig = $cc
    }
  }
}

if ($meshConfig) {
  Write-Pass "Global Mesh configuration found: $($meshConfig.name)"
  $isGlobal = $false
  if ($meshConfig.appliesToGroups) {
    foreach ($g in $meshConfig.appliesToGroups) {
      if ($g.isGlobal -eq $true) { $isGlobal = $true }
    }
  }
  if ($isGlobal) {
    Write-Pass "isGlobal = true  - cross-region mesh is configured"
  } else {
    Write-Warn "isGlobal = false - mesh exists but is NOT cross-region"
    Write-Info "  Edit the config in the portal and enable 'Global Mesh'."
  }

  # Cross-region peerings (hub-r1 to hub-r2) indicate mesh is active
  $hubR1Peerings = az network vnet peering list `
    --resource-group $ResourceGroup `
    --vnet-name $HubVnetR1 `
    -o json 2>$null | ConvertFrom-Json

  $crossRegionPeering = $null
  if ($hubR1Peerings) {
    foreach ($p in $hubR1Peerings) {
      $remoteName = $p.remoteVirtualNetwork.id.Split('/')[-1]
      if ($remoteName -eq $HubVnetR2 -or $remoteName -eq $SpokeVnetR2) {
        $crossRegionPeering = $p
      }
    }
  }

  if ($crossRegionPeering) {
    Write-Pass "Cross-region peering detected: $HubVnetR1 <-> $($crossRegionPeering.remoteVirtualNetwork.id.Split('/')[-1]) : $($crossRegionPeering.peeringState)"
  } else {
    Write-Info "No cross-region peerings yet. If Global Mesh was just deployed, wait 1-2 min."
  }
} else {
  Write-Info "No Global Mesh configuration found."
  Write-Info "This is expected - Global Mesh is the manual portal step."
  Write-Host ""
  Write-Host "  To enable Global Mesh (portal walkthrough):" -ForegroundColor Yellow
  Write-Host "    1. Open Azure Portal > Virtual Network Managers > $AvnmName" -ForegroundColor Gray
  Write-Host "    2. Configurations > + Add > Connectivity configuration" -ForegroundColor Gray
  Write-Host "    3. Name: cc-global-mesh | Topology: Mesh | Enable 'Enable mesh connectivity across regions'" -ForegroundColor Gray
  Write-Host "    4. Add network group: ng-global-mesh (create it first with hub-r1 + hub-r2)" -ForegroundColor Gray
  Write-Host "    5. Deployments > Deploy > select cc-global-mesh > regions: $Location, $Location2" -ForegroundColor Gray
  Write-Host ""
  Write-Host "  See README.md Section 4 for full instructions." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Inspection complete." -ForegroundColor Green
Write-Host ""
