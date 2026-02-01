# Azure Labs

A hands-on collection of Azure networking labs with Infrastructure-as-Code (Bicep + Terraform). Build real hybrid cloud scenarios including Virtual WAN, VPN gateways, and AWS interoperability.

## Features

- **PowerShell-driven** - Consistent deploy/validate/destroy workflow
- **Infrastructure-as-Code** - Azure Bicep + AWS Terraform
- **Safe cleanup** - Tag-based resource tracking, WhatIf preview modes
- **Cross-cloud** - Azure ↔ AWS hybrid networking labs

## Quick Start

```powershell
# Full setup (installs tooling, prompts for Azure + AWS login)
.\scripts\setup.ps1 -DoLogin

# Check status
.\run.ps1 status

# Run a lab (example: Lab 003)
cd labs/lab-003-vwan-aws-vpn-bgp-apipa
.\scripts\deploy.ps1 -AdminPassword (Read-Host -AsSecureString "Password")
.\scripts\validate.ps1
.\scripts\destroy.ps1
```

For detailed setup instructions, see **[docs/setup-overview.md](docs/setup-overview.md)**.

## Configuration

Labs use `.data/subs.json` for Azure subscription configuration:

```json
{
  "default": "your-subscription-id",
  "dev": "dev-subscription-id"
}
```

Override with `-SubscriptionKey`:
```powershell
.\scripts\deploy.ps1 -SubscriptionKey dev -AdminPassword $pwd
```

See [docs/labs-config.md](docs/labs-config.md) for details.

## AWS Setup (Optional)

AWS integration is only required for hybrid labs (e.g., `lab-003`).

| Guide | Description |
|-------|-------------|
| [AWS Account Setup](docs/aws-account-setup.md) | Create account, billing guardrails |
| [AWS Identity Center (SSO)](docs/aws-identity-center-sso.md) | Set up browser-based login |
| [AWS CLI Profile Setup](docs/aws-cli-profile-setup.md) | Configure `aws-labs` profile |
| [AWS Troubleshooting](docs/aws-troubleshooting.md) | Common errors and fixes |

**Quick AWS setup:**
```powershell
# Install CLI
winget install Amazon.AWSCLI

# Configure SSO profile (recommended)
aws configure sso --profile aws-labs

# Login
aws sso login --profile aws-labs

# Verify
aws sts get-caller-identity --profile aws-labs
```

## Labs

| Lab | Description |
|-----|-------------|
| [lab-000](labs/lab-000_resource-group/) | Resource Group basics |
| [lab-001](labs/lab-001-virtual-wan-hub-routing/) | Virtual WAN hub routing |
| [lab-002](labs/lab-002-l7-fastapi-appgw-frontdoor/) | L7 load balancing with App Gateway + Front Door |
| [lab-003](labs/lab-003-vwan-aws-vpn-bgp-apipa/) | **Azure vWAN ↔ AWS VPN** with BGP over APIPA |
| [lab-004](labs/lab-004-vwan-default-route-propagation/) | vWAN default route propagation |

Each lab includes:
- `scripts/deploy.ps1` - Deploy infrastructure
- `scripts/validate.ps1` - Verify connectivity and configuration
- `scripts/destroy.ps1` - Clean up resources (supports `-WhatIf`)

---
Zachary Allen - 2026
