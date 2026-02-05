# Azure Labs

A hands-on collection of Azure networking labs with Infrastructure-as-Code (Bicep + Terraform). Build real hybrid cloud scenarios including Virtual WAN, VPN gateways, and AWS interoperability.

## Features

- **PowerShell-driven** - Consistent deploy/validate/destroy workflow
- **Infrastructure-as-Code** - Azure Bicep + AWS Terraform
- **Safe cleanup** - Tag-based resource tracking, WhatIf preview modes
- **Cross-cloud** - Azure ↔ AWS hybrid networking labs

## Local Setup

### Option A: Clone with Git (Recommended)

```powershell
# Windows (recommended location)
cd C:\Users\$env:USERNAME\source\repos
git clone https://github.com/zacha0dev/azure-labs.git
cd azure-labs

# macOS / Linux
cd ~/repos
git clone https://github.com/zacha0dev/azure-labs.git
cd azure-labs
```

### Option B: Download ZIP (No Git Required)

1. Go to [github.com/zacha0dev/azure-labs](https://github.com/zacha0dev/azure-labs)
2. Click **Code** → **Download ZIP**
3. Extract to recommended folder:
   - **Windows:** `C:\Users\<you>\source\repos\azure-labs`
   - **macOS/Linux:** `~/repos/azure-labs`

> **Note:** Without Git, updates require re-downloading the ZIP. For the best experience, use Git.

### Required Tools

| Tool | Required | Notes |
|------|----------|-------|
| **Git** | Yes (Option A) | [git-scm.com](https://git-scm.com/) |
| **PowerShell** | Yes | Windows PowerShell 5.1+ or PowerShell 7+ |
| **Azure CLI** | Yes | [aka.ms/installazurecli](https://aka.ms/installazurecli) |
| **AWS CLI** | Optional | Only for lab-003 (hybrid). [aws.amazon.com/cli](https://aws.amazon.com/cli/) |
| **Terraform** | Optional | Only for lab-003. [terraform.io/downloads](https://developer.hashicorp.com/terraform/downloads) |

### Initial Setup

```powershell
# Check your environment status
.\setup.ps1 -Status

# If Azure login is needed
.\setup.ps1 -DoLogin
# Or manually: az login

# Full interactive setup (Azure + AWS)
.\setup.ps1
```

### Configure Subscriptions

Edit `.data/subs.json` with your Azure subscription(s):

```json
{
  "default": "lab",
  "subscriptions": {
    "lab": { "id": "00000000-0000-0000-0000-000000000000", "name": "My Lab Sub" }
  }
}
```

See [docs/labs-config.md](docs/labs-config.md) for advanced configuration.

### Running Labs

```powershell
# Example: Deploy lab-000 (basic resource group test)
cd labs/lab-000_resource-group
.\deploy.ps1

# Example: Deploy lab-001 (Virtual WAN hub routing)
cd labs/lab-001-virtual-wan-hub-routing
.\deploy.ps1
```

### Cleanup

**Always destroy resources when done** to avoid unexpected charges:

```powershell
# In the lab folder
.\destroy.ps1

# Preview what will be deleted
.\destroy.ps1 -WhatIf
```

### Keeping Up to Date

```powershell
# Pull latest changes (if using Git)
.\update.ps1

# Or manually
git pull
```

### Cost Safety

> **Warning:** Some labs deploy billable resources (VPN Gateways, Virtual WAN, VMs).
> - Always run `.\destroy.ps1` when finished
> - Use `.\tools\cost-check.ps1` to audit for leftover resources
> - Check the lab README for cost estimates before deploying

---

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
