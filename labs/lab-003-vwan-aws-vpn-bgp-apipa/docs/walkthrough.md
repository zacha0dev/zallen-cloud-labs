# Lab 003 Walkthrough

Complete step-by-step guide for deploying Azure vWAN ↔ AWS VPN with BGP.

## Prerequisites Check

From the **repo root**, run setup first:

```powershell
# Run setup (first time only)
.\scripts\setup.ps1 -DoLogin -IncludeAWS

# Verify tools are installed
az --version      # Azure CLI
terraform --version
aws --version     # AWS CLI
```

This creates `.data/subs.json` with your Azure subscription.

## Step 1: Deploy

Navigate to the lab and run deploy:

```powershell
cd labs/lab-003-vwan-aws-vpn-bgp-apipa
.\scripts\deploy.ps1
```

**Using a specific subscription:**
```powershell
.\scripts\deploy.ps1 -SubscriptionKey sub01
```

Type `DEPLOY` when prompted.

### What Gets Deployed

**Phase 1: Azure (20-30 min)**
- Resource Group: `rg-lab-003-vwan-aws`
- Virtual WAN (Standard)
- Virtual Hub (10.100.0.0/24)
- VPN Gateway with BGP ASN 65515
- Spoke VNet (10.200.0.0/24) + Test VM
- Hub-to-spoke connection

**Phase 2: AWS (5 min)**
- VPC (10.20.0.0/16)
- Public subnet + IGW + Route table
- Virtual Private Gateway (ASN 65001)
- Customer Gateway (pointing to Azure VPN IP)
- VPN Connection with 2 tunnels (IKEv2, BGP enabled)

**Phase 3: Azure VPN Site (2 min)**
- VPN Site representing AWS
- 2 links (one per AWS tunnel)
- BGP peering configuration
- VPN connection to site

## Step 2: Wait for Convergence

After deployment:
- IPsec tunnels need 2-5 min to establish
- BGP needs additional 2-5 min to exchange routes

Total wait: **5-10 minutes**

## Step 3: Validate

```powershell
.\scripts\validate.ps1

# Or with specific subscription
.\scripts\validate.ps1 -SubscriptionKey sub01
```

### Expected Output

```
Lab 003: VPN Validation
========================

Azure Checks:
[PASS] VPN Gateway exists - vpngw-lab-003
[PASS] VPN Site connections - 1 connection(s)

Azure BGP Peer Status:
  Peer 169.254.21.1 : Connected
  Peer 169.254.22.1 : Connected

[PASS] BGP sessions established - 2 peer(s) connected

AWS Checks:
[PASS] VPN Connection state - available

AWS Tunnel Status:
  52.x.x.x : UP
  52.y.y.y : UP

[PASS] At least one tunnel UP - 2 tunnel(s) up

========================
Summary: 5 passed, 0 failed
========================
```

## Step 4: Verify Routes

### Azure Side

In Azure Portal:
1. Go to VPN Gateway > BGP peers
2. Verify peers show "Connected"
3. Check Virtual Hub > Effective routes

Via CLI:
```powershell
az network vpn-gateway list-bgp-peer-status -g rg-lab-003-vwan-aws -n vpngw-lab-003 -o table
```

### AWS Side

In AWS Console:
1. Go to VPC > VPN Connections
2. Click your connection > Tunnel details
3. Verify at least one tunnel shows "UP"

Via CLI:
```powershell
aws ec2 describe-vpn-connections --profile aws-labs --query "VpnConnections[].VgwTelemetry[].{IP:OutsideIpAddress,Status:Status}" -o table
```

## Step 5: Test Connectivity (Optional)

SSH to Azure VM and ping AWS resources (if you add an EC2 instance):

```bash
# From Azure VM
ping 10.20.1.x  # AWS subnet
```

## Step 6: Cleanup

```powershell
.\scripts\destroy.ps1

# Or with specific subscription
.\scripts\destroy.ps1 -SubscriptionKey sub01
```

Type `DELETE` when prompted (or use `-Force` to skip).

### Cleanup Order
1. AWS: Terraform destroy (VPN, CGW, VGW, VPC)
2. Azure: Resource group deletion (runs in background)

Total cleanup time: **10-20 minutes**
