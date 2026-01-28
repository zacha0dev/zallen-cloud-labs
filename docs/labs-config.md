# Lab Configuration Guide

This document explains how lab scripts load configuration and common errors you may encounter.

## Configuration File Location

All labs use a shared configuration file:

```
.data/subs.json
```

This file is **gitignored** (contains subscription IDs). It's created automatically when you run `scripts\setup.ps1`.

## Required Structure

```json
{
  "subscriptions": {
    "lab": {
      "id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
      "name": "My Lab Subscription",
      "tenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    },
    "prod": {
      "id": "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy",
      "name": "My Prod Subscription",
      "tenantId": "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
    }
  },
  "default": "lab"
}
```

### Required Fields

| Field | Description |
|-------|-------------|
| `subscriptions` | Object containing subscription entries |
| `subscriptions.<key>` | A subscription entry (e.g., "lab", "prod", or custom) |
| `subscriptions.<key>.id` | Azure subscription ID (GUID) |

### Optional Fields

| Field | Description |
|-------|-------------|
| `subscriptions.<key>.name` | Human-readable subscription name |
| `subscriptions.<key>.tenantId` | Azure AD tenant ID |
| `default` | Default subscription key to use |

## Setting Up Configuration

### Option 1: Run Setup (Recommended)

```powershell
.\scripts\setup.ps1 -DoLogin
```

This will:
1. Prompt you to log in to Azure
2. Let you select a subscription
3. Create `.data/subs.json` automatically

### Option 2: Manual Creation

1. Copy the example file:
   ```powershell
   Copy-Item .data\subs.example.json .data\subs.json
   ```

2. Get your subscription ID:
   ```powershell
   az account list -o table
   ```

3. Edit `.data/subs.json` with your real values.

## Using Different Subscriptions

Lab scripts accept a `-SubscriptionKey` parameter:

```powershell
# Use the "lab" subscription (default)
.\scripts\deploy.ps1

# Use a different subscription
.\scripts\deploy.ps1 -SubscriptionKey prod

# Use a custom key (must exist in subs.json)
.\scripts\deploy.ps1 -SubscriptionKey mydev
```

## Common Errors

### "Missing .data/subs.json"

**Cause:** Config file doesn't exist.

**Fix:** Run setup:
```powershell
.\scripts\setup.ps1 -DoLogin
```

### "The property 'lab' cannot be found"

**Cause:** The `subscriptions` object doesn't have the requested key (e.g., "lab").

**Fix:** Either:
1. Run `.\scripts\setup.ps1 -DoLogin` to reconfigure
2. Manually add the key to `.data/subs.json`
3. Use a different key: `.\scripts\deploy.ps1 -SubscriptionKey <available-key>`

### "Subscription 'lab' has placeholder ID"

**Cause:** The subscription ID is still the placeholder value from the template.

**Fix:** Update `.data/subs.json` with your real subscription ID:
```powershell
az account list -o table
# Copy the SubscriptionId, then edit .data/subs.json
```

### "No subscriptions configured"

**Cause:** The `subscriptions` object is empty.

**Fix:** Run setup to add a subscription:
```powershell
.\scripts\setup.ps1 -DoLogin
```

### "Subscription key 'X' not found. Available: Y, Z"

**Cause:** You requested a subscription key that doesn't exist.

**Fix:** Use one of the available keys shown in the error message:
```powershell
.\scripts\deploy.ps1 -SubscriptionKey Y
```

## AWS Configuration (For Hybrid Labs)

Labs that use AWS (e.g., lab-003) also require AWS CLI authentication:

```powershell
# Configure SSO profile
aws configure sso --profile aws-labs

# Login
aws sso login --profile aws-labs
```

See [AWS SSO Setup](aws-identity-center-sso.md) for detailed instructions.

## Debugging Config Issues

Lab scripts print config preflight information:

```
==> Config preflight
  Config path: C:\path\to\.data\subs.json
  Config keys: subscriptions, default
  Status: OK
```

If you see errors, check:
1. Does the file exist at the printed path?
2. Is the JSON valid?
3. Does it have the required `subscriptions` key?

## File Permissions

The `.data/` directory contains sensitive information:
- **Never commit** `.data/subs.json` to git
- The `.gitignore` already excludes this file
- Keep subscription IDs private
