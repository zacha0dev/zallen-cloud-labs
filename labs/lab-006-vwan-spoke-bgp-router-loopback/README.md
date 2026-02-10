# Lab 006: vWAN Spoke BGP Router with Loopback

Prove that a vWAN Virtual Hub learns routes via BGP from a router/NVA VM and propagates them to connected spokes.

## What This Lab Proves

- **BGP Route Learning**: vHub learns routes advertised by a FRR router VM
- **Spoke Propagation**: Routes propagate to Spoke A (BGP-peered) and optionally Spoke B (control)
- **Loopback Behavior**: Inside-VNet loopback vs outside-VNet loopback route acceptance
- **Fail-Forward Design**: Phased deployment with validation between steps
- **2-NIC Router Pattern**: Hub-side + spoke-side NICs with IP forwarding

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                      Azure vWAN (Standard)                       │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │                    Virtual Hub                             │  │
│  │                   (vhub-lab-006)                           │  │
│  │                  10.0.0.0/24                               │  │
│  │                  ASN 65515                                 │  │
│  │                                                            │  │
│  │              BGP peering ◄──────────────────┐              │  │
│  └────────────────────────────────────────────────────────────┘  │
│        │                          │            │                 │
│   conn-spoke-a               conn-spoke-b      │                 │
│        │                          │            │                 │
│  ┌─────┴──────────────┐   ┌──────┴──────┐     │                 │
│  │  Spoke A (BGP)     │   │  Spoke B    │     │                 │
│  │  10.61.0.0/16      │   │  10.62.0.0/16│    │                 │
│  │                    │   │  (control)  │     │                 │
│  │  ┌──────────────┐  │   │             │     │                 │
│  │  │  Router VM   │  │   │  ┌────────┐ │     │                 │
│  │  │  ASN 65100   │──┼───┼──┤BGP peer│─┘     │                 │
│  │  │  NIC1: hub   │  │   │  └────────┘ │                       │
│  │  │  NIC2: spoke │  │   │             │                       │
│  │  │  lo0: loopback│ │   │  Client B   │                       │
│  │  └──────────────┘  │   │  VM         │                       │
│  │                    │   └─────────────┘                       │
│  │  Client A VM       │                                         │
│  └────────────────────┘                                         │
└──────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Azure subscription with Contributor access
- Azure CLI installed and authenticated
- PowerShell 7+ (or Windows PowerShell 5.1)
- Repository configured (run `scripts/setup.ps1` first)

## Quick Start

```powershell
# 1. First-time setup (if not done already)
cd azure-labs
.\scripts\setup.ps1 -DoLogin

# 2. Navigate to lab directory
cd labs/lab-006-vwan-spoke-bgp-router-loopback

# 3. Deploy with defaults
.\deploy.ps1

# Or deploy with specific options
.\deploy.ps1 -Location eastus2 -Owner "yourname" -Force

# 4. Inspect routes and BGP state
.\inspect.ps1

# 5. Cleanup when done (stops billing!)
.\destroy.ps1 -Force
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionKey` | `default` from subs.json | Which subscription to use |
| `-Location` | `centralus` | Azure region (centralus, eastus, eastus2, westus2) |
| `-Owner` | (empty) | Optional owner tag |
| `-Force` | `$false` | Skip cost confirmation prompt |

## Deployment Phases

| Phase | Description | Duration |
|-------|-------------|----------|
| 0 | Preflight + config contracts | ~30s |
| 1 | Core fabric (RG + vWAN + vHub) | 5-10 min |
| 2 | Spoke VNets + hub connections | 2-5 min |
| 3 | Compute (Router VM + Client VMs) | 3-5 min |
| 4 | Router config + loopback creation | 1-2 min |
| 5 | BGP peering (router to vHub) | 2-5 min |
| 6 | Route table control + propagation | ~1 min |
| 7 | Observability proof pack | ~30s |

**Total expected time: 15-30 minutes**

## Cost Estimate

| Resource | Approximate Cost |
|----------|------------------|
| vWAN Hub | ~$0.25/hr |
| Router VM (B2s) | ~$0.04/hr |
| Client VM A (B2s) | ~$0.04/hr |
| Client VM B (B2s) | ~$0.04/hr |
| **Total** | **~$0.37/hr** |

**Run `destroy.ps1` when done to stop billing!**

## Validation

```powershell
# Quick: check BGP peering state
az network vhub bgpconnection list -g rg-lab-006-vwan-bgp-router --vhub-name vhub-lab-006 -o table

# Quick: effective routes on Client A
.\inspect.ps1 -RoutesOnly

# Full inspection
.\inspect.ps1
```

See [docs/validation.md](docs/validation.md) for full commands and expected outputs.

## Loopback Experiments

| Test | Loopback Prefix | Expected Behavior |
|------|----------------|-------------------|
| Inside VNet | `10.61.250.1/32` | May conflict with Spoke A system routes |
| Outside VNet | `10.200.200.1/32` | Should propagate cleanly to vHub |

See [docs/experiments.md](docs/experiments.md) for detailed procedures and results.

## Resources Created

| Resource | Name |
|----------|------|
| Resource Group | `rg-lab-006-vwan-bgp-router` |
| Virtual WAN | `vwan-lab-006` |
| Virtual Hub | `vhub-lab-006` |
| Spoke A VNet | `vnet-spoke-a` |
| Spoke B VNet | `vnet-spoke-b` |
| Router VM | `vm-router-006` (2 NICs) |
| Client A VM | `vm-client-a-006` |
| Client B VM | `vm-client-b-006` |
| BGP Peering | `bgp-peer-router-006` |

## Cleanup

```powershell
# Interactive (with confirmation)
.\destroy.ps1

# Force (no prompts)
.\destroy.ps1 -Force

# Keep log files
.\destroy.ps1 -Force -KeepLogs
```

## Documentation

- [Architecture](docs/architecture.md) - Detailed topology and design decisions
- [Validation](docs/validation.md) - CLI commands and expected outputs
- [Observability](docs/observability.md) - Health gates and troubleshooting
- [Experiments](docs/experiments.md) - Loopback propagation tests

## Security Note

This lab is **public-safe**:
- No real customer IPs or secrets checked in
- SSH keys generated at runtime (gitignored in `.data/`)
- Deterministic naming (no random suffixes)
- Logs are local-only (gitignored)
