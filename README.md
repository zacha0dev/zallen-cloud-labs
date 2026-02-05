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

## Configuration Templates

Your local configuration files are **gitignored** - they never leave your machine. Copy from templates:

### Azure Subscription Config

```powershell
# Copy template to create your config
cp .data/subs.example.json .data/subs.json
```

Then edit `.data/subs.json` with your subscription ID:

```json
{
  "default": "lab",
  "subscriptions": {
    "lab": {
      "id": "00000000-0000-0000-0000-000000000000",
      "name": "My Lab Subscription",
      "tenantId": "00000000-0000-0000-0000-000000000000"
    }
  }
}
```

### AWS Account Config (for lab-003)

```powershell
# Copy template
cp .data/accounts.aws.template.json .data/accounts.aws.json
```

Edit `.data/accounts.aws.json`:

```json
{
  "default": {
    "profile": "aws-labs",
    "region": "us-east-2",
    "accountId": "123456789012",
    "notes": "My AWS lab account"
  }
}
```

### AWS CLI Profile

AWS uses a CLI profile you create. The default name is `aws-labs`, but you can use any name:

```powershell
# Create SSO profile (opens browser for login)
aws configure sso --profile aws-labs

# When prompted:
#   SSO session name: aws-labs-session (or any name)
#   SSO start URL: https://d-XXXXXXXXXX.awsapps.com/start (from your AWS Identity Center)
#   SSO region: us-east-1 (where Identity Center is enabled)
#   CLI default region: us-east-2 (where labs deploy)
#   CLI default output: json
#   Profile name: aws-labs (must match --profile above)
```

After setup, authenticate anytime with:
```powershell
# Browser login (opens automatically)
aws sso login --profile aws-labs

# Verify it worked
aws sts get-caller-identity --profile aws-labs
```

## AWS Setup (for hybrid labs)

AWS is only required for cross-cloud labs like `lab-003`.

### Quick Start (SSO)

1. **Set up Identity Center** in AWS Console (one-time)
2. **Create a CLI profile:**
   ```powershell
   aws configure sso --profile aws-labs
   ```
3. **Login via browser:**
   ```powershell
   aws sso login --profile aws-labs
   ```

SSO tokens expire (1-12 hours). Re-run `aws sso login --profile aws-labs` when needed.

### Detailed Guides

| Guide | Description |
|-------|-------------|
| [AWS Account Setup](docs/aws-account-setup.md) | Create account, billing guardrails |
| [AWS Identity Center (SSO)](docs/aws-identity-center-sso.md) | Set up browser-based login |
| [AWS CLI Profile Setup](docs/aws-cli-profile-setup.md) | Configure CLI profile step-by-step |
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

## Operations & Observability

Each lab includes an observability guide with health gates, troubleshooting patterns, and what NOT to look at. See [docs/observability-index.md](docs/observability-index.md) for the full guide.

| Lab | Observability Guide | Golden Rule |
|-----|---------------------|-------------|
| [lab-000](labs/lab-000_resource-group/) | [observability.md](labs/lab-000_resource-group/docs/observability.md) | RG exists + `Succeeded` state |
| [lab-001](labs/lab-001-virtual-wan-hub-routing/) | [observability.md](labs/lab-001-virtual-wan-hub-routing/docs/observability.md) | vHub `Succeeded` + connection `Connected` |
| [lab-002](labs/lab-002-l7-fastapi-appgw-frontdoor/) | [observability.md](labs/lab-002-l7-fastapi-appgw-frontdoor/docs/observability.md) | `/health` returns `{"ok":true}` via Front Door |
| [lab-003](labs/lab-003-vwan-aws-bgp-apipa/) | [observability.md](labs/lab-003-vwan-aws-bgp-apipa/docs/observability.md) | AWS tunnels `UP` + BGP routes > 0 |
| [lab-004](labs/lab-004-vwan-default-route-propagation/) | [observability.md](labs/lab-004-vwan-default-route-propagation/docs/observability.md) | A1/A2 have 0/0; A3/A4/B1/B2 do NOT |
| [lab-005](labs/lab-005-vwan-s2s-bgp-apipa/) | [observability.md](labs/lab-005-vwan-s2s-bgp-apipa/docs/observability.md) | All connections `Succeeded` + APIPA matches |

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

## Security - Public Repository

This is a **public repository**. No secrets, credentials, or sensitive data are committed.

**What's safe to commit:**
- Templates with placeholder values (`00000000-0000-0000-0000-000000000000`)
- Scripts and documentation
- APIPA addresses (`169.254.x.x`) - these are link-local only

**What's gitignored (never committed):**
- `.data/subs.json` - Your Azure subscription IDs
- `.data/accounts.aws.json` - Your AWS account IDs
- `.data/lab-*/config.json` - Lab-specific configs
- `~/.aws/` - AWS credentials and SSO cache
- `logs/` - Runtime logs (may contain IPs)
- Any file matching `*secret*`, `*credential*`, `*.pem`, `*.key`

**Before committing:** Run `git status` and verify no sensitive files are staged.

---
Zachary Allen - 2026
