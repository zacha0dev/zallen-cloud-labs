# Lab 004 Walkthrough

This guide walks through deploying and validating the vWAN default route propagation lab.

## Prerequisites

Before starting, ensure you have:

1. **Azure CLI installed**
   ```powershell
   az --version
   # Should show 2.x.x
   ```

2. **Logged in to Azure**
   ```powershell
   az login
   az account show
   ```

3. **Selected the correct subscription**
   ```powershell
   az account set --subscription "your-subscription-name"
   ```

## Step 1: Configure the Lab

1. Navigate to the lab directory:
   ```powershell
   cd labs/lab-004-vwan-default-route-propagation
   ```

2. Run deploy.ps1 once to create the config template:
   ```powershell
   .\scripts\deploy.ps1
   ```
   This creates `.data/lab-004/config.json`

3. Edit the config file:
   ```powershell
   code $env:USERPROFILE\.data\lab-004\config.json
   # Or: notepad .data\lab-004\config.json
   ```

4. Update these values:
   - `subscriptionId`: Your Azure subscription ID
   - `adminPassword`: A strong password (12+ chars, mixed case, numbers, symbols)

## Step 2: Deploy Infrastructure

Run the deployment:

```powershell
.\scripts\deploy.ps1
```

**What gets deployed:**

| Resource | Name | Purpose |
|----------|------|---------|
| Resource Group | rg-lab-004-vwan-route-prop | Contains all resources |
| Virtual WAN | vwan-lab-004 | Standard vWAN |
| Hub A | vhub-a-lab-004 | Primary hub (10.100.0.0/24) |
| Hub B | vhub-b-lab-004 | Secondary hub (10.101.0.0/24) |
| Route Table | rt-fw-default | Custom RT with 0/0 route |
| VNet-FW | vnet-fw-lab-004 | Simulated firewall VNet |
| Spokes A1-A4 | vnet-spoke-a1..a4 | Hub A spokes |
| Spokes B1-B2 | vnet-spoke-b1..b2 | Hub B spokes |
| VMs | vm-fw, vm-a1..a4, vm-b1..b2 | Test VMs |

**Deployment time:** 30-45 minutes (vWAN hubs are slow to provision)

## Step 3: Understand the Topology

After deployment, the routing configuration is:

### Hub A Custom Route Table (rt-fw-default)
- **Static route:** `0.0.0.0/0 -> conn-vnet-fw`
- **Associated VNets:** Spoke A1, Spoke A2
- **Effect:** These spokes learn the 0/0 route

### Hub A Default Route Table
- **Associated VNets:** Spoke A3, Spoke A4
- **Effect:** No 0/0 route (not associated with rt-fw-default)

### Hub B Default Route Table
- **Associated VNets:** Spoke B1, Spoke B2
- **Effect:** No 0/0 route (different hub, default RT only)

## Step 4: Validate Route Propagation

Run the validation script:

```powershell
.\scripts\validate.ps1
```

Expected output:

```
============================================
  vWAN Default Route Propagation Validation
============================================

[PASS] Spoke A1 (rt-fw-default) - Has 0.0.0.0/0 route
[PASS] Spoke A2 (rt-fw-default) - Has 0.0.0.0/0 route
[PASS] Spoke A3 (Default RT) - No 0.0.0.0/0 route (correct)
[PASS] Spoke A4 (Default RT) - No 0.0.0.0/0 route (correct)
[PASS] Spoke B1 (Hub B, Default RT) - No 0.0.0.0/0 route (correct)
[PASS] Spoke B2 (Hub B, Default RT) - No 0.0.0.0/0 route (correct)

============================================
Summary: 6 passed, 0 failed
============================================
```

## Step 5: Manual Verification (Optional)

### Check effective routes in Azure Portal

1. Go to Azure Portal > Virtual machines > vm-a1
2. Networking > Network interface > Effective routes
3. Look for `0.0.0.0/0` entry with "Virtual network gateway" next hop

### Check via CLI

```powershell
# Spoke A1 (should have 0/0)
az network nic show-effective-route-table `
  -g rg-lab-004-vwan-route-prop `
  -n nic-vm-a1 `
  --query "value[?addressPrefix[0]=='0.0.0.0/0']" `
  -o table

# Spoke A3 (should NOT have 0/0)
az network nic show-effective-route-table `
  -g rg-lab-004-vwan-route-prop `
  -n nic-vm-a3 `
  --query "value[?addressPrefix[0]=='0.0.0.0/0']" `
  -o table
```

### Check route table contents

```powershell
az network vhub route-table show `
  -g rg-lab-004-vwan-route-prop `
  --vhub-name vhub-a-lab-004 `
  -n rt-fw-default `
  --query routes `
  -o table
```

## Step 6: Clean Up

When done, delete all resources:

```powershell
.\scripts\destroy.ps1
```

Or to skip confirmation:

```powershell
.\scripts\destroy.ps1 -Force
```

## Troubleshooting

### Routes not appearing after deployment

vWAN route propagation can take 5-10 minutes. Wait and re-run `validate.ps1`.

### Deployment fails with quota error

Check your subscription quotas for:
- Public IP addresses
- VM cores (7 VMs = 7 cores minimum)

### "Token expired" error

Re-authenticate:
```powershell
az login
```

### Validation shows failures

1. Check deployment completed successfully in Azure portal
2. Verify VNet connection associations are correct
3. Wait additional time for route propagation
