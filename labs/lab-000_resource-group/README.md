# Lab 000: Resource Group + VNet Baseline

A minimal lab to verify your Azure Labs setup is working. Deploys a resource group and VNet with proper tagging following the standard phased deployment model.

## Purpose

- Verify Azure CLI authentication and subscription configuration
- Create baseline infrastructure with proper tagging
- Demonstrate the phased deployment pattern used across all labs

## Quick Start

```powershell
cd labs/lab-000_resource-group
./deploy.ps1
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionKey` | (from config) | Subscription key from `.data/subs.json` |
| `-Location` | `centralus` | Azure region |
| `-Owner` | (from env) | Owner tag value |
| `-Force` | (switch) | Skip confirmation prompts |

## Deployment Phases

| Phase | Description | Duration |
|-------|-------------|----------|
| 0 | Preflight Checks | ~5s |
| 1 | Core Fabric (RG + VNet) | ~10s |
| 2-4 | N/A (baseline lab) | ~0s |
| 5 | Validation | ~5s |
| 6 | Summary | ~1s |

**Total: ~20 seconds**

## Resources Created

| Resource | Name | Notes |
|----------|------|-------|
| Resource Group | `rg-lab-000-baseline` | Tagged with standard labels |
| VNet | `vnet-lab-000` | 10.50.0.0/16 |
| Subnet | `snet-workload` | 10.50.1.0/24 |
| Subnet | `snet-management` | 10.50.2.0/24 |

## Cost Estimate

**FREE** - Resource groups and VNets have no cost.

## Tags Applied

```json
{
  "project": "azure-labs",
  "lab": "lab-000",
  "owner": "<from config>",
  "environment": "lab",
  "cost-center": "learning"
}
```

## Validation

Quick validation:
```powershell
# Check resource group
az group show -n rg-lab-000-baseline -o table

# Check VNet
az network vnet show -g rg-lab-000-baseline -n vnet-lab-000 -o table

# Check subnets
az network vnet subnet list -g rg-lab-000-baseline --vnet-name vnet-lab-000 -o table
```

See [docs/validation.md](docs/validation.md) for comprehensive validation commands.

**Operational Observability:** See [docs/observability.md](docs/observability.md) for health gates, troubleshooting patterns, and what NOT to look at.

## Cleanup

```powershell
./destroy.ps1
```

## Files

```
lab-000_resource-group/
├── deploy.ps1      # Main deployment script
├── destroy.ps1     # Cleanup script
├── README.md       # This file
├── docs/
│   └── validation.md
├── logs/           # Runtime logs
└── outputs/        # (unused, outputs in .data/)
```

## Troubleshooting

**"Not logged in" error:**
```powershell
az login
```

**Wrong subscription:**
```powershell
az account show  # Check current
az account set --subscription "your-subscription-id"
```

**Config not found:**
```powershell
# Run the guided subscription wizard from repo root
.\setup.ps1 -ConfigureSubs
```
