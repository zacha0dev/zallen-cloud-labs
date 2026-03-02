# Documentation Hub

> Navigation root for the `zallen-cloud-labs` repository.
> Everything lives here or links from here.

---

## 1. Getting Started

| Resource | When to use |
|----------|-------------|
| [Onboarding Guide](ops/ONBOARDING.md) | **Start here** - Azure-only setup in 3 steps |
| [Lab Standard](ops/LAB-STANDARD.md) | Contributing a lab or understanding the deploy/destroy contract |

---

## 2. Labs

| Lab | Description | Cloud | Est. Cost |
|-----|-------------|-------|-----------|
| [lab-000](../labs/lab-000_resource-group/README.md) | Resource Group + VNet baseline | Azure | Free |
| [lab-001](../labs/lab-001-virtual-wan-hub-routing/README.md) | vWAN hub routing | Azure | ~$0.26/hr |
| [lab-002](../labs/lab-002-l7-fastapi-appgw-frontdoor/README.md) | App Gateway + Front Door | Azure | ~$0.30/hr |
| [lab-003](../labs/lab-003-vwan-aws-bgp-apipa/README.md) | vWAN to AWS VPN (BGP/APIPA) | Azure + AWS | ~$0.70/hr |
| [lab-004](../labs/lab-004-vwan-default-route-propagation/README.md) | vWAN default route propagation | Azure | ~$0.60/hr |
| [lab-005](../labs/lab-005-vwan-s2s-bgp-apipa/README.md) | vWAN S2S BGP/APIPA reference | Azure | ~$0.61/hr |
| [lab-006](../labs/lab-006-vwan-spoke-bgp-router-loopback/README.md) | vWAN spoke BGP router + loopback | Azure | ~$0.37/hr |

Full catalog with prereqs and status: [LABS/README.md](LABS/README.md)

---

## 3. Domains

Conceptual and operational guides organized by technology area.

| Domain | Description |
|--------|-------------|
| [vWAN](DOMAINS/vwan.md) | Azure Virtual WAN concepts, routing, BGP, APIPA |
| [AWS Hybrid](DOMAINS/aws-hybrid.md) | AWS account, Identity Center, CLI profile, lab-003 setup, troubleshooting |
| [Observability](DOMAINS/observability.md) | 3-gate health model, validation patterns, what not to do |

Adding a new domain? Use [DOMAINS/_template.md](DOMAINS/_template.md).

---

## 4. Reference

Shared patterns and quick-reference material that applies across labs and domains.

| Reference | Description |
|-----------|-------------|
| [REFERENCE.md](REFERENCE.md) | BGP ASNs, cost safety, cleanup discipline, subscription schema, git workflow |

---

## 5. Audit

Current health, findings, and open issues for the repository.

| Resource | Description |
|----------|-------------|
| [AUDIT.md](AUDIT.md) | **Living audit** - current findings, fix log, drift watchlist, next actions |
| [audit/AUDIT-REPORT.md](audit/AUDIT-REPORT.md) | Full v0.6.0 snapshot audit (historical reference) |
| [audit/IMPLEMENTATION-PLAN.md](audit/IMPLEMENTATION-PLAN.md) | Phase 0-5 UX improvement record |

---

## 6. Decisions

Architecture Decision Records (ADRs) for significant choices made in this repository.

| ADR | Decision |
|-----|----------|
| [ADR-000 Template](DECISIONS/ADR-000-template.md) | How to write ADRs |

---

## Maintenance Rule

**Every doc must either be linked from this file or be a redirect stub.**

If you add a doc, add it here. If you move a doc, leave a stub with a redirect note.
