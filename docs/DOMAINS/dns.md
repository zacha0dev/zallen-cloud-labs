# Azure DNS Domain Guide

> Concepts and patterns behind the Azure DNS labs in this repository.
> For hands-on implementation, see [lab-007](../../labs/lab-007-azure-dns-foundations/README.md) and [lab-008](../../labs/lab-008-azure-dns-private-resolver/README.md).

---

## Core Concepts

### Azure DNS Platform Resolver (`168.63.129.16`)

Every Azure VM uses `168.63.129.16` as its DNS server by default (visible in `/etc/resolv.conf`). This is a virtual IP that routes through Azure's DNS fabric. It provides:

- Public name resolution (internet DNS)
- Private DNS zone resolution (when zone is linked to the VNet)
- DNS forwarding ruleset evaluation (when a ruleset is linked to the VNet)

This resolver is the foundation that all DNS lab patterns build on.

---

### Private DNS Zones

A Private DNS Zone is a globally-scoped Azure resource that holds DNS records visible only within linked VNets.

Key properties:
- `location: 'global'` — not region-specific
- Requires a **VNet link** to be resolvable from inside a VNet
- Supports **auto-registration**: VMs in a linked VNet are automatically added as `<hostname>.<zone>` when they boot

One zone can be linked to multiple VNets. Only one zone per VNet can have auto-registration enabled.

**Lab:** [lab-007 — Azure DNS Foundations](../../labs/lab-007-azure-dns-foundations/README.md)

---

### DNS Private Resolver

A DNS Private Resolver adds explicit, controllable forwarding behavior to Azure DNS. It consists of:

| Component | Purpose |
|-----------|---------|
| **Inbound endpoint** | Accepts DNS queries from peered/connected networks |
| **Outbound endpoint** | Exit point for queries forwarded to external DNS servers |
| **Forwarding ruleset** | Domain-scoped rules linking the resolver to VNets |

Subnet requirements (both endpoints):
- Minimum `/28` subnet
- Delegated to `Microsoft.Network/dnsResolvers`
- No NSG attached

**Lab:** [lab-008 — Azure DNS Private Resolver](../../labs/lab-008-azure-dns-private-resolver/README.md)

---

## Resolution Patterns

### Pattern 1: Single-VNet Private Zone (lab-007)

```
VM in VNet A
  → Azure DNS (168.63.129.16)
  → Private zone linked to VNet A
  → Returns record
```

Use this when all workloads share the same VNet and you need private hostnames without complex routing.

### Pattern 2: Cross-VNet via DNS Private Resolver (lab-008)

```
VM in Spoke VNet
  → Azure DNS (168.63.129.16)
  → Forwarding ruleset linked to Spoke VNet
  → Rule: internal.lab. → inbound endpoint IP:53
  → Inbound endpoint resolves against zone (linked to Hub VNet)
  → Returns record
```

Use this when private zones live in a hub VNet and spokes need controlled access to them — without linking the zone to every spoke.

---

## DNS Security Policy + Cache Persistence

Azure DNS Security Policy allows you to enforce domain-level access controls at the resolver — for example, blocking resolution of a specific FQDN or returning a custom response (NXDOMAIN, CNAME sinkhole).

### How it works

A DNS Security Policy is applied to a forwarding ruleset. When a matching query arrives at the resolver, the policy evaluation happens **before** the query is forwarded. If the policy blocks the domain, the resolver returns the configured response immediately.

```
VM query → Azure DNS → ruleset evaluation → [policy check] → block/pass
```

### Cache persistence (sticky block behavior)

Even when a policy blocks a domain, cached responses at the resolver or client may persist for their TTL. This leads to what practitioners call **sticky block behavior**:

1. Client resolves `app.internal.lab` → answer cached with TTL = 30s
2. Policy is applied: block `app.internal.lab`
3. Client queries again within TTL window → **still gets cached answer** (policy not evaluated for cached response)
4. Policy is removed
5. Client queries again → cached response (from step 3) may still be NXDOMAIN until its TTL expires

Key distinction:
- **Policy evaluation** happens at the resolver, on cache miss
- **Cache serving** bypasses policy evaluation entirely

### Proving the cache, not the policy

To isolate cache behavior:
- Use a **fresh random subdomain** each test run (guarantees a cache miss on first query)
- Use a **fresh VM** (no prior queries = no client-side cache)
- Watch the TTL window — Azure Private DNS default TTL is 10-300s depending on record type
- Ensure all queries go through the **same resolver path** (same inbound endpoint IP)

### Lab reference

[lab-008 StickyBlock mode](../../labs/lab-008-azure-dns-private-resolver/README.md#dns-security-policy--sticky-block) runs this test automatically:
- Seeds a test DNS record
- Applies a block (DNS Security Policy or forwarding rule redirect to RFC 5737 TEST-NET)
- Queries before/after/post-removal in a loop
- Emits structured evidence JSON to `.data/lab-008/test-results.json`

---

## Security Model: No Wildcard Deny

A common mistake when deploying DNS Private Resolver is adding a `'.'` (dot) forwarding rule to intercept all DNS traffic. **Do not do this.**

A wildcard `'.'` rule breaks Azure's internal DNS — platform services, metadata endpoint (`169.254.169.254`), and public internet resolution all stop working.

The correct approach (used in lab-008):
- Define explicit rules only for private domains you control (`internal.lab.`, `onprem.corp.`)
- All other queries flow through Azure DNS as normal
- Security boundary is enforced by zone visibility (zone linked only to hub) + ruleset scoping (ruleset linked only to spoke)

---

## VNet Link vs Ruleset Link

| Mechanism | What it does | Scope |
|-----------|-------------|-------|
| **VNet link** (on private zone) | Makes zone resolvable from linked VNet | Per-zone |
| **VNet link** (on forwarding ruleset) | Applies forwarding rules to VMs in that VNet | Per-ruleset |
| **auto-registration** | Auto-adds VM hostnames to zone as A records | Per-VNet-link |

---

## Troubleshooting Reference

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `NXDOMAIN` for private record | Zone not linked to VM's VNet | Add VNet link to zone |
| `NXDOMAIN` after resolver deploy | Ruleset not linked to spoke VNet | Link ruleset to spoke |
| `NXDOMAIN` across VNets | Rule target IP wrong | Check inbound endpoint IP matches rule target |
| Auto-registration not working | VNet link missing `registrationEnabled: true` | Update link in Bicep |
| VM not auto-registered | VM in wrong subnet | Subnet must be in the linked VNet |
| Azure DNS broken (public names fail) | Wildcard `'.'` rule in ruleset | Remove wildcard rule |
| Resolver endpoint fails to provision | Subnet delegated/NSG issue | Remove NSG, add delegation |
| `az dns-resolver` not found | CLI extension missing | `az extension add --name dns-resolver` |

---

## Region Support

DNS Private Resolver is generally available in:

| Region |
|--------|
| eastus |
| eastus2 |
| westus2 |
| centralus |
| northeurope |
| westeurope |

Private DNS Zones (without resolver) are available in all Azure regions.

---

## Labs in This Domain

| Lab | Focus | Cost |
|-----|-------|------|
| [lab-007](../../labs/lab-007-azure-dns-foundations/README.md) | Private DNS Zone, VNet link, auto-registration, static A record | ~$0.02/hr |
| [lab-008](../../labs/lab-008-azure-dns-private-resolver/README.md) | DNS Private Resolver, forwarding ruleset, cross-VNet resolution | ~$0.03/hr |

---

## References

- [Azure Private DNS Zones overview](https://docs.microsoft.com/azure/dns/private-dns-overview)
- [DNS Private Resolver overview](https://docs.microsoft.com/azure/dns/dns-private-resolver-overview)
- [DNS auto-registration](https://docs.microsoft.com/azure/dns/private-dns-autoregistration)
- [What is IP 168.63.129.16?](https://docs.microsoft.com/azure/virtual-network/what-is-ip-address-168-63-129-16)
- [DNS Forwarding Rulesets](https://docs.microsoft.com/azure/dns/private-resolver-endpoints-rulesets)
