# AWS Identity Center (SSO) Setup

AWS Identity Center (formerly AWS SSO) provides browser-based login with temporary credentials. This is **recommended** over long-lived IAM access keys.

## Why Use Identity Center?

- **Temporary credentials** — tokens expire automatically (no leaked keys)
- **Browser login** — no secrets stored in plaintext
- **Centralized access** — one portal for all AWS accounts
- **Audit trail** — all access logged in CloudTrail

## Enable Identity Center

1. Sign in to AWS Console as root or admin
2. Go to **IAM Identity Center** (search in top bar)
3. Click **Enable** if not already enabled
4. Choose identity source:
   - **Identity Center directory** (simplest for personal accounts)
   - External IdP (for enterprise federation)

## Note Your SSO Settings

After enabling, go to **Settings** and note:

| Setting | Example | Where to find |
|---------|---------|---------------|
| **AWS access portal URL** | `https://d-1234567890.awsapps.com/start` | Settings > Identity source |
| **SSO Region** | `us-east-1` | Settings > Identity source |

You'll need these for `aws configure sso`.

## Create a User

1. Go to **Users** > **Add user**
2. Enter:
   - Username (e.g., your email)
   - Email address
   - First name, Last name
3. Click **Next**, then **Add user**
4. User receives email to set password

## Create a Permission Set

Permission sets define what the user can do in AWS accounts.

1. Go to **Permission sets** > **Create permission set**
2. Choose **Predefined permission set**
3. Select **AdministratorAccess** (for lab work)
4. Click **Next**, name it, then **Create**

> For production, use least-privilege custom permission sets.

## Assign User to Account

1. Go to **AWS accounts**
2. Select your AWS account (checkbox)
3. Click **Assign users or groups**
4. Select your user
5. Select the permission set (e.g., `AdministratorAccess`)
6. Click **Submit**

## Test Portal Access

1. Go to your access portal URL: `https://d-xxxxxxxxxx.awsapps.com/start`
2. Sign in with your Identity Center credentials
3. You should see your AWS account listed with the permission set
4. Click the account to expand, then click **Command line or programmatic access**
5. This shows temporary credentials (but we'll use SSO login instead)

## Common Issues

### "No AWS accounts are available to you"

This means you're authenticated to the portal but haven't been assigned to any accounts.

**Fix:**
1. Sign in as admin to AWS Console
2. Go to **IAM Identity Center** > **AWS accounts**
3. Assign your user to the account with a permission set

### "The config profile could not be found"

The AWS CLI profile doesn't exist yet.

**Fix:** Run `aws configure sso --profile aws-labs` (see [CLI Profile Setup](aws-cli-profile-setup.md))

### "Token has expired"

SSO tokens last 1–12 hours depending on settings.

**Fix:** Run `aws sso login --profile aws-labs`

## Next Steps

- [Configure AWS CLI profile](aws-cli-profile-setup.md)
- [Troubleshooting](aws-troubleshooting.md)
