# Audit - Living Log

> Single source of truth for repository health, findings, and open issues.
> See [audit/AUDIT-REPORT.md](audit/AUDIT-REPORT.md) for the historical v0.6.0 snapshot (2026-03).

---

## Current Status

Last checked 2026-09-26 against the working tree (VERSION 0.11.0).

| Area | Status | Last Checked |
|------|--------|-------------|
| Security (secrets) | PASS - `git grep` for GUIDs finds only placeholder and example IDs | 2026-09-26 |
| Azure setup flow | PASS - `Invoke-SubsWizard` still in `setup.ps1` | 2026-09-26 |
| AWS isolation | PASS - AWS setup still gated behind `setup.ps1 -Aws` | 2026-09-26 |
| Lab scripts (PS 5.1) | PASS - all 47 `.ps1` files parse under Windows PowerShell 5.1; no en/em dashes in any `.ps1` (parse check only, not a run) | 2026-09-26 |
| Cost-check references | PARTIAL - billable labs 001-007 and 009 cite `cost-check.ps1`; lab-008 and lab-010 READMEs do not (L-007) | 2026-09-26 |
| Doc structure | PASS - canonical tree in place | 2026-09-26 |
| Stale links / stub docs | PASS - no broken relative links in `docs/` or `labs/` Markdown (placeholders in `docs/DOMAINS/_template.md` aside) | 2026-09-26 |
| Lab outputs.json | PARTIAL - all 11 labs write one; lab-004 writes to its own `outputs/` folder instead of `.data/lab-004/` | 2026-09-26 |
| inspect.ps1 coverage | PARTIAL - labs 001, 006, 008, 009, 010; missing for 000, 002, 003, 004, 005, 007 (M-007) | 2026-09-26 |
| Region allowlist (Phase 0) | PARTIAL - missing in labs 004 and 008 (M-008) | 2026-09-26 |

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
| M-002 | Cost-check tool not referenced in lab READMEs | `labs/lab-00[1-6]/README.md` | FIXED for labs 001-006 (2026-03-02); newer gaps tracked as L-007 |
| M-003 | Doc sprawl: 5 separate AWS docs with overlapping content | `docs/aws-*.md` | FIXED - merged to `docs/DOMAINS/aws-hybrid.md` (2026-03-02) |
| M-004 | No lab catalog with status/cost overview | `docs/` | FIXED - added `docs/LABS/README.md` (2026-03-02) |
| M-005 | `inspect.ps1` missing for labs 002, 003, 004, 005 | `labs/lab-00[2-5]/` | SUPERSEDED by M-007 (2026-09-26) |
| M-006 | `outputs.json` schema partially implemented in older labs | `labs/lab-00[1-5]/` | OPEN - lab-004 also writes outside `.data/` (checked 2026-09-26) |
| M-007 | `inspect.ps1` missing for labs 000, 002, 003, 004, 005, 007 | `labs/lab-000_resource-group/`, `labs/lab-00[2-5]-*/`, `labs/lab-007-*/` | OPEN (2026-09-26) |
| M-008 | No region allowlist in Phase 0. lab-004 never had one; lab-008 lost it when `deploy.ps1` was simplified (4db69b2). lab-003 does have one. | `labs/lab-004-*/deploy.ps1`, `labs/lab-008-*/deploy.ps1` | OPEN (2026-09-26) |

### LOW

| ID | Finding | File(s) | Status |
|----|---------|---------|--------|
| L-001 | `git-&-github.md` is minimal / low-value | `docs/git-&-github.md` | DELETED (2026-03-02) |
| L-002 | `setup-overview.md` duplicates ONBOARDING.md after update | `docs/setup-overview.md` | DELETED (2026-03-02) |
| L-003 | `labs-config.md` duplicates ONBOARDING.md content | `docs/labs-config.md` | DELETED (2026-03-02) |
| L-004 | Lab READMEs repeat vWAN concepts inline | `labs/lab-001,004,005,006/README.md` | PARTIAL - labs 001, 004, 006 link `DOMAINS/vwan.md`; lab-005 does not (checked 2026-09-26) |
| L-005 | Duplicate helpers. `.packages/` (5 scripts) is referenced only by its own files. `tools/update-azure-labs.ps1` is referenced only by itself, while `setup.ps1` and `lab.ps1` call `scripts/update-labs.ps1`. | `.packages/`, `tools/update-azure-labs.ps1`, `scripts/update-labs.ps1` | OPEN (2026-09-26) |
| L-006 | lab-000 folder uses an underscore (`lab-000_resource-group`); every other lab uses hyphens | `labs/lab-000_resource-group/` | OPEN (2026-09-26) |
| L-007 | lab-008 and lab-010 READMEs do not mention `tools/cost-check.ps1` | `labs/lab-008-*/README.md`, `labs/lab-010-*/README.md` | OPEN (2026-09-26) |
| L-008 | `lab.ps1 -Research` has no scenarios to run since lab-008's `research/` folder was removed (cfba7eb) | `lab.ps1` | OPEN (2026-09-26) |

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

### 2026-03-02 - Cleanup, Rename + CONTRIBUTING.md (PR: claude/azure-lab-setup-uKSi2)

- Renamed project from "Zallen Cloud Labs" to "AI-Driven Cloud Labs" (`README.md`, `docs/README.md`)
- Deleted 9 stale/stub files: `docs/aws-*.md` (5), `docs/setup-overview.md`, `docs/labs-config.md`, `docs/observability-index.md`, `docs/git-&-github.md`
- Fixed remaining `.\scripts\setup.ps1 -DoLogin` refs in `lab-000/README.md`, `lab-005/README.md`, `lab-004/docs/walkthrough.md`
- Fixed stale doc refs in `scripts/aws/aws-common.ps1` (6 paths → `docs/DOMAINS/aws-hybrid.md`)
- Fixed stale `docs/labs-config.md` refs in `scripts/labs-common.ps1` → `docs/REFERENCE.md`
- Fixed `docs/ops/ONBOARDING.md` line 137 link (`aws-setup.md` → `DOMAINS/aws-hybrid.md`)
- Added `CONTRIBUTING.md` - AI-driven IaC workflow story, prompting patterns, CLAUDE.md guide
- Bumped `VERSION` to `0.7.0`

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

- [ ] **M-007**: Add `inspect.ps1` to labs 000, 002, 003, 004, 005, 007 (as time allows)
- [ ] **M-008**: Add a Phase 0 region allowlist to labs 004 and 008
- [ ] **M-006**: Align `outputs.json` schema across labs 001-005 per LAB-STANDARD.md
- [ ] **L-005**: Remove or document `.packages/` and `tools/update-azure-labs.ps1`
- [ ] **L-007**: Add the cost-check step to lab-008 and lab-010 READMEs
- [ ] Add `docs/DOMAINS/app-gateway.md` when lab-002 is expanded
- [ ] Add `docs/DOMAINS/bgp.md` for BGP concepts shared by labs 003, 005, 006
- [ ] Add ADR for APIPA address range allocation (why 169.254.21.x and 169.254.22.x)
- [ ] Add ADR for dual-instance VPN gateway behavior
- [ ] Validate `setup.ps1` against real PS 5.1 environment (currently verified by code review only)
