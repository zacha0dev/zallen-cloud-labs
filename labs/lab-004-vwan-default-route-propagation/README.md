# Lab 004: vWAN Default Route (0/0) Propagation

This lab demonstrates how default route (0.0.0.0/0) propagation works in Azure Virtual WAN, specifically:
- How custom route tables propagate static routes to associated VNets
- Why VNets on the Default route table do NOT learn 0/0 from custom route tables
- Hub-to-hub behavior: how 0/0 stays scoped to the custom route table

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

## Prerequisites

- Azure CLI (`az`) installed
- Active Azure subscription
- PowerShell 5.1+ or PowerShell Core

## Quick Start

```powershell
# 1. Deploy infrastructure (takes 30-45 min for vWAN)
.\scripts\deploy.ps1

# 2. Validate route propagation
.\scripts\validate.ps1

# 3. Clean up when done
.\scripts\destroy.ps1
```

## Configuration

Edit `.data/lab-004/config.json`:

```json
{
  "azure": {
    "subscriptionId": "your-subscription-id",
    "location": "eastus2",
    "resourceGroup": "rg-lab-004-vwan-route-prop",
    "adminUsername": "azureuser",
    "adminPassword": "your-secure-password"
  }
}
```

## Cost Estimate

| Resource | Approximate Cost |
|----------|------------------|
| vWAN Hub (x2) | ~$0.50/hour combined |
| VMs (7x Standard_B1s) | ~$0.07/hour combined |
| VNets, NICs | Minimal |

**Estimated total:** ~$0.60/hour

Run `destroy.ps1` when done to avoid ongoing charges.

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

## Documentation

- [Walkthrough](docs/walkthrough.md) - Step-by-step deployment guide
- [Validation Checks](docs/validation-checks.md) - Detailed test explanations

## Troubleshooting

**Routes not appearing:**
- Wait 5-10 minutes after deployment for route propagation
- Check vWAN hub routing status in Azure portal

**Deployment fails:**
- Ensure subscription has quota for VMs and public IPs
- Check Azure CLI is authenticated: `az account show`

## References

- [Azure Virtual WAN routing](https://learn.microsoft.com/azure/virtual-wan/about-virtual-hub-routing)
- [Custom route tables](https://learn.microsoft.com/azure/virtual-wan/how-to-virtual-hub-routing)
- [Default route propagation](https://learn.microsoft.com/azure/virtual-wan/virtual-wan-about#basicstandard)
