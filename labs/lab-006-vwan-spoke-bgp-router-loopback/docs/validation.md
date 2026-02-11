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

### 3. Check Hub Router Health (BEFORE checking BGP)

```powershell
az network vhub show -g rg-lab-006-vwan-bgp-router -n vhub-lab-006 -o json | ConvertFrom-Json | Select-Object provisioningState, routingState, virtualRouterAsn, virtualRouterIps
```

**Expected:** `routingState` = `Provisioned`, `virtualRouterIps` has 2 IPs (active-active).
If `virtualRouterIps` is empty or `routingState` = `Failed`, see docs/observability.md > Hub Router Health Triage.

### 4. Check BGP Peering (single bgpconnection)

```powershell
az network vhub bgpconnection list -g rg-lab-006-vwan-bgp-router --vhub-name vhub-lab-006 `
  --query "[].{Name:name, PeerIP:peerIp, PeerASN:peerAsn, State:provisioningState}" -o table
```

**Expected:** One peering. The vHub peers from both active-active instances via this single resource:
```
Name                   PeerIP      PeerASN  State
---------------------  ----------  -------  ---------
bgp-peer-router-006   10.61.1.4   65100    Succeeded
```

**Note:** You do NOT need two bgpconnection resources. Azure's vHub internally peers from both its active-active router instances through the single bgpconnection. The router VM (FRR) has two neighbors (the two `virtualRouterIps`).

### 5. Check VM Status

```powershell
az vm list -g rg-lab-006-vwan-bgp-router --show-details `
  --query "[].{Name:name, State:powerState, PrivateIPs:privateIps}" -o table
```

**Expected:** All 3 VMs in `VM running` state.

## Router Console Access

Access the router VM from the Azure Portal Serial Console or via SSH.

### Option A: Azure Serial Console (no public IP needed)

1. Portal > VM `vm-router-006` > Help > Serial console
2. Log in as `azurelab` (SSH key auth; Serial Console uses the VM's boot diagnostics)
3. Once logged in, access FRR's router shell:

```bash
sudo vtysh
```

### Option B: SSH via Azure Bastion or jump host

```bash
ssh -i .data/lab-006/id_rsa_lab006 azurelab@<router-private-ip>
```

### Option C: Run commands remotely via az CLI

```powershell
az vm run-command invoke -g rg-lab-006-vwan-bgp-router -n vm-router-006 `
  --command-id RunShellScript --scripts "sudo vtysh -c 'show bgp summary'"
```

## Router Verification Commands (FRR / vtysh)

Once on the router VM, use `sudo vtysh` to enter the FRR router shell.
These commands verify loopback interfaces, BGP adjacency to both vHub
instances, and route advertisements.

### 1. Check loopback interface and IPs

```bash
# From Linux shell:
ip link show lo0
ip addr show lo0
```

**Expected:**
```
lo0: <BROADCAST,NOARP,UP,LOWER_UP> mtu 1500 ...
    inet 10.61.250.1/32 scope global lo0
    inet 10.200.200.1/32 scope global lo0
```

### 2. Verify IP forwarding is enabled

```bash
sysctl net.ipv4.ip_forward
```

**Expected:** `net.ipv4.ip_forward = 1`

### 3. Check BGP session status (both vHub peers)

```bash
sudo vtysh -c "show bgp summary"
```

**Expected:** Two neighbors (the vHub active-active instances) in Established state:
```
Neighbor        V   AS   MsgRcvd MsgSent   TblVer  InQ OutQ  Up/Down  State/PfxRcd
10.0.0.69       4  65515     ...     ...        0    0    0 00:xx:xx            x
10.0.0.70       4  65515     ...     ...        0    0    0 00:xx:xx            x
```

If `State/PfxRcd` shows a number (not `Active` or `Connect`), the session is established.
Both peers MUST be established for full active-active routing.

### 4. Check advertised routes (what router sends to vHub)

```bash
sudo vtysh -c "show bgp ipv4 unicast"
```

**Expected:** Both loopback prefixes in the BGP table:
```
   Network          Next Hop    Metric LocPrf Weight Path
*> 10.61.250.1/32   0.0.0.0          0         32768 i
*> 10.200.200.1/32  0.0.0.0          0         32768 i
```

### 5. Check what routes are being advertised to each vHub peer

```bash
# Replace with actual vHub IPs from deployment output
sudo vtysh -c "show bgp ipv4 unicast neighbors 10.0.0.70 advertised-routes"
sudo vtysh -c "show bgp ipv4 unicast neighbors 10.0.0.69 advertised-routes"
```

**Expected:** Both loopback prefixes advertised to each peer.

### 6. Check routes received from vHub

```bash
sudo vtysh -c "show bgp ipv4 unicast neighbors 10.0.0.70 received-routes"
sudo vtysh -c "show bgp ipv4 unicast neighbors 10.0.0.69 received-routes"
```

**Expected:** vHub advertises spoke VNet prefixes and hub prefix back to the router.

### 7. Full routing table on the router

```bash
sudo vtysh -c "show ip route"
```

**Expected:** BGP-learned routes (marked `B>`) for spoke prefixes, plus connected routes for hub-side and spoke-side subnets.

### 8. Quick all-in-one status check

```bash
sudo vtysh -c "show bgp summary" && sudo vtysh -c "show bgp ipv4 unicast" && ip addr show lo0
```

## Detailed Validation

### BGP Learned Routes (from vHub perspective)

```powershell
# Get vHub effective routes for peering instance 0
az network vhub get-effective-routes -g rg-lab-006-vwan-bgp-router -n vhub-lab-006 `
  --resource-type HubBgpConnection `
  --resource-id $(az network vhub bgpconnection show -g rg-lab-006-vwan-bgp-router --vhub-name vhub-lab-006 -n bgp-peer-router-006-0 --query id -o tsv) `
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

**Look for:** Compare with Client A -- Spoke B may or may not have the BGP-learned routes depending on propagation config.

### L3 Sanity (pre-BGP baseline)

```bash
# From Router VM:
ping -c 2 10.61.10.x       # client-a (spoke-side reachability)
ping -c 2 10.62.10.x       # client-b (cross-spoke via vHub)

# From Client A VM:
ping -c 2 10.61.2.4        # router spoke-side NIC
```

## PASS/FAIL Criteria

### PASS
- vHub provisioning = Succeeded
- vHub routingState = Provisioned, virtualRouterIps has 2 IPs
- Both hub connections = Succeeded (Connected)
- BGP peering (`bgp-peer-router-006`) provisioned = Succeeded
- All 3 VMs running with correct IPs
- Router NIC1 + NIC2 have IP forwarding enabled
- FRR running on router, **both** BGP sessions established (show bgp summary)
- Loopback prefixes visible in vHub learned routes
- Client A effective routes include BGP-learned prefix
- Outside-VNet loopback (10.200.200.1/32) propagates cleanly

### FAIL Conditions
- vHub routingState = Failed / virtualRouterIps empty (hub router not provisioned)
- vHub or hub connections in Failed state
- BGP peering Failed (check router VM is running, NIC1 IP is correct)
- Only 1 of 2 BGP sessions established on router (check FRR has both vHub IPs as neighbors)
- No BGP-learned routes in vHub (check FRR config, advertised networks)
- Client A has no route to loopback (propagation/association issue)
- Router NICs missing IP forwarding

## Troubleshooting Failed Validation

| Symptom | Check First |
|---------|-------------|
| BGP peering stuck at Updating | Wait 5-10 min, check vHub state |
| BGP peering Failed | Verify router VM NIC1 IP matches peer config |
| Only 1 BGP session up | Verify both bgpconnections exist in portal; check FRR has both neighbors |
| No learned routes | SSH to router, check `show bgp summary` and `show bgp ipv4 unicast` |
| Routes in vHub but not in spoke | Check route table association/propagation |
| Inside-VNet loopback not reachable | Expected -- system routes may take precedence |
| Client B has routes but shouldn't | Check propagation labels on route tables |
| FRR neighbor shows Active/Connect | vHub peer IP may be wrong; check `show run` in vtysh |

## Terminal-First Router Management (az vm run-command)

No SSH or portal needed. All commands below run from your local terminal.

### Check if bgpd is running

```powershell
az vm run-command invoke -g rg-lab-006-vwan-bgp-router -n vm-router-006 `
  --command-id RunShellScript `
  --scripts "systemctl is-active frr && grep '^bgpd=' /etc/frr/daemons"
```

**Expected:** `active` and `bgpd=yes`

### Show BGP summary

```powershell
az vm run-command invoke -g rg-lab-006-vwan-bgp-router -n vm-router-006 `
  --command-id RunShellScript `
  --scripts "sudo vtysh -c 'show bgp summary'"
```

**Expected:** Both vHub peer IPs in Established state with a prefix count (not `Active`/`Connect`).

### Show advertised routes per neighbor

Replace the IPs below with the actual vHub virtualRouterIps from `az network vhub show ... --query virtualRouterIps`.

```powershell
# Advertised to vHub instance 0
az vm run-command invoke -g rg-lab-006-vwan-bgp-router -n vm-router-006 `
  --command-id RunShellScript `
  --scripts "sudo vtysh -c 'show bgp ipv4 unicast neighbors 10.0.0.70 advertised-routes'"

# Advertised to vHub instance 1
az vm run-command invoke -g rg-lab-006-vwan-bgp-router -n vm-router-006 `
  --command-id RunShellScript `
  --scripts "sudo vtysh -c 'show bgp ipv4 unicast neighbors 10.0.0.69 advertised-routes'"
```

### Show loopback interface state

```powershell
az vm run-command invoke -g rg-lab-006-vwan-bgp-router -n vm-router-006 `
  --command-id RunShellScript `
  --scripts "ip addr show lo0"
```

**Expected:** `10.61.250.1/32` and `10.200.200.1/32` on `lo0`.

### Quick tcpdump capture (BGP TCP 179)

```powershell
az vm run-command invoke -g rg-lab-006-vwan-bgp-router -n vm-router-006 `
  --command-id RunShellScript `
  --scripts "sudo timeout 10 tcpdump -i eth0 -n port 179 -c 10 2>&1 || true"
```

### Full routing table

```powershell
az vm run-command invoke -g rg-lab-006-vwan-bgp-router -n vm-router-006 `
  --command-id RunShellScript `
  --scripts "sudo vtysh -c 'show ip route'"
```

### IP forwarding check

```powershell
az vm run-command invoke -g rg-lab-006-vwan-bgp-router -n vm-router-006 `
  --command-id RunShellScript `
  --scripts "sysctl net.ipv4.ip_forward"
```

### All-in-one health check

```powershell
az vm run-command invoke -g rg-lab-006-vwan-bgp-router -n vm-router-006 `
  --command-id RunShellScript `
  --scripts "echo '=== FRR daemon ===' && systemctl is-active frr && echo '=== BGP Summary ===' && sudo vtysh -c 'show bgp summary' && echo '=== Loopback ===' && ip addr show lo0 && echo '=== IP Forward ===' && sysctl net.ipv4.ip_forward"
```
