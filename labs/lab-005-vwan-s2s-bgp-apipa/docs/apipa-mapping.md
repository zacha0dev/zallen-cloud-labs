# Lab 005: APIPA Mapping

## Overview

APIPA (Automatic Private IP Addressing) uses the 169.254.0.0/16 range for link-local addresses. In Azure VPN, APIPA is used for BGP peering over IPsec tunnels to avoid IP overlap with real network ranges.

## APIPA Allocation Table

| VPN Site | Link   | APIPA /30        | Remote BGP    | Azure BGP     | Gateway Instance |
|----------|--------|------------------|---------------|---------------|------------------|
| site-1   | link-1 | 169.254.21.0/30  | 169.254.21.1  | 169.254.21.2  | Instance 0       |
| site-1   | link-2 | 169.254.22.0/30  | 169.254.22.1  | 169.254.22.2  | Instance 1       |
| site-2   | link-3 | 169.254.21.4/30  | 169.254.21.5  | 169.254.21.6  | Instance 0       |
| site-2   | link-4 | 169.254.22.4/30  | 169.254.22.5  | 169.254.22.6  | Instance 1       |
| site-3   | link-5 | 169.254.21.8/30  | 169.254.21.9  | 169.254.21.10 | Instance 0       |
| site-3   | link-6 | 169.254.22.8/30  | 169.254.22.9  | 169.254.22.10 | Instance 1       |
| site-4   | link-7 | 169.254.21.12/30 | 169.254.21.13 | 169.254.21.14 | Instance 0       |
| site-4   | link-8 | 169.254.22.12/30 | 169.254.22.13 | 169.254.22.14 | Instance 1       |

## /30 Address Assignment Rule

Each /30 CIDR provides 4 addresses:
- `.0` - Network address (unusable)
- `.1` - First host (Remote/Customer BGP peer)
- `.2` - Second host (Azure BGP peer)
- `.3` - Broadcast address (unusable)

## Instance Assignment Pattern

The APIPA ranges follow a deterministic pattern:

### Instance 0 Links (169.254.21.x)
- link-1: 169.254.21.0/30
- link-3: 169.254.21.4/30
- link-5: 169.254.21.8/30
- link-7: 169.254.21.12/30

### Instance 1 Links (169.254.22.x)
- link-2: 169.254.22.0/30
- link-4: 169.254.22.4/30
- link-6: 169.254.22.8/30
- link-8: 169.254.22.12/30

## Why This Pattern?

1. **Easy Visual Identification**:
   - `169.254.21.x` = Instance 0
   - `169.254.22.x` = Instance 1

2. **Non-Overlapping**: Each link has a unique /30, preventing BGP peer conflicts

3. **Public-Safe**: APIPA range is link-local only, never routed on the internet

4. **Deterministic**: Same CIDR always maps to same instance, enabling predictable troubleshooting

## Validation

To verify APIPA assignments after deployment:

```powershell
# Get VPN Gateway BGP settings
az network vpn-gateway show -g rg-lab-005-vwan-s2s -n vpngw-lab-005 --query "bgpSettings.bgpPeeringAddresses" -o table

# Check connection link details
az network vpn-gateway connection show -g rg-lab-005-vwan-s2s --gateway-name vpngw-lab-005 -n conn-site-1 --query "vpnLinkConnections[].{Name:name, CustomBgp:vpnGatewayCustomBgpAddresses}" -o json
```

## Azure REST API Reference

Custom BGP addresses are set via the `vpnGatewayCustomBgpAddresses` property:

```json
{
  "vpnLinkConnections": [
    {
      "name": "conn-site-1-link-1",
      "properties": {
        "vpnGatewayCustomBgpAddresses": [
          {
            "ipConfigurationId": ".../vpnGatewayInstances/Instance0",
            "customBgpIpAddress": "169.254.21.2"
          }
        ]
      }
    }
  ]
}
```
