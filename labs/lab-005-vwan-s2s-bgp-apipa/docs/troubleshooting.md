# Lab 005: Troubleshooting Guide

## Common Issues

### Phase 1: vHub Creation

#### vHub Stuck in "Updating" State

**Symptoms:**
- vHub provisioningState remains "Updating" for >15 minutes

**Resolution:**
1. Check Azure Portal for detailed error messages
2. Wait up to 20 minutes (vHub creation can be slow)
3. If still stuck, delete and recreate:
   ```powershell
   az network vhub delete -g rg-lab-005-vwan-s2s -n vhub-lab-005 --yes
   # Wait 2-3 minutes, then re-run deploy.ps1
   ```

#### vHub Creation Fails

**Common causes:**
- Region capacity constraints
- Subscription quotas exceeded

**Resolution:**
1. Try a different region: `.\deploy.ps1 -Location eastus2`
2. Check subscription quotas in Azure Portal

---

### Phase 2: VPN Gateway

#### VPN Gateway in "Failed" State

**Symptoms:**
- Gateway shows provisioningState = "Failed"
- Error in portal mentions "internal error"

**Resolution:**
1. The deploy script automatically handles this by deleting and retrying
2. If manual intervention needed:
   ```powershell
   az network vpn-gateway delete -g rg-lab-005-vwan-s2s -n vpngw-lab-005 --yes
   # Wait 2-3 minutes for cleanup
   Start-Sleep -Seconds 180
   .\deploy.ps1 -Force
   ```

#### VPN Gateway Takes >40 Minutes

**Symptoms:**
- Deployment running but no progress

**Resolution:**
1. Check Azure status page for region issues
2. VPN Gateway creation is genuinely slow (20-35 min normal)
3. If >45 min, consider restarting deployment

---

### Phase 3: VPN Sites

#### VPN Site Creation Fails via REST API

**Symptoms:**
- Error: "BadRequest" or "InvalidResource"
- ARM REST API returns 4xx error

**Resolution:**
1. Check the temp JSON file in `.data/lab-005/`
2. Validate JSON structure is correct
3. Ensure vWAN ID is correct
4. Try creating site via Azure CLI:
   ```powershell
   az network vpn-site create -g rg-lab-005-vwan-s2s -n site-1 --virtual-wan vwan-lab-005 --location centralus --device-vendor "Azure-Lab" --device-model "Simulated"
   ```

#### Links Not Appearing on Site

**Symptoms:**
- Site exists but has 0 or 1 links

**Resolution:**
1. Delete the incomplete site
2. Re-run deploy.ps1 (it will recreate)

---

### Phase 4: Connections

#### Connection Fails to Create

**Symptoms:**
- ARM REST API returns error
- Connection shows "Failed" state

**Resolution:**
1. Verify VPN Site exists and has links
2. Check PSK file exists in `.data/lab-005/psk-secrets.json`
3. Verify instance IP configuration IDs are correct

#### Both Links Bound to Same Instance

**Symptoms:**
- Validation shows both links on Instance 0 (or both on Instance 1)

**This is a critical failure** - the whole point of the lab is to prove instance split.

**Resolution:**
1. Delete the connection:
   ```powershell
   az network vpn-gateway connection delete -g rg-lab-005-vwan-s2s --gateway-name vpngw-lab-005 -n conn-site-1 --yes
   ```
2. Check `vpnGatewayCustomBgpAddresses` in the connection JSON
3. Verify `ipConfigurationId` points to correct instance
4. Re-run deploy.ps1

---

### General Issues

#### Azure CLI Token Expired

**Symptoms:**
- Error: "AADSTS700082: The refresh token has expired"

**Resolution:**
```powershell
az logout
az login
az account set --subscription <subscription-id>
.\deploy.ps1 -Force
```

#### Rate Limiting / Throttling

**Symptoms:**
- Error: "TooManyRequests"
- Error: "429 throttled"

**Resolution:**
1. Wait 5 minutes
2. Re-run deploy.ps1 (it resumes from where it left off)

#### Subscription Quota Exceeded

**Symptoms:**
- Error: "QuotaExceeded"

**Resolution:**
1. Delete other unused vWAN resources in the subscription
2. Request quota increase via Azure Portal
3. Try a different region

---

## Log Files

Deployment logs are written to `logs/lab-005-<timestamp>.log`.

To view recent logs:
```powershell
Get-Content (Get-ChildItem logs\lab-005-*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
```

## Getting Help

1. Check Azure status: https://status.azure.com
2. Review ARM deployment errors in Portal
3. Check `outputs.json` in `.data/lab-005/` for state information

## Clean Restart

To completely start over:

```powershell
.\destroy.ps1 -Force
# Wait 5 minutes for full cleanup
Start-Sleep -Seconds 300
.\deploy.ps1
```
