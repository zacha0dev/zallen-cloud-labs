# Lab 004: vWAN Default Route (0/0) Propagation

Demonstrates how default route (0.0.0.0/0) propagation works in Azure Virtual WAN with custom route tables. Learn why static routes in custom route tables only propagate to associated VNets.

## Purpose

- Create a vWAN with two hubs (Hub A and Hub B)
- Configure a custom route table with static 0.0.0.0/0 route
- Associate specific spokes with the custom route table
- Observe which spokes receive the default route

## What This Lab Proves

| Scenario | Expected Result |
|----------|-----------------|
| Spoke A1, A2 (rt-fw-default) | **SEES 0.0.0.0/0** - Associated with custom RT containing static 0/0 |
| Spoke A3, A4 (Default RT) | **NO 0.0.0.0/0** - Default RT doesn't learn from custom RT |
| Spoke B1, B2 (Hub B, Default RT) | **NO 0.0.0.0/0** - Different hub, default RT only |

## Architecture

```
                    +-----------------+
                    |    Virtual WAN  |
                    +-----------------+
                           |
          +----------------+----------------+
          |                                 |
    +-----v-----+                    +------v----+
    |   Hub A   |                    |   Hub B   |
    | 10.100/24 |                    | 10.101/24 |
    +-----------+                    +-----------+
          |                                 |
   +------+------+                   +------+------+
   |             |                   |             |
   v             v                   v             v
rt-fw-default  Default RT        Default RT    Default RT
   |             |                   |             |
+--+--+       +--+--+             +--+--+       +--+--+
|VNet |       |VNet |             |VNet |       |VNet |
|A1/A2|       |A3/A4|             | B1  |       | B2  |
+-----+       +-----+             +-----+       +-----+
   ^
   |
0.0.0.0/0 -> VNet-FW
```

**Custom Route Table (rt-fw-default):**
- Contains static route: `0.0.0.0/0 -> VNet-FW connection`
- Spoke A1 and A2 are associated with this RT
- These spokes WILL learn the 0/0 route

**Default Route Table:**
- Spoke A3, A4, B1, B2 are associated with Default RT
- These spokes will NOT learn the 0/0 route from rt-fw-default

## Quick Start

```powershell
cd labs/lab-004-vwan-default-route-propagation
./deploy.ps1 -AdminPassword "YourPassword123!"
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionKey` | (from config) | Subscription key from `.data/subs.json` |
| `-Location` | `eastus2` | Azure region |
| `-AdminPassword` | *required* | VM admin password |
| `-Owner` | (from env) | Owner tag value |
| `-Force` | (switch) | Skip confirmation prompts |

## Deployment Phases

| Phase | Description | Duration |
|-------|-------------|----------|
| 0 | Preflight Checks | ~5s |
| 1 | Core Fabric (vWAN + 2 vHubs) | 20-40 min |
| 2 | Spoke VNets | ~1 min |
| 3 | Hub Connections + Routing | ~5 min |
| 4 | Test VMs | ~3-5 min |
| 5 | Validation | ~1 min |
| 6 | Summary | ~5s |

**Total: ~30-50 minutes** (vHub provisioning dominates)

## Resources Created

| Resource | Name | Notes |
|----------|------|-------|
| Resource Group | `rg-lab-004-vwan-route-prop` | Contains all resources |
| Virtual WAN | `vwan-lab-004` | Standard SKU |
| Virtual Hub A | `vhub-a-lab-004` | 10.100.0.0/24 |
| Virtual Hub B | `vhub-b-lab-004` | 10.101.0.0/24 |
| Custom Route Table | `rt-fw-default` | Contains 0/0 static route |
| VNet-FW | `vnet-fw-lab-004` | 10.110.0.0/24 (simulated firewall) |
| Spoke VNets | `vnet-spoke-a1` - `vnet-spoke-b2` | 7 spoke VNets |
| VMs | `vm-fw`, `vm-a1` - `vm-b2` | 7 test VMs |

## Cost Estimate

| Resource | Approximate Cost |
|----------|------------------|
| vWAN Hub (x2) | ~$0.50/hour combined |
| VMs (7x Standard_B1s) | ~$0.07/hour combined |
| VNets, Connections | Minimal |

**Estimated total: ~$0.60/hour (~$14.40/day)**

Run `destroy.ps1` when done to avoid ongoing charges.

## Tags Applied

```json
{
  "project": "azure-labs",
  "lab": "lab-004",
  "owner": "<from config>",
  "environment": "lab",
  "cost-center": "learning",
  "purpose": "vwan-route-propagation"
}
```

## Validation

Quick validation (after deployment):
```powershell
# Check Hub A
az network vhub show -g rg-lab-004-vwan-route-prop -n vhub-a-lab-004 --query provisioningState -o tsv

# Check custom route table
az network vhub route-table show -g rg-lab-004-vwan-route-prop --vhub-name vhub-a-lab-004 -n rt-fw-default --query provisioningState -o tsv

# Check if A1 has 0/0 route
az network nic show-effective-route-table -g rg-lab-004-vwan-route-prop -n nic-vm-a1 --query "value[?addressPrefix[0]=='0.0.0.0/0']" -o json
```

See [docs/validation.md](docs/validation.md) for comprehensive validation commands.

**Operational Observability:** See [docs/observability.md](docs/observability.md) for health gates, troubleshooting patterns, and what NOT to look at.

## Cleanup

```powershell
./destroy.ps1
```

Run the cost audit tool to confirm no billable resources remain:

```powershell
.\tools\cost-check.ps1
```

## Files

```
lab-004-vwan-default-route-propagation/
├── deploy.ps1      # Main deployment script (7 phases)
├── destroy.ps1     # Cleanup script
├── README.md       # This file
├── docs/
│   ├── validation.md
│   ├── validation-checks.md
│   └── walkthrough.md
├── logs/           # Runtime logs
└── outputs/        # Generated outputs (outputs.json)
```

## Validation Output

```
============================================
  vWAN Default Route Propagation Validation
============================================

Expected behavior:
  - Spoke A1, A2: SHOULD have 0.0.0.0/0 (associated with rt-fw-default)
  - Spoke A3, A4: should NOT have 0.0.0.0/0 (associated with Default RT)
  - Spoke B1, B2: should NOT have 0.0.0.0/0 (Hub B, Default RT only)

[PASS] Spoke A1 (rt-fw-default) - Has 0.0.0.0/0 route
[PASS] Spoke A2 (rt-fw-default) - Has 0.0.0.0/0 route
[PASS] Spoke A3 (Default RT) - No 0.0.0.0/0 route (correct)
[PASS] Spoke A4 (Default RT) - No 0.0.0.0/0 route (correct)
[PASS] Spoke B1 (Hub B, Default RT) - No 0.0.0.0/0 route (correct)
[PASS] Spoke B2 (Hub B, Default RT) - No 0.0.0.0/0 route (correct)

============================================
Summary: 6 passed, 0 failed
============================================
```

## Key Learnings

1. **Custom RT isolation**: Static routes in custom route tables only propagate to VNets explicitly associated with that RT

2. **Default RT behavior**: The Default route table doesn't automatically inherit routes from custom RTs

3. **Hub-to-hub**: Routes in a custom RT on Hub A don't propagate to Hub B's Default RT

4. **Use case**: This pattern is common for firewall insertion - only specific spokes get the 0/0 route to the firewall NVA

## Troubleshooting

**Routes not appearing on A1/A2:**
- Wait 5-10 minutes after deployment for route propagation
- Check vWAN hub routing status in Azure portal

**Deployment fails:**
- Ensure subscription has quota for VMs and public IPs
- Check Azure CLI is authenticated: `az account show`

**Hub provisioning stuck:**
- Wait up to 30 minutes for initial deployment
- Check Azure portal for detailed status

## References

- [vWAN Domain Guide](../../docs/DOMAINS/vwan.md) - Route propagation patterns, custom route table concepts
- [Observability Guide](../../docs/DOMAINS/observability.md) - How to validate effective routes
- [Azure Virtual WAN routing](https://learn.microsoft.com/azure/virtual-wan/about-virtual-hub-routing)
- [Custom route tables](https://learn.microsoft.com/azure/virtual-wan/how-to-virtual-hub-routing)
- [Default route propagation](https://learn.microsoft.com/azure/virtual-wan/virtual-wan-about#basicstandard)
