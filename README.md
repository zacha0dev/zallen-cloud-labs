# Azure Labs

A hands-on collection of Azure networking labs with Infrastructure-as-Code (Bicep + Terraform). Build real hybrid cloud scenarios including Virtual WAN, VPN gateways, and AWS interoperability.

## Features

- **PowerShell-driven** - Consistent deploy/validate/destroy workflow
- **Infrastructure-as-Code** - Azure Bicep + AWS Terraform
- **Safe cleanup** - Tag-based resource tracking, WhatIf preview modes
- **Cross-cloud** - Azure ↔ AWS hybrid networking labs

## Quick Start

```powershell
# 1. Setup (one-time)
.\setup.ps1

# 2. Deploy a simple lab to test your setup
cd labs/lab-000_resource-group
.\deploy.ps1

# 3. Verify it worked
az group list --query "[?starts_with(name,'rg-lab-000')]" -o table

# 4. Clean up
.\destroy.ps1
```

**Ready for more?** Try [lab-005](labs/lab-005-vwan-s2s-bgp-apipa/) for a full vWAN S2S VPN deployment (Azure-only, ~30 min).

**Setup options:**
```powershell
.\setup.ps1            # Interactive - checks Azure + AWS, prompts for logins
.\setup.ps1 -Azure     # Azure setup only
.\setup.ps1 -Aws       # AWS setup only
.\setup.ps1 -Status    # Quick status check (no prompts)
```

For detailed setup instructions, see **[docs/setup-overview.md](docs/setup-overview.md)**.

## Configuration

Azure subscriptions are configured in `.data/subs.json` (gitignored):

```json
{
  "default": "sub01",
  "subscriptions": {
    "sub01": { "id": "00000000-0000-0000-0000-000000000000", "name": "My Sub" }
  }
}
```

AWS uses the `aws-labs` profile. Configure with:
```powershell
aws configure sso --profile aws-labs   # SSO (recommended)
aws configure --profile aws-labs        # IAM keys
```

## AWS Setup (for hybrid labs)

AWS is only required for cross-cloud labs like `lab-003`. Run `.\setup.ps1 -Aws` or see:

| Guide | Description |
|-------|-------------|
| [AWS Account Setup](docs/aws-account-setup.md) | Create account, billing guardrails |
| [AWS Identity Center (SSO)](docs/aws-identity-center-sso.md) | Set up browser-based login |
| [AWS CLI Profile Setup](docs/aws-cli-profile-setup.md) | Configure `aws-labs` profile |
| [AWS Troubleshooting](docs/aws-troubleshooting.md) | Common errors and fixes |

## Labs

| Lab | Description | Cloud |
|-----|-------------|-------|
| [lab-000](labs/lab-000_resource-group/) | Resource Group basics | Azure |
| [lab-001](labs/lab-001-virtual-wan-hub-routing/) | Virtual WAN hub routing | Azure |
| [lab-002](labs/lab-002-l7-fastapi-appgw-frontdoor/) | L7 load balancing with App Gateway + Front Door | Azure |
| [lab-003](labs/lab-003-vwan-aws-vpn-bgp-apipa/) | Azure vWAN ↔ AWS VPN with BGP over APIPA | Azure + AWS |
| [lab-004](labs/lab-004-vwan-default-route-propagation/) | vWAN default route propagation | Azure |
| [lab-005](labs/lab-005-vwan-s2s-bgp-apipa/) | **vWAN S2S BGP over APIPA** - dual instance reference lab | Azure |

Each lab includes:
- `scripts/deploy.ps1` - Deploy infrastructure
- `scripts/validate.ps1` - Verify connectivity and configuration
- `scripts/destroy.ps1` - Clean up resources (supports `-WhatIf`)

## Tools

Utility scripts for managing lab resources. See [tools/README.md](tools/README.md) for details.

```powershell
# Audit Azure + AWS for billable lab resources
./tools/cost-check.ps1

# Check specific lab with AWS
./tools/cost-check.ps1 -Lab lab-003 -AwsProfile aws-labs

# Full subscription audit
./tools/cost-check.ps1 -Scope All -AwsProfile aws-labs
```

---
Zachary Allen - 2026
