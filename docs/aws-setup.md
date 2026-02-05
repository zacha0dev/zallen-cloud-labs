# AWS Setup Guide

AWS is only required for **lab-003** (Azure vWAN ↔ AWS VPN hybrid lab).

## Prerequisites

- AWS account with admin access
- AWS CLI v2 installed

```powershell
# Install AWS CLI (Windows)
winget install Amazon.AWSCLI

# Verify
aws --version
```

## Quick Start (SSO - Recommended)

### 1. Create SSO Profile

```powershell
aws configure sso --profile aws-labs
```

When prompted:

| Prompt | Value |
|--------|-------|
| SSO session name | `aws-labs-session` |
| SSO start URL | `https://d-XXXXXXXXXX.awsapps.com/start` (from AWS Identity Center) |
| SSO region | `us-east-1` (where Identity Center is enabled) |
| CLI default region | `us-east-2` (where labs deploy) |
| CLI default output | `json` |
| Profile name | `aws-labs` |

### 2. Login via Browser

```powershell
aws sso login --profile aws-labs
```

This opens your browser automatically. Sign in with your Identity Center credentials.

### 3. Verify

```powershell
aws sts get-caller-identity --profile aws-labs
```

## Re-authentication

SSO tokens expire (1-12 hours). When you see auth errors:

```powershell
aws sso login --profile aws-labs
```

## Configuration Files

### AWS CLI Profile Config

Located at `~/.aws/config`:

```ini
[profile aws-labs]
sso_session = aws-labs-session
sso_account_id = 123456789012
sso_role_name = AdministratorAccess
region = us-east-2
output = json

[sso-session aws-labs-session]
sso_start_url = https://d-XXXXXXXXXX.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access
```

### Lab-003 Config (Optional)

Copy template:
```powershell
copy .data\accounts.aws.template.json .data\accounts.aws.json
```

Edit `.data\accounts.aws.json`:
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

## Alternative: IAM Access Keys

If you can't use Identity Center:

```powershell
aws configure --profile aws-labs
```

Enter Access Key ID, Secret Access Key, region, and output format.

**Warning:** Access keys are long-lived secrets. Rotate regularly and use least-privilege policies.

## Running Lab-003

```powershell
# Login first
aws sso login --profile aws-labs

# Deploy
cd labs/lab-003-vwan-aws-bgp-apipa
.\deploy.ps1 -AwsProfile aws-labs

# Destroy when done
.\destroy.ps1 -AwsProfile aws-labs
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `ExpiredToken` | Run `aws sso login --profile aws-labs` |
| `NoCredentialProviders` | Profile not configured - run `aws configure sso` |
| `AccessDenied` | Check IAM permissions in AWS Console |

See [aws-troubleshooting.md](aws-troubleshooting.md) for more issues.

## Related Guides

- [AWS Account Setup](aws-account-setup.md) - Create account, billing guardrails
- [AWS Identity Center](aws-identity-center-sso.md) - Set up SSO in AWS Console
- [AWS CLI Profile Setup](aws-cli-profile-setup.md) - Detailed CLI configuration
