# Troubleshooting Guide for Lab 003

## Common Issues by Phase

### Phase 0: Preflight

#### Issue: Azure CLI not authenticated

```
Error: Azure CLI is not authenticated
```

**Solution:**
```powershell
az login
```

#### Issue: AWS profile not found

```
Error: AWS profile 'aws-labs' does not exist
```

**Solution:**
```bash
aws configure sso --profile aws-labs
# or
aws configure --profile aws-labs
```

#### Issue: AWS credentials expired

```
Error: AWS profile 'aws-labs' is configured (SSO) but not authenticated
```

**Solution:**
```bash
aws sso login --profile aws-labs
```

### Phase 1: Core Fabric

#### Issue: vHub provisioning timeout

```
Error: vHub did not provision within timeout
```

**Possible causes:**
- Azure region capacity issues
- Network connectivity problems

**Solution:**
1. Check Azure status: https://status.azure.com
2. Wait 5 minutes and re-run deploy.ps1
3. Try a different region with `-Location eastus`

#### Issue: vHub in Failed state

**Solution:**
```powershell
# Delete the vHub and re-deploy
az network vhub delete -g rg-lab-003-vwan-aws -n vhub-lab-003 --yes
./deploy.ps1 -Force
```

### Phase 2: VPN Gateway

#### Issue: VPN Gateway provisioning failed

```
Error: VPN Gateway provisioning failed
```

**Solution:**
1. Check portal for detailed error
2. Delete and retry:
```powershell
az network vpn-gateway delete -g rg-lab-003-vwan-aws -n vpngw-lab-003 --yes
# Wait 2-3 minutes
./deploy.ps1 -Force
```

#### Issue: VPN Gateway timeout (>30 minutes)

**Possible causes:**
- Azure capacity constraints
- Region issues

**Solution:**
1. Wait and re-run - the script will detect existing gateway
2. Check Azure Portal for actual status
3. Try a different region

### Phase 5: AWS Deployment

#### Issue: VPN Connection creation failed

```
Error: An error occurred (InvalidVpnGatewayId.NotFound)
```

**Solution:**
1. Wait for VGW to be fully attached:
```bash
aws ec2 describe-vpn-gateways --filters "Name=tag:lab,Values=lab-003" --query "VpnGateways[0].VpcAttachments[0].State"
```
2. Re-run deploy.ps1

#### Issue: Customer Gateway already exists

This is not an error - the script reuses existing CGWs.

#### Issue: VPN tunnels not coming UP

**Possible causes:**
1. PSK mismatch
2. APIPA mismatch
3. Azure connection not yet established

**Diagnosis:**
```bash
# Check AWS tunnel status
aws ec2 describe-vpn-connections --filters "Name=tag:lab,Values=lab-003" --query "VpnConnections[*].VgwTelemetry[*].[OutsideIpAddress,Status,StatusMessage]" --output table
```

**Common StatusMessages:**
- `IPSEC IS UP` - Tunnel is healthy
- `IKE NEGOTIATION IS STARTED` - Still negotiating
- `IPSEC IS DOWN` - Check PSK and routing

### Phase 5b: Azure VPN Sites + Connections

#### Issue: VPN Site creation failed

```
Error: Failed to create VPN Site
```

**Solution:**
1. Check for existing site with incomplete config:
```powershell
az network vpn-site show -g rg-lab-003-vwan-aws -n aws-site-1 -o json
```
2. Delete and retry:
```powershell
az network vpn-site delete -g rg-lab-003-vwan-aws -n aws-site-1 --yes
./deploy.ps1 -Force
```

#### Issue: VPN Connection provisioning stuck

**Solution:**
1. Wait - connections can take 2-3 minutes
2. Check portal for detailed status
3. Delete connection and retry:
```powershell
az network vpn-gateway connection delete -g rg-lab-003-vwan-aws --gateway-name vpngw-lab-003 -n conn-aws-site-1 --yes
./deploy.ps1 -Force
```

## BGP Issues

### BGP Session Not Establishing

**Symptoms:**
- AWS tunnel shows `UP` but no accepted routes
- Azure connection shows `Connected` but no routes

**Diagnosis:**
```bash
# Check AWS accepted routes
aws ec2 describe-vpn-connections --filters "Name=tag:lab,Values=lab-003" --query "VpnConnections[*].VgwTelemetry[*].AcceptedRouteCount"
```

**Possible causes:**
1. APIPA mismatch between Azure and AWS
2. ASN mismatch
3. Custom BGP addresses not configured on gateway

**Solution:**
1. Verify APIPA mapping:
```powershell
# Azure side
az network vpn-gateway show -g rg-lab-003-vwan-aws -n vpngw-lab-003 --query "bgpSettings.bgpPeeringAddresses[*].customBgpIpAddresses"

# AWS side
aws ec2 describe-vpn-connections --filters "Name=tag:lab,Values=lab-003" --query "VpnConnections[*].Options.TunnelOptions[*].TunnelInsideCidr"
```

2. Verify ASNs match:
- Azure: 65515
- AWS: 65001 (default)

### Only Partial Tunnels UP

**Symptoms:**
- 2 of 4 tunnels UP
- Usually Instance 0 OR Instance 1 tunnels

**Possible cause:**
- One Azure instance IP incorrect in AWS CGW

**Solution:**
```powershell
# Get Azure gateway IPs
az network vpn-gateway show -g rg-lab-003-vwan-aws -n vpngw-lab-003 --query "bgpSettings.bgpPeeringAddresses[*].tunnelIpAddresses" -o json

# Verify AWS CGW IPs match
aws ec2 describe-customer-gateways --filters "Name=tag:lab,Values=lab-003" --query "CustomerGateways[*].{Name:Tags[?Key=='Name'].Value|[0],IP:IpAddress}"
```

## Cleanup Issues

### Resource Group deletion hangs

**Solution:**
1. Delete in correct order:
```powershell
# Delete connections first
az network vpn-gateway connection delete -g rg-lab-003-vwan-aws --gateway-name vpngw-lab-003 -n conn-aws-site-1 --yes
az network vpn-gateway connection delete -g rg-lab-003-vwan-aws --gateway-name vpngw-lab-003 -n conn-aws-site-2 --yes

# Delete sites
az network vpn-site delete -g rg-lab-003-vwan-aws -n aws-site-1 --yes
az network vpn-site delete -g rg-lab-003-vwan-aws -n aws-site-2 --yes

# Delete gateway
az network vpn-gateway delete -g rg-lab-003-vwan-aws -n vpngw-lab-003 --yes

# Then delete RG
az group delete -n rg-lab-003-vwan-aws --yes
```

### AWS resources not deleted

**Solution:**
```bash
# Manual cleanup in order:
# 1. VPN Connections
aws ec2 delete-vpn-connection --vpn-connection-id <vpn-id>

# 2. CGWs
aws ec2 delete-customer-gateway --customer-gateway-id <cgw-id>

# 3. VGW (detach first)
aws ec2 detach-vpn-gateway --vpn-gateway-id <vgw-id> --vpc-id <vpc-id>
aws ec2 delete-vpn-gateway --vpn-gateway-id <vgw-id>

# 4. VPC resources (IGW, subnets, route tables)
# 5. VPC
aws ec2 delete-vpc --vpc-id <vpc-id>
```

## Log Files

Deployment logs are saved to:
```
labs/lab-003-vwan-aws-bgp-apipa/logs/lab-003-YYYYMMDD-HHmmss.log
```

View recent logs:
```powershell
Get-ChildItem logs/*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content
```

## Clean Restart

If everything is broken, start fresh:

```powershell
# Destroy everything
./destroy.ps1 -Force

# Wait 5 minutes for Azure cleanup

# Re-deploy
./deploy.ps1 -Force
```

## Getting Help

1. Check the logs in `logs/` directory
2. Review Azure Portal deployment history
3. Check AWS VPN connection telemetry
4. Open an issue with log output
