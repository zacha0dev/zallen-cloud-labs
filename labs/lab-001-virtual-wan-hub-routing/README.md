# Lab 001: Virtual WAN Hub Routing

Introduction to Azure Virtual WAN with a single hub, spoke VNet, and test VM. Learn the basics of vWAN hub routing and VNet connections.

## What This Lab Does

- Creates an Azure Virtual WAN (Standard SKU)
- Deploys a Virtual Hub with address space
- Connects a spoke VNet to the hub
- Deploys a test VM in the spoke VNet

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

## Prerequisites

- Run `.\setup.ps1` from repo root
- Azure subscription with vWAN quota

## Quick Start

```powershell
# From repo root
.\setup.ps1 -Status

# Deploy (takes 15-20 min for vWAN hub)
.\labs\lab-001-virtual-wan-hub-routing\deploy.ps1 -AdminPassword "YourPassword123!"

# Inspect routing
.\labs\lab-001-virtual-wan-hub-routing\inspect.ps1

# Cleanup
.\labs\lab-001-virtual-wan-hub-routing\destroy.ps1
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Sub` | from config | Subscription ID |
| `-Location` | centralus | Azure region |
| `-AdminPassword` | *required* | VM admin password |
| `-VhubCidr` | 10.60.0.0/24 | Virtual Hub address space |
| `-VnetCidr` | 10.61.0.0/16 | Spoke VNet address space |

## Resources Created

| Resource | Name | Notes |
|----------|------|-------|
| Resource Group | rg-azure-labs-lab-001 | Contains all resources |
| Virtual WAN | vwan-lab-001 | Standard SKU |
| Virtual Hub | vhub-lab-001 | 10.60.0.0/24 |
| VNet | vnet-lab-001 | 10.61.0.0/16 |
| Hub Connection | conn-vnet-lab-001 | Links VNet to hub |
| VM | vm-lab-001 | Ubuntu 22.04, Standard_B1s |

## Cost Estimate

| Resource | Approximate Cost |
|----------|------------------|
| vWAN Hub | ~$0.25/hour |
| VM (Standard_B1s) | ~$0.01/hour |
| VNets, Connections | Minimal |

**Estimated total:** ~$0.26/hour

Run `destroy.ps1` when done to avoid ongoing charges.

## Key Learnings

1. **vWAN Hub provisioning** takes 15-20 minutes
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
