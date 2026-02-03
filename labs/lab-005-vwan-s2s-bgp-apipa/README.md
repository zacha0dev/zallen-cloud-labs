# Lab 005: vWAN S2S BGP over APIPA (Azure-style)

Prove correct Azure vWAN S2S VPN Gateway dual-instance behavior with deterministic APIPA /30 allocations.

## What This Lab Proves

- **Instance 0 vs Instance 1**: Both gateway instances are active and accepting connections
- **APIPA Mapping Correctness**: Custom BGP addresses are honored per link
- **Fail-Forward Design**: Phased deployment with validation between steps
- **Deterministic Behavior**: Same configuration always produces same result

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Azure vWAN (centralus)                   │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                  Virtual Hub                          │  │
│  │                 10.0.0.0/24                           │  │
│  │                                                       │  │
│  │    ┌───────────────────────────────────────────┐      │  │
│  │    │         S2S VPN Gateway                   │      │  │
│  │    │        (2 instances, ASN 65515)           │      │  │
│  │    │                                           │      │  │
│  │    │  Instance 0          Instance 1           │      │  │
│  │    │  ──────────          ──────────           │      │  │
│  │    │  link-1 (21.2)       link-2 (22.2)        │      │  │
│  │    │  link-3 (21.6)       link-4 (22.6)        │      │  │
│  │    │  link-5 (21.10)      link-6 (22.10)       │      │  │
│  │    │  link-7 (21.14)      link-8 (22.14)       │      │  │
│  │    └───────────────────────────────────────────┘      │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
│  VPN Sites:                                                 │
│    site-1 (ASN 65001) ─ link-1, link-2                      │
│    site-2 (ASN 65002) ─ link-3, link-4                      │
│    site-3 (ASN 65003) ─ link-5, link-6                      │
│    site-4 (ASN 65004) ─ link-7, link-8                      │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Azure subscription with Contributor access
- Azure CLI installed and authenticated
- PowerShell 7+ (Windows/Linux/macOS)
- Repository configured (run `scripts/setup.ps1` first)

## Quick Start

```powershell
# Navigate to lab directory
cd labs/lab-005-vwan-s2s-bgp-apipa

# Deploy (will prompt for confirmation)
.\deploy.ps1

# Or deploy with force (skip prompts)
.\deploy.ps1 -Force

# Cleanup when done (important - stops billing!)
.\destroy.ps1
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionKey` | (from config) | Subscription key from `.data/subs.json` |
| `-Location` | `centralus` | Azure region (must be in allowlist) |
| `-Owner` | `` | Optional owner tag for resources |
| `-Force` | `$false` | Skip confirmation prompts |

## Deployment Phases

The deployment runs in 5 distinct phases with validation between each:

| Phase | Description | Duration |
|-------|-------------|----------|
| 0 | Preflight checks | ~30s |
| 1 | Core fabric (vWAN + vHub) | 5-10 min |
| 2 | S2S VPN Gateway | 20-30 min |
| 3 | VPN Sites + Links (4 sites, 8 links) | 2-3 min |
| 4 | VPN Connections (instance split) | 2-3 min |
| 5 | Validation output | ~30s |

**Total expected time: 30-45 minutes**

## APIPA Mapping

| Site | Link | APIPA /30 | Azure BGP | Instance |
|------|------|-----------|-----------|----------|
| site-1 | link-1 | 169.254.21.0/30 | 169.254.21.2 | 0 |
| site-1 | link-2 | 169.254.22.0/30 | 169.254.22.2 | 1 |
| site-2 | link-3 | 169.254.21.4/30 | 169.254.21.6 | 0 |
| site-2 | link-4 | 169.254.22.4/30 | 169.254.22.6 | 1 |
| site-3 | link-5 | 169.254.21.8/30 | 169.254.21.10 | 0 |
| site-3 | link-6 | 169.254.22.8/30 | 169.254.22.10 | 1 |
| site-4 | link-7 | 169.254.21.12/30 | 169.254.21.14 | 0 |
| site-4 | link-8 | 169.254.22.12/30 | 169.254.22.14 | 1 |

Pattern: `169.254.21.x` = Instance 0, `169.254.22.x` = Instance 1

## Cost Estimate

| Resource | Approximate Cost |
|----------|------------------|
| vWAN Hub | ~$0.25/hr |
| S2S VPN Gateway (1 scale unit) | ~$0.36/hr |
| **Total** | **~$0.61/hr** |

**Run `destroy.ps1` when done to stop billing!**

## Validation

After deployment completes, verify instance bindings:

```powershell
# Quick check - all connections provisioned
az network vpn-gateway connection list -g rg-lab-005-vwan-s2s --gateway-name vpngw-lab-005 --query "[].{Name:name,State:provisioningState}" -o table

# Detailed - check instance bindings per link
# See docs/validation.md for full commands
```

Expected output shows:
- 4 connections (conn-site-1 through conn-site-4)
- Each with 2 link connections
- Odd links bound to Instance 0
- Even links bound to Instance 1

## Azure Portal

Monitor deployment progress:
```
https://portal.azure.com/#@/resource/subscriptions/<sub-id>/resourceGroups/rg-lab-005-vwan-s2s/deployments
```

## Resources Created

| Resource | Name |
|----------|------|
| Resource Group | `rg-lab-005-vwan-s2s` |
| Virtual WAN | `vwan-lab-005` |
| Virtual Hub | `vhub-lab-005` |
| VPN Gateway | `vpngw-lab-005` |
| VPN Sites | `site-1`, `site-2`, `site-3`, `site-4` |

## Cleanup

```powershell
# Interactive (with confirmation)
.\destroy.ps1

# Force (no prompts)
.\destroy.ps1 -Force

# Keep log files
.\destroy.ps1 -Force -KeepLogs
```

Cleanup takes 5-10 minutes.

## Documentation

- [Architecture](docs/architecture.md) - Detailed architecture explanation
- [APIPA Mapping](docs/apipa-mapping.md) - APIPA allocation details
- [Validation](docs/validation.md) - CLI commands to verify deployment
- [Troubleshooting](docs/troubleshooting.md) - Common issues and fixes

## Why This Lab Matters

This lab is the **gold reference** for Azure vWAN S2S VPN behavior:

1. **Proves Instance 1 exists and works** - Many assume only Instance 0 is used
2. **Validates custom BGP addresses** - Confirms APIPA assignments are honored
3. **Fail-forward design** - Easy to debug when things go wrong
4. **No external dependencies** - All Azure, no AWS/on-prem complexity

Use this lab to:
- Debug other hybrid VPN labs
- Validate customer configurations
- Train on vWAN S2S architecture
- Create baseline for future labs

## Security Note

This lab is **public-safe**:
- No real customer IPs
- No secrets checked in (PSKs generated at runtime)
- APIPA addresses only (169.254.x.x)
- Logs are local-only (gitignored)
