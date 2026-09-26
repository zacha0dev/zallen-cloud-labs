# Documentation Hub

> Navigation root for the **AI-Driven Cloud Labs** repository.
> Everything lives here or links from here.

---

## 1. Getting Started

| Resource | When to use |
|----------|-------------|
| [Onboarding Guide](ops/ONBOARDING.md) | **Start here** - Azure-only setup in 3 steps |
| [Lab Standard](ops/LAB-STANDARD.md) | Contributing a lab or understanding the deploy/destroy contract |

---

## 2. Labs

Eleven labs, lab-000 (free) to lab-010. Goals, costs, prerequisites and the recommended run
order live in one place: **[LABS/README.md](LABS/README.md)**.

To run them by prompt with Claude Code, see **[AGENTIC-OPS.md](AGENTIC-OPS.md)** and the
package in [`.claude/`](../.claude/README.md).

---

## 3. Domains

Conceptual and operational guides organized by technology area.

| Domain | Description |
|--------|-------------|
| [vWAN](DOMAINS/vwan.md) | Azure Virtual WAN concepts, routing, BGP, APIPA |
| [AWS Hybrid](DOMAINS/aws-hybrid.md) | AWS account, Identity Center, CLI profile, lab-003 setup, troubleshooting |
| [Azure DNS](DOMAINS/dns.md) | Private DNS zones, Private Resolver, forwarding rulesets, DNS Security Policy |
| [Observability](DOMAINS/observability.md) | 3-gate health model, validation patterns, what not to do |

Adding a new domain? Use [DOMAINS/_template.md](DOMAINS/_template.md).

---

## 4. Reference

Shared patterns and quick-reference material that applies across labs and domains.

| Reference | Description |
|-----------|-------------|
| [REFERENCE.md](REFERENCE.md) | BGP ASNs, cost safety, cleanup discipline, subscription schema, git workflow |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each version |

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
