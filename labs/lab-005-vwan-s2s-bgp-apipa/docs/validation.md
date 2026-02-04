# Lab 005: Validation Commands

## Overview

This document provides CLI commands to validate the lab deployment and verify correct instance binding.

## Quick Validation

### 1. Check VPN Gateway Status

```powershell
# Gateway provisioning state
az network vpn-gateway show -g rg-lab-005-vwan-s2s -n vpngw-lab-005 --query "provisioningState" -o tsv

# Expected: Succeeded
```

### 2. List All VPN Sites

```powershell
az network vpn-site list -g rg-lab-005-vwan-s2s --query "[].{Name:name, Links:vpnSiteLinks[].name}" -o table
```

### 3. List All Connections

```powershell
az network vpn-gateway connection list -g rg-lab-005-vwan-s2s --gateway-name vpngw-lab-005 --query "[].{Name:name, State:provisioningState}" -o table
```

## Detailed Validation

### Check BGP Peering Addresses (Instance 0 vs Instance 1)

```powershell
# Get BGP peering addresses for both instances
$gw = az network vpn-gateway show -g rg-lab-005-vwan-s2s -n vpngw-lab-005 -o json | ConvertFrom-Json

foreach ($peer in $gw.bgpSettings.bgpPeeringAddresses) {
    $instance = if ($peer.ipconfigurationId -match "Instance0") { "Instance 0" } else { "Instance 1" }
    Write-Host "`n$instance"
    Write-Host "  Default BGP IPs: $($peer.defaultBgpIpAddresses -join ', ')"
    Write-Host "  Custom BGP IPs:  $($peer.customBgpIpAddresses -join ', ')"
    Write-Host "  Tunnel IPs:      $($peer.tunnelIpAddresses -join ', ')"
}
```

### Verify Link-to-Instance Binding

```powershell
# Check each connection's link bindings
$connections = @("conn-site-1", "conn-site-2", "conn-site-3", "conn-site-4")

foreach ($conn in $connections) {
    Write-Host "`nConnection: $conn"
    $connObj = az network vpn-gateway connection show -g rg-lab-005-vwan-s2s --gateway-name vpngw-lab-005 -n $conn -o json | ConvertFrom-Json

    foreach ($link in $connObj.vpnLinkConnections) {
        $linkName = $link.name -replace "^$conn-", ""
        $customBgp = $link.vpnGatewayCustomBgpAddresses
        if ($customBgp) {
            $ipConfig = $customBgp[0].ipConfigurationId
            $instance = if ($ipConfig -match "Instance0") { "0" } else { "1" }
            $bgpIp = $customBgp[0].customBgpIpAddress
            Write-Host "  $linkName -> Instance $instance (BGP: $bgpIp)"
        } else {
            Write-Host "  $linkName -> No custom BGP (default assignment)"
        }
    }
}
```

### Expected Output

```
Connection: conn-site-1
  link-1 -> Instance 0 (BGP: 169.254.21.2)
  link-2 -> Instance 1 (BGP: 169.254.22.2)

Connection: conn-site-2
  link-3 -> Instance 0 (BGP: 169.254.21.6)
  link-4 -> Instance 1 (BGP: 169.254.22.6)

Connection: conn-site-3
  link-5 -> Instance 0 (BGP: 169.254.21.10)
  link-6 -> Instance 1 (BGP: 169.254.22.10)

Connection: conn-site-4
  link-7 -> Instance 0 (BGP: 169.254.21.14)
  link-8 -> Instance 1 (BGP: 169.254.22.14)
```

## PASS/FAIL Criteria

### PASS
- All 4 VPN Sites created successfully
- Each site has exactly 2 links
- All 4 connections provisioned successfully
- Each connection has correct instance binding:
  - Odd links (1,3,5,7) -> Instance 0
  - Even links (2,4,6,8) -> Instance 1

### FAIL Conditions
- VPN Gateway in Failed state
- Missing VPN Sites or links
- Connections not provisioned
- Both links from same site bound to same instance

## Troubleshooting Failed Validation

If links are not binding to correct instances:

1. Check the ARM REST API response for the connection
2. Verify `vpnGatewayCustomBgpAddresses` is correctly specified
3. Delete and recreate the connection with explicit instance binding

```powershell
# Delete a problematic connection
az network vpn-gateway connection delete -g rg-lab-005-vwan-s2s --gateway-name vpngw-lab-005 -n conn-site-1 --yes

# Wait 30 seconds, then re-run deploy.ps1
Start-Sleep -Seconds 30
.\deploy.ps1 -Force
```

## Azure Portal Verification

Navigate to:
1. Azure Portal > Resource Groups > rg-lab-005-vwan-s2s
2. vpngw-lab-005 > Site-to-site connections
3. Click each connection to see link details and BGP configuration
