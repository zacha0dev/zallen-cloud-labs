# Observability and Troubleshooting

> Consistent approach to validating and troubleshooting labs in this repository.
> Every lab uses the same 3-gate model. Follow the gates in order.

---

## The 3-Gate Health Model

### Gate 1: Control Plane (Did It Deploy?)

Check that Azure/AWS resources exist and show `Succeeded` provisioning state. This is the minimum bar.

```powershell
az network vhub show -g <rg> -n <hub-name> --query provisioningState -o tsv
# Expected: Succeeded
```

**If Gate 1 fails:** The deployment didn't complete. Check deployment logs, re-run `deploy.ps1`, or check the Azure Activity Log. Do not proceed to Gate 2.

### Gate 2: Data Plane (Is It Configured?)

Check that resources are configured correctly: health probes, tunnel parameters, BGP settings, NSG rules.

```powershell
az network application-gateway show-backend-health -g <rg> -n <agw-name> \
  --query "backendAddressPools[0].backendHttpSettingsCollection[0].servers[0].health" -o tsv
# Expected: Healthy
```

**If Gate 2 fails:** Resources exist but aren't configured correctly. Check configuration parameters, wait for propagation (up to 5-10 minutes for routing changes), or inspect data plane logs.

### Gate 3: The Proof (Does It Work?)

The single most important validation for this specific lab. This is what the lab was designed to prove.

| Lab type | Gate 3 check |
|----------|-------------|
| VPN labs | BGP routes learned > 0, tunnels UP |
| L7 labs | `/health` endpoint returns expected JSON |
| Routing labs | Effective routes show expected prefixes (or correctly absent) |

**If Gate 3 fails:** Go back to Gate 2. The proof depends on Gates 1 and 2 being healthy.

---

## Per-Lab Validation Summary

| Lab | Gate 1 | Gate 3 (Golden Rule) |
|-----|--------|---------------------|
| [lab-000](../../labs/lab-000_resource-group/README.md) | RG provisioningState = Succeeded | VNet CIDR and subnets match config |
| [lab-001](../../labs/lab-001-virtual-wan-hub-routing/README.md) | vHub provisioningState = Succeeded | Hub connection = Succeeded; spoke has hub routes |
| [lab-002](../../labs/lab-002-l7-fastapi-appgw-frontdoor/README.md) | App Gateway provisioningState = Succeeded | `/health` returns `{"ok":true}` via Front Door |
| [lab-003](../../labs/lab-003-vwan-aws-bgp-apipa/README.md) | VPN connections = Succeeded | AWS tunnels UP; BGP routes learned > 0 |
| [lab-004](../../labs/lab-004-vwan-default-route-propagation/README.md) | All vHubs provisioned | Spoke A1/A2 HAVE 0/0; Spoke A3/A4 do NOT |
| [lab-005](../../labs/lab-005-vwan-s2s-bgp-apipa/README.md) | All VPN connections = Succeeded | 4 sites, 8 links, APIPA addresses correct |
| [lab-006](../../labs/lab-006-vwan-spoke-bgp-router-loopback/README.md) | vHub routingState = Provisioned | BGP peering UP; client VMs have spoke routes |

---

## Common Validation Commands

### Provisioning State (Any Resource)

```powershell
az <resource-type> show -g <rg> -n <name> --query provisioningState -o tsv
```

### Effective Routes (VM NIC)

```powershell
az network nic show-effective-route-table -g <rg> -n <nic-name> \
  --query "value[].{prefix:addressPrefix[0], nextHop:nextHopType}" -o table
```

### Hub Routing State

```powershell
az network vhub show -g <rg> -n <hub-name> \
  --query "{routingState:routingState, routerIps:virtualRouterIps}" -o json
```

### VPN Connections

```powershell
# Azure VPN connection list
az network vpn-gateway connection list -g <rg> --gateway-name <gw-name> \
  --query "[].{name:name, status:connectionStatus}" -o table

# Azure VPN learned routes
az network vpn-gateway connection list -g <rg> --gateway-name <gw-name> \
  --query "[0].vpnLinkConnections[0].connectionBandwidth" -o tsv
```

### AWS VPN Tunnel Status

```powershell
aws ec2 describe-vpn-connections \
  --filters "Name=tag:lab,Values=lab-003" \
  --query "VpnConnections[*].VgwTelemetry[*].[Status,StatusMessage]" \
  --profile aws-labs --output table
```

### App Gateway Backend Health

```powershell
az network application-gateway show-backend-health \
  -g <rg> -n <agw-name> \
  --query "backendAddressPools[0].backendHttpSettingsCollection[0].servers[0].health" \
  -o tsv
```

---

## What NOT to Do

1. **Don't enable all diagnostics.** Most issues are visible via CLI. Only enable diagnostics for specific investigations — they add cost and noise.

2. **Don't check metrics first.** Metrics require traffic. Start with provisioning state (Gate 1).

3. **Don't skip gates.** If Gate 1 fails, Gate 3 will definitely fail. Work in order.

4. **Don't assume the worst immediately.** Many "failures" are propagation delays. Wait 5 minutes and re-check before escalating.

5. **Don't delete and recreate a hub as a first response.** Hub provisioning takes 10-20 minutes. Only delete if genuinely stuck after 30+ minutes.

---

## Portal Quick Links

### Azure

- [Resource Groups](https://portal.azure.com/#blade/HubsExtension/BrowseResourceGroups)
- [Virtual WANs](https://portal.azure.com/#blade/HubsExtension/BrowseResource/resourceType/Microsoft.Network%2FvirtualWans)
- [VPN Gateways](https://portal.azure.com/#blade/HubsExtension/BrowseResource/resourceType/Microsoft.Network%2FvpnGateways)
- [Application Gateways](https://portal.azure.com/#blade/HubsExtension/BrowseResource/resourceType/Microsoft.Network%2FapplicationGateways)
- [Front Door Profiles](https://portal.azure.com/#blade/HubsExtension/BrowseResource/resourceType/Microsoft.Cdn%2Fprofiles)

### AWS

- [VPN Connections](https://console.aws.amazon.com/vpc/home#VpnConnections:)
- [Customer Gateways](https://console.aws.amazon.com/vpc/home#CustomerGateways:)
- [Virtual Private Gateways](https://console.aws.amazon.com/vpc/home#VpnGateways:)

---

## Timing Reference

| Resource | Typical Provisioning Time |
|----------|--------------------------|
| Resource Group | < 5 seconds |
| VNet | < 30 seconds |
| Virtual Hub (first create) | 10-20 minutes |
| S2S VPN Gateway | 20-35 minutes |
| VPN Site + Connection | 2-5 minutes |
| Application Gateway | 5-8 minutes |
| Azure Front Door | 2-3 minutes |
| AWS VGW + CGW + VPN | 3-5 minutes |
| AWS VPN tunnel UP (after Azure VPN) | 2-5 minutes |

---

## Related Resources

| Resource | Description |
|----------|-------------|
| [vWAN Domain](vwan.md) | vWAN-specific validation commands |
| [AWS Hybrid](aws-hybrid.md) | AWS tunnel troubleshooting |
| [REFERENCE.md](../REFERENCE.md) | Cost safety and cleanup patterns |
