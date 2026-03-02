# AWS Hybrid Connectivity

> **AWS is optional.** This guide only applies to [lab-003](../../labs/lab-003-vwan-aws-bgp-apipa/README.md).
> All other labs in this repository are Azure-only.

This document is the single canonical reference for everything AWS in this repo:
account setup, Identity Center (SSO), CLI configuration, lab-003 prerequisites, and troubleshooting.

---

## Quick Start

```powershell
# 1. Check AWS CLI is installed and profile works
.\setup.ps1 -Status

# 2. Run AWS setup (installs CLI, guides SSO config)
.\setup.ps1 -Aws

# 3. Login before each session (tokens expire)
aws sso login --profile aws-labs

# 4. Verify
aws sts get-caller-identity --profile aws-labs

# 5. Deploy the hybrid lab
cd labs\lab-003-vwan-aws-bgp-apipa
.\deploy.ps1 -AwsProfile aws-labs

# 6. Always destroy when done
.\destroy.ps1 -AwsProfile aws-labs
.\tools\cost-check.ps1 -AwsProfile aws-labs
```

---

## Prerequisites

| Tool | Install |
|------|---------|
| AWS CLI v2 | `winget install Amazon.AWSCLI` |
| Terraform | `winget install Hashicorp.Terraform` |
| AWS account with admin access | [Create one](#1-aws-account-setup) |
| Identity Center (SSO) configured | [Setup guide](#2-identity-center-sso-setup) |

---

## 1. AWS Account Setup

### Create an AWS Account

1. Go to [aws.amazon.com](https://aws.amazon.com/) and click **Create an AWS Account**
2. Enter email, password, and account name
3. Choose **Personal** or **Business** account type
4. Enter payment information (required even for free tier)
5. Verify identity via phone
6. Select **Basic/Free** support plan

### Enable MFA on Root Account

Enable MFA immediately after account creation:

1. Sign in as root user
2. Go to **IAM** > **Security credentials**
3. Under **Multi-factor authentication (MFA)**, click **Assign MFA device**
4. Choose **Authenticator app** and follow prompts

### Set Up Billing Guardrails

**Create a budget** (recommended: $50/month for lab work):

1. Go to **AWS Budgets** > **Create budget** > **Cost budget**
2. Set monthly amount and add email alerts at 50%, 80%, 100%
3. Go to **Billing** > **Billing preferences** and enable **Receive Billing Alerts**

### Region Selection

Labs default to `us-east-2` (Ohio). This region offers lower cost than `us-east-1` and full service availability. To change the region, update the `region` field in `.data/lab-003/config.json`.

---

## 2. Identity Center (SSO) Setup

AWS Identity Center (formerly AWS SSO) provides browser-based login with temporary credentials. **Recommended** over long-lived IAM access keys.

### Why Use Identity Center?

- Temporary credentials that expire automatically (no leaked keys)
- Browser-based login (no plaintext secrets)
- All access logged in CloudTrail

### Enable Identity Center

1. Sign in to AWS Console as root or admin
2. Go to **IAM Identity Center** (search in top bar)
3. Click **Enable** if not already enabled
4. Choose **Identity Center directory** as identity source (simplest for personal accounts)

### Note Your SSO Settings

After enabling, go to **Settings** and record:

| Setting | Example |
|---------|---------|
| AWS access portal URL | `https://d-1234567890.awsapps.com/start` |
| SSO Region | `us-east-1` |

You will need these for `aws configure sso`.

### Create a User

1. Go to **Users** > **Add user**
2. Enter username (e.g., your email), email, first and last name
3. User receives an email to set password

### Create a Permission Set

1. Go to **Permission sets** > **Create permission set**
2. Choose **Predefined permission set** > **AdministratorAccess**
3. Name it and create

### Assign User to Account

1. Go to **AWS accounts**
2. Select your AWS account
3. Click **Assign users or groups** > select your user > select `AdministratorAccess`
4. Submit

---

## 3. AWS CLI Profile Setup

### Install AWS CLI

```powershell
winget install Amazon.AWSCLI
aws --version
```

Expected: `aws-cli/2.x.x ...`

### Configure SSO Profile

```powershell
aws configure sso --profile aws-labs
```

The wizard prompts for:

| Prompt | Example Value |
|--------|---------------|
| SSO session name | `aws-labs-session` |
| SSO start URL | `https://d-1234567890.awsapps.com/start` |
| SSO region | `us-east-1` (where Identity Center is enabled) |
| SSO registration scopes | (press Enter for default) |

A browser opens for authentication. After signing in, select your account and then:

| Prompt | Example Value |
|--------|---------------|
| CLI default client Region | `us-east-2` |
| CLI default output format | `json` |
| CLI profile name | `aws-labs` |

### Verify Configuration

```powershell
# Profile exists?
aws configure list-profiles

# Login and verify
aws sso login --profile aws-labs
aws sts get-caller-identity --profile aws-labs
```

Expected output:
```json
{
    "UserId": "AROAXXXXXXXXXXXXXXXXX:your-email@example.com",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_AdministratorAccess_abc123/your-email@example.com"
}
```

### Config File Location

Located at `~/.aws/config` (Windows: `%USERPROFILE%\.aws\config`):

```ini
[profile aws-labs]
sso_session = aws-labs-session
sso_account_id = 123456789012
sso_role_name = AdministratorAccess
region = us-east-2
output = json

[sso-session aws-labs-session]
sso_start_url = https://d-1234567890.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access
```

**This file is gitignored** in this repo.

---

## 4. Re-authentication

SSO tokens expire (typically 1-12 hours). When you see auth errors:

```powershell
aws sso login --profile aws-labs
```

If that fails with a stale cache error, clear the cache first:

```powershell
# Windows
Remove-Item -Recurse -Force "$env:USERPROFILE\.aws\sso\cache\*"
Remove-Item -Recurse -Force "$env:USERPROFILE\.aws\cli\cache\*"
aws sso login --profile aws-labs
```

---

## 5. Lab-003 Configuration

Lab-003 uses the profile from its config file. Copy the template before first run:

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

The deploy script reads `AwsProfile` directly from the `-AwsProfile` parameter (defaults to `aws-labs`). The config file is optional metadata.

---

## 6. Troubleshooting

### "AWS profile 'aws-labs' does not exist" or "config profile not found"

Profile hasn't been configured yet.

```powershell
aws configure sso --profile aws-labs
aws configure list-profiles    # verify it appears
```

### "No AWS accounts are available to you"

Authenticated to portal but not assigned to any accounts.

1. Sign in to AWS Console as admin
2. Go to **IAM Identity Center** > **AWS accounts**
3. Assign your user to an account with a permission set

### "Token has expired" / "pending authorization expired" / "Error loading SSO Token"

SSO session expired or was never completed.

```powershell
aws sso login --profile aws-labs
```

### "Unable to locate credentials"

Profile exists but no active session.

```powershell
aws sso login --profile aws-labs
```

### "AccessDenied" or "not authorized to perform"

Permission set lacks required permissions. Check which role you're using:

```powershell
aws sts get-caller-identity --profile aws-labs
# Look at the Arn for role name
```

Ensure the permission set includes `AdministratorAccess` or the specific permissions required.

### "Could not connect to the endpoint URL"

Network or wrong region issue.

```powershell
aws configure get region --profile aws-labs   # check current region
aws configure set region us-east-2 --profile aws-labs   # fix if wrong
```

### Full Verification Sequence

```powershell
# 1. Profile exists?
aws configure list-profiles | Select-String "aws-labs"

# 2. Authenticated?
aws sts get-caller-identity --profile aws-labs

# 3. Can list resources?
aws ec2 describe-vpcs --profile aws-labs --region us-east-2
```

### Still Stuck?

1. Check AWS CLI version: `aws --version` (needs v2.x)
2. Check proxy: `echo $env:HTTPS_PROXY`
3. Try debug mode: `aws sts get-caller-identity --profile aws-labs --debug`
4. AWS docs: [Identity Center Troubleshooting](https://docs.aws.amazon.com/singlesignon/latest/userguide/troubleshooting.html)

---

## Alternative: IAM Access Keys

If you cannot use Identity Center, IAM access keys work but are less secure:

```powershell
aws configure --profile aws-labs
# Enter: Access Key ID, Secret Access Key, region (us-east-2), output (json)
```

**Warning:** Access keys are long-lived secrets. Rotate regularly and use least-privilege policies. Never commit them to git.

---

## Related Resources

| Resource | Description |
|----------|-------------|
| [lab-003 README](../../labs/lab-003-vwan-aws-bgp-apipa/README.md) | The hybrid lab that needs AWS |
| [vWAN Domain](vwan.md) | Azure vWAN concepts used in the hybrid lab |
| [Observability](observability.md) | How to validate AWS VPN tunnel status |
| [REFERENCE.md](../REFERENCE.md) | Cost safety and cleanup discipline |
