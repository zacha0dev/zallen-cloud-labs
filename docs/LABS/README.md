# Lab Catalog

> Full index of all labs in this repository. This is the canonical list of labs and costs;
> other docs link here. Costs are estimates at list price.
> "Validation" says how a lab proves itself: a standalone `inspect.ps1`, or checks in deploy Phase 5.
> For onboarding and setup, see [docs/ops/ONBOARDING.md](../ops/ONBOARDING.md).
> For the lab interface contract, see [docs/ops/LAB-STANDARD.md](../ops/LAB-STANDARD.md).

---

## Lab Index

| Lab | Goal | Cloud | Est. Cost | Key Prereq | Validation |
|-----|------|-------|-----------|------------|------------|
| [lab-000](../../labs/lab-000_resource-group/README.md) | Verify Azure setup; create RG + VNet baseline | Azure | Free | Azure CLI, `.\lab.ps1 -Setup` | Phase 5 checks |
| [lab-001](../../labs/lab-001-virtual-wan-hub-routing/README.md) | Deploy vWAN + hub, connect spoke VNet, learn hub routing basics | Azure | ~$0.26/hr | lab-000 passing | `inspect.ps1` |
| [lab-002](../../labs/lab-002-l7-fastapi-appgw-frontdoor/README.md) | L7 load balancing with App Gateway (Standard_v2) + Front Door | Azure | ~$0.31/hr | lab-000 passing | Phase 5 checks |
| [lab-003](../../labs/lab-003-vwan-aws-bgp-apipa/README.md) | Azure vWAN site-to-site (S2S) VPN to an AWS virtual private gateway, BGP over APIPA (169.254.x.x link-local) addresses | Azure + AWS | ~$0.71/hr | lab-001 + AWS setup | Phase 5 checks |
| [lab-004](../../labs/lab-004-vwan-default-route-propagation/README.md) | Prove how the default route (0.0.0.0/0) propagates to spokes in custom vs. Default route tables | Azure | ~$0.60/hr | lab-001 passing | Phase 5 checks |
| [lab-005](../../labs/lab-005-vwan-s2s-bgp-apipa/README.md) | Azure-only reference: dual-instance vWAN VPN with deterministic APIPA addressing | Azure | ~$0.61/hr | lab-001 passing | Phase 5 checks |
| [lab-006](../../labs/lab-006-vwan-spoke-bgp-router-loopback/README.md) | vWAN hub learns BGP from FRR router VM; loopback propagation | Azure | ~$0.37/hr | lab-001 + familiarity with BGP | `inspect.ps1` |
| [lab-007](../../labs/lab-007-azure-dns-foundations/README.md) | Azure Private DNS Zone, VNet link, auto-registration, static A record | Azure | ~$0.02/hr | lab-000 passing | Phase 5 checks |
| [lab-008](../../labs/lab-008-azure-dns-private-resolver/README.md) | DNS Private Resolver in hub; forwarding ruleset to spoke; DNS Security Policy blocking listed domains | Azure | ~$0.03/hr | lab-007 recommended | `inspect.ps1` |
| [lab-009](../../labs/lab-009-avnm-hub-spoke-global-mesh/README.md) | Azure Virtual Network Manager (AVNM) dual-region hub-spoke; script deploys two hub-spoke topologies; Global Mesh is a manual portal step | Azure | ~$0.01/hr | Azure CLI 2.51+ | `inspect.ps1` (mesh step is manual) |
| [lab-010](../../labs/lab-010-vwan-route-maps/README.md) | vWAN Route Maps: community tagging, route filtering, AS path prepend applied to hub connections | Azure | ~$0.26/hr | lab-001 passing, Azure CLI 2.54+ | `inspect.ps1` |
| [lab-011](../../labs/lab-011-vwan-p2s-s2s-firewall-split/README.md) | Can P2S use the hub Azure Firewall while S2S uses a spoke Azure Firewall when both share the Default route table? Measured with effective routes, a real P2S client and firewall logs | Azure | ~$2.26/hr | lab-001 passing, Azure CLI 2.54+ | `inspect.ps1` |

---

## Lab Contract

Every lab must implement:

| File | Required | Description |
|------|----------|-------------|
| `deploy.ps1` | Yes | Phases 0-6; accepts `-SubscriptionKey`, `-Location`, `-Force` |
| `destroy.ps1` | Yes | Idempotent cleanup; prints verification at end |
| `inspect.ps1` | Recommended | Post-deploy validation and route inspection |
| `README.md` | Yes | Goal, Architecture, Cost, Prereqs, Deploy, Validate, Destroy, Troubleshooting |
| `lab.config.example.json` | If needed | Lab-specific config template |

Full contract details: [docs/ops/LAB-STANDARD.md](../ops/LAB-STANDARD.md)

---

## Domain Map

| Labs | Primary Domain |
|------|---------------|
| lab-001, 003, 004, 005, 006, 010, 011 | [vWAN](../DOMAINS/vwan.md) |
| lab-002 | App Gateway + Front Door |
| lab-003 | [AWS Hybrid](../DOMAINS/aws-hybrid.md) |
| lab-007, lab-008 | [Azure DNS](../DOMAINS/dns.md) |
| lab-009 | Azure Virtual Network Manager (no domain page yet) |

---

## Run Order (Recommended for Learning)

1. **lab-000** - Free, ~20 seconds. Confirms your setup works.
2. **lab-001** - Introduces vWAN. Takes 15-25 min. Good first billable lab.
3. **lab-006** - Most complete lab. BGP, FRR, routing experiments.
4. **lab-004** or **lab-005** - Route propagation deep-dives.
5. **lab-002** - L7 LB if App Gateway is relevant to you.
6. **lab-003** - Only when you have AWS configured and need hybrid VPN.
7. **lab-007** - Azure DNS fundamentals. Private zones, VNet links, auto-registration. ~5-8 min.
8. **lab-008** - DNS Private Resolver. Cross-VNet forwarding, ruleset isolation. ~8-12 min.
9. **lab-009** - AVNM hub-spoke + Global Mesh. Near-free, CLI deploys infra, portal step enables cross-region mesh. ~8-12 min.
10. **lab-010** - vWAN Route Maps. Community tagging, route filtering, AS path prepend. Requires Azure CLI 2.54+. ~15-20 min.
11. **lab-011** - P2S + S2S on the Default route table with a hub firewall and a spoke firewall. The priciest lab (~$2.26/hr); deploy ~75-100 min, so plan a ~3 hour session.

**Always run `.\lab.ps1 -Destroy <lab-id>` after each lab session.**

---

## Cost Safety

Scan for leftover billable resources any time:

```powershell
.\lab.ps1 -Cost                        # all labs
.\lab.ps1 -Cost -Lab lab-004           # one lab
.\lab.ps1 -Cost -AwsProfile aws-labs   # include AWS (lab-003)
```

See [tools/README.md](../../tools/README.md) for full options.
