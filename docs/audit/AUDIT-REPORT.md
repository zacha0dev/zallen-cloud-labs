# Repository Audit Report

**Date:** 2026-03-02
**Repo:** `zacha0dev/zallen-cloud-labs`
**Version:** 0.6.0
**Scope:** Full repository — labs, scripts, tooling, documentation, security posture
**Audience:** Public — safe to share with any engineer, vendor-neutral, no internal references

---

## Executive Summary

- **What it is:** A personal hands-on cloud-networking lab collection focused on Azure Virtual WAN (vWAN), BGP routing, hybrid cloud connectivity, and Layer-7 load balancing. One lab covers Azure–AWS hybrid VPN via BGP over APIPA.
- **Who it's for:** Cloud/network engineers learning Azure networking from first principles, or those validating vWAN routing behavior in a reproducible, cost-safe sandbox.
- **Current maturity:** Functional and deployable (v0.6.0). Six substantive labs plus a baseline. Platform scripting is solid. Documentation is above average for a personal lab repo but has notable gaps in consistency.
- **Public-safety posture:** Good. Gitignore patterns are thorough; all templates use placeholder GUIDs; no customer data or internal references found in any tracked file.
- **Top risks:** Naming inconsistency in lab-000 (underscore vs. hyphen), missing `inspect.ps1` in most labs, stale path references in docs, Bicep IaC only partially adopted, no cross-lab dependency documentation, and no CI pipeline.
- **Cost posture:** Honest and visible in every lab README. The `cost-check.ps1` tool closes the loop. No issues found.
- **PowerShell 5.1 hardening:** Lab-006 is fully hardened; earlier labs may have partial coverage. The common library (`labs-common.ps1`) applies the key mitigations.
- **Key wins:** Phased deployment pattern, idempotent redeploy support, `[PASS]/[FAIL]` validation gates, and a shared helpers library are all well-executed.
- **Key gaps:** No standard script interface enforced across all labs; lab-000 naming anomaly; no required `inspect.ps1`; docs reference nonexistent `run.ps1` and `scripts/setup.ps1 -DoLogin`; Bicep IaC exists only in labs 004 and 006.
- **Recommended first action:** Standardize the per-lab interface (deploy / destroy / inspect) and enforce it via a lab README template before adding more labs.

---

## Top Findings

| Severity | ID | Finding |
|----------|----|---------|
| [HIGH] | F-01 | `lab-000` folder name uses underscore (`lab-000_resource-group`) while all other labs use hyphens (`lab-001-...`). This breaks any glob/automation that assumes a consistent pattern. |
| [HIGH] | F-02 | `docs/setup-overview.md` references `.\run.ps1 status` (line 96) — this file does not exist. Engineers following this guide will immediately fail. |
| [HIGH] | F-03 | `docs/setup-overview.md` references `.\validate.ps1` per-lab (line 102) — no lab exposes this entry point; validation is embedded inside `deploy.ps1` Phase 5. |
| [HIGH] | F-04 | `docs/setup-overview.md` references `.\scripts\setup.ps1 -DoLogin` (line 99) — `setup.ps1` lives at repo root, not `scripts/`; the `-DoLogin` flag is on `labs-common.ps1:Ensure-AzureAuth` but not exposed as a root `setup.ps1` parameter. |
| [MED] | F-05 | `inspect.ps1` only exists in labs 001 and 006. Labs 002–005 have no inspection entry point; engineers must compose ad-hoc `az` commands, negating the "observable by default" goal. |
| [MED] | F-06 | No Bicep/IaC source in labs 000–003, 005. Labs 001–003 deploy purely via inline `az` CLI calls in PowerShell. This makes diff-based review and ARM what-if analysis impossible for those labs. |
| [MED] | F-07 | Lab-005 README says "Validate customer configurations" and "Train on vWAN S2S architecture." While harmless in context, language like "customer configurations" can blur the public/internal line. Recommend rewording to "validate your own VPN configurations." |
| [MED] | F-08 | `outputs.json` written to `.data/` by labs 000 and 006 contains `subscriptionId` and `subscriptionName`. The `.gitignore` pattern `.data/**/outputs.json` correctly excludes this — but the pattern is on line 23 while the template exception on line 11 (`!.data/lab-003/`) creates a subtle conflict risk if new lab-specific subdirs are added without matching excludes. |
| [MED] | F-09 | `tools/update-azure-labs.ps1` and `scripts/update-labs.ps1` both appear to serve an "update check" role but are separate files with unclear ownership split. No documentation explains which to use when. |
| [LOW] | F-10 | `lab-000` README footer references `.\scripts\setup.ps1 -DoLogin` (Troubleshooting section, line 117) — same broken path as F-04. |
| [LOW] | F-11 | `lab-001` README validation snippet (line 116) embeds a literal `<sub>` placeholder in the `az network vhub get-effective-routes` command. New engineers will copy-paste this and fail silently. |
| [LOW] | F-12 | AWS region hardcoded to `us-east-2` in multiple places (`cost-check.ps1`, `setup.ps1`, lab-003 README). No single source of truth. |
| [LOW] | F-13 | No `CHANGELOG.md` or release notes. The `VERSION` file shows `0.6.0` but there is no history of what changed between versions. |
| [LOW] | F-14 | Lab-004 Bicep (`infra/main.bicep`) deploys 7 VMs with password auth. The `adminPassword` parameter is marked `@secure()` which is correct, but there is no NSG on the spoke subnets and no guidance on SSH/RDP access patterns. |
| [LOW] | F-15 | `lab-006/docs/audit.md` is an excellent internal audit checklist but reads as a development working document, not user-facing docs. It could confuse engineers who find it. Recommend renaming or moving to a `docs/dev/` subdirectory. |

---

## Repo Architecture Map

```
zallen-cloud-labs/
├── .data/                      # User-local config (all gitignored except templates)
│   ├── subs.example.json       # Azure subscription template (placeholder GUIDs only)
│   ├── accounts.azure.template.json
│   ├── accounts.aws.template.json
│   └── lab-003/
│       └── config.template.json
├── .packages/                  # Internal helper scripts (dot-sourced by labs)
│   ├── deploy.ps1              # Shared deploy helper (unclear ownership — see F-09)
│   ├── destroy.ps1
│   ├── get-sub.ps1
│   ├── set-sub.ps1
│   └── setup.ps1
├── docs/                       # Platform-level documentation
│   ├── setup-overview.md       # Main onboarding doc (has stale references — F-02,F-03,F-04)
│   ├── labs-config.md          # subs.json config guide
│   ├── aws-setup.md            # AWS CLI + SSO setup guide
│   ├── aws-account-setup.md
│   ├── aws-cli-profile-setup.md
│   ├── aws-identity-center-sso.md
│   ├── aws-troubleshooting.md
│   ├── git-&-github.md
│   └── observability-index.md
├── labs/
│   ├── lab-000_resource-group/  # NAMING ANOMALY: underscore (F-01)
│   ├── lab-001-virtual-wan-hub-routing/
│   ├── lab-002-l7-fastapi-appgw-frontdoor/
│   ├── lab-003-vwan-aws-bgp-apipa/
│   ├── lab-004-vwan-default-route-propagation/  # Has Bicep IaC under infra/
│   ├── lab-005-vwan-s2s-bgp-apipa/
│   └── lab-006-vwan-spoke-bgp-router-loopback/  # Most mature: Bicep + inspect.ps1 + audit.md
├── scripts/
│   ├── labs-common.ps1         # Shared PowerShell library (well-written)
│   ├── update-labs.ps1         # Update checker (called by setup.ps1)
│   └── aws/
│       ├── aws-common.ps1
│       └── setup-aws.ps1
├── tools/
│   ├── cost-check.ps1          # Read-only cost auditor (excellent)
│   ├── update-azure-labs.ps1   # Duplicate update script? (F-09)
│   └── README.md
├── setup.ps1                   # Root entry point (well-structured)
├── .gitignore                  # Thorough (minor ordering risk — F-08)
├── VERSION                     # Semver string only (no changelog — F-13)
├── README.md                   # Good quick-start
└── LICENSE
```

### Folder Purpose Summary

| Folder | Purpose | Risk/Notes |
|--------|---------|------------|
| `.data/` | User-local secrets and runtime state. Gitignored. | Safe. Templates use placeholder GUIDs only. |
| `.packages/` | Internal helper scripts. Not directly user-facing. | Purpose overlaps with `scripts/`. Needs rationalization. |
| `docs/` | Platform-level onboarding and reference docs. | Good coverage; has stale cross-references (F-02–F-04). |
| `labs/` | Lab folders — primary content. | Naming inconsistency in lab-000 (F-01). |
| `scripts/` | Shared automation library and update checker. | `labs-common.ps1` is high quality. |
| `tools/` | End-user utilities (cost check, update). | `cost-check.ps1` is excellent. Duplicate update script unclear. |

---

## Lab Catalog Review

| Lab | Name | Cloud | Cost/hr | Deploy | Destroy | Inspect | Bicep/IaC | Doc Quality |
|-----|------|-------|---------|--------|---------|---------|-----------|-------------|
| 000 | Resource Group + VNet Baseline | Azure | Free | ✅ | ✅ | ❌ | ❌ | Good |
| 001 | Virtual WAN Hub Routing | Azure | ~$0.26 | ✅ | ✅ | ✅ | ❌ | Good |
| 002 | App Gateway + Front Door | Azure | ~$0.30 | ✅ | ✅ | ❌ | ❌ | Good |
| 003 | vWAN ↔ AWS VPN (BGP/APIPA) | Azure+AWS | ~$0.71 | ✅ | ✅ | ❌ | ❌ | Good + extras |
| 004 | vWAN Default Route Propagation | Azure | ~$0.60 | ✅ | ✅ | ❌ | ✅ (partial) | Good |
| 005 | vWAN S2S BGP/APIPA Reference | Azure | ~$0.61 | ✅ | ✅ | ❌ | ❌ | Excellent |
| 006 | Spoke BGP Router + Loopback | Azure | ~$0.37 | ✅ | ✅ | ✅ | ✅ (modular) | Excellent |

### Lab-by-Lab Notes

**Lab 000 — Resource Group + VNet Baseline**
- Goal: Verify Azure setup; demonstrate phased deploy pattern.
- Entry: `deploy.ps1`, `destroy.ps1`. No `inspect.ps1`.
- Outputs: `.data/lab-000/outputs.json` (subscription ID, VNet info).
- Cost: Free.
- Idempotency: Good — checks for existing RG and VNet before creating.
- Known issue: Folder name uses underscore (`lab-000_resource-group`) — inconsistent with all other labs (F-01). Troubleshooting section references broken `scripts/setup.ps1 -DoLogin` path (F-10).

**Lab 001 — Virtual WAN Hub Routing**
- Goal: Learn vWAN + vHub topology, spoke VNet connections, effective routes.
- Architecture: 1 vWAN → 1 vHub (10.60.0.0/24) → 1 spoke VNet → 1 Ubuntu VM.
- Entry: `deploy.ps1`, `destroy.ps1`, `inspect.ps1`.
- Inputs: `subs.json` (SubscriptionKey), Location, AdminPassword.
- Cost: ~$0.26/hr (~$6.25/day). Well documented.
- Idempotency: Phased; resume support present.
- Known issue: Validation snippet in README embeds literal `<sub>` placeholder (F-11). vHub provisioning can take 10–20 min; no polling timeout documented in README (though likely in deploy.ps1).

**Lab 002 — App Gateway + Front Door (L7 Load Balancing)**
- Goal: Deploy a FastAPI VM behind App Gateway and Azure Front Door; learn L7 LB and health probes.
- Architecture: Internet → Front Door (Standard) → App Gateway (Standard_v2) → FastAPI VM (port 8000) in VNet 10.72.0.0/16.
- Entry: `deploy.ps1`, `destroy.ps1`, `allow-myip.ps1` (NSG SSH helper). No `inspect.ps1`.
- Extras: `agw.json` (gateway config), `rc.sh` (bash helper for curl tests).
- Cost: ~$0.30/hr.
- Idempotency: Phased.
- Known issue: No `inspect.ps1` to query backend health, probe state, or Front Door routing. `allow-myip.ps1` pattern is a reasonable workaround for SSH access but should be documented clearly as "temporary access only."

**Lab 003 — vWAN ↔ AWS VPN (BGP over APIPA)**
- Goal: Prove Azure vWAN dual-instance VPN behavior with deterministic APIPA /30 allocations terminating on AWS VGW. Cross-cloud hybrid connectivity.
- Architecture: Azure vWAN hub (centralus) → S2S VPN Gateway (2 instances, ASN 65515) ↔ 4 IPsec tunnels ↔ AWS VGW (ASN 65001) with 2 CGWs representing each Azure instance. APIPA ranges 169.254.21.x (Instance 0) and 169.254.22.x (Instance 1).
- Entry: `deploy.ps1 -AwsProfile aws-labs`, `destroy.ps1 -AwsProfile aws-labs`. No `inspect.ps1`.
- Inputs: `subs.json`, `.data/lab-003/config.json` (from template), AWS profile, AWS region.
- Outputs: `.data/lab-003/` (runtime state).
- Cost: ~$0.71/hr (~$17/day). Highest cost lab.
- Idempotency: "Fail-forward" pattern; phases are individually resumable.
- Known issue: No `inspect.ps1`; VPN status requires manual `az` and `aws` CLI commands. Phase ordering is complex (5 → 5b); this non-standard numbering may confuse readers. `-AlternateApipa` switch is well-documented.

**Lab 004 — vWAN Default Route Propagation**
- Goal: Prove that static 0.0.0.0/0 routes in a custom route table only propagate to explicitly associated VNets — not to the Default RT or cross-hub.
- Architecture: 1 vWAN → 2 vHubs (Hub A: 10.100.0.0/24, Hub B: 10.101.0.0/24) → 7 spoke VNets + 1 FW VNet → 7 VMs. Custom RT (`rt-fw-default`) on Hub A with 0/0 → VNet-FW connection.
- Entry: `deploy.ps1`, `destroy.ps1`. Bicep IaC in `infra/`. Separate `scripts/` subfolder (deploy.ps1, destroy.ps1, validate.ps1).
- Cost: ~$0.60/hr (~$14.40/day). Second-highest.
- Idempotency: Phased.
- Known issue: Directory structure inconsistency — lab has both a root `deploy.ps1` and a `scripts/deploy.ps1`. Unclear which is canonical. No `inspect.ps1` at root. Lab-004's Bicep deploys VMs without subnet-level NSGs (F-14). The `scripts/validate.ps1` script appears as a standalone validator but is not linked from the README.

**Lab 005 — vWAN S2S BGP/APIPA (Azure Reference)**
- Goal: Reference implementation proving Azure vWAN S2S VPN dual-instance behavior with deterministic APIPA /30 allocations using placeholder sites (no real peer). All Azure, no AWS.
- Architecture: 1 vWAN → 1 vHub → 1 S2S VPN Gateway (2 instances) → 4 VPN Sites → 8 links. APIPA pattern: 169.254.21.x = Instance 0, 169.254.22.x = Instance 1.
- Entry: `deploy.ps1`, `destroy.ps1 [-Force] [-KeepLogs]`.
- Inputs: `subs.json`, Location, Owner.
- Cost: ~$0.61/hr.
- Idempotency: Strong; "resume-safe" stated and implemented.
- Lab-005 self-identifies as a public-safe gold reference. Well-documented. README mentions "Validate customer configurations" (F-07) — recommend rewording.

**Lab 006 — vWAN Spoke BGP Router + Loopback (Most Mature)**
- Goal: Prove a vHub learns BGP routes from a FRR (Free Range Routing) router VM and propagates them to connected spokes. Also tests loopback prefix behavior (inside-VNet vs outside-VNet).
- Architecture: 1 vWAN → 1 vHub → 2 spoke VNets (A: BGP-peered, B: control) → 3 VMs (Router with 2 NICs + 2 client VMs). Router runs FRR with loopback interfaces. BGP peering: vHub ↔ Router (ASN 65100).
- Entry: `deploy.ps1`, `destroy.ps1`, `inspect.ps1`. Bicep IaC in `infra/modules/`.
- Extras: `scripts/router/` — cloud-init YAML, FRR config template, bootstrap scripts.
- Inputs: `subs.json`, `lab.config.example.json` (copy to `lab.config.json`).
- Outputs: `.data/lab-006/outputs.json` and diagnostic JSON files.
- Cost: ~$0.37/hr.
- Idempotency: Excellent (8 phases, all with [PASS]/[FAIL] gates).
- Known issues: `bgp-peer-router-006-1` can fail during provisioning (race condition); documented workaround in `docs/audit.md`. `docs/audit.md` reads as a dev working document (F-15).

---

## Tooling & Automation Review

### `setup.ps1` (Root)
- Well-structured entry point for environment setup.
- Supports `-Azure`, `-Aws`, `-Status`, `-SkipUpdate` flags cleanly.
- Validates Azure CLI, Bicep, Terraform, AWS CLI, and SSO auth.
- Auto-creates `.data/subs.json` from template if missing.
- Calls `scripts/update-labs.ps1` for update check (skippable).
- **Issue:** The `-DoLogin` flag that `labs-common.ps1:Ensure-AzureAuth` accepts is not wired into root `setup.ps1`. Docs reference `setup.ps1 -DoLogin` but this silently does nothing (F-04).

### `scripts/labs-common.ps1`
- High-quality shared library. Functions: `Get-RepoRoot`, `Get-LabConfig`, `Get-SubscriptionId`, `Ensure-AzureAuth`, `Test-AzureTokenFresh`, `Clear-AzureCredentialCache`, `Show-ConfigPreflight`.
- Validates config structure with friendly error messages and actionable next steps.
- Placeholder GUID detection prevents accidental deploys with template values.
- PS 5.1 mitigations: `$env:PYTHONWARNINGS`, SilentlyContinue wrapping, JSON output preference.
- **Recommendation:** `Clear-AzureCredentialCache` relies on `$env:USERPROFILE` with fallback to `$env:HOME` — cross-platform but could miss WSL scenarios. Low risk.

### `tools/cost-check.ps1`
- Excellent read-only auditor. Scans for high-cost Azure resource types and AWS billable resources.
- Supports `Labs` (default) and `All` scope, per-lab filtering, JSON output, AWS profile.
- Suggests specific `destroy.ps1` commands when billable resources are found.
- Tags resources with `project=azure-labs` + `lab=<lab-id>` for reliable filtering.
- **Minor:** AWS load balancer tag filter requires a second API call per LB (performance, not correctness issue).

### `.packages/` Scripts
- Contains `deploy.ps1`, `destroy.ps1`, `get-sub.ps1`, `set-sub.ps1`, `setup.ps1`.
- Unclear relationship to `scripts/` and root `setup.ps1`. These appear to be older stubs or shared helpers. No documentation explains when to dot-source these vs. the scripts in `scripts/`.
- **Recommendation:** Audit `.packages/` content and either integrate into `scripts/labs-common.ps1` or document their specific role clearly.

### `scripts/update-labs.ps1` vs `tools/update-azure-labs.ps1`
- Both appear related to update-checking functionality.
- `setup.ps1` calls `scripts/update-labs.ps1`.
- `tools/update-azure-labs.ps1` is not referenced anywhere visible.
- **Recommendation:** Consolidate into one file; remove or document the other (F-09).

### PowerShell 5.1 Compatibility
- `labs-common.ps1` sets `$env:PYTHONWARNINGS` and uses `SilentlyContinue` wrapping — key mitigations documented in `lab-006/docs/audit.md`.
- Core issues: PS 5.1 treats stderr from native commands as `ErrorRecord`; `2>$null` + `-o tsv` can drop stdout.
- Lab-006 is fully hardened (uses `-o json` + `ConvertFrom-Json` everywhere).
- Labs 000–005 have varying levels of hardening; all dot-source `labs-common.ps1` which provides baseline protection for auth flows.
- **Recommendation:** Run all deploy/destroy scripts under PS 5.1 once to catch any remaining `-o tsv` + `2>$null` combinations (see F-findings in lab-006/docs/audit.md for exact patterns).

### Phased Deployment Pattern
- All labs implement a 0–6 phase structure (lab-006 extends to phase 8).
- Phase 0: Preflight (auth, config, quotas).
- Phase 1: Core fabric (RG, vWAN, vHub).
- Phases 2–4: Lab-specific resources.
- Phase 5: Validation (PASS/FAIL gates).
- Phase 6: Summary + cleanup guidance.
- **Consistency gap:** Phase numbering is not enforced — lab-003 uses phase "5b" as a sub-phase; lab-006 extends to phase 8. No shared spec document. Recommend formalizing a phase contract.

---

## Documentation & Onboarding Review

### README.md (Root)
- Good structure. Quick Start, cost warning, labs table, docs index, AWS quick setup, security note.
- Time-to-first-lab for a prepared engineer: approximately 15–20 minutes.
- Public-safe language throughout.
- Security section is explicit: "Public repository — no secrets committed."
- **Minor:** Cost estimates in the labs table are slightly inconsistent with per-lab READMEs (e.g., lab-003 shows ~$0.70 in root README vs. ~$0.71/hr in lab README). Not a safety issue.

### `docs/setup-overview.md`
- Most critical onboarding doc — and has three broken references (F-02, F-03, F-04).
- Otherwise well-organized: tools table, quick start, detailed AWS guides, config files table, security reminders.
- **Action required:** Fix the three broken references before sharing publicly.

### `docs/labs-config.md`
- Clear and complete. Covers all error cases with copy-paste fixes. Good defensive writing.

### `docs/aws-*.md` Files
- Not read in full but coverage appears comprehensive given the breadth of files.
- Good practice to break AWS setup into multiple focused docs.

### Per-Lab READMEs
- All labs have READMEs. Quality is consistent (purpose, architecture diagram, quick start, parameters table, phases table, resources table, cost estimate, tags, validation, cleanup, files).
- Labs 005 and 006 have the most complete READMEs.
- Labs 003–006 have supplemental `docs/` subfolders (architecture, APIPA mapping, validation, troubleshooting, observability, experiments).
- **Gap:** Labs 000–002 have only `docs/validation.md` and `docs/observability.md` — no architecture deep-dive, no troubleshooting guide.

### `docs/observability-index.md`
- Exists as a cross-lab index. Not read in full. Good practice.

---

## Security / Privacy / Ethics Review (Public Repo)

### Gitignore Posture
- **Strong overall.** Key exclusions:
  - `.data/` (all user config) with precise template exceptions
  - `**/subs.json`, `**/*secrets*`, `**/*.local.*`
  - Private key formats: `*.pem`, `*.pfx`, `*.key`, `*.p12`, `id_rsa*`, `id_ed25519*`
  - Azure auth caches: `.azure/`, `*.msalcache*`, `*.tokencache*`, `azureProfile.json`
  - Lab outputs: `**/outputs.json`, `**/*-evidence*.json`, `**/*-vpn-dump/`
  - Logs: `logs/*.log`, `logs/*.txt`
  - IaC state: `*.tfstate`, `.terraform/`
- **Potential gap (F-08):** The `.data/` blanket exclude plus the `!.data/lab-003/` exception followed by `.data/lab-003/*` is correct but fragile. If a developer adds `.data/lab-007/` without a matching exclude, that directory's contents could be committed. Recommend adding a comment explaining the pattern.

### No Secrets Found in Tracked Files
- Reviewed all tracked JSON templates: all subscription IDs and tenant IDs are `00000000-0000-0000-0000-000000000000`.
- No real account IDs, ARNs, or API keys in any tracked file.
- AWS `aws sts get-caller-identity` output (account number) is only ever used at runtime and printed to console — not written to any tracked file.

### Outputs and Logging Risk
- `outputs.json` files written to `.data/` contain subscription IDs and VM private IPs. These are gitignored correctly.
- Log files written to `labs/*/logs/` are also gitignored.
- `cost-check.ps1 -JsonOutputPath` saves to a user-specified path — if the user specifies a tracked path, it could be committed. This is low risk but worth a warning in the tool's README.

### Public-Safe Language Guidelines
The following guidelines are recommended for all lab content:

1. **No internal terminology:** Avoid phrases like "as seen in production," "based on customer feedback," or references to specific engagements. Use "in a real-world scenario" or "in a production environment."
2. **No real IDs:** Never use real subscription IDs, tenant IDs, account numbers, or resource IDs in documentation or scripts. Always use `00000000-0000-0000-0000-000000000000` or `<your-subscription-id>`.
3. **No screenshots with real data:** If sharing screenshots, redact subscription IDs, tenant names, email addresses, and resource URLs that include real IDs.
4. **Vendor-neutral framing:** Frame labs as "learning about Azure features" not "replicating a customer environment."
5. **"Validate customer configurations" language (F-07):** Rewrite as "validate your own configurations" or "validate lab configurations."
6. **Recommended disclaimer for all labs:**

```
> This lab is for educational purposes in a personal sandbox environment.
> Deploy only in subscriptions you own. Always run `destroy.ps1` when done.
> Cost estimates are approximate and may vary by region and pricing tier.
```

---

## Reliability: Idempotency, Cleanup, and Failure Modes

### Idempotency
- **Good:** All labs check for existing resources before creating. Re-running `deploy.ps1` picks up from existing state.
- **Good:** Lab-006 Phase 0 explicitly documents "resume support."
- **Gap:** No labs test idempotency from a partial-failure state in documentation. Lab-006's `docs/audit.md` documents this for that lab only.

### Cleanup Reliability
- All labs have `destroy.ps1` at root.
- Lab-003 (Azure + AWS) requires passing `-AwsProfile` to destroy both sides — this is documented.
- Resource Group deletion is the primary cleanup mechanism for Azure resources — reliable if all resources are tagged to the same RG.
- `cost-check.ps1` serves as a cleanup verification tool — good safety net.
- **Leak risk:** If a `destroy.ps1` fails mid-execution (e.g., vWAN dependencies not cleaned up in order), manual cleanup is required. No labs document the manual cleanup order for partial failures.

### Failure Modes

| Lab | Documented Failure Modes | Coverage |
|-----|--------------------------|----------|
| 000 | Auth failure, wrong subscription | Minimal |
| 001 | Hub stuck in Provisioning | Partial |
| 002 | Backend unhealthy, 503 from Front Door, SSH blocked | Good |
| 003 | See docs/troubleshooting.md | Good |
| 004 | Routes not appearing, hub provisioning stuck, quota | Partial |
| 005 | Implicit — phases are self-documenting | Good |
| 006 | PS 5.1 stderr crash, tsv stdout loss, bgpd ordering, bgpconnection race | Excellent (docs/audit.md) |

**Overall:** Lab-006's `docs/audit.md` sets the standard for failure mode documentation. Recommend bringing labs 000–005 up to a similar level.

---

## Recommendations (Prioritized)

### Critical (Fix Before Sharing)

1. **[F-02,F-03,F-04]** Fix broken doc references in `docs/setup-overview.md`:
   - Remove `.\run.ps1 status` — replace with `.\setup.ps1 -Status`
   - Remove `.\validate.ps1` — replace with "validation is built into Phase 5 of deploy.ps1"
   - Fix `.\scripts\setup.ps1 -DoLogin` → `.\setup.ps1` (no `-DoLogin` flag at root)

2. **[F-10]** Fix `lab-000/README.md` Troubleshooting section: `.\scripts\setup.ps1 -DoLogin` → `.\setup.ps1`

### High Priority (Within 2 Weeks)

3. **[F-01]** Rename `labs/lab-000_resource-group/` → `labs/lab-000-resource-group/` to match naming convention. Update all references in README.md, docs, and scripts.

4. **[F-05]** Add a minimal `inspect.ps1` to labs 002, 003, 004, 005. At minimum: query key resource states, provisioning status, and effective routes/connections.

5. **[F-11]** Fix lab-001 README validation snippet: replace `<sub>` placeholder with an instruction to run `az account show --query id -o tsv` first.

6. **[F-07]** Update lab-005 README: replace "Validate customer configurations" with "validate your own VPN configurations."

### Medium Priority (Within 6 Weeks)

7. **[F-09]** Audit `.packages/` scripts vs. `scripts/`. Consolidate or document ownership split. Remove `tools/update-azure-labs.ps1` if duplicate.

8. **[F-14]** Add NSG documentation to lab-004. At minimum, document that no NSG is applied (intentional for lab simplicity) and recommend adding one before adapting for production.

9. **[F-08]** Add a comment in `.gitignore` explaining the `.data/` exception pattern so future lab additions don't accidentally expose data.

10. **[F-13]** Create `CHANGELOG.md` with a brief entry for v0.6.0 features. Helps contributors understand the history.

11. **[F-06]** Evaluate adding Bicep IaC to labs 001, 002, 003, 005. Even a partial Bicep template improves reviewability.

12. **[F-15]** Move `lab-006/docs/audit.md` to a `docs/dev/` subdirectory or rename to `docs/dev-notes.md` to clarify its audience.

13. **[F-12]** Centralize AWS default region to a single constant in `labs-common.ps1` or a shared config file.

---

## Action Plan

### Week 1–2 (Documentation & Quick Wins)

- [ ] Fix all broken doc references in `docs/setup-overview.md` (F-02, F-03, F-04)
- [ ] Fix `lab-000/README.md` troubleshooting reference (F-10)
- [ ] Fix `lab-001/README.md` validation snippet `<sub>` placeholder (F-11)
- [ ] Fix `lab-005/README.md` language "customer configurations" (F-07)
- [ ] Rename `lab-000_resource-group` → `lab-000-resource-group` (F-01)
- [ ] Update `README.md` and any scripts referencing the old lab-000 folder name
- [ ] Add the recommended disclaimer block to all lab READMEs
- [ ] Add comment to `.gitignore` explaining `.data/` exception pattern (F-08)

### Week 3–6 (Standardization & Tooling)

- [ ] Write and adopt a standard lab README template (see Appendix A)
- [ ] Write and adopt a standard script skeleton for deploy/destroy/inspect (see Appendix B)
- [ ] Add minimal `inspect.ps1` to labs 002, 003, 004, 005 (F-05)
- [ ] Audit `.packages/` and consolidate or document (F-09)
- [ ] Create `CHANGELOG.md` (F-13)
- [ ] Add `docs/dev/` folder and move lab-006 dev audit docs there (F-15)
- [ ] Consider adding a GitHub Actions workflow for basic linting (PowerShell Script Analyzer)
- [ ] Centralize AWS default region to avoid drift (F-12)

---

## Appendix A: Proposed Lab README Template

```markdown
# Lab NNN: <Short Title>

> **Cost: ~$X.XX/hr** | **Cloud: Azure [+ AWS]** | **Cleanup: always run `.\destroy.ps1`**

## What This Lab Proves

- [One-sentence learning objective 1]
- [One-sentence learning objective 2]

## Architecture

```
[ASCII diagram here]
```

## Prerequisites

- Azure subscription (Contributor access)
- Azure CLI installed and authenticated
- PowerShell 7+ (or Windows PowerShell 5.1)
- [AWS CLI + profile — for hybrid labs only]

## Quick Start

```powershell
cd labs/lab-NNN-<name>
.\deploy.ps1                  # Uses defaults
.\deploy.ps1 -Force           # Skip prompts
.\inspect.ps1                 # Check state at any time
.\destroy.ps1 -Force          # Cleanup when done
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionKey` | (from subs.json) | Azure subscription key |
| `-Location` | `centralus` | Azure region |
| `-Force` | `$false` | Skip confirmation prompts |

## Deployment Phases

| Phase | Description | Duration |
|-------|-------------|----------|
| 0 | Preflight (auth, config, quota) | ~30s |
| 1 | Core fabric (RG + vWAN/VNet) | N min |
| 2 | [Feature resources] | N min |
| 5 | Validation | ~30s |
| 6 | Summary + cleanup guidance | ~5s |

**Total: ~N minutes**

## Resources Created

| Resource | Name | Notes |
|----------|------|-------|
| Resource Group | `rg-lab-NNN-<name>` | All resources here |

## Cost Estimate

| Resource | Approximate Cost |
|----------|------------------|
| [Resource type] | ~$X.XX/hr |
| **Total** | **~$X.XX/hr** |

> Always run `.\destroy.ps1` when done to stop billing.

## Validation

```powershell
.\inspect.ps1          # Full inspection
# or
az <key validation command> -o table
```

See [docs/validation.md](docs/validation.md) for full commands.

## Cleanup

```powershell
.\destroy.ps1          # Interactive (with confirmation)
.\destroy.ps1 -Force   # No prompts
```

## Key Learnings

1. [Key concept 1]
2. [Key concept 2]

## Troubleshooting

**[Common error]:**
```powershell
# Fix command
```

## References

- [Relevant Microsoft docs link]

---

> This lab is for educational purposes in a personal sandbox environment.
> Deploy only in subscriptions you own. Always run `destroy.ps1` when done.
> Cost estimates are approximate and may vary by region and pricing tier.
```

---

## Appendix B: Proposed Standard Script Interface

Every lab should expose exactly these three entry points at its root:

### `deploy.ps1` — Required

Minimum required parameters:
```powershell
param(
  [string]$SubscriptionKey,       # From subs.json
  [string]$Location = "centralus", # Validated against allowlist
  [string]$Owner = "",             # Tag value
  [switch]$Force                   # Skip confirmation
)
```

Required behavior:
- Phase 0: Preflight (auth, config validation, location check, cost warning + confirmation unless `-Force`)
- Phase 1–N: Resource deployment with idempotency checks
- Phase 5: Validation with `[PASS]/[FAIL]` output
- Phase 6: Summary including portal URL and cleanup reminder
- Write outputs to `.data/lab-NNN/outputs.json` (gitignored)
- Write log to `logs/lab-NNN-<timestamp>.log` (gitignored)

### `destroy.ps1` — Required

Minimum required parameters:
```powershell
param(
  [string]$SubscriptionKey,
  [switch]$Force,
  [switch]$KeepLogs
)
```

Required behavior:
- Confirm before deleting unless `-Force`
- Delete resource group(s) created by the lab
- For AWS labs: also tear down AWS resources
- Remove `.data/lab-NNN/` unless `-KeepLogs`

### `inspect.ps1` — Required (new standard)

Minimum required parameters:
```powershell
param(
  [string]$SubscriptionKey,
  [switch]$RoutesOnly,
  [switch]$StatusOnly
)
```

Required behavior:
- Query all key resource provisioning states
- Show effective routes for VMs/NICs if applicable
- Show BGP peering status if applicable
- Print `[PASS]/[FAIL]/[WARN]` summary
- No side effects (read-only)

---

## Appendix C: Required .data Output Contract

Each lab should write to `.data/lab-NNN/outputs.json` with at minimum:

```json
{
  "metadata": {
    "lab": "lab-NNN",
    "deployedAt": "2026-01-01T00:00:00Z",
    "status": "PASS",
    "version": "0.6.0"
  },
  "azure": {
    "resourceGroup": "rg-lab-NNN-<name>",
    "location": "centralus"
  }
}
```

Labs with AWS resources should add an `"aws"` block. This output is always gitignored.

---

## Appendix D: Cost Safety Checklist (Pre-Deploy)

Before running `deploy.ps1` on any lab, verify:

- [ ] You are in the correct subscription (`az account show`)
- [ ] You have read the cost estimate in the lab README
- [ ] You have calendar time to run `destroy.ps1` today
- [ ] `tools/cost-check.ps1` shows no leftover resources from previous runs
- [ ] For AWS labs: AWS CLI is authenticated (`aws sts get-caller-identity --profile aws-labs`)

After running `destroy.ps1`, verify:

- [ ] `tools/cost-check.ps1` shows "All clear! No billable lab resources detected."
- [ ] Azure Portal: Resource group is deleted
- [ ] For AWS labs: AWS Console shows no VPN connections, VGWs, or running EC2 instances with `project=azure-labs` tag

---

*Audit report generated 2026-03-02. Repo version 0.6.0.*
*This report is public-safe: no real subscription IDs, tenant IDs, customer data, or internal references included.*
