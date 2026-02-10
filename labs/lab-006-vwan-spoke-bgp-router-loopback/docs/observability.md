# Operational Observability & Troubleshooting

## Orientation (What You Deployed)

**Components:**
- Virtual WAN + Virtual Hub (10.0.0.0/24, ASN 65515)
- Spoke A VNet (10.61.0.0/16) with Router VM (2 NICs, FRR, ASN 65100) + Client A VM
- Spoke B VNet (10.62.0.0/16) with Client B VM (control — no BGP)
- BGP peering from Router VM to vHub
- Loopback interface on Router with two test prefixes

**Golden Rule:** If BGP peering shows `Succeeded` AND `show bgp summary` on the router shows an established session, the control plane is healthy. Route visibility issues are then propagation/association problems.

---

## Health Gates (Follow This Order)

### Gate 1: Control Plane (Provisioning State)

**Check vHub:**
```powershell
az network vhub show -g rg-lab-006-vwan-bgp-router -n vhub-lab-006 --query provisioningState -o tsv
```

**Check hub connections:**
```powershell
az network vhub connection list -g rg-lab-006-vwan-bgp-router --vhub-name vhub-lab-006 `
  --query "[].{name:name, state:provisioningState}" -o table
```

**Check BGP peering:**
```powershell
az network vhub bgpconnection list -g rg-lab-006-vwan-bgp-router --vhub-name vhub-lab-006 `
  --query "[].{name:name, peerIp:peerIp, peerAsn:peerAsn, state:provisioningState}" -o table
```

**Expected:** All `Succeeded`.

---

### Gate 2: Data Plane (VM + Router Health)

**VMs running:**
```powershell
az vm list -g rg-lab-006-vwan-bgp-router --show-details `
  --query "[].{Name:name, State:powerState}" -o table
```

**Router NIC IP forwarding:**
```powershell
az network nic show -g rg-lab-006-vwan-bgp-router -n nic-router-hubside-006 --query enableIpForwarding -o tsv
az network nic show -g rg-lab-006-vwan-bgp-router -n nic-router-spokeside-006 --query enableIpForwarding -o tsv
```

**Expected:** Both `true`.

---

### Gate 3: BGP Session (The PROOF)

SSH to router VM, then:

```bash
# BGP session summary
sudo vtysh -c "show bgp summary"

# Advertised routes
sudo vtysh -c "show bgp ipv4 unicast"

# Full routing table
sudo vtysh -c "show ip route"

# Loopback interface
ip addr show lo0

# IP forwarding
sysctl net.ipv4.ip_forward
```

**Expected:**
- BGP neighbor to vHub in `Established` state
- Loopback prefixes in BGP table
- lo0 has 10.61.250.1/32 and 10.200.200.1/32
- ip_forward = 1

---

### Gate 4: Route Propagation

```powershell
# Run the inspect script
.\inspect.ps1 -RoutesOnly
```

Compare effective routes between Client A and Client B. Key differences prove propagation behavior.

---

## VM-Side Observability (5 Best Signals)

### 1. BGP Session State
```bash
sudo vtysh -c "show bgp summary"
```
**Why:** Single most important signal. If session is not Established, nothing else matters.

### 2. Advertised Prefixes
```bash
sudo vtysh -c "show bgp ipv4 unicast advertised-routes"
```
**Why:** Confirms what the router is actually sending to vHub.

### 3. Packet Captures on Router NICs
```bash
# Hub-side NIC (BGP traffic)
sudo tcpdump -i eth0 -n port 179 -c 20

# Spoke-side NIC (data traffic)
sudo tcpdump -i eth1 -n icmp -c 20
```
**Why:** Proves BGP TCP sessions and ICMP reachability at the wire level.

### 4. Routing Table
```bash
ip route show
```
**Why:** Shows what the OS actually knows. Loopback routes should appear.

### 5. iptables Counters (if rules exist)
```bash
sudo iptables -L -v -n
```
**Why:** If any firewall rules are dropping traffic, counters show it immediately.

---

## Azure-Side Observability (5 Best Signals)

### 1. Effective Routes per NIC
```powershell
.\inspect.ps1 -RoutesOnly
```
**Why:** Shows exactly what Azure has programmed for each VM's traffic.

### 2. vHub BGP Learned Routes
```powershell
az network vhub get-effective-routes -g rg-lab-006-vwan-bgp-router -n vhub-lab-006 `
  --resource-type HubBgpConnection `
  --resource-id $(az network vhub bgpconnection show -g rg-lab-006-vwan-bgp-router --vhub-name vhub-lab-006 -n bgp-peer-router-006 --query id -o tsv) `
  -o json
```
**Why:** Proves the hub actually received the routes from the router.

### 3. NSG Flow Logs (if enabled)
```powershell
# Enable on router subnets for packet-level visibility
# See lab.config.example.json: diagnostics.nsgFlowLogs
```

### 4. Hub Connection State
```powershell
az network vhub connection list -g rg-lab-006-vwan-bgp-router --vhub-name vhub-lab-006 -o table
```

### 5. Resource Provisioning Timeline
```powershell
az monitor activity-log list -g rg-lab-006-vwan-bgp-router --max-events 30 `
  --query "[].{time:eventTimestamp, op:operationName.localizedValue, status:status.localizedValue}" -o table
```

---

## Common Failure Patterns (Fast Triage)

| Symptom | Likely Cause | Fastest Check |
|---------|--------------|---------------|
| BGP peering stuck at `Updating` | vHub still provisioning | Check vHub state |
| BGP peering `Failed` | Wrong peer IP or router VM not running | Verify NIC1 IP |
| Session `Idle` in FRR | vHub not peering back | Check BGP connection resource |
| Routes in vHub but not in spoke | Association/propagation config | Check route table labels |
| Inside-VNet loopback unreachable | System route takes precedence | Expected behavior to document |
| Router can't ping Client B | Cross-spoke routing via vHub | Check hub connections |
| Asymmetric routing drops | 2-NIC return path issue | Add UDR on spoke-side subnet |

---

## What NOT to Look At

- **NSG flow logs** (unless explicitly enabled) — not on by default in this lab
- **Connection monitor** — not configured by default
- **vHub metrics** — useful for production, noisy for lab
- **Azure Firewall logs** — no firewall in this lab
- **VPN Gateway diagnostics** — no VPN gateway in this lab

---

## Minimal KQL Queries (Optional, if diagnostics enabled)

**BGP peering events:**
```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.NETWORK"
| where Resource contains "vhub-lab-006"
| project TimeGenerated, OperationName, ResultType, properties_s
| order by TimeGenerated desc
| take 30
```

**Activity log for lab resource group:**
```kusto
AzureActivity
| where ResourceGroup == "rg-lab-006-vwan-bgp-router"
| project TimeGenerated, OperationNameValue, ActivityStatusValue, Caller
| order by TimeGenerated desc
| take 50
```
