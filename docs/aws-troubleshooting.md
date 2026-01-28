# AWS Troubleshooting

Common errors and how to fix them.

---

## "AWS profile 'aws-labs' does not exist"

**Cause:** The profile hasn't been configured yet.

**Fix:**
```powershell
aws configure sso --profile aws-labs
```

Follow the prompts — see [AWS CLI Profile Setup](aws-cli-profile-setup.md).

**Verify:**
```powershell
aws configure list-profiles
```

---

## "The config profile (aws-labs) could not be found"

**Cause:** Same as above — no `~/.aws/config` entry for this profile.

**Fix:**
```powershell
aws configure sso --profile aws-labs
```

**Check config exists:**
```powershell
cat ~/.aws/config
```

You should see `[profile aws-labs]` section.

---

## "No AWS accounts are available to you"

**Cause:** You're authenticated to the SSO portal, but your user hasn't been assigned to any AWS accounts.

**Fix:**
1. Sign in to AWS Console as an admin
2. Go to **IAM Identity Center** > **AWS accounts**
3. Select your AWS account
4. Click **Assign users or groups**
5. Select your user and a permission set
6. Submit

Then retry:
```powershell
aws configure sso --profile aws-labs
```

---

## "Token has expired and refresh failed"

**Cause:** SSO session expired (typically after 1–12 hours).

**Fix:**
```powershell
aws sso login --profile aws-labs
```

Browser opens for re-authentication.

---

## "Error loading SSO Token: Token for ... does not exist"

**Cause:** Never logged in, or cache was cleared.

**Fix:**
```powershell
aws sso login --profile aws-labs
```

---

## "pending authorization expired"

**Cause:** You started `aws sso login` but didn't complete browser auth in time.

**Fix:** Run again and complete browser login within 5 minutes:
```powershell
aws sso login --profile aws-labs
```

---

## "Unable to locate credentials"

**Cause:** Profile exists but no active session.

**Fix:**
```powershell
aws sso login --profile aws-labs
```

If using IAM keys instead of SSO:
```powershell
aws configure --profile aws-labs
```

---

## "AccessDenied" or "not authorized to perform"

**Cause:** Your permission set doesn't allow this action.

**Fix:**
1. Check which permission set you're using:
   ```powershell
   aws sts get-caller-identity --profile aws-labs
   ```
   Look at the `Arn` — it shows the role name.

2. In IAM Identity Center, verify the permission set has required permissions.

For labs, `AdministratorAccess` is recommended.

---

## Missing `~/.aws/config` or `~/.aws/credentials`

**Cause:** AWS CLI never configured on this machine.

**Check:**
```powershell
# Windows
Test-Path $env:USERPROFILE\.aws\config

# Linux/macOS
test -f ~/.aws/config && echo "exists" || echo "missing"
```

**Fix:**
```powershell
aws configure sso --profile aws-labs
```

This creates the config directory and files automatically.

---

## "Could not connect to the endpoint URL"

**Cause:** Network issue or wrong region.

**Fix:**
1. Check internet connectivity
2. Verify region in your profile:
   ```powershell
   aws configure get region --profile aws-labs
   ```
3. Try a different region if needed:
   ```powershell
   aws configure set region us-east-2 --profile aws-labs
   ```

---

## "An error occurred (ExpiredToken)"

**Cause:** STS token expired.

**Fix:**
```powershell
aws sso login --profile aws-labs
```

---

## Clearing Stale Caches

If you're stuck with stale auth state:

```powershell
# Remove SSO cache (Windows)
Remove-Item -Recurse -Force "$env:USERPROFILE\.aws\sso\cache\*"
Remove-Item -Recurse -Force "$env:USERPROFILE\.aws\cli\cache\*"

# Then re-login
aws sso login --profile aws-labs
```

On Linux/macOS:
```bash
rm -rf ~/.aws/sso/cache/*
rm -rf ~/.aws/cli/cache/*
aws sso login --profile aws-labs
```

---

## Verifying Everything Works

Run this sequence to confirm full setup:

```powershell
# 1. Profile exists?
aws configure list-profiles | Select-String "aws-labs"

# 2. Logged in?
aws sts get-caller-identity --profile aws-labs

# 3. Can list resources?
aws ec2 describe-vpcs --profile aws-labs --region us-east-2
```

Expected output for step 2:
```json
{
    "UserId": "AROAXXXXXXXXXXXXXXXXX:your-email@example.com",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_AdministratorAccess_abc123/your-email@example.com"
}
```

---

## Still Stuck?

1. Check AWS CLI version: `aws --version` (needs v2.x)
2. Check for proxy issues: `echo $env:HTTPS_PROXY`
3. Try verbose mode: `aws sts get-caller-identity --profile aws-labs --debug`

For Identity Center issues, see [AWS Identity Center Troubleshooting](https://docs.aws.amazon.com/singlesignon/latest/userguide/troubleshooting.html).
