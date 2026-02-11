# labs/lab-006-vwan-spoke-bgp-router-loopback/inspect.ps1
# Quick inspection of lab-006 routes, BGP state, and VM health
#
# Captures all artifacts to .data/lab-006/ and prints a PASS/FAIL summary.
# Safe on Windows PowerShell 5.1: all az calls use JSON + ConvertFrom-Json,
# stderr is suppressed with SilentlyContinue to prevent crash from native warnings.
#
# Usage:
#   .\inspect.ps1                    # Full inspection
#   .\inspect.ps1 -RoutesOnly        # Just effective routes
#   .\inspect.ps1 -BgpOnly           # Just BGP peering status

[CmdletBinding()]
param(
  [string]$SubscriptionKey,
  [switch]$RoutesOnly,
  [switch]$BgpOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Suppress Python 32-bit-on-64-bit-Windows UserWarning from Azure CLI.
$env:PYTHONWARNINGS = "ignore::UserWarning"

$LabRoot = $PSScriptRoot
$RepoRoot = Resolve-Path (Join-Path $LabRoot "..\..") | Select-Object -ExpandProperty Path

# Load shared helpers
. (Join-Path $RepoRoot "scripts\labs-common.ps1")

# Lab configuration
$ResourceGroup = "rg-lab-006-vwan-bgp-router"
$VhubName      = "vhub-lab-006"
$RouterVmName  = "vm-router-006"
$ClientAVmName = "vm-client-a-006"
$ClientBVmName = "vm-client-b-006"

# Artifacts output directory
$DataDir = Join-Path $RepoRoot ".data\lab-006"
if (-not (Test-Path $DataDir)) {
  New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}

# Helper: safe az CLI call returning parsed JSON (never crashes on stderr)
function Invoke-AzJson {
  param([string]$Command)
  $oldErrPref = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  try {
    $raw = Invoke-Expression "az $Command -o json 2>`$null"
    if ($LASTEXITCODE -ne 0) { return $null }
    if ($raw) {
      try { return ($raw | ConvertFrom-Json) } catch { return $null }
    }
    return $null
  } finally {
    $ErrorActionPreference = $oldErrPref
  }
}

# Helper: write JSON artifact without BOM
function Write-JsonArtifact {
  param([string]$Name, $Object)
  if (-not $Object) { return }
  $json = $Object | ConvertTo-Json -Depth 10
  $path = Join-Path $DataDir "inspect-$Name.json"
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($path, $json, $utf8NoBom)
}

function Write-Section {
  param([string]$Title)
  Write-Host ""
  Write-Host ("=" * 50) -ForegroundColor Cyan
  Write-Host $Title -ForegroundColor Cyan
  Write-Host ("=" * 50) -ForegroundColor Cyan
}

function Write-Check {
  param([string]$Label, [bool]$Passed, [string]$Detail = "")
  if ($Passed) {
    Write-Host "  [PASS] $Label" -ForegroundColor Green
  } else {
    Write-Host "  [FAIL] $Label" -ForegroundColor Red
  }
  if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
}

# --- Auth (opens browser if no valid token) ---
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Ensure-AzureAuth -DoLogin
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
az account set --subscription $SubscriptionId 2>$null | Out-Null
$setExit = $LASTEXITCODE
$ErrorActionPreference = $oldErrPref
if ($setExit -ne 0) {
  Write-Host "Could not set subscription $SubscriptionId. Check .data/subs.json." -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "Lab 006: Inspect" -ForegroundColor Cyan
Write-Host "=================" -ForegroundColor Cyan

# Check RG exists
$existingRg = Invoke-AzJson "group show -n $ResourceGroup"
if (-not $existingRg) {
  Write-Host "Resource group '$ResourceGroup' not found. Deploy first." -ForegroundColor Red
  exit 1
}

# Track pass/fail for summary
$checks = @()

# --- vHub Router IPs ---
$vhubObj = Invoke-AzJson "network vhub show -g $ResourceGroup -n $VhubName"
$vhubRouterIps = @()
if ($vhubObj -and $vhubObj.virtualRouterIps) {
  $vhubRouterIps = @($vhubObj.virtualRouterIps)
}
Write-JsonArtifact -Name "vhub" -Object $vhubObj

# --- BGP Status ---
if (-not $RoutesOnly) {
  Write-Section "BGP Peering Status"

  $bgpConns = Invoke-AzJson "network vhub bgpconnection list -g $ResourceGroup --vhub-name $VhubName"
  Write-JsonArtifact -Name "bgpconnections" -Object $bgpConns

  if ($bgpConns) {
    $bgpConnsArr = @($bgpConns)
    foreach ($conn in $bgpConnsArr) {
      $stateColor = if ($conn.provisioningState -eq "Succeeded") { "Green" } else { "Red" }
      Write-Host "  $($conn.name)" -ForegroundColor White
      Write-Host "    Peer IP:     $($conn.peerIp)" -ForegroundColor DarkGray
      Write-Host "    Peer ASN:    $($conn.peerAsn)" -ForegroundColor DarkGray
      Write-Host "    State:       $($conn.provisioningState)" -ForegroundColor $stateColor
      $connName = ""
      if ($conn.hubVirtualNetworkConnection -and $conn.hubVirtualNetworkConnection.id) {
        $connName = ($conn.hubVirtualNetworkConnection.id -split "/")[-1]
      }
      Write-Host "    Connection:  $connName" -ForegroundColor DarkGray
    }

    $succeededCount = @($bgpConnsArr | Where-Object { $_.provisioningState -eq "Succeeded" }).Count
    $bothSucceeded = ($succeededCount -ge 2)
    $checks += @{ label = "Both bgpconnections Succeeded"; passed = $bothSucceeded }
  } else {
    Write-Host "  No BGP peerings found." -ForegroundColor Yellow
    $checks += @{ label = "Both bgpconnections Succeeded"; passed = $false }
  }

  # Per-connection show (for detailed diagnostics)
  foreach ($name in @("bgp-peer-router-006-0", "bgp-peer-router-006-1")) {
    $connDetail = Invoke-AzJson "network vhub bgpconnection show -g $ResourceGroup --vhub-name $VhubName -n $name"
    Write-JsonArtifact -Name "bgpconn-$name" -Object $connDetail
  }

  # vHub router IPs
  Write-Host ""
  if ($vhubRouterIps.Count -ge 2) {
    Write-Host "  vHub Router IPs: $($vhubRouterIps[0]), $($vhubRouterIps[1])" -ForegroundColor Gray
    $checks += @{ label = "vHub virtualRouterIps resolved (2)"; passed = $true }
  } else {
    Write-Host "  vHub Router IPs: not available" -ForegroundColor Yellow
    $checks += @{ label = "vHub virtualRouterIps resolved (2)"; passed = $false }
  }

  # vHub learned routes
  Write-Section "vHub Learned Routes (defaultRouteTable)"
  $learnedRoutes = Invoke-AzJson "network vhub route-table show -g $ResourceGroup --vhub-name $VhubName -n defaultRouteTable --query routes"
  Write-JsonArtifact -Name "vhub-routes" -Object $learnedRoutes
  if ($learnedRoutes) {
    $routesArr = @($learnedRoutes)
    foreach ($route in $routesArr) {
      $dests = if ($route.destinations) { $route.destinations -join ", " } else { "" }
      Write-Host "  $($route.destinationType): $dests -> $($route.nextHopType)" -ForegroundColor DarkGray
    }
  } else {
    Write-Host "  No static routes in default RT (BGP-learned routes show in effective routes)" -ForegroundColor DarkGray
  }
}

# --- Effective Routes ---
if (-not $BgpOnly) {
  # Client A
  Write-Section "Effective Routes - Client A"
  $clientAVm = Invoke-AzJson "vm show -g $ResourceGroup -n $ClientAVmName"
  $clientANicId = $null
  if ($clientAVm) { try { $clientANicId = $clientAVm.networkProfile.networkInterfaces[0].id } catch { } }
  if ($clientANicId) {
    $clientANicName = ($clientANicId -split "/")[-1]
    $clientARoutes = Invoke-AzJson "network nic show-effective-route-table -g $ResourceGroup -n $clientANicName"
    Write-JsonArtifact -Name "routes-client-a" -Object $clientARoutes
    if ($clientARoutes -and $clientARoutes.value) {
      foreach ($r in $clientARoutes.value) {
        $prefixes = if ($r.addressPrefix) { $r.addressPrefix -join ", " } else { "" }
        $nhops = if ($r.nextHopIpAddress) { $r.nextHopIpAddress -join ", " } else { "" }
        Write-Host "  $($r.source) $prefixes -> $($r.nextHopType) $nhops" -ForegroundColor DarkGray
      }
    }
  } else {
    Write-Host "  Client A VM not found." -ForegroundColor Yellow
  }

  # Client B
  Write-Section "Effective Routes - Client B"
  $clientBVm = Invoke-AzJson "vm show -g $ResourceGroup -n $ClientBVmName"
  $clientBNicId = $null
  if ($clientBVm) { try { $clientBNicId = $clientBVm.networkProfile.networkInterfaces[0].id } catch { } }
  if ($clientBNicId) {
    $clientBNicName = ($clientBNicId -split "/")[-1]
    $clientBRoutes = Invoke-AzJson "network nic show-effective-route-table -g $ResourceGroup -n $clientBNicName"
    Write-JsonArtifact -Name "routes-client-b" -Object $clientBRoutes
    if ($clientBRoutes -and $clientBRoutes.value) {
      foreach ($r in $clientBRoutes.value) {
        $prefixes = if ($r.addressPrefix) { $r.addressPrefix -join ", " } else { "" }
        $nhops = if ($r.nextHopIpAddress) { $r.nextHopIpAddress -join ", " } else { "" }
        Write-Host "  $($r.source) $prefixes -> $($r.nextHopType) $nhops" -ForegroundColor DarkGray
      }
    }
  } else {
    Write-Host "  Client B VM not found." -ForegroundColor Yellow
  }

  # Router hub-side NIC
  Write-Section "Effective Routes - Router (hub-side NIC)"
  $routerNicName = "nic-router-hubside-006"
  $routerRoutes = Invoke-AzJson "network nic show-effective-route-table -g $ResourceGroup -n $routerNicName"
  Write-JsonArtifact -Name "routes-router" -Object $routerRoutes
  if ($routerRoutes -and $routerRoutes.value) {
    foreach ($r in $routerRoutes.value) {
      $prefixes = if ($r.addressPrefix) { $r.addressPrefix -join ", " } else { "" }
      $nhops = if ($r.nextHopIpAddress) { $r.nextHopIpAddress -join ", " } else { "" }
      Write-Host "  $($r.source) $prefixes -> $($r.nextHopType) $nhops" -ForegroundColor DarkGray
    }
  }
}

# --- Router vtysh outputs ---
if (-not $RoutesOnly) {
  Write-Section "Router BGP Status (vtysh)"

  $bgpSummaryScript = 'sudo vtysh -c "show bgp summary" 2>/dev/null; echo "---"; sudo vtysh -c "show bgp ipv4 unicast" 2>/dev/null'
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $vtyshRaw = az vm run-command invoke `
    --resource-group $ResourceGroup `
    --name $RouterVmName `
    --command-id RunShellScript `
    --scripts $bgpSummaryScript `
    -o json 2>$null
  $ErrorActionPreference = $oldErrPref

  $vtyshOutput = $null
  if ($vtyshRaw) {
    try {
      $vtyshObj = $vtyshRaw | ConvertFrom-Json
      $vtyshOutput = $vtyshObj.value[0].message
    } catch { }
  }

  if ($vtyshOutput) {
    Write-Host $vtyshOutput -ForegroundColor DarkGray
    Write-JsonArtifact -Name "vtysh-bgp" -Object @{ output = $vtyshOutput }

    # Parse established count
    $establishedMatches = [regex]::Matches($vtyshOutput, '(?m)^\S+\s+4\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+[\d:]+\s+\d+')
    $establishedCount = $establishedMatches.Count
    $checks += @{ label = "Both BGP neighbors Established on router"; passed = ($establishedCount -ge 2) }
  } else {
    Write-Host "  Could not retrieve vtysh output from router." -ForegroundColor Yellow
    $checks += @{ label = "Both BGP neighbors Established on router"; passed = $false }
  }
}

# --- VM Status ---
if (-not $RoutesOnly -and -not $BgpOnly) {
  Write-Section "VM Status"
  $vms = @($RouterVmName, $ClientAVmName, $ClientBVmName)
  $allRunning = $true
  foreach ($vm in $vms) {
    $vmObj = Invoke-AzJson "vm show -g $ResourceGroup -n $vm --show-details"
    if ($vmObj) {
      $stateColor = if ($vmObj.powerState -eq "VM running") { "Green" } else { "Yellow" }
      if ($vmObj.powerState -ne "VM running") { $allRunning = $false }
      Write-Host "  $($vmObj.name): $($vmObj.powerState)" -ForegroundColor $stateColor
      Write-Host "    Private: $($vmObj.privateIps)  Public: $($vmObj.publicIps)" -ForegroundColor DarkGray
    }
  }
  $checks += @{ label = "All 3 VMs running"; passed = $allRunning }
}

# --- PASS/FAIL Summary ---
Write-Host ""
Write-Host ("=" * 50) -ForegroundColor Cyan
Write-Host "INSPECTION SUMMARY" -ForegroundColor Cyan
Write-Host ("=" * 50) -ForegroundColor Cyan

$passCount = 0
$failCount = 0
foreach ($c in $checks) {
  if ($c.passed) {
    Write-Host "  [PASS] $($c.label)" -ForegroundColor Green
    $passCount++
  } else {
    Write-Host "  [FAIL] $($c.label)" -ForegroundColor Red
    $failCount++
  }
}

Write-Host ""
if ($failCount -eq 0) {
  Write-Host "  Result: ALL CHECKS PASSED ($passCount/$passCount)" -ForegroundColor Green
} else {
  Write-Host "  Result: $failCount FAILED, $passCount PASSED" -ForegroundColor Red
}

Write-Host ""
Write-Host "  Artifacts saved to: $DataDir" -ForegroundColor DarkGray
Write-Host "  For detailed validation, see docs/validation.md" -ForegroundColor DarkGray
Write-Host ""
