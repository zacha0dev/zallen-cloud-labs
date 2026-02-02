# Lab 000: Resource Group + VNet Basics

A minimal lab to verify your Azure Labs setup is working. Deploys a resource group and VNet to confirm authentication and subscription configuration.

## What This Lab Does

- Creates a resource group with lab tags
- Deploys a VNet with two subnets
- Validates Azure CLI authentication and subscription access

## Prerequisites

- Run `.\setup.ps1` from repo root (sets up Azure CLI)
- Configure `.data/subs.json` with your subscription

## Quick Start

```powershell
# From repo root
.\setup.ps1 -Status              # Verify Azure is ready

# Deploy
.\labs\lab-000_resource-group\deploy.ps1

# Cleanup
.\labs\lab-000_resource-group\destroy.ps1
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Subs` | from config | Subscription ID(s) or key(s) from subs.json |
| `-Location` | centralus | Azure region |
| `-RgPrefix` | rg-azure-labs | Resource group name prefix |
| `-VnetCidr` | 10.50.0.0/16 | VNet address space |

## Resources Created

| Resource | Name | Notes |
|----------|------|-------|
| Resource Group | rg-azure-labs-{sub} | Tagged with project, lab, owner |
| VNet | vnet-azure-labs-{sub} | 10.50.0.0/16 |
| Subnet | snet-01 | 10.50.1.0/24 |
| Subnet | snet-02 | 10.50.2.0/24 |

## Cost Estimate

**Minimal** - Resource groups and VNets are free. No compute resources.

## Configuration

Optional: Create `lab.config.json` in this folder to override defaults:

```json
{
  "location": "eastus2",
  "rgPrefix": "rg-myproject",
  "vnetCidr": "10.100.0.0/16"
}
```

## Troubleshooting

**"Not logged in" error:**
```powershell
az login
```

**Wrong subscription:**
```powershell
# Check current subscription
az account show

# Set specific subscription
az account set --subscription "your-subscription-id"
```
