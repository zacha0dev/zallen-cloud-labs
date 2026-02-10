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
- Azure CLI installed and authenticated (`az login`)
- PowerShell 7+ (or Windows PowerShell 5.1)
- Repository configured (see Quick Start below)

## Quick Start

```powershell
# 1. Clone and setup (one-time)
git clone https://github.com/zacha0dev/zallen-cloud-labs.git
cd zallen-cloud-labs

.\setup.ps1                # Interactive — checks tools, prompts for az login
.\setup.ps1 -Status        # Quick check — are tools + auth ready?

# 2. Configure subscription (one-time)
copy .data\subs.example.json .data\subs.json
notepad .data\subs.json    # Add your subscription ID

# 3. Deploy this lab
cd labs\lab-006-vwan-spoke-bgp-router-loopback
.\deploy.ps1               # Uses defaults (centralus, default sub)

# Or with options
.\deploy.ps1 -Location eastus2 -Owner "yourname" -Force

# 4. Inspect routes and BGP state
.\inspect.ps1              # Full inspection
.\inspect.ps1 -RoutesOnly  # Just effective route tables
.\inspect.ps1 -BgpOnly     # Just BGP peering status

# 5. Run experiments (SSH to router VM)
# See docs/experiments.md for loopback propagation tests

# 6. Cleanup when done (stops billing!)
.\destroy.ps1 -Force
```

## Parameters

### deploy.ps1

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionKey` | `default` from subs.json | Which subscription to use |
| `-Location` | `centralus` | Azure region (centralus, eastus, eastus2, westus2) |
| `-Owner` | (empty) | Optional owner tag |
| `-Force` | `$false` | Skip cost confirmation prompt |

### inspect.ps1

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionKey` | `default` from subs.json | Which subscription to use |
| `-RoutesOnly` | `$false` | Show only effective route tables |
| `-BgpOnly` | `$false` | Show only BGP peering status |

### destroy.ps1

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionKey` | `default` from subs.json | Which subscription to use |
| `-Force` | `$false` | Skip DELETE confirmation prompt |
| `-KeepLogs` | `$false` | Preserve log files after cleanup |

## Deployment Phases

| Phase | Description | Duration |
|-------|-------------|----------|
| 0 | Preflight + config contracts (auth, quota, providers) | ~30s |
| 1 | Core fabric (RG + vWAN + vHub) | 5-10 min |
| 2 | Spoke VNets + hub connections | 2-5 min |
| 3 | Compute (Router VM + Client VMs, all parallel) | 3-5 min |
| 4 | Router config + loopback creation (FRR bootstrap) | 1-2 min |
| 5 | BGP peering (router to vHub) | 2-5 min |
| 6 | Route table control + propagation experiments | ~1 min |
| 7 | Observability proof pack (outputs.json) | ~30s |

**Total expected time: 15-30 minutes**

Each phase has [PASS]/[FAIL] validation gates. If a phase fails, the script stops with actionable output. Re-run `.\deploy.ps1 -Force` to resume from where it left off (idempotent).

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
az network vhub bgpconnection list `
  -g rg-lab-006-vwan-bgp-router `
  --vhub-name vhub-lab-006 -o table

# Quick: effective routes on Client A
.\inspect.ps1 -RoutesOnly

# Full inspection (BGP + routes + VM status)
.\inspect.ps1

# SSH to router for FRR state
ssh azurelab@<router-public-ip>
sudo vtysh -c "show bgp summary"
sudo vtysh -c "show bgp ipv4 unicast"
```

See [docs/validation.md](docs/validation.md) for full commands and expected outputs.

## Loopback Experiments

| Test | Loopback Prefix | Expected Behavior |
|------|----------------|-------------------|
| Inside VNet | `10.61.250.1/32` | May conflict with Spoke A system routes |
| Outside VNet | `10.200.200.1/32` | Should propagate cleanly to vHub |

The core question: does a /32 BGP-learned route win over Azure's system route for the VNet CIDR?

See [docs/experiments.md](docs/experiments.md) for step-by-step procedures, FRR commands, and a results template.

## Resources Created

| Resource | Name | Notes |
|----------|------|-------|
| Resource Group | `rg-lab-006-vwan-bgp-router` | All resources live here |
| Virtual WAN | `vwan-lab-006` | Standard SKU (required for NVA BGP) |
| Virtual Hub | `vhub-lab-006` | 10.0.0.0/24, ASN 65515 |
| Spoke A VNet | `vnet-spoke-a` | 10.61.0.0/16 (3 subnets) |
| Spoke B VNet | `vnet-spoke-b` | 10.62.0.0/16 (1 subnet) |
| Router VM | `vm-router-006` | 2 NICs, IP forwarding, FRR |
| Client A VM | `vm-client-a-006` | Spoke A test workload |
| Client B VM | `vm-client-b-006` | Spoke B control workload |
| BGP Peering | `bgp-peer-router-006` | vHub <-> Router, ASN 65100 |

## Cleanup

```powershell
# Interactive (with confirmation)
.\destroy.ps1

# Force (no prompts)
.\destroy.ps1 -Force

# Keep log files
.\destroy.ps1 -Force -KeepLogs
```

Cleanup takes 5-10 minutes. Deletes the entire resource group and local `.data/lab-006/` directory.

## File Structure

```
lab-006-vwan-spoke-bgp-router-loopback/
├── README.md                    # This file
├── deploy.ps1                   # Phased deployment (Phases 0-7)
├── destroy.ps1                  # Resource cleanup
├── inspect.ps1                  # Route + BGP + VM inspection
├── lab.config.example.json      # Config contract (CIDRs, ASNs, switches)
├── logs/                        # Runtime logs (gitignored)
├── docs/
│   ├── architecture.md          # Topology, address plan, design decisions
│   ├── validation.md            # CLI commands + PASS/FAIL criteria
│   ├── observability.md         # Health gates + triage table
│   └── experiments.md           # Loopback propagation tests
├── infra/                       # Bicep modules (placeholders)
│   ├── main.bicep
│   └── modules/
│       ├── vwan.bicep
│       ├── spoke-a.bicep
│       ├── spoke-b.bicep
│       └── compute.bicep
└── scripts/router/              # Router VM bootstrap
    ├── cloud-init-router.yaml   # FRR + loopback + IP forwarding
    ├── cloud-init-client.yaml   # Basic network tools
    ├── bootstrap-router.sh      # Alternative (az vm run-command)
    └── frr.conf                 # FRR BGP config template
```

## Documentation

- [Architecture](docs/architecture.md) - Detailed topology, address plan, and design decisions
- [Validation](docs/validation.md) - CLI commands, expected outputs, and PASS/FAIL criteria
- [Observability](docs/observability.md) - 5 health gates, triage table, and what NOT to look at
- [Experiments](docs/experiments.md) - 4 loopback propagation experiments with results template

## Security Note

This lab is **public-safe**:
- No real customer IPs or secrets checked in
- SSH keys generated at runtime (gitignored in `.data/`)
- Deterministic naming (no random suffixes)
- Logs are local-only (gitignored)
