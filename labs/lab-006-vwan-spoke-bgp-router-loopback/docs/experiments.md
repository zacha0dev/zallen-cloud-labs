# Lab 006: Experiments

## Overview

This document describes the loopback route propagation experiments that are the core purpose of this lab.

---

## Experiment 1: Inside-VNet Loopback (10.61.250.1/32)

### Setup
The router's loopback interface (lo0) has IP 10.61.250.1/32, which falls **inside** Spoke A's address space (10.61.0.0/16).

### Hypothesis
Azure system routes for the VNet CIDR (10.61.0.0/16) may take precedence over the BGP-learned /32 route. The effective route table on Client A may show the system route "winning."

### Steps

1. **Configure router to advertise 10.61.250.1/32 via BGP**
   ```bash
   # On router VM:
   sudo vtysh
   configure terminal
   router bgp 65100
     address-family ipv4 unicast
       network 10.61.250.1/32
     exit-address-family
   end
   write memory
   ```

2. **Check vHub learned routes**
   ```powershell
   az network vhub get-effective-routes -g rg-lab-006-vwan-bgp-router -n vhub-lab-006 `
     --resource-type HubBgpConnection `
     --resource-id $(az network vhub bgpconnection show -g rg-lab-006-vwan-bgp-router --vhub-name vhub-lab-006 -n bgp-peer-router-006 --query id -o tsv) `
     -o json
   ```

3. **Check Client A effective routes**
   ```powershell
   .\inspect.ps1 -RoutesOnly
   ```

4. **Test reachability from Client A**
   ```bash
   # On Client A:
   ping -c 4 10.61.250.1
   traceroute 10.61.250.1
   ```

### Expected Results
- vHub MAY learn the /32 route
- Client A effective routes MAY show the /32 route BUT system route for 10.61.0.0/16 may take precedence
- Ping MAY fail if the system route directs traffic to the VNet's default path instead of the BGP-learned path
- **This is the interesting edge case**: document whether /32 wins or VNet system route wins

### What to Record
- Does the /32 appear in vHub learned routes? (Y/N)
- Does the /32 appear in Client A effective routes? (Y/N)
- Does ping to 10.61.250.1 succeed from Client A? (Y/N)
- What does traceroute show? (hops)

---

## Experiment 2: Outside-VNet Loopback (10.200.200.1/32)

### Setup
The router's loopback interface also has IP 10.200.200.1/32, which is **outside** any VNet address space.

### Hypothesis
Since there's no conflicting system route, the BGP-learned /32 should propagate cleanly through the vHub to connected spokes.

### Steps

1. **Configure router to advertise 10.200.200.1/32 via BGP**
   ```bash
   # On router VM:
   sudo vtysh
   configure terminal
   router bgp 65100
     address-family ipv4 unicast
       network 10.200.200.1/32
     exit-address-family
   end
   write memory
   ```

2. **Check vHub learned routes** (same command as Experiment 1)

3. **Check Client A AND Client B effective routes**
   ```powershell
   .\inspect.ps1 -RoutesOnly
   ```

4. **Test reachability from both clients**
   ```bash
   # On Client A:
   ping -c 4 10.200.200.1
   traceroute 10.200.200.1

   # On Client B:
   ping -c 4 10.200.200.1
   traceroute 10.200.200.1
   ```

### Expected Results
- vHub learns the /32 route
- Client A effective routes include 10.200.200.1/32 via vHub next hop
- Client B effective routes MAY include the route (depends on propagation config)
- Ping from Client A should succeed
- Ping from Client B depends on route table propagation

### What to Record
- Does the /32 appear in vHub learned routes? (Y/N)
- Does the /32 appear in Client A effective routes? (Y/N)
- Does the /32 appear in Client B effective routes? (Y/N)
- Ping success from Client A? (Y/N)
- Ping success from Client B? (Y/N)

---

## Experiment 3: Spoke A (BGP) vs Spoke B (Control) Comparison

### Setup
Both spokes are connected to the same vHub via default route table association.

### Hypothesis
Both spokes should receive the same routes from the default route table UNLESS custom route table association/propagation is configured.

### Steps

1. **Run both experiments above first**

2. **Compare effective routes side by side**
   ```powershell
   .\inspect.ps1 -RoutesOnly
   ```

3. **Optional: Create custom route table for Spoke A**
   ```powershell
   # Create custom RT
   az network vhub route-table create `
     -g rg-lab-006-vwan-bgp-router `
     --vhub-name vhub-lab-006 `
     --name rt-bgp-spoke `
     --labels bgp-propagation

   # Re-associate Spoke A connection to custom RT
   # (This changes propagation behavior)
   ```

### Expected Results
- Default config: both spokes see same routes
- Custom RT: Spoke A may see additional BGP-learned routes not visible to Spoke B

---

## Experiment 4: Route Withdrawal

### Setup
Remove a loopback prefix from BGP advertisement and observe route withdrawal.

### Steps

1. **Remove prefix from FRR**
   ```bash
   sudo vtysh
   configure terminal
   router bgp 65100
     address-family ipv4 unicast
       no network 10.200.200.1/32
     exit-address-family
   end
   write memory
   ```

2. **Wait 30-60 seconds for BGP update propagation**

3. **Check effective routes on both clients**
   ```powershell
   .\inspect.ps1 -RoutesOnly
   ```

### Expected Results
- Route should be withdrawn from vHub
- Client effective routes should no longer show the prefix
- Convergence time is informative

---

## Results Template

Copy this template after running experiments:

```markdown
## Results -- [Date]

### Experiment 1: Inside-VNet Loopback (10.61.250.1/32)
- vHub learned: [Y/N]
- Client A effective routes: [Y/N]
- Client A ping: [Y/N]
- Notes: [...]

### Experiment 2: Outside-VNet Loopback (10.200.200.1/32)
- vHub learned: [Y/N]
- Client A effective routes: [Y/N]
- Client B effective routes: [Y/N]
- Client A ping: [Y/N]
- Client B ping: [Y/N]
- Notes: [...]

### Experiment 3: Spoke Comparison
- Routes differ between A and B: [Y/N]
- Notes: [...]

### Experiment 4: Route Withdrawal
- Withdrawal time: [Xs]
- Route removed from Client A: [Y/N]
- Route removed from Client B: [Y/N]
```

---

## Storage-Account-Driven Router Config (Bonus)

For repeatable experiments without redeploying the VM:

### Pattern
1. Storage account container: `router-config/`
2. Blobs: `frr.conf`, `startup.sh`
3. Router VM bootstrap uses Managed Identity to pull config
4. Update config by uploading new blob + restarting FRR

### Setup (manual, not automated yet)

```powershell
# Create storage account
az storage account create -g rg-lab-006-vwan-bgp-router -n stlab006routerconfig --sku Standard_LRS -l centralus

# Create container
az storage container create --account-name stlab006routerconfig -n router-config

# Upload FRR config
az storage blob upload --account-name stlab006routerconfig -c router-config -f scripts/router/frr.conf -n frr.conf
```

```bash
# On router VM (with managed identity):
az storage blob download --account-name stlab006routerconfig -c router-config -n frr.conf -f /etc/frr/frr.conf
sudo systemctl restart frr
```

This enables "update config without redeploying VM" -- a clean platform pattern.
