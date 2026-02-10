# Lab 006: Validation Commands

## Overview

CLI commands to validate the lab deployment and verify BGP route propagation.

## Quick Validation

### 1. Check vHub State

```powershell
az network vhub show -g rg-lab-006-vwan-bgp-router -n vhub-lab-006 --query provisioningState -o tsv
```

**Expected:** `Succeeded`

### 2. Check Hub Connections

```powershell
az network vhub connection list -g rg-lab-006-vwan-bgp-router --vhub-name vhub-lab-006 `
  --query "[].{Name:name, State:provisioningState}" -o table
```

**Expected:**
```
Name          State
------------  ---------
conn-spoke-a  Succeeded
conn-spoke-b  Succeeded
```

### 3. Check BGP Peering

```powershell
az network vhub bgpconnection list -g rg-lab-006-vwan-bgp-router --vhub-name vhub-lab-006 `
  --query "[].{Name:name, PeerIP:peerIp, PeerASN:peerAsn, State:provisioningState}" -o table
```

**Expected:**
```
Name                  PeerIP     PeerASN  State
--------------------  ---------  -------  ---------
bgp-peer-router-006  10.61.1.x  65100    Succeeded
```

### 4. Check VM Status

```powershell
az vm list -g rg-lab-006-vwan-bgp-router --show-details `
  --query "[].{Name:name, State:powerState, PrivateIPs:privateIps}" -o table
```

**Expected:** All 3 VMs in `VM running` state.

## Detailed Validation

### BGP Learned Routes (from vHub perspective)

```powershell
# Get vHub effective routes
az network vhub get-effective-routes -g rg-lab-006-vwan-bgp-router -n vhub-lab-006 `
  --resource-type HubBgpConnection `
  --resource-id $(az network vhub bgpconnection show -g rg-lab-006-vwan-bgp-router --vhub-name vhub-lab-006 -n bgp-peer-router-006 --query id -o tsv) `
  -o json
```

**Expected:** Routes advertised by router should appear (loopback prefixes).

### Effective Routes on Client A NIC

```powershell
$nicId = az vm show -g rg-lab-006-vwan-bgp-router -n vm-client-a-006 `
  --query "networkProfile.networkInterfaces[0].id" -o tsv
$nicName = ($nicId -split "/")[-1]
az network nic show-effective-route-table -g rg-lab-006-vwan-bgp-router -n $nicName -o table
```

**Look for:** BGP-learned routes from router (loopback prefixes with nextHop via vHub).

### Effective Routes on Client B NIC (Control)

```powershell
$nicId = az vm show -g rg-lab-006-vwan-bgp-router -n vm-client-b-006 `
  --query "networkProfile.networkInterfaces[0].id" -o tsv
$nicName = ($nicId -split "/")[-1]
az network nic show-effective-route-table -g rg-lab-006-vwan-bgp-router -n $nicName -o table
```

**Look for:** Compare with Client A — Spoke B may or may not have the BGP-learned routes depending on propagation config.

### Router VM — FRR BGP State (SSH required)

```bash
# SSH to router VM, then:
sudo vtysh -c "show bgp summary"
sudo vtysh -c "show bgp ipv4 unicast"
sudo vtysh -c "show ip route"
ip addr show lo0
sysctl net.ipv4.ip_forward
```

**Expected:**
- BGP session to vHub peer established
- Loopback IPs visible on lo0
- IP forwarding enabled (= 1)

### L3 Sanity (pre-BGP baseline)

```bash
# From Router VM:
ping -c 2 <client-a-ip>       # spoke-side reachability
ping -c 2 <client-b-ip>       # cross-spoke via vHub

# From Client A VM:
ping -c 2 <router-spokeside-ip>  # direct spoke connectivity
```

## PASS/FAIL Criteria

### PASS
- vHub provisioning = Succeeded
- Both hub connections = Succeeded (Connected)
- BGP peering provisioned = Succeeded
- All 3 VMs running with correct IPs
- Router NIC1 + NIC2 have IP forwarding enabled
- FRR running on router, BGP session established
- Loopback prefixes visible in vHub learned routes
- Client A effective routes include BGP-learned prefix
- Outside-VNet loopback (10.200.200.1/32) propagates cleanly

### FAIL Conditions
- vHub or hub connections in Failed state
- BGP peering Failed (check router VM is running, NIC1 IP is correct)
- No BGP-learned routes in vHub (check FRR config, advertised networks)
- Client A has no route to loopback (propagation/association issue)
- Router NICs missing IP forwarding

## Troubleshooting Failed Validation

| Symptom | Check First |
|---------|-------------|
| BGP peering stuck at Updating | Wait 5-10 min, check vHub state |
| BGP peering Failed | Verify router VM NIC1 IP matches peer config |
| No learned routes | SSH to router, check `show bgp summary` |
| Routes in vHub but not in spoke | Check route table association/propagation |
| Inside-VNet loopback not reachable | Expected — system routes may take precedence |
| Client B has routes but shouldn't | Check propagation labels on route tables |
