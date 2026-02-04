# Lab 005: Architecture

## Overview

This lab deploys a complete Azure vWAN S2S VPN infrastructure to demonstrate and validate dual-instance gateway behavior with BGP over APIPA.

## Target Architecture

```
                          Azure (centralus)
    ┌────────────────────────────────────────────────────────────────────┐
    │                                                                    │
    │    ┌──────────────────────────────────────────────────────────┐    │
    │    │                    Virtual WAN                           │    │
    │    │                   (vwan-lab-005)                         │    │
    │    │                                                          │    │
    │    │    ┌──────────────────────────────────────────────────┐  │    │
    │    │    │              Virtual Hub                         │  │    │
    │    │    │             (vhub-lab-005)                        │  │    │
    │    │    │            10.0.0.0/24                            │  │    │
    │    │    │                                                   │  │    │
    │    │    │    ┌────────────────────────────────────────┐     │  │    │
    │    │    │    │         S2S VPN Gateway               │     │  │    │
    │    │    │    │        (vpngw-lab-005)                 │     │  │    │
    │    │    │    │                                        │     │  │    │
    │    │    │    │   ┌────────────┐  ┌────────────┐       │     │  │    │
    │    │    │    │   │ Instance 0 │  │ Instance 1 │       │     │  │    │
    │    │    │    │   │ ASN 65515  │  │ ASN 65515  │       │     │  │    │
    │    │    │    │   │            │  │            │       │     │  │    │
    │    │    │    │   │ link-1     │  │ link-2     │       │     │  │    │
    │    │    │    │   │ link-3     │  │ link-4     │       │     │  │    │
    │    │    │    │   │ link-5     │  │ link-6     │       │     │  │    │
    │    │    │    │   │ link-7     │  │ link-8     │       │     │  │    │
    │    │    │    │   └────────────┘  └────────────┘       │     │  │    │
    │    │    │    │                                        │     │  │    │
    │    │    │    └────────────────────────────────────────┘     │  │    │
    │    │    │                                                   │  │    │
    │    │    └──────────────────────────────────────────────────┘  │    │
    │    │                                                          │    │
    │    └──────────────────────────────────────────────────────────┘    │
    │                                                                    │
    │    ┌──────────────────────────────────────────────────────────┐    │
    │    │                    VPN Sites                             │    │
    │    │                                                          │    │
    │    │  ┌─────────────┐  ┌─────────────┐                        │    │
    │    │  │   site-1    │  │   site-2    │                        │    │
    │    │  │ ASN 65001   │  │ ASN 65002   │                        │    │
    │    │  │ link-1,2    │  │ link-3,4    │                        │    │
    │    │  └─────────────┘  └─────────────┘                        │    │
    │    │                                                          │    │
    │    │  ┌─────────────┐  ┌─────────────┐                        │    │
    │    │  │   site-3    │  │   site-4    │                        │    │
    │    │  │ ASN 65003   │  │ ASN 65004   │                        │    │
    │    │  │ link-5,6    │  │ link-7,8    │                        │    │
    │    │  └─────────────┘  └─────────────┘                        │    │
    │    │                                                          │    │
    │    └──────────────────────────────────────────────────────────┘    │
    │                                                                    │
    └────────────────────────────────────────────────────────────────────┘
```

## Components

### Resource Group
- **Name**: `rg-lab-005-vwan-s2s`
- **Region**: centralus

### Virtual WAN
- **Name**: `vwan-lab-005`
- **Type**: Standard

### Virtual Hub
- **Name**: `vhub-lab-005`
- **Address Space**: 10.0.0.0/24
- **Region**: centralus

### S2S VPN Gateway
- **Name**: `vpngw-lab-005`
- **Scale Units**: 1
- **BGP ASN**: 65515
- **Instances**: 2 (active-active)

### VPN Sites

| Site | ASN | Links | Purpose |
|------|-----|-------|---------|
| site-1 | 65001 | link-1, link-2 | Primary customer simulation |
| site-2 | 65002 | link-3, link-4 | Secondary customer simulation |
| site-3 | 65003 | link-5, link-6 | Tertiary customer simulation |
| site-4 | 65004 | link-7, link-8 | Quaternary customer simulation |

## Instance Distribution

Each site has two links:
- **Odd links** (1, 3, 5, 7) bind to **Instance 0**
- **Even links** (2, 4, 6, 8) bind to **Instance 1**

This ensures equal distribution across both gateway instances and validates that custom BGP APIPA assignments are honored.

## BGP Configuration

- Azure BGP ASN: 65515 (both instances)
- Site ASNs: 65001-65004 (one per site)
- BGP peer type: APIPA (169.254.x.x)

## Why This Architecture?

1. **Dual-Instance Validation**: Proves both gateway instances are active and accepting connections
2. **APIPA Correctness**: Validates deterministic APIPA assignment per link
3. **Fail-Forward Design**: Each phase is isolated for easy troubleshooting
4. **No External Dependencies**: All "remote" sites are Azure VPN Site objects (no AWS/on-prem needed)
