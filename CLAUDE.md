# CLAUDE.md

This is an **Azure networking labs repository** built with Claude Code. All labs use PowerShell (PS 5.1 + PS 7 compatible).

---

## Repository Purpose

A personal collection of Azure cloud labs focused on Virtual WAN, hybrid connectivity, DNS, and networking patterns. Every lab is designed to be deployed, validated, and destroyed cleanly.

---

## Key Conventions

| Convention | Detail |
|------------|--------|
| **PS compatibility** | PS 5.1 + PS 7. No ternary (`?:`), no `?.`, no em-dashes (`—`), no null-conditional operators |
| **Naming** | `rg-lab-NNN-*`, `vwan-lab-NNN`, `vhub-lab-NNN`, `vnet-lab-NNN-*` |
| **Phase structure** | 0=Preflight, 1=Core Fabric, 2=Primary Resources, 3=Secondary, 4=Connections, 5=Validation, 6=Summary |
| **Config loading** | Always via `Get-LabConfig` and `Get-SubscriptionId` from `scripts/labs-common.ps1` |
| **Cost warnings** | Phase 0, before DEPLOY prompt, itemized estimate required |
| **Outputs** | Saved to `.data/lab-NNN/outputs.json` |
| **Tags** | `project=azure-labs lab=lab-NNN owner=... environment=lab cost-center=learning` |
| **Cleanup** | `destroy.ps1` must be idempotent; ends with cleanup verification + cost-check hint |

---

## Key Documentation

| File | Purpose |
|------|---------|
| `docs/ops/LAB-STANDARD.md` | Lab interface contract — required files, phases, parameter interface |
| `docs/ops/ONBOARDING.md` | User onboarding guide |
| `docs/REFERENCE.md` | BGP ASNs, APIPA ranges, cost safety pattern |
| `docs/LABS/README.md` | Lab catalog with status, cost, and prereqs |
| `docs/DOMAINS/vwan.md` | Azure vWAN concepts |
| `docs/DOMAINS/dns.md` | Azure DNS concepts |
| `docs/DOMAINS/aws-hybrid.md` | AWS hybrid connectivity (lab-003 only) |
| `docs/AUDIT.md` | Living audit log / known issues |
| `scripts/labs-common.ps1` | Shared helpers used by all deploy/destroy scripts |

---

## Script Interface (deploy.ps1)

Every `deploy.ps1` must accept:

```powershell
param(
  [string]$SubscriptionKey,    # Key from .data/subs.json (uses default if omitted)
  [string]$Location,           # Azure region (has a sensible default)
  [switch]$Force               # Skip confirmation prompts
)
```

---

## PS5.1 + Azure CLI Patterns (Learned Rules)

### Az CLI existence checks — ALWAYS wrap with EAP toggle

When `$ErrorActionPreference = "Stop"` is set (required in all lab scripts), any `az` command that exits non-zero (e.g., `az ... show` on a resource that doesn't exist yet) will throw a **terminating error** in PS5.1, even with `2>$null`. The `2>$null` redirect suppresses display but does **not** prevent the error record from being created.

**Required pattern for every `az ... show` / `az ... list` existence check:**

```powershell
$oldEap = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$existing = az resource show ... -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEap
```

Actual deployment commands (`az ... create`, `az ... delete`) should NOT be wrapped — failures there should terminate the script.

### Em-dashes are forbidden in .ps1 files

Never use `—` (U+2014) inside PowerShell strings. PS5.1 misparses the line, causing the parser to misread subsequent tokens as bare commands. Use ` - ` (hyphen with spaces) instead. Em-dashes are fine in `.md` files.

### AVNM subscription scope format

`az network manager create --network-manager-scopes` requires the full ARM path:

```powershell
--network-manager-scopes subscriptions="/subscriptions/$SubscriptionId"
```

Not just `subscriptions=$SubscriptionId`.

---

## Do Not

- **Deploy resources** unless explicitly asked — describe and plan only by default
- **Commit `.data/` files** — they contain real subscription IDs and outputs
- **Hardcode subscription IDs** in scripts — always load from `Get-SubscriptionId`
- **Use PS 7-only syntax** — all scripts must work on PS 5.1
- **Leave billable resources running** — always end examples with `.\destroy.ps1`
- **Use em-dashes in .ps1 files** — use ` - ` (hyphen) instead

---

## Lab Directory Structure

```
labs/lab-NNN-<name>/
  deploy.ps1         # Phased deployment (phases 0-6)
  destroy.ps1        # Idempotent teardown
  inspect.ps1        # Post-deploy validation (recommended)
  README.md          # Goal, Architecture, Cost, Prereqs, Deploy, Validate, Destroy, Troubleshooting
  lab.config.example.json   # If lab needs config overrides
```

---

## Current Labs

| Lab | Description | Cost |
|-----|-------------|------|
| lab-000 | Resource Group + VNet baseline | Free |
| lab-001 | vWAN hub routing | ~$0.26/hr |
| lab-002 | App Gateway + Front Door | ~$0.30/hr |
| lab-003 | vWAN to AWS VPN (BGP/APIPA) | ~$0.70/hr |
| lab-004 | vWAN default route propagation | ~$0.60/hr |
| lab-005 | vWAN S2S BGP/APIPA reference | ~$0.61/hr |
| lab-006 | vWAN spoke BGP router + loopback | ~$0.37/hr |
| lab-007 | Azure Private DNS Zones + auto-registration | ~$0.02/hr |
| lab-008 | Azure DNS Private Resolver + forwarding ruleset | ~$0.03/hr |
| lab-009 | AVNM dual-region hub-spoke + portal Global Mesh | ~$0.01/hr |
