# Implementation Plan: Azure Lab Setup UX Improvements

**Branch:** `claude/azure-lab-setup-uKSi2`
**Date:** 2026-03-02
**Status:** Complete

---

## Overview

This document records all changes made to implement the phased improvement plan for the `zallen-cloud-labs` repository. The goal was to make the "clone to first running lab" experience seamless for a new user with only an Azure account, eliminating the need to manually edit JSON files.

---

## PHASE 0 - Baseline + Guardrails

**Goal:** Documentation and onboarding without behavioral changes.

### Files Added

| File | Purpose |
|------|---------|
| `docs/ops/ONBOARDING.md` | Complete Azure-only onboarding guide |

### What ONBOARDING.md Covers

- Prerequisites table (PowerShell version, Azure CLI, Bicep)
- Step-by-step Azure-only path (3 steps: clone, setup, deploy lab-000)
- Subscription configuration details and schema explanation
- What is gitignored and why
- AWS optional path clearly isolated in its own section
- Quick verification checklist with expected output
- Troubleshooting table for common errors
- Next steps reference table

### Rationale

New users had no single document explaining the Azure-only path. The existing `docs/setup-overview.md` mixed Azure and AWS instructions. `ONBOARDING.md` creates a dedicated, scannable entry point.

---

## PHASE 1 - Seamless Azure-Only Setup

**Goal:** Replace "edit .data/subs.json manually" with a guided wizard.

### Files Modified

| File | Change |
|------|--------|
| `setup.ps1` | Added guided subscription wizard, new flags, AWS isolation |

### New Parameters Added to setup.ps1

| Parameter | Type | Description |
|-----------|------|-------------|
| `-ConfigureSubs` | Switch | Run the guided subscription wizard and exit |
| `-SubscriptionId` | String | Write subscription ID directly to config (non-interactive) |
| `-SubscriptionName` | String | Friendly key for subs.json entry (default: "lab") |

### New Function: Invoke-SubsWizard

The `Invoke-SubsWizard` function implements the guided flow:

1. Verifies Azure CLI is installed
2. Checks authentication; prompts `az login` if needed
3. Runs `az account list` to enumerate enabled subscriptions
4. If exactly 1 subscription: selects automatically (no prompt)
5. If multiple subscriptions: shows numbered list, prompts user to pick
6. Validates selected ID format (UUID pattern, not placeholder)
7. Fetches `tenantId` and verified display name from `az account show`
8. Preserves existing subscription keys when updating
9. Writes `.data/subs.json` atomically
10. Reads back and validates the written config
11. Prints a "configured subscription summary"

### New Function: Test-SubsConfigValid

Checks whether `.data/subs.json` has at least one subscription with a non-placeholder ID. Used to decide whether to trigger the wizard automatically.

### Setup-Azure Behavior Change

When `Setup-Azure` detects missing or unconfigured `subs.json`, it now automatically calls `Invoke-SubsWizard` instead of printing "Edit .data/subs.json with your subscription IDs."

### How to Test (Dry Run)

```powershell
# Check script parses (PS 5.1 compatible)
pwsh -Version 5.1 -Command "& { . .\setup.ps1 -Status; exit 0 }"

# Non-interactive: write a subscription ID directly
.\setup.ps1 -SubscriptionId "12345678-0000-0000-0000-000000000000"

# Interactive wizard
.\setup.ps1 -ConfigureSubs

# Verify config was written
Get-Content .data\subs.json | ConvertFrom-Json

# Status check
.\setup.ps1 -Status
```

---

## PHASE 2 - AWS Truly Optional

**Goal:** No Azure-only path should require or invoke AWS CLI/tools.

### Files Modified

| File | Change |
|------|--------|
| `setup.ps1` | Default interactive mode now runs Azure-only |

### Behavioral Change

**Before:**
```
# Default: Interactive mode - check both
$azOk = Setup-Azure
$awsOk = Setup-Aws   # <-- always ran even without -Aws flag
```

**After:**
```
# Default: Azure-only interactive mode
# AWS is NOT checked by default - only needed for lab-003
$azOk = Setup-Azure
```

AWS setup is now only invoked when:
- User explicitly passes `-Aws` flag
- User passes both `-Azure` and `-Aws`

The status display (`Show-Status`) still shows AWS section but marks it as "(optional - lab-003 only)" and skips detailed checks if AWS CLI is not installed.

### Next Steps Hint

The end of the default flow now shows:

```
AWS (lab-003): .\setup.ps1 -Aws
```

This makes AWS visible but clearly optional.

---

## PHASE 3 - Standardize Lab Contract

**Goal:** Define and document the required structure for all labs.

### Files Added

| File | Purpose |
|------|---------|
| `docs/ops/LAB-STANDARD.md` | Lab interface contract and compliance matrix |

### What LAB-STANDARD.md Defines

- Required files per lab (`deploy.ps1`, `destroy.ps1`, optional `inspect.ps1`)
- Standard parameters for `deploy.ps1` (`-SubscriptionKey`, `-Location`, `-Force`)
- Phase structure (0-6) with descriptions and durations
- Phase 0 (Preflight) requirements: auth check, location allowlist, cost warning, confirmation
- Standard `destroy.ps1` interface with idempotency requirement
- Cleanup verification pattern after destroy
- Output artifact schema (`outputs.json`)
- Required README sections (Goal, Architecture, Cost, Prerequisites, Deploy, Validate, Destroy, Troubleshooting)
- Resource naming conventions
- Tagging requirements
- Compliance matrix showing current status of each lab

---

## PHASE 4 - Cost Safety Improvements

**Goal:** Ensure `cost-check.ps1` is prominently referenced in every billable lab.

### Files Modified

| File | Change |
|------|--------|
| `labs/lab-001-virtual-wan-hub-routing/README.md` | Added cost-check command to Cleanup section |
| `labs/lab-002-l7-fastapi-appgw-frontdoor/README.md` | Added cost-check command to Cleanup section |
| `labs/lab-003-vwan-aws-bgp-apipa/README.md` | Added cost-check command (with -AwsProfile) to Destroy section |
| `labs/lab-004-vwan-default-route-propagation/README.md` | Added cost-check command to Cleanup section |
| `labs/lab-005-vwan-s2s-bgp-apipa/README.md` | Added cost-check command to Cleanup section |
| `labs/lab-006-vwan-spoke-bgp-router-loopback/README.md` | Added cost-check command to Cleanup section |

### Pattern Added to Each Lab

```powershell
# After destroy.ps1:
.\tools\cost-check.ps1
```

For lab-003 (hybrid):
```powershell
.\tools\cost-check.ps1 -AwsProfile aws-labs
```

Lab-000 was not updated (it is free; no billable resources are created).

---

## PHASE 5 - Subscription Portability UX

**Goal:** Make it easy to use your own subscription without editing JSON.

### Files Modified

| File | Change |
|------|--------|
| `.data/subs.example.json` | Added `_schema_version` and `_instructions` fields |

### Schema Improvements

The example JSON now includes:
- `_schema_version: "2"` to support future auto-migration
- `_instructions` field explaining how to use the file
- Existing multi-subscription structure preserved

### Wizard Features Supporting Portability

The `Invoke-SubsWizard` function (in `setup.ps1`) supports:

1. **Single subscription**: auto-selects without prompting
2. **Multiple subscriptions**: interactive numbered list
3. **Preserve existing keys**: reads current `subs.json` before writing, keeps other entries
4. **Non-interactive**: `.\setup.ps1 -SubscriptionId <id>` skips the menu entirely
5. **Named subscriptions**: `.\setup.ps1 -ConfigureSubs -SubscriptionName prod` adds a second entry without overwriting "lab"
6. **Schema migration hook**: `_schema_version` field enables future auto-migration

### Error Messages for Inaccessible Subscriptions

The wizard validates the subscription ID before writing and provides actionable guidance:

- Invalid UUID format: prints the value and instructs the user to run `az account list -o table`
- Placeholder ID: catches `00000000-0000-0000-0000-000000000000` and rejects it
- `az account show` failure: warns but continues (does not block write)

---

## scripts/labs-common.ps1 Fixes

All error messages pointing to the old setup path have been updated:

| Old Reference | New Reference |
|---------------|---------------|
| `.\scripts\setup.ps1 -DoLogin` | `.\setup.ps1 -ConfigureSubs` |
| `.\scripts\setup.ps1 -DoLogin` | `.\setup.ps1 -Azure` |
| `docs/labs-config.md` | `docs/ops/ONBOARDING.md` |

---

## Deliverable C - README.md Updates

See `README.md` for the updated Quick Start section which:
- Shows 3 commands from clone to first lab
- Emphasizes Azure-only default
- Moves AWS to an optional "Advanced" section

---

## PS 5.1 Compatibility Notes

All code changes follow these constraints for PS 5.1 compatibility:

| Requirement | How Handled |
|-------------|-------------|
| No em-dashes in strings | Used hyphens only |
| Safe integer parsing | `[int]::TryParse()` instead of direct cast |
| No null-conditional (`?.`) | Explicit `if ($x)` checks |
| No ternary operator | `if/else` blocks |
| No `[HashSet[T]]` etc. | Basic arrays only |
| String concatenation | `"$variable"` and `+` operator |
| Exit codes | `exit $(if ($ok) { 0 } else { 1 })` |

---

## How to Test Locally (Azure-Only Path)

### 1. Parse Check (PS 5.1)

```powershell
# On Windows with PS 5.1:
powershell.exe -NonInteractive -Command "
  try {
    . .\setup.ps1 -Status
    Write-Host 'Parse OK'
  } catch {
    Write-Host 'Parse error:' `$_
  }
"

# On PS 7:
pwsh -NonInteractive -Command ". .\setup.ps1 -Status"
```

### 2. Wizard Dry Run (Non-Interactive)

```powershell
# Provide a real subscription ID (no actual deployment)
.\setup.ps1 -SubscriptionId "<your-sub-id>"
cat .data\subs.json
```

### 3. Wizard Interactive

```powershell
.\setup.ps1 -ConfigureSubs
# Follow prompts to select a subscription
.\setup.ps1 -Status
```

### 4. Lab-000 Preflight Only

```powershell
cd labs\lab-000_resource-group
# Inspect Phase 0 source (no deployment)
notepad deploy.ps1
# When you run it, Phase 0 prints config, auth, and cost info before prompting
```

### 5. Full Status Check

```powershell
.\setup.ps1 -Status
# Expected: all Azure items [ok], AWS shows as optional
```

---

## How to Test AWS Optional Path (lab-003)

```powershell
# 1. Ensure Azure is set up
.\setup.ps1 -Status

# 2. Add AWS
.\setup.ps1 -Aws

# 3. Verify full status
.\setup.ps1 -Status
# Expected: all items [ok] including AWS
```

---

## Breaking Changes Avoided

| Risk | Mitigated By |
|------|-------------|
| Existing `subs.json` overwritten | Wizard reads existing config before writing; preserves other keys |
| AWS setup broken | AWS functions unchanged; just moved to explicit flag |
| Lab scripts broken | Only error message strings updated in `labs-common.ps1`; all function signatures preserved |
| `-Azure`, `-Aws`, `-Status`, `-SkipUpdate` flags removed | All original flags preserved exactly |

---

## Open Issues / Follow-Ups

| Issue | Priority | Notes |
|-------|----------|-------|
| `inspect.ps1` missing for lab-002, lab-003, lab-004, lab-005 | Low | Lab standard defines it as "Recommended" not required |
| outputs.json schema partially implemented in some labs | Low | Lab standard defines the target schema; existing labs save partial data |
| Cost warning in deploy scripts is text-only | Done | Phase 0 of each lab already prints cost estimate before prompting |
| Auto-migration for schema changes | Future | `_schema_version` field added to subs.example.json to enable this |
| `docs/labs-config.md` references remain in some places | Low | Core error paths updated; older doc file still exists for backwards compat |
