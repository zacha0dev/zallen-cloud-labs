# Lab 003: Azure vWAN ↔ AWS Site-to-Site VPN with BGP over APIPA

This lab deploys a fully functional Site-to-Site VPN between Azure Virtual WAN and AWS VPC using BGP with APIPA (Automatic Private IP Addressing) for tunnel inside addresses.

## What This Lab Demonstrates

- Azure Virtual WAN with VPN Gateway (active-active with 2 instances)
- AWS VPC with Virtual Private Gateway
- **4 IPsec/IKEv2 tunnels** with BGP dynamic routing (2 per Azure instance)
- APIPA /30 tunnel addressing for BGP peering
- Full redundancy: 2 AWS VPN connections, 4 tunnels total

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Azure (10.100.0.0/24 hub, 10.200.0.0/24 spoke)                         │
│                                                                          │
│  ┌─────────┐    ┌──────────────────────────┐    ┌─────────────┐         │
│  │  vWAN   │───▶│      VPN Gateway         │───▶│ Spoke VNet  │         │
│  │         │    │      (ASN 65515)         │    │  + Test VM  │         │
│  └─────────┘    │  ┌──────┐    ┌──────┐   │    └─────────────┘         │
│                 │  │Inst 0│    │Inst 1│   │                             │
│                 │  │ IP 1 │    │ IP 2 │   │                             │
│                 └──┴──┬───┴────┴──┬───┴───┘                             │
└───────────────────────┼───────────┼─────────────────────────────────────┘
                        │           │
          ┌─────────────┘           └─────────────┐
          │  Tunnels 1-2                Tunnels 3-4│
          │  169.254.21.0/30            169.254.23.0/30
          │  169.254.22.0/30            169.254.24.0/30
          ▼                             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  AWS (10.20.0.0/16)                                                     │
│                                                                          │
│  ┌───────────┐    ┌───────────┐         ┌─────────────────────────┐    │
│  │   CGW 1   │───▶│ VPN Conn 1│────┐    │                         │    │
│  │ (→Inst 0) │    │ (2 tunls) │    │    │          VGW            │    │
│  └───────────┘    └───────────┘    ├───▶│      (ASN 65001)        │    │
│  ┌───────────┐    ┌───────────┐    │    │                         │    │
│  │   CGW 2   │───▶│ VPN Conn 2│────┘    └───────────┬─────────────┘    │
│  │ (→Inst 1) │    │ (2 tunls) │                     │                  │
│  └───────────┘    └───────────┘                     ▼                  │
│                                              ┌─────────────┐           │
│                                              │     VPC     │           │
│                                              │ 10.20.0.0/16│           │
│                                              └─────────────┘           │
└─────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Run `scripts\setup.ps1` first (sets up Azure CLI + AWS CLI)
- Terraform installed (`winget install HashiCorp.Terraform`)
- Azure subscription with permissions for vWAN/VPN
- AWS account with SSO configured (see [AWS SSO Setup](docs/aws-sso-setup.md))

## Quick Start

From the repo root:

```powershell
# 1. Setup (first time only)
.\scripts\setup.ps1 -DoLogin -IncludeAWS

# 2. Navigate to lab
cd labs/lab-003-vwan-aws-vpn-bgp-apipa

# 3. Deploy (takes 25-35 min) - AdminPassword is REQUIRED
$pwd = Read-Host -AsSecureString "Enter VM admin password"
.\scripts\deploy.ps1 -AdminPassword $pwd

# 4. Validate connectivity (wait 5-10 min after deploy)
.\scripts\validate.ps1

# 5. Clean up when done (use -WhatIf to preview)
.\scripts\destroy.ps1 -WhatIf   # Preview what will be deleted
.\scripts\destroy.ps1           # Actually delete resources
```

> **Note**: The `-AdminPassword` parameter is required. Running `deploy.ps1` without it will show an error.

### Using Different Subscriptions

Scripts use subscription from `.data/subs.json`. Override with `-SubscriptionKey`:

```powershell
# Use default subscription from config
.\scripts\deploy.ps1 -AdminPassword (Read-Host -AsSecureString "Password")

# Use a specific subscription key
.\scripts\deploy.ps1 -SubscriptionKey sub01 -AdminPassword (Read-Host -AsSecureString "Password")

# With owner tag for resource tracking
.\scripts\deploy.ps1 -AdminPassword (Read-Host -AsSecureString "Password") -Owner "yourname"
```

See [docs/labs-config.md](../../docs/labs-config.md) for subscription configuration.

## Configuration

Uses repo-level config from `.data/subs.json` for Azure subscription.

| Parameter | Default | Description |
|-----------|---------|-------------|
| Azure BGP ASN | 65515 | Azure VPN Gateway ASN |
| AWS BGP ASN | 65001 | AWS Virtual Private Gateway ASN |
| Azure Hub | 10.100.0.0/24 | Virtual Hub address space |
| Azure Spoke | 10.200.0.0/24 | Spoke VNet for test VM |
| AWS VPC | 10.20.0.0/16 | AWS VPC CIDR |

## Resource Tagging

All resources are tagged for tracking and safe cleanup:

| Tag | Value | Description |
|-----|-------|-------------|
| `project` | azure-labs | Repository identifier |
| `lab` | lab-003 | Lab identifier |
| `env` | lab | Environment type |
| `owner` | (optional) | Your name/alias for tracking |

Use `-Owner "yourname"` when deploying to add owner tracking.

## APIPA Tunnel Addressing

| Tunnel | AWS VPN Conn | Azure Instance | AWS (VGW) Side | Azure Side |
|--------|--------------|----------------|----------------|------------|
| Tunnel 1 | VPN Conn 1 | Instance 0 | 169.254.21.1/30 | 169.254.21.2/30 |
| Tunnel 2 | VPN Conn 1 | Instance 0 | 169.254.22.1/30 | 169.254.22.2/30 |
| Tunnel 3 | VPN Conn 2 | Instance 1 | 169.254.23.1/30 | 169.254.23.2/30 |
| Tunnel 4 | VPN Conn 2 | Instance 1 | 169.254.24.1/30 | 169.254.24.2/30 |

## Validation Output

```
Lab 003: VPN Validation
========================

Azure VPN Site Checks:
[PASS] VPN Site exists - lab-003-aws-site
[PASS] VPN Site Links count >= 4 - 4 link(s)
[PASS] APIPA (169.254.x.x) in BGP properties - 169.254.21.2, 169.254.22.2, 169.254.23.2, 169.254.24.2

Azure VPN Gateway Checks:
[PASS] VPN Gateway exists - vpngw-lab-003
[PASS] VPN Gateway connections - 1 connection(s)
[PASS] BGP enabled on VPN connection

Azure BGP Peer Status:
  Peer 169.254.21.1 : Connected
  Peer 169.254.22.1 : Connected
  Peer 169.254.23.1 : Connected
  Peer 169.254.24.1 : Connected
[PASS] BGP sessions established - 4 peer(s) connected

AWS Checks:
  VPN vpn-xxx : available
  VPN vpn-yyy : available
[PASS] AWS VPN Connections (need 2) - 2 connection(s) available

AWS Tunnel Status (4 tunnels expected):
  3.x.x.x : UP
  3.y.y.y : UP
  18.x.x.x : UP
  18.y.y.y : UP
[PASS] AWS tunnels UP (need >= 2 of 4) - 4 tunnel(s) up

========================
Summary: 10 passed, 0 failed
========================
```

## Cost Estimate

| Resource | Approximate Cost |
|----------|------------------|
| Azure vWAN Hub | ~$0.25/hour |
| Azure VPN Gateway | Included in hub |
| Azure VM (B1s) | ~$0.01/hour |
| AWS VPN Connection x2 | ~$0.10/hour |
| AWS VGW | Free (attached to VPC) |

**Total: ~$0.35/hour**

Run `destroy.ps1` when done!

## Documentation

- [Prerequisites](docs/prerequisites.md) - What you need before starting
- [AWS SSO Setup](docs/aws-sso-setup.md) - Configure AWS Identity Center
- [Walkthrough](docs/walkthrough.md) - Step-by-step deployment guide
- [Troubleshooting](docs/troubleshooting.md) - Common issues and fixes
- [Best Practices](docs/best-practices.md) - APIPA planning, PSK handling

## File Structure

```
labs/lab-003-vwan-aws-vpn-bgp-apipa/
├── README.md
├── azure/
│   ├── main.bicep              # Azure infrastructure
│   └── main.parameters.json
├── aws/
│   ├── main.tf                 # AWS infrastructure
│   ├── variables.tf
│   └── outputs.tf
├── scripts/
│   ├── deploy.ps1              # Orchestrated deployment
│   ├── validate.ps1            # PASS/FAIL validation
│   └── destroy.ps1             # Safe teardown (-WhatIf supported)
└── docs/
    ├── prerequisites.md
    ├── aws-sso-setup.md
    ├── walkthrough.md
    ├── troubleshooting.md
    └── best-practices.md
```
