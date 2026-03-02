# Lab 001: Virtual WAN Hub Routing

Introduction to Azure Virtual WAN with a single hub, spoke VNet, and test VM. Learn the basics of vWAN hub routing and VNet connections.

## Purpose

- Create an Azure Virtual WAN (Standard SKU)
- Deploy a Virtual Hub with address space
- Connect a spoke VNet to the hub
- Deploy a test VM in the spoke VNet
- Understand hub routing fundamentals

## Architecture

```
┌─────────────────────────────────────────┐
│              Virtual WAN                │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │        Virtual Hub              │   │
│  │        (10.60.0.0/24)           │   │
│  └──────────────┬──────────────────┘   │
│                 │                       │
│                 │ Hub Connection        │
│                 │                       │
│  ┌──────────────▼──────────────────┐   │
│  │        Spoke VNet               │   │
│  │        (10.61.0.0/16)           │   │
│  │                                 │   │
│  │    ┌─────────────────┐          │   │
│  │    │   Test VM       │          │   │
│  │    │   (Ubuntu)      │          │   │
│  │    └─────────────────┘          │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

## Quick Start

```powershell
cd labs/lab-001-virtual-wan-hub-routing
./deploy.ps1 -AdminPassword "YourPassword123!"
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionKey` | (from config) | Subscription key from `.data/subs.json` |
| `-Location` | `centralus` | Azure region |
| `-AdminPassword` | *required* | VM admin password |
| `-Owner` | (from env) | Owner tag value |
| `-Force` | (switch) | Skip confirmation prompts |

## Deployment Phases

| Phase | Description | Duration |
|-------|-------------|----------|
| 0 | Preflight Checks | ~5s |
| 1 | Core Fabric (vWAN + vHub) | 10-20 min |
| 2 | Spoke VNet | ~10s |
| 3 | Test VM | ~2 min |
| 4 | Hub Connection | ~2 min |
| 5 | Validation | ~30s |
| 6 | Summary | ~5s |

**Total: ~15-25 minutes** (vHub provisioning dominates)

## Resources Created

| Resource | Name | Notes |
|----------|------|-------|
| Resource Group | `rg-lab-001-vwan-routing` | Contains all resources |
| Virtual WAN | `vwan-lab-001` | Standard SKU |
| Virtual Hub | `vhub-lab-001` | 10.60.0.0/24 |
| VNet | `vnet-spoke-lab-001` | 10.61.0.0/16 |
| Hub Connection | `conn-vnet-spoke-lab-001` | Links VNet to hub |
| VM | `vm-lab-001` | Ubuntu 22.04, Standard_B1s |

## Cost Estimate

| Resource | Approximate Cost |
|----------|------------------|
| vWAN Hub | ~$0.25/hour |
| VM (Standard_B1s) | ~$0.01/hour |
| VNets, Connections | Minimal |

**Estimated total: ~$0.26/hour (~$6.25/day)**

Run `destroy.ps1` when done to avoid ongoing charges.

## Tags Applied

```json
{
  "project": "azure-labs",
  "lab": "lab-001",
  "owner": "<from config>",
  "environment": "lab",
  "cost-center": "learning"
}
```

## Validation

Quick validation:
```powershell
# Check vHub status
az network vhub show -g rg-lab-001-vwan-routing -n vhub-lab-001 --query provisioningState -o tsv

# Check hub connection
az network vhub connection show -g rg-lab-001-vwan-routing --vhub-name vhub-lab-001 -n conn-vnet-spoke-lab-001 --query provisioningState -o tsv

# View effective routes
az network vhub get-effective-routes -g rg-lab-001-vwan-routing -n vhub-lab-001 --resource-type VirtualNetworkConnection --resource-id "/subscriptions/<sub>/resourceGroups/rg-lab-001-vwan-routing/providers/Microsoft.Network/virtualHubs/vhub-lab-001/hubVirtualNetworkConnections/conn-vnet-spoke-lab-001"
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
lab-001-virtual-wan-hub-routing/
├── deploy.ps1      # Main deployment script
├── destroy.ps1     # Cleanup script
├── inspect.ps1     # Route inspection utility
├── README.md       # This file
├── docs/
│   └── validation.md
├── logs/           # Runtime logs
└── outputs/
```

## Key Learnings

1. **vWAN Hub provisioning** takes 10-20 minutes
2. **Hub connections** link spoke VNets to the hub
3. **Effective routes** show what routes the hub propagates to spokes
4. Use `inspect.ps1` to view routing tables

## Troubleshooting

**Hub stuck in "Provisioning":**
- Wait up to 30 minutes for initial deployment
- Check Azure portal for detailed status

**VM not reachable:**
- Verify hub connection is in "Connected" state
- Check effective routes on VM NIC

## References

- [Azure Virtual WAN overview](https://learn.microsoft.com/azure/virtual-wan/virtual-wan-about)
- [Virtual hub routing](https://learn.microsoft.com/azure/virtual-wan/about-virtual-hub-routing)
