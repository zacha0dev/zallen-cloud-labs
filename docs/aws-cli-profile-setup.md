# AWS CLI Profile Setup

This guide walks through configuring the AWS CLI to use Identity Center (SSO) for authentication.

## Prerequisites

- AWS CLI v2 installed (`winget install Amazon.AWSCLI`)
- Identity Center enabled with a user assigned to an account
- Your SSO start URL and region (from [Identity Center setup](aws-identity-center-sso.md))

## Install AWS CLI

```powershell
# Install via winget
winget install Amazon.AWSCLI

# Verify installation
aws --version
```

Expected output:
```
aws-cli/2.x.x Python/3.x.x Windows/10 exe/AMD64
```

## Configure SSO Profile

Run the SSO configuration wizard:

```powershell
aws configure sso --profile aws-labs
```

The wizard prompts for:

| Prompt | Example Value | Notes |
|--------|---------------|-------|
| SSO session name | `aws-labs-session` | Any name you choose |
| SSO start URL | `https://d-1234567890.awsapps.com/start` | From Identity Center |
| SSO region | `us-east-1` | Where Identity Center is enabled |
| SSO registration scopes | (press Enter for default) | Leave default |

After entering these, a browser opens for authentication. Sign in with your Identity Center credentials.

Then the CLI shows available accounts:

```
There are N AWS accounts available to you.
> 123456789012, my-account@example.com
```

Select your account, then:

| Prompt | Example Value | Notes |
|--------|---------------|-------|
| CLI default client Region | `us-east-2` | Deploy region for labs |
| CLI default output format | `json` | Or `table`, `text` |
| CLI profile name | `aws-labs` | Must match what you started with |

## Verify Configuration

### Check profile exists

```powershell
aws configure list-profiles
```

Expected output includes:
```
aws-labs
```

### Check config file

```powershell
cat ~/.aws/config
```

You should see something like:

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

### Test authentication

```powershell
aws sso login --profile aws-labs
```

Browser opens. After signing in:

```
Successfully logged into Start URL: https://d-1234567890.awsapps.com/start
```

### Verify identity

```powershell
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

## Using the Profile

### With AWS CLI

```powershell
# Explicit profile
aws ec2 describe-vpcs --profile aws-labs

# Set default for session
$env:AWS_PROFILE = "aws-labs"
aws ec2 describe-vpcs
```

### With Azure Labs

The lab scripts use the profile from `.data/lab-003/config.json`:

```json
{
  "aws": {
    "profile": "aws-labs",
    "region": "us-east-2"
  }
}
```

## Re-authenticate When Token Expires

SSO tokens expire (typically 1–12 hours). When you see authentication errors:

```powershell
aws sso login --profile aws-labs
```

Or run:

```powershell
.\scripts\setup.ps1 -IncludeAWS -DoLogin
```

## Alternative: IAM Access Keys (Not Recommended)

If you can't use Identity Center, you can use IAM access keys:

```powershell
aws configure --profile aws-labs
```

Enter:
- Access Key ID
- Secret Access Key
- Default region
- Output format

**Warning:** Access keys are long-lived secrets. If you use them:
- Never commit them to git
- Rotate them regularly
- Use least-privilege IAM policies

## Config File Locations

| OS | Config | Credentials |
|----|--------|-------------|
| Windows | `%USERPROFILE%\.aws\config` | `%USERPROFILE%\.aws\credentials` |
| Linux/macOS | `~/.aws/config` | `~/.aws/credentials` |

**These files are gitignored** in this repo (see `.gitignore`).

## Next Steps

- [Troubleshooting](aws-troubleshooting.md)
- [Run Lab 003](../labs/lab-003-vwan-aws-vpn-bgp-apipa/README.md)
