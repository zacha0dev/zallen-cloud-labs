# APIPA Mapping for Lab 003

## Overview

APIPA (Automatic Private IP Addressing) uses the 169.254.0.0/16 range for link-local addressing. In this lab, we use specific /30 subnets within this range for BGP peering between Azure and AWS.

## Allocation Rules

### Instance Assignment

- **Instance 0**: Uses 169.254.21.x addresses
- **Instance 1**: Uses 169.254.22.x addresses

### /30 Address Assignment

Within each /30 CIDR:
- **.0** = Network address (unused)
- **.1** = AWS (remote) BGP peer
- **.2** = Azure BGP peer
- **.3** = Broadcast (unused)

For the second /30 in each instance:
- **.4** = Network address (unused)
- **.5** = AWS (remote) BGP peer
- **.6** = Azure BGP peer
- **.7** = Broadcast (unused)

## Complete Mapping Table

| Tunnel | APIPA CIDR | Azure IP | AWS IP | Azure Instance | VPN Site |
|--------|------------|----------|--------|----------------|----------|
| 1 | 169.254.21.0/30 | 169.254.21.2 | 169.254.21.1 | 0 | aws-site-1 |
| 2 | 169.254.21.4/30 | 169.254.21.6 | 169.254.21.5 | 0 | aws-site-1 |
| 3 | 169.254.22.0/30 | 169.254.22.2 | 169.254.22.1 | 1 | aws-site-2 |
| 4 | 169.254.22.4/30 | 169.254.22.6 | 169.254.22.5 | 1 | aws-site-2 |

## Visual Representation

```
Instance 0 (169.254.21.x)
├── Tunnel 1: 169.254.21.0/30
│   ├── Azure: 169.254.21.2
│   └── AWS:   169.254.21.1
└── Tunnel 2: 169.254.21.4/30
    ├── Azure: 169.254.21.6
    └── AWS:   169.254.21.5

Instance 1 (169.254.22.x)
├── Tunnel 3: 169.254.22.0/30
│   ├── Azure: 169.254.22.2
│   └── AWS:   169.254.22.1
└── Tunnel 4: 169.254.22.4/30
    ├── Azure: 169.254.22.6
    └── AWS:   169.254.22.5
```

## Azure Configuration

### Gateway Custom BGP Addresses

The VPN Gateway is configured with custom APIPA addresses for each instance:

```json
{
  "bgpSettings": {
    "asn": 65515,
    "bgpPeeringAddresses": [
      {
        "ipconfigurationId": ".../Instance0",
        "customBgpIpAddresses": ["169.254.21.2", "169.254.21.6"]
      },
      {
        "ipconfigurationId": ".../Instance1",
        "customBgpIpAddresses": ["169.254.22.2", "169.254.22.6"]
      }
    ]
  }
}
```

### VPN Site Link Configuration

Each VPN Site link specifies the AWS BGP peer address:

```json
{
  "vpnSiteLinks": [
    {
      "name": "link-1",
      "properties": {
        "ipAddress": "<AWS Tunnel 1 Public IP>",
        "bgpProperties": {
          "asn": 65001,
          "bgpPeeringAddress": "169.254.21.1"
        }
      }
    }
  ]
}
```

## AWS Configuration

### VPN Connection Tunnel Options

Each AWS VPN connection specifies the inside CIDR for its tunnels:

```json
{
  "TunnelOptions": [
    {
      "TunnelInsideCidr": "169.254.21.0/30",
      "PreSharedKey": "<psk>",
      "IKEVersions": [{"Value": "ikev2"}]
    },
    {
      "TunnelInsideCidr": "169.254.21.4/30",
      "PreSharedKey": "<psk>",
      "IKEVersions": [{"Value": "ikev2"}]
    }
  ]
}
```

## Why This Layout?

1. **Deterministic**: The mapping follows a predictable pattern
2. **Non-overlapping**: Each tunnel has its own /30
3. **Instance-aware**: Instance 0 and Instance 1 have distinct ranges
4. **Microsoft-recommended**: Follows Azure documentation guidelines

## Validation Commands

### Azure: Check Gateway BGP Settings

```powershell
az network vpn-gateway show -g rg-lab-003-vwan-aws -n vpngw-lab-003 --query "bgpSettings" -o json
```

### Azure: Check Site Link BGP Properties

```powershell
az network vpn-site show -g rg-lab-003-vwan-aws -n aws-site-1 --query "vpnSiteLinks[].bgpProperties" -o json
```

### AWS: Check Tunnel Inside CIDR

```bash
aws ec2 describe-vpn-connections --filters "Name=tag:lab,Values=lab-003" --query "VpnConnections[*].Options.TunnelOptions[*].TunnelInsideCidr" --output table
```

## References

- [Azure VPN Gateway BGP documentation](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-bgp-overview)
- [Azure vWAN + AWS integration guide](https://learn.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-howto-aws-bgp)
- [APIPA RFC 3927](https://tools.ietf.org/html/rfc3927)
