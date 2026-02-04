# Tools

Utility scripts for managing Azure Labs resources.

## Prerequisites

- **Azure CLI** - [Install](https://aka.ms/installazurecli)
- **AWS CLI** - [Install](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (optional, for hybrid labs)

## cost-check.ps1

Audits Azure and AWS resources created by these labs to help you stay cost-aware. **Read-only** - no destructive actions.

### Quick Start

```powershell
# Basic scan (Azure only, lab resource groups)
./tools/cost-check.ps1

# Scan specific lab with AWS
./tools/cost-check.ps1 -Lab lab-003 -AwsProfile aws-labs

# Full subscription scan with AWS
./tools/cost-check.ps1 -Scope All -AwsProfile aws-labs -AwsRegion us-east-2

# Save JSON report
./tools/cost-check.ps1 -AwsProfile aws-labs -JsonOutputPath ./audit-report.json
```

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Scope` | `Labs` | `Labs` = scan lab RGs only; `All` = entire subscription |
| `-Lab` | (none) | Filter to specific lab (e.g., `lab-003`) |
| `-SubscriptionKey` | (from config) | Azure subscription key from `.data/subs.json` |
| `-AwsProfile` | (none) | AWS CLI profile; if not set, AWS checks are skipped |
| `-AwsRegion` | `us-east-2` | AWS region to scan |
| `-JsonOutputPath` | (none) | Path to save JSON report |

### What It Checks

**Azure (in lab resource groups `rg-lab-*`, `rg-azure-labs-*`):**
- Virtual WANs
- Virtual Hubs
- VPN Gateways
- Application Gateways
- Virtual Machines
- Public IP Addresses
- Front Door / CDN profiles
- Azure Firewalls

**AWS (tagged with `project=azure-labs`):**
- VPN Connections
- Virtual Private Gateways
- Customer Gateways
- EC2 Instances
- Elastic IPs (especially unassociated ones)
- NAT Gateways
- Load Balancers
- VPCs

### Example Output

```
Cost Audit Tool for Azure Labs
===============================

Scope: Labs
AWS Profile: aws-labs

============================================================
Azure Resource Audit
============================================================

--- Resource Groups ---

  Found 2 resource group(s):

  Resource Group                      Location        Resources  Tags
  ----------------------------------- --------------- ---------- --------------------
  rg-lab-003-vwan-aws                 centralus       12         project=azure-labs, lab=lab-003
  rg-lab-005-vwan-s2s                 westus2         8          project=azure-labs, lab=lab-005

--- High-Cost Resources in Lab RGs ---

  [WARN] Found 4 high-cost resource(s):

  Resource Group                      Resource Name             Type
  ----------------------------------- ------------------------- ---------------
  rg-lab-003-vwan-aws                 vwan-lab-003              vWAN
  rg-lab-003-vwan-aws                 vhub-lab-003              vHub
  rg-lab-003-vwan-aws                 vpngw-lab-003             VPN Gateway

============================================================
Summary
============================================================

  Azure:
    Lab resource groups: 2
    High-cost resources: 4

  AWS:
    Billable resources:  2

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  ACTION REQUIRED: Billable resources detected!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  To clean up, run the destroy script for the relevant lab:

    cd C:\path\to\azure-labs\labs\lab-003-vwan-aws-bgp-apipa
    .\destroy.ps1
```

### Interpretation

- **[PASS]** - No billable resources of this type found
- **[WARN]** - Billable resources detected - consider cleanup
- **[INFO]** - Resources found but not directly billable (VPCs, Customer Gateways)

### Cleanup

When the tool detects billable resources, it suggests running the appropriate destroy script:

```powershell
# Clean up Lab 003 (Azure + AWS)
cd labs/lab-003-vwan-aws-bgp-apipa
.\destroy.ps1 -AwsProfile aws-labs

# Clean up Lab 005 (Azure only)
cd labs/lab-005-vwan-s2s-bgp-apipa
.\destroy.ps1
```

Always use the lab's destroy script rather than deleting resources manually - the scripts handle dependencies and cleanup order correctly.
