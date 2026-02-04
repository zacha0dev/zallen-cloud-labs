# Lab 003: Azure vWAN S2S VPN with AWS (BGP over APIPA)

This lab establishes a site-to-site VPN connection between Azure Virtual WAN and AWS Virtual Private Gateway using BGP over APIPA addresses.

## Purpose

Prove Azure vWAN S2S VPN Gateway dual-instance behavior with deterministic APIPA /30 allocations connecting to AWS VGW.

## Architecture

```
Azure                                           AWS
+------------------+                           +------------------+
|  Virtual WAN     |                           |      VPC         |
|  +------------+  |                           |  10.20.0.0/16    |
|  | vHub       |  |                           |                  |
|  | 10.0.0.0/24|  |    4 IPsec Tunnels       |  +------------+  |
|  +-----+------+  |    (BGP over APIPA)       |  |   VGW      |  |
|        |         |                           |  | ASN: 65001 |  |
|  +-----+------+  |   Tunnel 1: 169.254.21.0  |  +-----+------+  |
|  | VPN Gateway|  |<------------------------->|        |         |
|  | Instance 0 |  |   Tunnel 2: 169.254.21.4  |        |         |
|  | ASN: 65515 |  |<------------------------->|  +-----+------+  |
|  +-----+------+  |                           |  |    CGW 1   |  |
|        |         |                           |  | (Inst 0 IP)|  |
|  +-----+------+  |   Tunnel 3: 169.254.22.0  |  +------------+  |
|  | VPN Gateway|  |<------------------------->|                  |
|  | Instance 1 |  |   Tunnel 4: 169.254.22.4  |  +------------+  |
|  +------------+  |<------------------------->|  |    CGW 2   |  |
+------------------+                           |  | (Inst 1 IP)|  |
                                               |  +------------+  |
                                               +------------------+
```

## Quick Start

### Prerequisites

1. Azure CLI installed and authenticated (`az login`)
2. AWS CLI installed with profile configured (`aws configure --profile aws-labs`)
3. PowerShell 7+ or Windows PowerShell 5.1+

### Deploy

```powershell
cd labs/lab-003-vwan-aws-bgp-apipa
./deploy.ps1 -AwsProfile aws-labs
```

### Destroy

```powershell
./destroy.ps1 -AwsProfile aws-labs
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionKey` | (from config) | Azure subscription key from `.data/subs.json` |
| `-AwsProfile` | `aws-labs` | AWS CLI profile name |
| `-AwsRegion` | `us-east-2` | AWS region for resources |
| `-Location` | `centralus` | Azure region for resources |
| `-AwsBgpAsn` | `65001` | BGP ASN for AWS side |
| `-Owner` | (empty) | Owner tag for resource tracking |
| `-Force` | (switch) | Skip confirmation prompts |

## Deployment Phases

| Phase | Description | Duration |
|-------|-------------|----------|
| 0 | Preflight Checks | ~30s |
| 1 | Core Fabric (vWAN + vHub) | 5-10 min |
| 2 | S2S VPN Gateway | 20-30 min |
| 3 | VPN Sites + Links (placeholder) | ~10s |
| 4 | VPN Connections (deferred) | ~10s |
| 5 | AWS Deployment (VPC, VGW, CGW, VPN) | 3-5 min |
| 5b | Azure VPN Sites + Connections | 2-3 min |
| 6 | Final Validation | ~30s |

**Total: ~35-50 minutes**

## APIPA Mapping

| Instance | CIDR | Azure IP | AWS IP |
|----------|------|----------|--------|
| 0 | 169.254.21.0/30 | .2 | .1 |
| 0 | 169.254.21.4/30 | .6 | .5 |
| 1 | 169.254.22.0/30 | .2 | .1 |
| 1 | 169.254.22.4/30 | .6 | .5 |

See [docs/apipa-mapping.md](docs/apipa-mapping.md) for details.

## Cost Estimates

### Azure (~$0.61/hr)
- vWAN Hub: ~$0.25/hr
- S2S VPN Gateway: ~$0.36/hr

### AWS (~$0.10/hr)
- VPN Connection x2: ~$0.10/hr
- VGW: included with VPN

**Total: ~$0.71/hr (~$17/day)**

## Validation

Quick validation commands:

```powershell
# Azure: Check VPN connection status
az network vpn-gateway connection list -g rg-lab-003-vwan-aws --gateway-name vpngw-lab-003 -o table

# AWS: Check VPN tunnel status
aws ec2 describe-vpn-connections --filters "Name=tag:lab,Values=lab-003" --query "VpnConnections[*].VgwTelemetry[*].[OutsideIpAddress,Status]" --output table
```

See [docs/validation.md](docs/validation.md) for comprehensive validation commands.

## Files

```
labs/lab-003-vwan-aws-bgp-apipa/
├── deploy.ps1          # Main deployment script
├── destroy.ps1         # Cleanup script
├── README.md           # This file
├── docs/
│   ├── architecture.md     # Architecture details
│   ├── apipa-mapping.md    # APIPA address mapping
│   ├── validation.md       # Validation commands
│   └── troubleshooting.md  # Troubleshooting guide
├── logs/               # Runtime logs
└── outputs/            # (unused, outputs in .data/)
```

## Key Features

- **Fail-forward**: Each phase validates independently
- **Resume-safe**: Can re-run deployment to resume from any point
- **Cost-safe**: Clear cost warnings before deployment
- **Deterministic**: APIPA addresses follow a predictable pattern
- **Observable**: Clear status, logs, and portal links throughout

## Resources Created

### Azure
- Resource Group: `rg-lab-003-vwan-aws`
- Virtual WAN: `vwan-lab-003`
- Virtual Hub: `vhub-lab-003`
- VPN Gateway: `vpngw-lab-003`
- VPN Sites: `aws-site-1`, `aws-site-2`
- VPN Connections: `conn-aws-site-1`, `conn-aws-site-2`

### AWS
- VPC: `lab-003-vpc`
- VGW: `lab-003-vgw`
- CGW 1: `lab-003-cgw-azure-inst0`
- CGW 2: `lab-003-cgw-azure-inst1`
- VPN Connection 1: `lab-003-vpn-1`
- VPN Connection 2: `lab-003-vpn-2`

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) for common issues and solutions.

## Related Labs

- **Lab 005**: Azure vWAN S2S BGP over APIPA (Azure-only, reference implementation)
