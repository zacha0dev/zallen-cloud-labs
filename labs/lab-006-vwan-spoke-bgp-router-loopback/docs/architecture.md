# Lab 006: Architecture

## Overview

This lab deploys a vWAN Standard hub with two spoke VNets. Spoke A contains a 2-NIC FRR router VM that peers BGP with the Virtual Hub and advertises loopback prefixes. Spoke B is a control spoke with no BGP peering, used to observe route propagation differences.

## Target Architecture

```
                           Azure (centralus)
┌──────────────────────────────────────────────────────────────────────┐
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │                     Virtual WAN (Standard)                     │  │
│  │                    (vwan-lab-006)                               │  │
│  │                                                                │  │
│  │  ┌──────────────────────────────────────────────────────────┐  │  │
│  │  │                  Virtual Hub                              │  │  │
│  │  │                 (vhub-lab-006)                             │  │  │
│  │  │                10.0.0.0/24, ASN 65515                     │  │  │
│  │  │                                                           │  │  │
│  │  │    BGP Peering: bgp-peer-router-006                       │  │  │
│  │  │    Peer IP: 10.61.1.x  Peer ASN: 65100                   │  │  │
│  │  └──────────────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                  │                              │                     │
│           conn-spoke-a                    conn-spoke-b               │
│                  │                              │                     │
│  ┌───────────────┴──────────────┐  ┌────────────┴──────────────┐    │
│  │  Spoke A VNet (BGP spoke)    │  │  Spoke B VNet (control)   │    │
│  │  vnet-spoke-a                │  │  vnet-spoke-b             │    │
│  │  10.61.0.0/16                │  │  10.62.0.0/16             │    │
│  │                              │  │                            │    │
│  │  ┌────────────────────────┐  │  │  ┌──────────────────────┐ │    │
│  │  │ snet-router-hubside   │  │  │  │ snet-client-b        │ │    │
│  │  │ 10.61.1.0/24          │  │  │  │ 10.62.10.0/24        │ │    │
│  │  │  ┌──────────────────┐ │  │  │  │  ┌────────────────┐  │ │    │
│  │  │  │ Router VM NIC1   │ │  │  │  │  │ Client B VM    │  │ │    │
│  │  │  │ (IP fwd enabled) │ │  │  │  │  │ vm-client-b-006│  │ │    │
│  │  │  └──────────────────┘ │  │  │  │  └────────────────┘  │ │    │
│  │  └────────────────────────┘  │  │  └──────────────────────┘ │    │
│  │                              │  │                            │    │
│  │  ┌────────────────────────┐  │  └────────────────────────────┘    │
│  │  │ snet-router-spokeside │  │                                    │
│  │  │ 10.61.2.0/24          │  │                                    │
│  │  │  ┌──────────────────┐ │  │                                    │
│  │  │  │ Router VM NIC2   │ │  │                                    │
│  │  │  │ (IP fwd enabled) │ │  │                                    │
│  │  │  └──────────────────┘ │  │                                    │
│  │  └────────────────────────┘  │                                    │
│  │                              │                                    │
│  │  ┌────────────────────────┐  │                                    │
│  │  │ snet-client-a          │  │                                    │
│  │  │ 10.61.10.0/24          │  │                                    │
│  │  │  ┌──────────────────┐ │  │                                    │
│  │  │  │ Client A VM      │ │  │                                    │
│  │  │  │ vm-client-a-006  │ │  │                                    │
│  │  │  └──────────────────┘ │  │                                    │
│  │  └────────────────────────┘  │                                    │
│  │                              │                                    │
│  │  Router VM (vm-router-006):  │                                    │
│  │    lo0: 10.61.250.1/32       │                                    │
│  │         10.200.200.1/32      │                                    │
│  │    FRR BGP ASN 65100         │                                    │
│  └──────────────────────────────┘                                    │
└──────────────────────────────────────────────────────────────────────┘
```

## Components

### Resource Group
- **Name**: `rg-lab-006-vwan-bgp-router`
- **Tags**: `project=azure-labs lab=lab-006 env=lab`

### Virtual WAN
- **Name**: `vwan-lab-006`
- **Type**: Standard (required for BGP peering to NVA)

### Virtual Hub
- **Name**: `vhub-lab-006`
- **Address Space**: 10.0.0.0/24
- **BGP ASN**: 65515

### Router VM (vm-router-006)
- **Image**: Ubuntu 22.04 LTS
- **Size**: Standard_B2s
- **NIC1**: `nic-router-hubside-006` in `snet-router-hubside` (10.61.1.0/24), IP forwarding ON
- **NIC2**: `nic-router-spokeside-006` in `snet-router-spokeside` (10.61.2.0/24), IP forwarding ON
- **Routing stack**: FRRouting (FRR)
- **Loopback (lo0)**: `ip link add lo0 type dummy`
  - 10.61.250.1/32 (inside VNet CIDR — tests system route conflict)
  - 10.200.200.1/32 (outside VNet CIDR — clean propagation test)
- **BGP**: Peers to vHub via NIC1 IP, advertises loopback prefixes

### Client VMs
- **Client A** (`vm-client-a-006`): Spoke A, `snet-client-a` (10.61.10.0/24)
- **Client B** (`vm-client-b-006`): Spoke B, `snet-client-b` (10.62.10.0/24)
- Basic tooling: ping, traceroute, tcpdump

## Design Decisions

### Why 2 NICs on the Router?
The hub-side NIC (NIC1) faces the vHub for BGP peering. The spoke-side NIC (NIC2) faces internal spoke workloads. This mimics real NVA designs where management/control plane traffic is separated from data plane traffic.

### Why FRR over VyOS?
FRR on Ubuntu is simpler to bootstrap (apt install), has excellent BGP support, and avoids image/licensing friction. VyOS would be a valid alternative for a more "router appliance" feel.

### Why Two Loopback Prefixes?
- **Inside VNet** (10.61.250.1/32): Tests whether Azure's system routes for the VNet CIDR conflict with BGP-learned routes. This is the interesting edge case.
- **Outside VNet** (10.200.200.1/32): Clean baseline — should propagate without conflict.

### Why Spoke B as Control?
Having a non-BGP spoke lets you compare effective routes between "BGP-peered spoke" and "default spoke" to prove propagation behavior.

## Network Address Plan

| Component | CIDR | Purpose |
|-----------|------|---------|
| vHub | 10.0.0.0/24 | Virtual Hub address space |
| Spoke A | 10.61.0.0/16 | BGP spoke |
| Router hub-side | 10.61.1.0/24 | Router NIC1 subnet |
| Router spoke-side | 10.61.2.0/24 | Router NIC2 subnet |
| Client A | 10.61.10.0/24 | Client A subnet |
| Spoke B | 10.62.0.0/16 | Control spoke |
| Client B | 10.62.10.0/24 | Client B subnet |
| Loopback (in-VNet) | 10.61.250.1/32 | Inside Spoke A CIDR |
| Loopback (out-VNet) | 10.200.200.1/32 | Outside any VNet CIDR |

## Gotchas

1. **2-NIC VMs**: IP forwarding must be enabled at both NIC resource AND OS level (`sysctl net.ipv4.ip_forward=1`)
2. **Asymmetric routing**: With 2 NICs in different subnets, return traffic may take unexpected paths. UDRs may be needed.
3. **Inside-VNet loopback**: Azure system routes for the VNet CIDR (10.61.0.0/16) have priority over BGP-learned more-specific routes in some cases — this is what we're testing.
4. **vHub BGP peering**: Uses `az network vhub bgpconnection` — requires the hub connection to Spoke A as the anchor.
5. **Route propagation**: Often about association + propagation on route tables, not "BGP is broken."
