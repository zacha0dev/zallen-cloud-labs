# labs/lab-006-vwan-spoke-bgp-router-loopback/inspect.ps1
# Quick inspection of lab-006 routes, BGP state, and VM health
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
# Without this, stderr warnings become terminating errors under $ErrorActionPreference = "Stop" in PS 5.1.
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

function Write-Section {
  param([string]$Title)
  Write-Host ""
  Write-Host ("=" * 50) -ForegroundColor Cyan
  Write-Host $Title -ForegroundColor Cyan
  Write-Host ("=" * 50) -ForegroundColor Cyan
}

# Auth
$SubscriptionId = Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot
Ensure-AzureAuth -DoLogin
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
az account set --subscription $SubscriptionId 2>$null | Out-Null
$ErrorActionPreference = $oldErrPref

Write-Host ""
Write-Host "Lab 006: Inspect" -ForegroundColor Cyan
Write-Host "=================" -ForegroundColor Cyan

# Check RG exists
$oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existingRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldErrPref
if (-not $existingRg) {
  Write-Host "Resource group '$ResourceGroup' not found. Deploy first." -ForegroundColor Red
  exit 1
}

# --- BGP Status ---
if (-not $RoutesOnly) {
  Write-Section "BGP Peering Status"

  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $bgpConnsRaw = az network vhub bgpconnection list -g $ResourceGroup --vhub-name $VhubName -o json 2>$null
  $ErrorActionPreference = $oldErrPref
  $bgpConns = $null
  if ($bgpConnsRaw) { try { $bgpConns = $bgpConnsRaw | ConvertFrom-Json } catch { } }
  if ($bgpConns) {
    foreach ($conn in $bgpConns) {
      $stateColor = if ($conn.provisioningState -eq "Succeeded") { "Green" } else { "Red" }
      Write-Host "  $($conn.name)" -ForegroundColor White
      Write-Host "    Peer IP:     $($conn.peerIp)" -ForegroundColor DarkGray
      Write-Host "    Peer ASN:    $($conn.peerAsn)" -ForegroundColor DarkGray
      Write-Host "    State:       $($conn.provisioningState)" -ForegroundColor $stateColor
      Write-Host "    Connection:  $($conn.hubVirtualNetworkConnection.id -split '/')[-1]" -ForegroundColor DarkGray
    }
  } else {
    Write-Host "  No BGP peerings found." -ForegroundColor Yellow
  }

  # vHub learned routes
  Write-Section "vHub Learned Routes (defaultRouteTable)"
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $learnedRaw = az network vhub route-table show -g $ResourceGroup --vhub-name $VhubName -n defaultRouteTable --query routes -o json 2>$null
  $ErrorActionPreference = $oldErrPref
  $learnedRoutes = $null
  if ($learnedRaw) { try { $learnedRoutes = $learnedRaw | ConvertFrom-Json } catch { } }
  if ($learnedRoutes) {
    foreach ($route in $learnedRoutes) {
      Write-Host "  $($route.destinationType): $($route.destinations -join ', ') -> $($route.nextHopType)" -ForegroundColor DarkGray
    }
  } else {
    Write-Host "  No static routes in default RT (BGP-learned routes show in effective routes)" -ForegroundColor DarkGray
  }
}

# --- Effective Routes ---
if (-not $BgpOnly) {
  Write-Section "Effective Routes - Client A"
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $clientANicRaw = az vm show -g $ResourceGroup -n $ClientAVmName -o json 2>$null
  $ErrorActionPreference = $oldErrPref
  $clientANicId = $null
  if ($clientANicRaw) { try { $clientANicId = ($clientANicRaw | ConvertFrom-Json).networkProfile.networkInterfaces[0].id } catch { } }
  if ($clientANicId) {
    $clientANicName = ($clientANicId -split "/")[-1]
    $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    az network nic show-effective-route-table -g $ResourceGroup -n $clientANicName -o table 2>$null
    $ErrorActionPreference = $oldErrPref
  } else {
    Write-Host "  Client A VM not found." -ForegroundColor Yellow
  }

  Write-Section "Effective Routes - Client B"
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  $clientBNicRaw = az vm show -g $ResourceGroup -n $ClientBVmName -o json 2>$null
  $ErrorActionPreference = $oldErrPref
  $clientBNicId = $null
  if ($clientBNicRaw) { try { $clientBNicId = ($clientBNicRaw | ConvertFrom-Json).networkProfile.networkInterfaces[0].id } catch { } }
  if ($clientBNicId) {
    $clientBNicName = ($clientBNicId -split "/")[-1]
    $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    az network nic show-effective-route-table -g $ResourceGroup -n $clientBNicName -o table 2>$null
    $ErrorActionPreference = $oldErrPref
  } else {
    Write-Host "  Client B VM not found." -ForegroundColor Yellow
  }

  Write-Section "Effective Routes - Router (hub-side NIC)"
  $routerNicName = "nic-router-hubside-006"
  $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
  az network nic show-effective-route-table -g $ResourceGroup -n $routerNicName -o table 2>$null
  $ErrorActionPreference = $oldErrPref
}

# --- VM Status ---
if (-not $RoutesOnly -and -not $BgpOnly) {
  Write-Section "VM Status"
  $vms = @($RouterVmName, $ClientAVmName, $ClientBVmName)
  foreach ($vm in $vms) {
    $oldErrPref = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $vmRaw = az vm show -g $ResourceGroup -n $vm --show-details -o json 2>$null
    $ErrorActionPreference = $oldErrPref
    $vmInfo = $null
    if ($vmRaw) { try { $obj = $vmRaw | ConvertFrom-Json; $vmInfo = [PSCustomObject]@{Name=$obj.name; State=$obj.powerState; PrivateIPs=$obj.privateIps; PublicIPs=$obj.publicIps} } catch { } }
    if ($vmInfo) {
      $stateColor = if ($vmInfo.State -eq "VM running") { "Green" } else { "Yellow" }
      Write-Host "  $($vmInfo.Name): $($vmInfo.State)" -ForegroundColor $stateColor
      Write-Host "    Private: $($vmInfo.PrivateIPs)  Public: $($vmInfo.PublicIPs)" -ForegroundColor DarkGray
    }
  }
}

Write-Host ""
Write-Host "Inspection complete." -ForegroundColor Green
Write-Host "For detailed validation, see docs/validation.md" -ForegroundColor DarkGray
Write-Host ""
