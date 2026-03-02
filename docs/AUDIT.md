# Audit - Living Log

> Single source of truth for repository health, findings, and open issues.
> See [audit/AUDIT-REPORT.md](audit/AUDIT-REPORT.md) for the full v0.6.0 snapshot.

---

## Current Status

| Area | Status | Last Checked |
|------|--------|-------------|
| Security (secrets) | PASS - no secrets committed | 2026-03-02 |
| Azure setup flow | PASS - guided wizard in place | 2026-03-02 |
| AWS isolation | PASS - optional, flag-gated | 2026-03-02 |
| Lab scripts (PS 5.1) | PASS - no breaking syntax found | 2026-03-02 |
| Cost-check references | PASS - all billable lab READMEs updated | 2026-03-02 |
| Doc structure | PASS - canonical tree established | 2026-03-02 |
| Lab outputs.json | PARTIAL - schema defined; older labs partial | 2026-03-02 |
| inspect.ps1 coverage | PARTIAL - labs 001, 006 only | 2026-03-02 |

---

## Findings

### HIGH

| ID | Finding | File(s) | Status |
|----|---------|---------|--------|
| H-001 | Manual subs.json editing was required (no guided setup) | `setup.ps1`, `scripts/labs-common.ps1` | FIXED (2026-03-02) |
| H-002 | AWS checks ran by default, blocking Azure-only users | `setup.ps1` | FIXED (2026-03-02) |
| H-003 | Error messages pointed to non-existent `.\scripts\setup.ps1 -DoLogin` | `scripts/labs-common.ps1` | FIXED (2026-03-02) |

### MEDIUM

| ID | Finding | File(s) | Status |
|----|---------|---------|--------|
| M-001 | No single onboarding doc for Azure-only path | `docs/` | FIXED - added `docs/ops/ONBOARDING.md` (2026-03-02) |
| M-002 | Cost-check tool not referenced in lab READMEs | `labs/lab-00[1-6]/README.md` | FIXED (2026-03-02) |
| M-003 | Doc sprawl: 5 separate AWS docs with overlapping content | `docs/aws-*.md` | FIXED - merged to `docs/DOMAINS/aws-hybrid.md` (2026-03-02) |
| M-004 | No lab catalog with status/cost overview | `docs/` | FIXED - added `docs/LABS/README.md` (2026-03-02) |
| M-005 | `inspect.ps1` missing for labs 002, 003, 004, 005 | `labs/lab-00[2-5]/` | OPEN |
| M-006 | `outputs.json` schema partially implemented in older labs | `labs/lab-00[1-5]/` | OPEN |

### LOW

| ID | Finding | File(s) | Status |
|----|---------|---------|--------|
| L-001 | `git-&-github.md` is minimal / low-value | `docs/git-&-github.md` | MERGED to REFERENCE.md (2026-03-02) |
| L-002 | `setup-overview.md` duplicates ONBOARDING.md after update | `docs/setup-overview.md` | STUBBED (2026-03-02) |
| L-003 | `labs-config.md` duplicates ONBOARDING.md content | `docs/labs-config.md` | STUBBED (2026-03-02) |
| L-004 | Lab READMEs repeat vWAN concepts inline | `labs/lab-001,004,005,006/README.md` | PARTIAL - links added |

---

## Fix Log

### 2026-03-02 - Phase 0-5 UX Improvements (PR: claude/azure-lab-setup-uKSi2)

- Added `docs/ops/ONBOARDING.md` - Azure-only onboarding guide
- Rewrote `setup.ps1` - added `Invoke-SubsWizard`, `-ConfigureSubs`, `-SubscriptionId`, `-SubscriptionName` flags
- Changed default setup mode to Azure-only (AWS removed from default flow)
- Added `Test-SubsConfigValid` helper - checks for non-placeholder IDs
- Fixed all `.\scripts\setup.ps1 -DoLogin` references in `scripts/labs-common.ps1`
- Added `docs/ops/LAB-STANDARD.md` - lab interface contract
- Added `.\tools\cost-check.ps1` to cleanup sections of labs 001-006
- Updated `.data/subs.example.json` with `_schema_version` and `_instructions`
- Updated root `README.md` - 3-command quick start, Azure-only emphasis

### 2026-03-02 - Docs Reorganization (PR: claude/azure-lab-setup-uKSi2)

- Created canonical docs tree: `docs/README.md`, `docs/AUDIT.md`, `docs/REFERENCE.md`, `docs/CHANGELOG.md`
- Created `docs/DOMAINS/` with `vwan.md`, `aws-hybrid.md`, `observability.md`, `_template.md`
- Merged 5 AWS docs (`aws-*.md`) into `docs/DOMAINS/aws-hybrid.md`; original files stubbed
- Moved observability content to `docs/DOMAINS/observability.md`; original file stubbed
- Stubbed `docs/setup-overview.md` and `docs/labs-config.md` (superseded by ONBOARDING.md)
- Created `docs/LABS/README.md` - lab catalog with status table
- Created `docs/DECISIONS/ADR-000-template.md`
- Root `README.md` updated to link to `docs/README.md` as documentation entry point

---

## Drift Watchlist

Things that are correct today but tend to break over time without maintenance:

| Item | Risk | Watch For |
|------|------|-----------|
| `az account list` output format | Azure CLI version changes may alter JSON fields | If wizard fails to parse subscription list |
| Subscription wizard PS 5.1 compat | New code added to `setup.ps1` without PS 5.1 testing | Test on PS 5.1 after any setup.ps1 changes |
| Lab cost estimates | Azure pricing changes quarterly | Review estimates before major labs are run |
| APIPA address ranges in lab-003/005 | IP range changes would break BGP peering | These are hardcoded; document any changes |
| AWS SSO token expiry behavior | AWS may change default session durations | If auth failures increase, check token TTL |
| `_schema_version` in subs.json | If schema changes, migration logic needed | Update wizard when adding new fields |

---

## Next Actions

- [ ] **M-005**: Add `inspect.ps1` to labs 002, 003, 004, 005 (one per sprint)
- [ ] **M-006**: Align `outputs.json` schema across labs 001-005 per LAB-STANDARD.md
- [ ] Add `docs/DOMAINS/app-gateway.md` when lab-002 is expanded
- [ ] Add `docs/DOMAINS/bgp.md` for BGP concepts shared by labs 003, 005, 006
- [ ] Add ADR for APIPA address range allocation (why 169.254.21.x and 169.254.22.x)
- [ ] Add ADR for dual-instance VPN gateway behavior
- [ ] Validate `setup.ps1` against real PS 5.1 environment (currently verified by code review only)
