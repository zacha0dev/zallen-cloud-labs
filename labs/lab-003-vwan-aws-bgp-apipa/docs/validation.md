# Validation Commands for Lab 003

## Quick Validation

### Azure VPN Connection Status

```powershell
# List all connections
az network vpn-gateway connection list -g rg-lab-003-vwan-aws --gateway-name vpngw-lab-003 -o table

# Check specific connection
az network vpn-gateway connection show -g rg-lab-003-vwan-aws --gateway-name vpngw-lab-003 -n conn-aws-site-1 --query "{Name:name, State:provisioningState}" -o table
```

### AWS VPN Tunnel Status

```bash
# Check all lab-003 VPN connections
aws ec2 describe-vpn-connections --filters "Name=tag:lab,Values=lab-003" --query "VpnConnections[*].{ID:VpnConnectionId,State:State,Tunnels:VgwTelemetry[*].Status}" --output table

# Detailed tunnel status
aws ec2 describe-vpn-connections --filters "Name=tag:lab,Values=lab-003" --query "VpnConnections[*].VgwTelemetry[*].[OutsideIpAddress,Status,StatusMessage]" --output table
```

## Detailed Validation

### Azure Resources

#### VPN Gateway

```powershell
# Gateway status
az network vpn-gateway show -g rg-lab-003-vwan-aws -n vpngw-lab-003 --query "{Name:name, State:provisioningState, Instances:bgpSettings.bgpPeeringAddresses[*].ipconfigurationId}" -o json

# BGP settings
az network vpn-gateway show -g rg-lab-003-vwan-aws -n vpngw-lab-003 --query "bgpSettings" -o json

# Public IPs
az network vpn-gateway show -g rg-lab-003-vwan-aws -n vpngw-lab-003 --query "bgpSettings.bgpPeeringAddresses[*].tunnelIpAddresses" -o json
```

#### VPN Sites

```powershell
# List sites
az network vpn-site list -g rg-lab-003-vwan-aws -o table

# Site 1 details
az network vpn-site show -g rg-lab-003-vwan-aws -n aws-site-1 --query "{Name:name, Links:vpnSiteLinks[*].{Name:name,IP:ipAddress,BGP:bgpProperties.bgpPeeringAddress}}" -o json

# Site 2 details
az network vpn-site show -g rg-lab-003-vwan-aws -n aws-site-2 --query "{Name:name, Links:vpnSiteLinks[*].{Name:name,IP:ipAddress,BGP:bgpProperties.bgpPeeringAddress}}" -o json
```

#### VPN Connections

```powershell
# Connection 1 link status
az network vpn-gateway connection show -g rg-lab-003-vwan-aws --gateway-name vpngw-lab-003 -n conn-aws-site-1 --query "vpnLinkConnections[*].{Name:name,EnableBgp:enableBgp,Protocol:vpnConnectionProtocolType}" -o table

# Connection 2 link status
az network vpn-gateway connection show -g rg-lab-003-vwan-aws --gateway-name vpngw-lab-003 -n conn-aws-site-2 --query "vpnLinkConnections[*].{Name:name,EnableBgp:enableBgp,Protocol:vpnConnectionProtocolType}" -o table
```

### AWS Resources

#### VPC and Network

```bash
# VPC details
aws ec2 describe-vpcs --filters "Name=tag:lab,Values=lab-003" --query "Vpcs[*].{ID:VpcId,CIDR:CidrBlock,State:State}" --output table

# VGW details
aws ec2 describe-vpn-gateways --filters "Name=tag:lab,Values=lab-003" --query "VpnGateways[*].{ID:VpnGatewayId,State:State,ASN:AmazonSideAsn}" --output table

# Customer Gateways
aws ec2 describe-customer-gateways --filters "Name=tag:lab,Values=lab-003" --query "CustomerGateways[*].{ID:CustomerGatewayId,IP:IpAddress,ASN:BgpAsn,State:State}" --output table
```

#### VPN Connections

```bash
# VPN Connection 1 tunnels
aws ec2 describe-vpn-connections --filters "Name=tag:Name,Values=lab-003-vpn-1" --query "VpnConnections[0].VgwTelemetry[*].{OutsideIP:OutsideIpAddress,Status:Status,StatusMessage:StatusMessage,AcceptedRoutes:AcceptedRouteCount}" --output table

# VPN Connection 2 tunnels
aws ec2 describe-vpn-connections --filters "Name=tag:Name,Values=lab-003-vpn-2" --query "VpnConnections[0].VgwTelemetry[*].{OutsideIP:OutsideIpAddress,Status:Status,StatusMessage:StatusMessage,AcceptedRoutes:AcceptedRouteCount}" --output table

# All tunnel options (APIPA CIDRs)
aws ec2 describe-vpn-connections --filters "Name=tag:lab,Values=lab-003" --query "VpnConnections[*].{Name:Tags[?Key=='Name'].Value|[0],Tunnels:Options.TunnelOptions[*].TunnelInsideCidr}" --output json
```

## BGP Validation

### Azure BGP Peers

```powershell
# Get custom BGP addresses
az network vpn-gateway show -g rg-lab-003-vwan-aws -n vpngw-lab-003 --query "bgpSettings.bgpPeeringAddresses[*].{Instance:ipconfigurationId,CustomBGP:customBgpIpAddresses}" -o json
```

### AWS BGP Routes

```bash
# Check accepted routes (indicates BGP session is up)
aws ec2 describe-vpn-connections --filters "Name=tag:lab,Values=lab-003" --query "VpnConnections[*].VgwTelemetry[*].AcceptedRouteCount" --output table

# If routes > 0, BGP is exchanging routes
```

## PASS/FAIL Criteria

### Infrastructure PASS
- [ ] Azure VPN Gateway provisioning state = `Succeeded`
- [ ] Azure VPN Sites have 2 links each
- [ ] Azure VPN Connections provisioning state = `Succeeded`
- [ ] AWS VPN Connections state = `available`
- [ ] AWS VPN Tunnels status = `UP` (at least 1 per connection)

### BGP PASS
- [ ] AWS tunnel `AcceptedRouteCount > 0`
- [ ] Azure BGP custom addresses configured

### Full PASS
- [ ] All 4 AWS tunnels status = `UP`
- [ ] All tunnels have accepted routes

## Automated Validation Script

```powershell
# Save this as validate.ps1

$rg = "rg-lab-003-vwan-aws"
$gwName = "vpngw-lab-003"

Write-Host "=== Azure Validation ===" -ForegroundColor Cyan

# Gateway
$gw = az network vpn-gateway show -g $rg -n $gwName -o json | ConvertFrom-Json
Write-Host "Gateway State: $($gw.provisioningState)" -ForegroundColor $(if($gw.provisioningState -eq 'Succeeded'){'Green'}else{'Red'})

# Connections
$conns = az network vpn-gateway connection list -g $rg --gateway-name $gwName -o json | ConvertFrom-Json
foreach ($conn in $conns) {
    Write-Host "  $($conn.name): $($conn.provisioningState)" -ForegroundColor $(if($conn.provisioningState -eq 'Succeeded'){'Green'}else{'Yellow'})
}

Write-Host "`n=== AWS Validation ===" -ForegroundColor Cyan

# VPN Tunnels
$vpns = aws ec2 describe-vpn-connections --filters "Name=tag:lab,Values=lab-003" --output json | ConvertFrom-Json
foreach ($vpn in $vpns.VpnConnections) {
    $name = ($vpn.Tags | Where-Object {$_.Key -eq 'Name'}).Value
    Write-Host "$name ($($vpn.State)):" -ForegroundColor White
    foreach ($tunnel in $vpn.VgwTelemetry) {
        $color = if($tunnel.Status -eq 'UP'){'Green'}else{'Yellow'}
        Write-Host "  $($tunnel.OutsideIpAddress): $($tunnel.Status)" -ForegroundColor $color
    }
}
```

## Azure Portal Links

- [Resource Group](https://portal.azure.com/#blade/HubsExtension/BrowseResourceGroups)
- [VPN Gateway](https://portal.azure.com/#blade/HubsExtension/BrowseResource/resourceType/Microsoft.Network%2FvpnGateways)
- [VPN Sites](https://portal.azure.com/#blade/HubsExtension/BrowseResource/resourceType/Microsoft.Network%2FvpnSites)

## AWS Console Links

- [VPN Connections](https://console.aws.amazon.com/vpc/home#VpnConnections:)
- [Customer Gateways](https://console.aws.amazon.com/vpc/home#CustomerGateways:)
- [VPN Gateways](https://console.aws.amazon.com/vpc/home#VpnGateways:)
