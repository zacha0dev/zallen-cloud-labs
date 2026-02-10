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
az account set --subscription $SubscriptionId | Out-Null

Write-Host ""
Write-Host "Lab 006: Inspect" -ForegroundColor Cyan
Write-Host "=================" -ForegroundColor Cyan

# Check RG exists
$existingRg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
if (-not $existingRg) {
  Write-Host "Resource group '$ResourceGroup' not found. Deploy first." -ForegroundColor Red
  exit 1
}

# --- BGP Status ---
if (-not $RoutesOnly) {
  Write-Section "BGP Peering Status"

  $bgpConns = az network vhub bgpconnection list -g $ResourceGroup --vhub-name $VhubName -o json 2>$null | ConvertFrom-Json
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
  $learnedRoutes = az network vhub route-table show -g $ResourceGroup --vhub-name $VhubName -n defaultRouteTable --query routes -o json 2>$null | ConvertFrom-Json
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
  $clientANicId = az vm show -g $ResourceGroup -n $ClientAVmName --query "networkProfile.networkInterfaces[0].id" -o tsv 2>$null
  if ($clientANicId) {
    $clientANicName = ($clientANicId -split "/")[-1]
    az network nic show-effective-route-table -g $ResourceGroup -n $clientANicName -o table 2>$null
  } else {
    Write-Host "  Client A VM not found." -ForegroundColor Yellow
  }

  Write-Section "Effective Routes - Client B"
  $clientBNicId = az vm show -g $ResourceGroup -n $ClientBVmName --query "networkProfile.networkInterfaces[0].id" -o tsv 2>$null
  if ($clientBNicId) {
    $clientBNicName = ($clientBNicId -split "/")[-1]
    az network nic show-effective-route-table -g $ResourceGroup -n $clientBNicName -o table 2>$null
  } else {
    Write-Host "  Client B VM not found." -ForegroundColor Yellow
  }

  Write-Section "Effective Routes - Router (hub-side NIC)"
  $routerNicName = "nic-router-hubside-006"
  az network nic show-effective-route-table -g $ResourceGroup -n $routerNicName -o table 2>$null
}

# --- VM Status ---
if (-not $RoutesOnly -and -not $BgpOnly) {
  Write-Section "VM Status"
  $vms = @($RouterVmName, $ClientAVmName, $ClientBVmName)
  foreach ($vm in $vms) {
    $vmInfo = az vm show -g $ResourceGroup -n $vm --show-details --query "{Name:name, State:powerState, PrivateIPs:privateIps, PublicIPs:publicIps}" -o json 2>$null | ConvertFrom-Json
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
