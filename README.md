# Azure Labs

Azure Labs is a lightweight set of scripts and lab scaffolds to help you build Azure-first networking scenarios quickly, with optional AWS interoperability where noted.

## Quick Start (Azure-only)
1. Run the setup wrapper:
   ```powershell
   .\scripts\setup.ps1
   ```
2. Run the default helper:
   ```powershell
   .\run.ps1
   ```

## AWS Setup (Optional)
AWS integration is **optional** and only required for labs that declare AWS support in their config.

### Account prep
- Use MFA on your AWS account.
- Use least-privilege IAM users/roles for lab work.
- **Never** commit access keys or credential files to the repo.

### Install AWS CLI
```powershell
winget install Amazon.AWSCLI
```

### Configure credentials
```powershell
aws configure
```

### Verify credentials
```powershell
aws sts get-caller-identity
```

### Run AWS setup checks
```powershell
./scripts/aws/setup-aws.ps1
```

## Labs
- `labs/lab-000_resource-group`
- `labs/lab-001-virtual-wan-hub-routing`
- `labs/lab-002-l7-fastapi-appgw-frontdoor`
- `labs/lab-003-vwan-aws-vpn-bgp-apipa`

---
Zachary Allen - 2026
