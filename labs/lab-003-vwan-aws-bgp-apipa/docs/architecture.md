# Lab 003 Architecture

## Overview

This lab establishes a cross-cloud site-to-site VPN connection between Azure Virtual WAN and AWS using BGP over APIPA (Automatic Private IP Addressing) for link-local BGP peering.

## Architecture Diagram

```
                          AZURE                                           AWS
+----------------------------------------------------------+   +----------------------------------+
|                                                          |   |                                  |
|  +------------------+                                    |   |          VPC: 10.20.0.0/16      |
|  |   Virtual WAN    |                                    |   |                                  |
|  |   vwan-lab-003   |                                    |   |  +----------------------------+  |
|  +--------+---------+                                    |   |  |   Virtual Private Gateway  |  |
|           |                                              |   |  |   lab-003-vgw              |  |
|  +--------+---------+                                    |   |  |   ASN: 65001               |  |
|  |   Virtual Hub    |                                    |   |  +-------------+--------------+  |
|  |   vhub-lab-003   |                                    |   |                |                 |
|  |   10.0.0.0/24    |                                    |   |                |                 |
|  +--------+---------+                                    |   |  +-------------+--------------+  |
|           |                                              |   |  |                            |  |
|  +--------+--------------------------------------------+ |   |  |   2 VPN Connections        |  |
|  |              VPN Gateway: vpngw-lab-003             | |   |  |   (4 tunnels total)        |  |
|  |              ASN: 65515                             | |   |  +----------------------------+  |
|  |                                                     | |   |                                  |
|  |  +-----------------+    +-----------------+         | |   |  +------------+  +------------+  |
|  |  |   Instance 0    |    |   Instance 1    |         | |   |  |   CGW 1    |  |   CGW 2    |  |
|  |  |   Public IP 1   |    |   Public IP 2   |         | |   |  | (Inst 0)   |  | (Inst 1)   |  |
|  |  +-----------------+    +-----------------+         | |   |  +------+-----+  +------+-----+  |
|  |         |                      |                    | |   |         |               |        |
|  +---------|----------------------|--------------------+ |   +---------+---------------+--------+
|            |                      |                      |             |               |
|            |    IPsec Tunnel 1    |                      |             |               |
|            +<-------------------->+----------------------+-------------+               |
|            |   169.254.21.0/30    |                                                    |
|            |                      |                      |                             |
|            |    IPsec Tunnel 2    |                      |                             |
|            +<-------------------->+----------------------+-----------------------------+
|            |   169.254.21.4/30    |                                                    |
|            |                      |                      |                             |
|            |                      |    IPsec Tunnel 3    |                             |
|            |                      +<-------------------->+-----------------------------+
|            |                      |   169.254.22.0/30                                  |
|            |                      |                      |                             |
|            |                      |    IPsec Tunnel 4    |                             |
|            |                      +<-------------------->+-----------------------------+
|            |                      |   169.254.22.4/30                                  |
+------------+----------------------+----------------------+-----------------------------+
```

## Component Inventory

### Azure Resources

| Resource | Name | Purpose |
|----------|------|---------|
| Resource Group | `rg-lab-003-vwan-aws` | Container for all Azure resources |
| Virtual WAN | `vwan-lab-003` | WAN backbone |
| Virtual Hub | `vhub-lab-003` | Regional routing hub |
| VPN Gateway | `vpngw-lab-003` | S2S VPN gateway (2 instances) |
| VPN Site 1 | `aws-site-1` | Represents AWS VPN tunnels 1-2 |
| VPN Site 2 | `aws-site-2` | Represents AWS VPN tunnels 3-4 |
| Connection 1 | `conn-aws-site-1` | Links Site 1 to gateway |
| Connection 2 | `conn-aws-site-2` | Links Site 2 to gateway |

### AWS Resources

| Resource | Name | Purpose |
|----------|------|---------|
| VPC | `lab-003-vpc` | Network container |
| Subnet | `lab-003-subnet` | Public subnet |
| Internet Gateway | `lab-003-igw` | Internet access |
| Route Table | `lab-003-rt` | Routing |
| VPN Gateway | `lab-003-vgw` | Virtual Private Gateway |
| Customer Gateway 1 | `lab-003-cgw-azure-inst0` | Represents Azure Instance 0 |
| Customer Gateway 2 | `lab-003-cgw-azure-inst1` | Represents Azure Instance 1 |
| VPN Connection 1 | `lab-003-vpn-1` | Tunnels 1-2 to Azure |
| VPN Connection 2 | `lab-003-vpn-2` | Tunnels 3-4 to Azure |

## Instance Distribution

Azure vWAN VPN Gateway deploys with 2 active-active instances:

| Instance | Public IP | APIPA Range | Tunnels |
|----------|-----------|-------------|---------|
| Instance 0 | Gateway IP 1 | 169.254.21.x | 1, 2 |
| Instance 1 | Gateway IP 2 | 169.254.22.x | 3, 4 |

Each AWS Customer Gateway targets one Azure instance, creating a fully redundant topology.

## Tunnel Mapping

```
Azure Instance 0                    AWS VPN Connection 1
├── Site 1, Link 1 ────────────────── Tunnel 1 (169.254.21.0/30)
└── Site 1, Link 2 ────────────────── Tunnel 2 (169.254.21.4/30)

Azure Instance 1                    AWS VPN Connection 2
├── Site 2, Link 3 ────────────────── Tunnel 3 (169.254.22.0/30)
└── Site 2, Link 4 ────────────────── Tunnel 4 (169.254.22.4/30)
```

## BGP Configuration

### Azure Side
- **ASN**: 65515 (Azure default)
- **BGP Peering**: Via custom APIPA addresses configured on gateway
- **Instance 0 BGP IPs**: 169.254.21.2, 169.254.21.6
- **Instance 1 BGP IPs**: 169.254.22.2, 169.254.22.6

### AWS Side
- **ASN**: 65001 (configurable)
- **BGP Peering**: Via tunnel inside CIDR
- **Tunnel BGP IPs**: .1 address of each /30 CIDR

## Network Address Spaces

| Network | CIDR | Description |
|---------|------|-------------|
| Azure vHub | 10.0.0.0/24 | Virtual Hub address space |
| AWS VPC | 10.20.0.0/16 | AWS VPC CIDR |
| AWS Subnet | 10.20.1.0/24 | AWS public subnet |
| APIPA Range | 169.254.21.0/24, 169.254.22.0/24 | BGP peering addresses |

## Data Flow

1. Traffic from Azure vHub destined for 10.20.0.0/16
2. Routes learned via BGP from AWS
3. Traffic encrypted and sent via IPsec tunnel
4. AWS VGW receives, decrypts, and routes to VPC
5. Return traffic follows same path in reverse

## High Availability

- **Azure**: 2 gateway instances (active-active)
- **AWS**: 2 VPN connections with 2 tunnels each
- **Total**: 4 independent IPsec tunnels
- **Failover**: Automatic via BGP path selection
