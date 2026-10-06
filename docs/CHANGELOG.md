# Changelog

> Repository-level changes that matter for users and contributors.
> Code-level details are in git commit messages and `docs/AUDIT.md` fix log.

---

## [Unreleased / In Progress]

See [AUDIT.md](AUDIT.md) for current next actions.

### Added

- `labs/lab-011-vwan-p2s-s2s-firewall-split/` - vWAN hub with S2S and P2S on the Default route table, Azure Firewall in a spoke (VNet-connection static route) and in the hub. `scenario.ps1` switches Default static routes; `inspect.ps1` measures effective routes, a real OpenVPN P2S client's pushed routes, data-plane probes and firewall logs. Bicep compiles and the scripts were exercised against a mocked `az`; not yet deployed to Azure.

---

## v0.12.0 - 2026-09-26 - v2 Review Pass

A full review of scripts, docs and presentation. Nothing was deployed to verify these; every
`.ps1` parses under Windows PowerShell 5.1 and is ASCII-only.

### Fixed

- lab-004 `deploy.ps1` - `"~$0.50/hour"` threw under StrictMode before the DEPLOY prompt; existence checks now use the EAP toggle so a fresh subscription no longer throws; cancel throws like other labs; `-AdminPassword` optional (prompted securely)
- lab-008 `destroy.ps1` - used `--forwarding-ruleset-name` (wrong flag), so rules and links were silently skipped; now `--ruleset-name`, and PASS only on exit code 0
- Destroy scripts for labs 000-006 - idempotent (safe to re-run), and end with a real `az group exists` check instead of printing "Cleanup complete" after a timeout
- lab-003 `destroy.ps1` - no longer deletes the tracked `config.template.json`; StrictMode crash when declining AWS delete
- `tools/cost-check.ps1` - AWS tag filters passed as separate arguments; AWS errors reported as errors, not as "nothing found"
- Validation-phase checks in labs 000-006 and 010 report FAIL instead of throwing when a resource is missing
- Cost text: lab-003 and lab-005 said "2 scale units" (code uses 1); lab-002 Front Door re-priced (~$0.05/hr base), total ~$0.31/hr

### Changed

- All 11 labs tag through `Get-LabTags` / `Get-LabTagArgs` (labs 003, 005, 006 now get owner, environment and cost-center tags too)
- `lab.ps1` - lab-010 added to the catalog and run order; lab-003 cost ~$0.71/hr; `-Validate` alias for `-Inspect`; help no longer advertises removed lab-008 modes or research scenarios
- `scripts/update-labs.ps1` - lists and confirms before `git clean` removes untracked files (`-Force` to skip)
- Docs - `docs/LABS/README.md` is the one canonical lab/cost list; README rewritten around what the project shows; ONBOARDING and CONTRIBUTING use `lab.ps1`; AUDIT and CHANGELOG brought up to date; example hostnames and IPs use reserved documentation ranges
- `.claude/settings.json` - cloud-change guard also covers the PowerShell tool
- CLAUDE.md - lab-010 lessons (ARM error bodies by PS version, Route Maps circular dependency, hub connection PUT requirements)

### Removed

- Dead code: `.packages/`, `tools/update-azure-labs.ps1`, lab-004 `scripts/` and `infra/`, lab-006 `infra/`, lab-000 `lab.config.example.json` (none were referenced)

---

## v0.11.0 - 2026-09-26 - Claude Code Package for Agentic Ops

### Added

- `.claude/` - Claude Code package: 4 agents (orchestrator, measurer, records-librarian, claim-auditor), 7 skills (infra-lane, deploy-lane, tagging-as-addressing, measure-before-claiming, cost-guard, lab-authoring, session-closeout), 2 rules (safety, scope), 2 hooks (session-start briefing, cloud-change guard), `settings.json`, `setup.ps1`
- `docs/AGENTIC-OPS.md` - Guide: the problem it solves, 5-minute quickstart on lab-000, prompts, how to adapt it
- `examples/github-actions/infra-lane.yml` - Example workflow: what-if on pull request, apply after environment approval, OIDC sign-in
- `llms.txt`, `CITATION.cff` - Machine-readable summary and citation metadata

### Changed

- Root `README.md` - New one-line description, topics line, and a "Run It by Prompt" section
- `CLAUDE.md` - Pointer to `.claude/` and the guide

---

## v0.10.0 - 2026-04-06 - lab-010 vWAN Route Maps

### Added

- `labs/lab-010-vwan-route-maps/` - vWAN hub, two spokes and three route maps (community tagging inbound, route drop outbound, AS path prepend outbound); `deploy.ps1`, `destroy.ps1`, `inspect.ps1` (25c0e54)
- `scripts/labs-common.ps1` - Tagging helpers `Get-LabTags`, `Get-LabTagString`, `Get-LabTagArgs`; schema documented in `CLAUDE.md` and `docs/REFERENCE.md` (6f6b924, 2026-04-07)

### Fixed

- lab-010 route map and hub connection creation, reworked over several passes: ARM REST calls, `parameters` array shape, UTF-8 BOM in route map JSON, vWAN tier check, circular failure between connection and route map (2026-04-06 to 2026-04-07)
- `az` calls under PS 5.1 no longer fail on Python OpenSSL warnings written to stderr (b4ce286, cb72c2d)
- lab-006 FRR BGP: `ebgp-multihop`, cloud-init wait, run-command retry (8fe6753, 2026-04-08)

---

## v0.9.1 - 2026-03-31 - AFD Certificate Watch Tool

### Added

- `tools/Watch-AfdCertPropagation.ps1` - Standalone watcher that samples Azure Front Door edge IPs and reports which certificate each edge serves (2d7710b)

### Changed

- `tools/Watch-Endpoint.ps1` - DNS row shows the full IP list when the resolver returns several addresses

---

## v0.9.0 - 2026-03-31 - Endpoint Watch Tool

### Added

- `tools/Watch-Endpoint.ps1` - Standalone DNS / TCP / TLS / HTTP poller with an in-place report; no repo dependencies (322c4d7)
- `lab.ps1` - `-Watch` / `-WatchTarget` commands that call it

### Fixed

- `tools/Watch-Endpoint.ps1` - Three PS 5.1 StrictMode bugs (0ae1fc7)

---

## v0.8.3 - 2026-03-30 - lab-008 Stripped to a Deployment Reference

### Changed

- lab-008 now deploys DNS Private Resolver, forwarding ruleset and DNS Security Policy, checks the resources exist, and stops; the configuration is explored in the portal (cfba7eb, 4db69b2, af9127c)

### Removed

- lab-008 test harnesses: `scripts/test-dns.ps1`, `test-forwarding-variants.ps1`, `test-stickyblock.ps1`
- lab-008 `-Mode` (StickyBlock / ForwardingVariants) and `-SkipTests`, live VM DNS validation, log files and the region allowlist
- lab-008 `research/cache-recovery.ps1`, the only research scenario. The `-Research` command stayed in `lab.ps1` with no scenarios left to run

---

## v0.8.2 - 2026-03-30 - lab-008 DNS Security Policy

### Added

- lab-008 DNS Security Policy: resolver policy and domain lists that block `blocked.lab.` and `malware.internal.lab.` from the spoke VNet, with inspect and destroy support (f8f6ccf)

---

## v0.8.1 - 2026-03-29 - lab-008 Validation Fixes

### Added

- `labs/lab-008-azure-dns-private-resolver/inspect.ps1` - Fast post-deploy check (75e88ff, 2026-03-30)

### Fixed

- lab-008 VM run-command DNS validation: retries, agent wait, `getent hosts` in place of `nslookup`, corrected `az dns-resolver` flags (2026-03-29 to 2026-03-30)

---

## v0.8.0 - 2026-03-29 - New Labs, lab.ps1 CLI, Research Mode

> The labs and CLI below landed between 2026-03-02 and 2026-03-29 while `VERSION` still read 0.7.0; the bump to 0.8.0 (414ab18) covers them.

### Added

- `labs/lab-007-azure-dns-foundations/` and `labs/lab-008-azure-dns-private-resolver/` (28f8c6c, 2026-03-02); lab-008 gained Base / StickyBlock / ForwardingVariants modes (d4c9080), removed in v0.8.3
- `labs/lab-009-avnm-hub-spoke-global-mesh/` - AVNM dual-region hub-spoke plus Global Mesh (d9e4474, 2026-03-23)
- `lab.ps1` - Single CLI for list, deploy, destroy, inspect, cost, `-Settings` and `-Update` (b0626c1 and follow-ups, 2026-03-29)
- `lab.ps1 -Research` - Runs scenario scripts from `labs/<lab>/research/` in the foreground or as background jobs (b238d70)
- `CLAUDE.md` - Session context, PS 5.1 rules learned from fixes, README maintenance and versioning rules

### Fixed

- PS 5.1 parse and error-handling bugs across labs (em-dashes in strings, `Join-Path` with three arguments, `ErrorActionPreference` on `az` existence checks)
- `scripts/update-labs.ps1` detects `origin/main` when the local branch is `master` (aca6aaf)

---

## v0.7.0 - 2026-03-02 - Docs Reorganization, Cleanup, Rename + CONTRIBUTING.md

> `VERSION` went from 0.6.0 to 0.7.0 in a3b8efb. That commit message says "v0.7.1", but the file never held 0.7.1, so the cleanup that was listed here as v0.7.1 is folded into this entry.

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
- `CONTRIBUTING.md` - AI-driven IaC workflow story: 6-step cycle, prompting patterns, CLAUDE.md guide, two paths (fork vs. fresh repo)

### Changed

- Project renamed from "Zallen Cloud Labs" to **AI-Driven Cloud Labs** (`README.md`, `docs/README.md`)
- Root `README.md` - Quick Start links point to `docs/README.md`; added "Why This Exists" and "Want to Build Your Own Labs?" sections
- `labs/lab-001,003,004,006/README.md` - Added links to domain docs (vWAN, observability)
- `scripts/aws/aws-common.ps1` - Fixed 6 stale doc refs → `docs/DOMAINS/aws-hybrid.md`
- `scripts/labs-common.ps1` - Fixed stale `docs/labs-config.md` refs → `docs/REFERENCE.md`
- `docs/ops/ONBOARDING.md` - Fixed `aws-setup.md` link → `docs/DOMAINS/aws-hybrid.md`
- `labs/lab-000,004,005` READMEs / walkthrough - Fixed `.\scripts\setup.ps1 -DoLogin` → `.\setup.ps1 -ConfigureSubs`

### Removed

Stubbed first, then deleted in the same release:

- `docs/aws-setup.md`, `docs/aws-account-setup.md`, `docs/aws-cli-profile-setup.md`, `docs/aws-identity-center-sso.md`, `docs/aws-troubleshooting.md` (canonical content in `docs/DOMAINS/aws-hybrid.md`)
- `docs/setup-overview.md` and `docs/labs-config.md` (canonical content in `docs/ops/ONBOARDING.md`)
- `docs/observability-index.md` (canonical content in `docs/DOMAINS/observability.md`)
- `docs/git-&-github.md` (low-value; content merged into `docs/REFERENCE.md`)

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
