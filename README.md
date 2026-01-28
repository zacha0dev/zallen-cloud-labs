# Azure Labs

Azure Labs is a lightweight set of scripts and lab scaffolds to help you build Azure-first networking scenarios quickly, with optional AWS interoperability where noted.

## Quick Start

```powershell
# Full setup (installs tooling, prompts for Azure + AWS login)
.\scripts\setup.ps1 -DoLogin

# Check status
.\run.ps1 status
```

For detailed setup instructions, see **[docs/setup-overview.md](docs/setup-overview.md)**.

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
- `labs/lab-000_resource-group`
- `labs/lab-001-virtual-wan-hub-routing`
- `labs/lab-002-l7-fastapi-appgw-frontdoor`
- `labs/lab-003-vwan-aws-vpn-bgp-apipa`
- `labs/lab-004-vwan-default-route-propagation`

---
Zachary Allen - 2026
