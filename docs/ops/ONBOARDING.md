# Onboarding Guide

> Get from zero to a running Azure lab in under 10 minutes.

## Who This Guide Is For

You have an **Azure account** and want to run cloud networking labs. No AWS account required for any Azure-only lab. AWS is optional and only needed for **lab-003** (hybrid Azure-AWS connectivity).

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| PowerShell | 5.1+ or 7+ | [Download](https://github.com/PowerShell/PowerShell/releases) |
| Azure CLI | 2.50+ | [Install guide](https://aka.ms/installazurecli) |
| Bicep (via Azure CLI) | latest | `az bicep install` |

**Not required** unless you run lab-003: AWS CLI, Terraform.

---

## Azure-Only Path (Default)

### Step 1 - Clone and enter the repo

```powershell
git clone https://github.com/zacha0dev/zallen-cloud-labs.git
cd zallen-cloud-labs
```

### Step 2 - Set up Azure tools + subscription

```powershell
.\setup.ps1 -Azure
```

This will:
- Check Azure CLI is installed (and offer to install it)
- Install Bicep if missing
- Prompt for `az login` if not authenticated
- Detect your subscriptions and let you pick one
- Write `.data/subs.json` automatically

If you want to configure subscriptions separately at any time:

```powershell
.\setup.ps1 -ConfigureSubs
```

To set a specific subscription ID directly (non-interactive):

```powershell
.\setup.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
```

### Step 3 - Run the baseline lab

```powershell
cd labs\lab-000_resource-group
.\deploy.ps1
.\destroy.ps1     # Always clean up!
```

Lab 000 is free and takes about 20 seconds. Use it to verify everything is wired up correctly before running billable labs.

---

## Subscription Configuration

`.data/subs.json` stores your subscription IDs locally. It is gitignored and never committed.

The setup wizard writes it for you. The schema supports multiple named subscriptions:

```json
{
  "subscriptions": {
    "lab": {
      "id": "<your-subscription-id>",
      "name": "My Lab Subscription",
      "tenantId": "<your-tenant-id>"
    }
  },
  "default": "lab"
}
```

To add a second subscription, run the wizard again with a different name:

```powershell
.\setup.ps1 -ConfigureSubs -SubscriptionName "prod"
```

To see what is currently configured:

```powershell
.\setup.ps1 -Status
```

---

## What Is Gitignored and Why

| Pattern | Why |
|---------|-----|
| `.data/subs.json` | Contains your real subscription IDs |
| `.data/**/*.json` (non-template) | Lab outputs may contain IPs, resource IDs |
| `.azure/` | Azure CLI auth tokens |
| `**/*.pem`, `**/*.key` | Private keys |
| `*.tfstate` | Terraform state with sensitive data |
| `.env`, `.env.*` | Environment secrets |

Templates (`.example.json`, `.template.json`) are tracked so new users get a schema reference.

---

## AWS Optional Path (lab-003 Only)

AWS is only required for the hybrid lab (lab-003: Azure vWAN S2S VPN to AWS). Skip this section unless you plan to run that lab.

### One-time AWS CLI setup

```powershell
# Install AWS CLI
winget install Amazon.AWSCLI

# Configure SSO profile (one-time)
aws configure sso --profile aws-labs

# Login when token expires
aws sso login --profile aws-labs

# Run AWS + Azure setup
.\setup.ps1 -Aws
```

See [docs/aws-setup.md](../aws-setup.md) for detailed instructions.

---

## Cost Safety

Labs deploy real Azure resources. **Always run `.\destroy.ps1` when done.**

- **Free**: lab-000 (resource group + VNet only)
- **Low cost (~$0.25-0.60/hr)**: lab-001, lab-002, lab-004, lab-005, lab-006
- **Moderate cost (~$0.70/hr)**: lab-003 (Azure + AWS charges)

To check for leftover billable resources:

```powershell
.\tools\cost-check.ps1
```

This is read-only and safe to run at any time.

---

## Quick Verification Checklist

Run this to verify your environment before deploying any lab:

```powershell
.\setup.ps1 -Status
```

Expected output when ready for Azure-only labs:

```
  [ok] CLI (az): v2.xx.x
  [ok] Bicep: x.xx.x
  [ok] Auth: user@example.com
  [ok] Subscription: My Lab Subscription
  [ok] Config (.data/subs.json): 1 subscription(s), default: lab

Ready for Azure-only labs.
```

If any item shows `[--]`, follow the hint in that line or run `.\setup.ps1 -Azure` to repair.

---

## Troubleshooting

### `az login` fails or opens wrong browser

```powershell
# Force a clean login
az logout
az login
```

### "Subscription not found" or placeholder ID in subs.json

```powershell
# Re-run the wizard to pick a real subscription
.\setup.ps1 -ConfigureSubs
```

### "Config file not found" when running a lab

```powershell
# Create the config
.\setup.ps1 -ConfigureSubs
```

### Can't select the right subscription

```powershell
# List subscriptions and their IDs
az account list -o table

# Pass the ID directly
.\setup.ps1 -SubscriptionId "<paste-id-here>"
```

### Bicep not found

```powershell
az bicep install
az bicep version
```

### PowerShell version issues

The scripts target both PowerShell 5.1 and 7+. If you encounter syntax errors:

```powershell
$PSVersionTable.PSVersion
```

- PS 5.1: Ships with Windows. Supported.
- PS 7+: Recommended for best experience. [Download here](https://github.com/PowerShell/PowerShell/releases).

If a script fails on PS 5.1 with a syntax error, please open an issue with the error message and your PS version.

---

## Next Steps

| Goal | Command |
|------|---------|
| First lab (free, ~20s) | `cd labs\lab-000_resource-group && .\deploy.ps1` |
| vWAN basics | `cd labs\lab-001-virtual-wan-hub-routing && .\deploy.ps1` |
| Check running costs | `.\tools\cost-check.ps1` |
| Clean up a lab | `.\destroy.ps1` (inside the lab directory) |
| Full status check | `.\setup.ps1 -Status` |
