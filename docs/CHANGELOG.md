# Changelog

> Repository-level changes that matter for users and contributors.
> Code-level details are in git commit messages and `docs/AUDIT.md` fix log.

---

## [Unreleased / In Progress]

See [AUDIT.md](AUDIT.md) for current next actions.

---

## v0.7.0 - 2026-03-02 - Docs Reorganization + UX Improvements

### Added

- `docs/README.md` - Documentation navigation hub (all docs link from here)
- `docs/AUDIT.md` - Living audit log: findings, fix log, drift watchlist, next actions
- `docs/REFERENCE.md` - Shared quick-reference: BGP ASNs, APIPA ranges, cost safety, cleanup, PS 5.1 compat, git
- `docs/CHANGELOG.md` - This file
- `docs/DOMAINS/vwan.md` - Azure Virtual WAN concepts, routing, BGP, APIPA reference
- `docs/DOMAINS/aws-hybrid.md` - Single canonical AWS reference (merged from 5 separate docs)
- `docs/DOMAINS/observability.md` - 3-gate health model, per-lab validation, common commands
- `docs/DOMAINS/_template.md` - Template for adding new domain pages
- `docs/DECISIONS/ADR-000-template.md` - ADR template for future architecture decisions
- `docs/LABS/README.md` - Lab catalog: table of all labs with goal, cost, prereqs, status

### Changed

- Root `README.md` - Updated Quick Start links to point to `docs/README.md`
- `docs/setup-overview.md` - Stubbed; content superseded by `docs/ops/ONBOARDING.md`
- `docs/labs-config.md` - Stubbed; content superseded by `docs/ops/ONBOARDING.md`
- `docs/observability-index.md` - Stubbed; content moved to `docs/DOMAINS/observability.md`
- `docs/aws-setup.md` - Stubbed; content merged into `docs/DOMAINS/aws-hybrid.md`
- `docs/aws-account-setup.md` - Stubbed; content merged into `docs/DOMAINS/aws-hybrid.md`
- `docs/aws-cli-profile-setup.md` - Stubbed; content merged into `docs/DOMAINS/aws-hybrid.md`
- `docs/aws-identity-center-sso.md` - Stubbed; content merged into `docs/DOMAINS/aws-hybrid.md`
- `docs/aws-troubleshooting.md` - Stubbed; content merged into `docs/DOMAINS/aws-hybrid.md`
- `labs/lab-001,003,004,006/README.md` - Added links to domain docs (vWAN, observability)

---

## v0.6.0 - 2026-03-02 - Azure Setup UX Improvements

### Added

- `docs/ops/ONBOARDING.md` - Complete Azure-only onboarding guide (3-step quick start, troubleshooting, gitignore rationale)
- `docs/ops/LAB-STANDARD.md` - Lab interface contract (files, parameters, phases, outputs schema, README sections)
- `docs/audit/IMPLEMENTATION-PLAN.md` - Phase-by-phase record of changes made

### Changed

- `setup.ps1` - Added guided subscription wizard (`Invoke-SubsWizard`), new flags (`-ConfigureSubs`, `-SubscriptionId`, `-SubscriptionName`), AWS now requires explicit `-Aws` flag
- `scripts/labs-common.ps1` - Fixed error message paths from `.\scripts\setup.ps1 -DoLogin` to `.\setup.ps1 -ConfigureSubs`
- Root `README.md` - Rewritten with 3-command quick start, Azure-only emphasis, AWS as Advanced section
- `.data/subs.example.json` - Added `_schema_version` and `_instructions` fields
- `labs/lab-001` through `lab-006` `README.md` - Added `.\tools\cost-check.ps1` to Cleanup sections

### Fixed

- H-001: Manual subs.json editing requirement eliminated
- H-002: AWS checks no longer run by default for Azure-only users
- H-003: Error messages now point to correct setup command

---

## v0.5.x and Earlier

See git log for earlier changes: `git log --oneline`
