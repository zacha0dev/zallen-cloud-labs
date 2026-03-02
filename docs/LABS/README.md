# Lab Catalog

> Full index of all labs in this repository.
> For onboarding and setup, see [docs/ops/ONBOARDING.md](../ops/ONBOARDING.md).
> For the lab interface contract, see [docs/ops/LAB-STANDARD.md](../ops/LAB-STANDARD.md).

---

## Lab Index

| Lab | Goal | Cloud | Est. Cost | Key Prereq | Status |
|-----|------|-------|-----------|------------|--------|
| [lab-000](../../labs/lab-000_resource-group/README.md) | Verify Azure setup; create RG + VNet baseline | Azure | Free | Azure CLI, `setup.ps1 -Azure` | Stable |
| [lab-001](../../labs/lab-001-virtual-wan-hub-routing/README.md) | Deploy vWAN + hub, connect spoke VNet, learn hub routing basics | Azure | ~$0.26/hr | lab-000 passing | Stable |
| [lab-002](../../labs/lab-002-l7-fastapi-appgw-frontdoor/README.md) | L7 load balancing with App Gateway (Standard_v2) + Front Door | Azure | ~$0.30/hr | lab-000 passing | Stable |
| [lab-003](../../labs/lab-003-vwan-aws-bgp-apipa/README.md) | Azure vWAN S2S VPN to AWS VGW using BGP over APIPA | Azure + AWS | ~$0.70/hr | lab-001 + AWS setup | Stable |
| [lab-004](../../labs/lab-004-vwan-default-route-propagation/README.md) | Prove 0/0 route propagation behavior in custom vs. Default RTs | Azure | ~$0.60/hr | lab-001 passing | Stable |
| [lab-005](../../labs/lab-005-vwan-s2s-bgp-apipa/README.md) | Gold reference: dual-instance vWAN VPN with deterministic APIPA | Azure | ~$0.61/hr | lab-001 passing | Stable |
| [lab-006](../../labs/lab-006-vwan-spoke-bgp-router-loopback/README.md) | vWAN hub learns BGP from FRR router VM; loopback propagation | Azure | ~$0.37/hr | lab-001 + familiarity with BGP | Stable |
| [lab-007](../../labs/lab-007-azure-dns-foundations/README.md) | Azure Private DNS Zone, VNet link, auto-registration, static A record | Azure | ~$0.02/hr | lab-000 passing | Stable |
| [lab-008](../../labs/lab-008-azure-dns-private-resolver/README.md) | DNS Private Resolver in hub; forwarding ruleset to spoke; cross-VNet resolution; supports `-Mode Base\|StickyBlock\|ForwardingVariants` | Azure | ~$0.03/hr | lab-007 recommended | Stable |

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
| lab-001, 003, 004, 005, 006 | [vWAN](../DOMAINS/vwan.md) |
| lab-002 | App Gateway + Front Door |
| lab-003 | [AWS Hybrid](../DOMAINS/aws-hybrid.md) |
| lab-007, lab-008 | [Azure DNS](../DOMAINS/dns.md) |

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

**Always run `.\destroy.ps1` after each lab session.**

---

## Cost Safety

Run the cost audit tool any time to find leftover billable resources:

```powershell
.\tools\cost-check.ps1
```

With AWS (lab-003):
```powershell
.\tools\cost-check.ps1 -AwsProfile aws-labs
```

See [tools/README.md](../../tools/README.md) for full options.
