# Lab 010: vWAN Route Maps

Learn how Azure Virtual WAN Route Maps work by deploying three practical examples: community tagging, route filtering, and AS path prepending. Each example is applied to a real hub connection so you can observe the effects in the hub routing table.

## Purpose

- Understand what Route Maps are and when to use them
- Apply route maps inbound and outbound on vHub connections
- See community tagging, prefix filtering, and AS path manipulation in action
- Learn the route map rule structure: match criteria, actions, nextStepIfMatched

## What Are Route Maps?

A **Route Map** is a policy engine attached to a Virtual Hub connection. It intercepts BGP route advertisements as they flow **into** the hub (inbound) or **out of** the hub toward a spoke (outbound), and applies rules to manipulate or filter them.

Each rule has three parts:
1. **Match Criteria** - which routes to target (by prefix, community, or AS path)
2. **Actions** - what to do (Add/Replace/Remove community or AS path, or Drop the route)
3. **nextStepIfMatched** - `Continue` (keep evaluating rules) or `Terminate` (stop here)

## Architecture

```
                  Virtual WAN: vwan-lab-010
                         |
              Virtual Hub: vhub-lab-010
                 (10.60.0.0/24)
                /                \
     conn-spoke-a                conn-spoke-b
     Inbound:  rm-community-tag  Inbound:  (none)
     Outbound: rm-as-prepend     Outbound: rm-route-filter
              |                            |
   Spoke-A VNet                   Spoke-B VNet
   (10.61.0.0/16)                 (10.62.0.0/16)
   "production"                   "isolated dev"
```

## Three Route Map Examples

### 1. Community Tagging (`rm-community-tag`)
**Applied:** Inbound on `conn-spoke-a`

```
Match:  any prefix (Contains 0.0.0.0/0)
Action: Add community 65010:100
Next:   Continue
```

**What it does:** Every route that Spoke-A advertises into the hub gets tagged with BGP community `65010:100`. This tag travels with the route inside the hub and can be matched by downstream route maps on other connections. Use communities to classify routes by tenant, environment, or priority.

---

### 2. Route Filtering (`rm-route-filter`)
**Applied:** Outbound on `conn-spoke-b`

```
Rule 1: Match Contains 10.61.0.0/16  ->  Drop     (Terminate)
Rule 2: Match Contains 0.0.0.0/0     ->  (pass)   (Continue)
```

**What it does:** When the hub is about to send its routing table to Spoke-B, rule 1 drops Spoke-A's prefix (`10.61.0.0/16`) from that advertisement. Spoke-B never learns the route, so any workload in Spoke-B cannot reach Spoke-A. Rule 2 passes everything else through.

**Observable effect:** Run `inspect.ps1` and look at Spoke-B's effective routes — `10.61.0.0/16` should be absent.

---

### 3. AS Path Prepend (`rm-as-prepend`)
**Applied:** Outbound on `conn-spoke-a`

```
Match:  any prefix (Contains 0.0.0.0/0)
Action: Add asPath ["65010", "65010"]  (prepend AS 65010 twice)
Next:   Continue
```

**What it does:** Routes sent from the hub to Spoke-A have ASN 65010 prepended to the AS path twice. In environments with multiple path options (e.g., ExpressRoute + VPN), a longer AS path is less preferred by BGP path selection. This technique makes routes via one path appear costlier to discourage their use.

---

## Quick Start

```powershell
# Deploy (no VMs - routing only)
.\lab.ps1 -Deploy lab-010

# Inspect route maps and effective routes
.\lab.ps1 -Inspect lab-010

# Destroy when done
.\lab.ps1 -Destroy lab-010
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionKey` | (from config) | Subscription key from `.data/subs.json` |
| `-Location` | `centralus` | Azure region |
| `-Owner` | (from env) | Owner tag value |
| `-Force` | (switch) | Skip confirmation prompts |

## Deployment Phases

| Phase | Description | Duration |
|-------|-------------|----------|
| 0 | Preflight Checks | ~5s |
| 1 | Core Fabric (vWAN + vHub) | 10-20 min |
| 2 | Spoke VNets (A and B) | ~15s |
| 3 | Route Maps (create all 3) | ~30s |
| 4 | Hub Connections + Route Map assignment | ~3-5 min |
| 5 | Validation + effective routes check | ~30s |
| 6 | Summary | ~5s |

**Total: ~15-25 minutes** (vHub provisioning dominates)

## Resources Created

| Resource | Name | Notes |
|----------|------|-------|
| Resource Group | `rg-lab-010-vwan-route-maps` | All resources |
| Virtual WAN | `vwan-lab-010` | Standard SKU |
| Virtual Hub | `vhub-lab-010` | 10.60.0.0/24 |
| VNet (Spoke-A) | `vnet-spoke-a-lab-010` | 10.61.0.0/16, "production" |
| VNet (Spoke-B) | `vnet-spoke-b-lab-010` | 10.62.0.0/16, "isolated dev" |
| Hub Connection | `conn-spoke-a` | Route maps: rm-community-tag (in), rm-as-prepend (out) |
| Hub Connection | `conn-spoke-b` | Route maps: rm-route-filter (out) |
| Route Map | `rm-community-tag` | Inbound on Spoke-A: add community 65010:100 |
| Route Map | `rm-route-filter` | Outbound on Spoke-B: drop 10.61.0.0/16 |
| Route Map | `rm-as-prepend` | Outbound on Spoke-A: prepend AS 65010 x2 |

## Cost Estimate

| Resource | Approximate Cost |
|----------|------------------|
| vWAN Hub | ~$0.25/hour |
| 2x VNets + Hub Connections | Minimal |
| Route Maps | No additional charge |

**Estimated total: ~$0.26/hour** (~$6.25/day)

No VMs are deployed. Run `destroy.ps1` when done.

## Prerequisites

- Azure CLI 2.54+ (`az version`)
- lab-001 completed or at minimum familiarity with vWAN concepts
- Subscription registered for `Microsoft.Network` provider

## Tags Applied

```json
{
  "project": "azure-labs",
  "lab": "lab-010",
  "owner": "<from config>",
  "environment": "lab",
  "cost-center": "learning"
}
```

## Validation

```powershell
# List all route maps on the hub
az network vhub route-map list -g rg-lab-010-vwan-route-maps --vhub-name vhub-lab-010 -o table

# Show a specific route map with rules
az network vhub route-map show -g rg-lab-010-vwan-route-maps --vhub-name vhub-lab-010 -n rm-route-filter -o json

# Check connection routing configuration (includes route map references)
az network vhub connection show -g rg-lab-010-vwan-route-maps --vhub-name vhub-lab-010 -n conn-spoke-b -o json --query routingConfiguration

# Effective routes seen by Spoke-B (rm-route-filter applied outbound - 10.61.0.0/16 should be absent)
az network vhub get-effective-routes \
  -g rg-lab-010-vwan-route-maps \
  -n vhub-lab-010 \
  --resource-type VirtualNetworkConnection \
  --resource-id "<conn-spoke-b-resource-id>" \
  -o json
```

Or use `inspect.ps1` which does all of the above automatically:

```powershell
.\lab.ps1 -Inspect lab-010
```

## Cleanup

```powershell
.\lab.ps1 -Destroy lab-010
.\lab.ps1 -Cost
```

## Key Learnings

1. **Route Maps are directional** - inbound controls what enters the hub routing table from a spoke; outbound controls what the hub advertises back to a spoke.
2. **Rule evaluation is sequential** - rules are checked top-to-bottom; `Terminate` stops evaluation, `Continue` moves to the next rule.
3. **Drop is permanent for that path** - a dropped route is not installed in the target routing table; the remote spoke never learns it.
4. **Community tagging enables chained policies** - tag a route inbound on one connection, then match that community outbound on another connection to create cross-spoke policies.
5. **AS path prepend is a BGP hint, not a hard block** - it influences path preference in multi-path scenarios but doesn't prevent route use when there's only one path.

## Troubleshooting

**Route map creation fails with "unsupported command":**
- Upgrade Azure CLI: `az upgrade`
- Minimum required: 2.54.0

**Route map not appearing on connection:**
- The `routingConfiguration` section on the connection shows the applied maps
- Run `inspect.ps1` to verify the inbound/outbound assignment
- Try `az network vhub connection update` with `--route-map-inbound` / `--route-map-outbound`

**Effective routes still show filtered prefix:**
- Routes may take 2-5 minutes to refresh after route map assignment
- Rerun `inspect.ps1` after a few minutes

**vHub stuck in "Updating":**
- Route map updates trigger a hub reprovisioning cycle (1-5 min)
- Wait for `provisioningState` to return to `Succeeded`

## Files

```
lab-010-vwan-route-maps/
├── deploy.ps1      # Phases 0-6: vWAN + hub + VNets + route maps + connections
├── destroy.ps1     # Idempotent teardown
├── inspect.ps1     # Show route maps, assignments, and effective routes
├── README.md       # This file
└── logs/           # Runtime deploy logs
```

## References

- [vWAN Domain Guide](../../docs/DOMAINS/vwan.md)
- [Azure vWAN Route Maps overview](https://learn.microsoft.com/azure/virtual-wan/route-maps-about)
- [Configure Route Maps](https://learn.microsoft.com/azure/virtual-wan/route-maps-how-to)
- [vWAN routing concepts](https://learn.microsoft.com/azure/virtual-wan/about-virtual-hub-routing)
