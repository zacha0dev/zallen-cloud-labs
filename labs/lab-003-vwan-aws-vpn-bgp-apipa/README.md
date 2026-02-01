# Lab 003: Azure vWAN ↔ AWS Site-to-Site VPN with BGP over APIPA

This lab deploys a fully functional Site-to-Site VPN between Azure Virtual WAN and AWS VPC using BGP with APIPA (Automatic Private IP Addressing) for tunnel inside addresses.

## What This Lab Demonstrates

- Azure Virtual WAN with VPN Gateway
- AWS VPC with Virtual Private Gateway
- IKEv2 IPsec tunnels with BGP dynamic routing
- APIPA /30 tunnel addressing for BGP peering
- Bidirectional route propagation

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│   Azure (10.100.0.0/24 hub, 10.200.0.0/24 spoke)                       │
│   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐              │
│   │   vWAN      │────▶│  VPN Gateway│────▶│  Spoke VNet │              │
│   │             │     │  (ASN 65515)│     │  + Test VM  │              │
│   └─────────────┘     └──────┬──────┘     └─────────────┘              │
│                              │                                          │
└──────────────────────────────┼──────────────────────────────────────────┘
                               │
                    IPsec/IKEv2 + BGP
                    ┌──────────┴──────────┐
                    │  APIPA Tunnels:     │
                    │  169.254.21.0/30    │
                    │  169.254.22.0/30    │
                    └──────────┬──────────┘
                               │
┌──────────────────────────────┼──────────────────────────────────────────┐
│                              │                                          │
│   AWS (10.20.0.0/16)        │                                          │
│   ┌─────────────┐     ┌─────┴───────┐     ┌─────────────┐              │
│   │     VPC     │◀────│     VGW     │◀────│  Customer   │              │
│   │             │     │ (ASN 65001) │     │   Gateway   │              │
│   └─────────────┘     └─────────────┘     └─────────────┘              │
│                                                                         │
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

| Tunnel | AWS (CGW) Side | Azure Side |
|--------|----------------|------------|
| Tunnel 1 | 169.254.21.1/30 | 169.254.21.2/30 |
| Tunnel 2 | 169.254.22.1/30 | 169.254.22.2/30 |

## Validation Output

```
Lab 003: VPN Validation
========================

Azure VPN Site Checks:
[PASS] VPN Site exists - vpnsite-aws-lab-003
[PASS] VPN Site Links count >= 2 - 2 link(s)
[PASS] APIPA (169.254.x.x) in BGP properties - 169.254.21.2, 169.254.22.2

Azure VPN Gateway Checks:
[PASS] VPN Gateway exists - vpngw-lab-003
[PASS] VPN Gateway connections - 1 connection(s)
[PASS] BGP enabled on VPN connection

Azure BGP Peer Status:
  Peer 169.254.21.1 : Connected
  Peer 169.254.22.1 : Connected
[PASS] BGP sessions established - 2 peer(s) connected

AWS Checks:
[PASS] VPN Connection state - available

AWS Tunnel Status:
  52.x.x.x : UP
  52.y.y.y : UP
[PASS] At least one tunnel UP - 2 tunnel(s) up

========================
Summary: 9 passed, 0 failed
========================
```

## Cost Estimate

| Resource | Approximate Cost |
|----------|------------------|
| Azure vWAN Hub | ~$0.25/hour |
| Azure VPN Gateway | Included in hub |
| Azure VM (B1s) | ~$0.01/hour |
| AWS VPN Connection | ~$0.05/hour |
| AWS VGW | Free (attached to VPC) |

**Total: ~$0.30/hour**

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
