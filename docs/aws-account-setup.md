# AWS Account Setup

This guide covers creating an AWS account and setting up billing guardrails before running any labs.

## Create an AWS Account

1. Go to [aws.amazon.com](https://aws.amazon.com/) and click **Create an AWS Account**
2. Enter email, password, and account name
3. Choose **Personal** or **Business** account type
4. Enter payment information (required even for free tier)
5. Verify your identity via phone
6. Select a support plan (Basic/Free is fine for labs)

## Enable MFA on Root Account

**Critical:** Enable MFA immediately after account creation.

1. Sign in as root user
2. Go to **IAM** > **Security credentials**
3. Under **Multi-factor authentication (MFA)**, click **Assign MFA device**
4. Choose **Authenticator app** and follow prompts

## Set Up Billing Guardrails

### Enable Billing Alerts

1. Go to **Billing** > **Billing preferences**
2. Enable **Receive Billing Alerts**
3. Save preferences

### Create a Budget

1. Go to **AWS Budgets** > **Create budget**
2. Choose **Cost budget**
3. Set monthly budget (e.g., $50 for lab work)
4. Add email alerts at 50%, 80%, 100%

### Enable Cost Explorer

1. Go to **Cost Explorer**
2. Click **Enable Cost Explorer**
3. Wait 24 hours for data to populate

## Region Selection

Labs default to `us-east-2` (Ohio). This region offers:
- Lower costs than `us-east-1`
- Full service availability
- Good latency from most US locations

**To change:** Update the `region` field in your lab config files.

## Verify Account Is Ready

```powershell
# After configuring AWS CLI (see aws-cli-profile-setup.md)
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

## Cost Awareness

Labs in this repo create billable resources:

| Resource | Approximate Cost |
|----------|------------------|
| VPN Gateway (VGW) | ~$0.05/hour |
| VPN Connection | ~$0.05/hour per tunnel |
| NAT Gateway | ~$0.045/hour + data |
| EC2 instances | Varies by size |

**Always run `destroy.ps1` when done testing.**

## Next Steps

- [Set up AWS Identity Center (SSO)](aws-identity-center-sso.md)
- [Configure AWS CLI profile](aws-cli-profile-setup.md)
