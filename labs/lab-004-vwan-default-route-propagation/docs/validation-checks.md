# Validation Checks Explained

This document explains each validation check in `validate.ps1` and the Azure networking concepts behind them.

## Overview

The validation script checks effective routes on VM NICs to verify that vWAN default route propagation works as expected.

## Check 1: Spoke A1 (rt-fw-default)

**Test:** Does vm-a1's NIC have a 0.0.0.0/0 route?

**Expected:** YES (PASS)

**Why:**
- Spoke A1's VNet connection is **associated** with `rt-fw-default`
- `rt-fw-default` contains a static route: `0.0.0.0/0 -> VNet-FW`
- VNets associated with a route table learn the routes in that table
- Therefore, vm-a1 sees `0.0.0.0/0` in its effective routes

**Bicep configuration:**
```bicep
resource connSpokeA1 ... {
  properties: {
    routingConfiguration: {
      associatedRouteTable: { id: rtFwDefault.id }
      // Association = this VNet learns routes from rt-fw-default
    }
  }
}
```

## Check 2: Spoke A2 (rt-fw-default)

**Test:** Does vm-a2's NIC have a 0.0.0.0/0 route?

**Expected:** YES (PASS)

**Why:**
- Same as Spoke A1 - associated with `rt-fw-default`
- Multiple VNets can be associated with the same custom route table

## Check 3: Spoke A3 (Default RT)

**Test:** Does vm-a3's NIC have a 0.0.0.0/0 route?

**Expected:** NO (PASS if absent)

**Why:**
- Spoke A3's VNet connection uses the **Default route table** (no explicit routingConfiguration)
- The Default RT doesn't automatically inherit routes from custom RTs
- Even though `rt-fw-default` is in the same hub, A3 doesn't see its routes
- This is the key learning: **route table association is explicit**

**Bicep configuration:**
```bicep
resource connSpokeA3 ... {
  properties: {
    // No routingConfiguration = uses Default route table
    // No association with rt-fw-default
  }
}
```

## Check 4: Spoke A4 (Default RT)

**Test:** Does vm-a4's NIC have a 0.0.0.0/0 route?

**Expected:** NO (PASS if absent)

**Why:**
- Same as Spoke A3 - uses Default route table, not rt-fw-default

## Check 5: Spoke B1 (Hub B, Default RT)

**Test:** Does vm-b1's NIC have a 0.0.0.0/0 route?

**Expected:** NO (PASS if absent)

**Why:**
- Spoke B1 is on **Hub B**, not Hub A
- Hub B only has the Default route table
- Routes in Hub A's custom route table don't automatically propagate to Hub B
- Hub-to-hub routing follows different rules (inter-hub label propagation)

**Key insight:** Even in the same vWAN, custom RT routes don't automatically cross hubs.

## Check 6: Spoke B2 (Hub B, Default RT)

**Test:** Does vm-b2's NIC have a 0.0.0.0/0 route?

**Expected:** NO (PASS if absent)

**Why:**
- Same as Spoke B1 - Hub B spoke on Default RT

## Route Propagation Concepts

### Association vs. Propagation

| Concept | Meaning |
|---------|---------|
| **Association** | Which route table a VNet **learns routes from** |
| **Propagation** | Which route tables a VNet **advertises its routes to** |

In this lab, we focus on **association** - which determines what routes a VNet sees.

### Why Default RT Doesn't Learn Custom RT Routes

The Default route table is special:
- It's the implicit route table for connections without explicit configuration
- It learns routes from connections that **propagate to it**
- It does NOT automatically inherit routes from other custom RTs

To make Default RT learn the 0/0 route, you would need to:
1. Add the static route directly to the Default RT, OR
2. Use labels to propagate routes between route tables

### Hub-to-Hub Behavior

Routes propagate between hubs via the vWAN backbone, but:
- Static routes in custom RTs stay local to that RT
- Only routes in RTs with matching **labels** propagate across hubs
- The `default` label is for built-in propagation

## Testing Methodology

The validation script uses:

```powershell
az network nic show-effective-route-table --resource-group <rg> --name <nic>
```

This shows the **effective routes** - what the VM actually sees after all Azure routing decisions are applied.

The script then searches for any route with `addressPrefix == "0.0.0.0/0"`.

## Common Misunderstandings

### "Custom RTs inherit from Default RT"
**False.** Custom and Default RTs are independent. You must explicitly configure route sharing.

### "Adding a route to Hub A propagates it to Hub B"
**Depends.** Static routes in custom RTs don't auto-propagate. You need label-based propagation.

### "VNet connections default to the Default RT"
**True.** Without explicit `routingConfiguration`, connections use the Default RT.

## Related Documentation

- [Virtual WAN routing concepts](https://learn.microsoft.com/azure/virtual-wan/about-virtual-hub-routing)
- [Route tables and associations](https://learn.microsoft.com/azure/virtual-wan/how-to-virtual-hub-routing)
- [Effective routes](https://learn.microsoft.com/azure/virtual-network/diagnose-network-routing-problem)
