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
| `lab.ps1` | Unified CLI entry point — all lab operations via one command |
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

For `az deployment group create` specifically, also add `--only-show-errors` to suppress advisory warnings (e.g. Bicep upgrade notices) that would otherwise write to stderr and trigger a `NativeCommandError` under `$ErrorActionPreference = "Stop"` before the `$LASTEXITCODE` check is reached:

```powershell
$bicepResult = az deployment group create `
  --resource-group $ResourceGroup `
  ...
  --output json `
  --only-show-errors 2>&1
```

### Em-dashes are forbidden in .ps1 files

Never use `—` (U+2014) inside PowerShell strings. PS5.1 misparses the line, causing the parser to misread subsequent tokens as bare commands. Use ` - ` (hyphen with spaces) instead. Em-dashes are fine in `.md` files.

### Passing user-supplied values to scripts — ALWAYS use hashtable splatting

When calling a script and passing a value that came from user input (e.g. a password entered via `Read-Host`), **never use array splatting** (`@("-ParamName", $value)`). PS5.1 re-parses array elements as shell tokens, so special characters like `#` and `$` in the value can cause it to slip past the intended named parameter and bind positionally to the wrong one.

**Required pattern — hashtable splatting:**

```powershell
$scriptArgs = @{}
if ($Location)        { $scriptArgs['Location']      = $Location }
if ($resolvedPassword){ $scriptArgs['AdminPassword'] = $resolvedPassword }
& $script @scriptArgs
```

Hashtable splatting binds names to values as objects — no token parsing, no special-char surprises. Use this pattern any time you build argument sets dynamically, not just for passwords.

### `Join-Path` only accepts 2 path segments in PS5.1

The 3-argument form `Join-Path $root "dir" "file"` throws `A positional parameter cannot be found that accepts argument 'file'` in PS5.1. Always nest two calls:

```powershell
# Wrong (PS7 only):
$path = Join-Path $RepoRoot "scripts" "labs-common.ps1"

# Correct (PS5.1 + PS7):
$path = Join-Path (Join-Path $RepoRoot "scripts") "labs-common.ps1"
```

### Pipeline-assigned variables must be pre-initialized to `$null` under `Set-StrictMode`

With `Set-StrictMode -Version Latest`, if a `$var = az ... | ConvertFrom-Json` pipeline produces **no output** (because the `az` command found nothing and `ConvertFrom-Json` received an empty stream), the variable is left **unset** — not `$null`. Any subsequent access throws `VariableIsUndefined`.

**Required pattern for every existence-check pipeline:**

```powershell
$resolver = $null
$oldEP = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
$resolver = az dns-resolver show -g $rg -n $name -o json 2>$null | ConvertFrom-Json
$ErrorActionPreference = $oldEP
```

This applies to ALL `$var = <cmd> | ConvertFrom-Json` patterns, not just `az`. The pre-init guarantees `$var` is always defined (as `$null`) even when the pipeline produces nothing.

Also guard any string interpolation that dereferences the variable before the null check completes:

```powershell
# Wrong - throws if $record is null:
-Details "IP: $($record.aRecords[0].ipv4Address)"

# Correct:
$ip = if ($record -and $record.aRecords.Count -gt 0) { $record.aRecords[0].ipv4Address } else { "not found" }
-Details "IP: $ip"
```

### `Get-ChildItem` `.Count` is unreliable in PS5.1 without `@()`

In PS5.1, if `Get-ChildItem` returns a single object (not an array), calling `.Count` on the result returns `$null`, not `1`. Wrap all `Get-ChildItem` results in `@()` before using `.Count`:

```powershell
# Wrong - silently skips cleanup when exactly 1 file exists:
$files = Get-ChildItem $dir -Filter "*.json"
if ($files.Count -gt 0) { ... }

# Correct:
$files = @(Get-ChildItem $dir -Filter "*.json")
if ($files.Count -gt 0) { ... }
```

### `az dns-resolver` forwarding-rule and vnet-link use `--ruleset-name`, not `--forwarding-ruleset-name`

`az dns-resolver forwarding-rule` and `az dns-resolver vnet-link` ARE valid top-level subgroups (confirmed in Azure CLI docs). The parameter flag is `--ruleset-name`, not `--forwarding-ruleset-name`. Using the wrong flag causes the command to silently return nothing (error eaten by `2>$null`).

**Wrong (silently returns nothing — wrong flag):**
```powershell
az dns-resolver forwarding-rule list --forwarding-ruleset-name $name -g $rg
az dns-resolver vnet-link list       --forwarding-ruleset-name $name -g $rg
```

**Correct:**
```powershell
az dns-resolver forwarding-rule list --ruleset-name $name -g $rg
az dns-resolver vnet-link list       --ruleset-name $name -g $rg
```

### `az group update --tags` with a space-separated string is unreliable on Windows

Passing a single space-separated string to `--tags` works for `az group create` but can fail silently for `az group update` on Windows (PS5.1 passes it as one arg, az parses it differently). Pass each tag as a separate argument instead:

```powershell
# Wrong - may set one giant tag or fail silently:
$tagsString = "project=azure-labs lab=lab-008 owner=$Owner"
az group update --name $rg --tags $tagsString

# Correct - each tag is a discrete argument:
$tagArgs = @("project=azure-labs", "lab=lab-008", "owner=$Owner", "environment=lab")
az group update --name $rg --tags @tagArgs
```

### AVNM subscription scope format

`az network manager create --network-manager-scopes` requires the full ARM path:

```powershell
--network-manager-scopes subscriptions="/subscriptions/$SubscriptionId"
```

Not just `subscriptions=$SubscriptionId`.

---

## Security & Multi-User Portability

These labs are designed so **any user can clone this repo and deploy to their own Azure subscription** without modifying any checked-in code. The following rules enforce that guarantee and protect users from accidentally leaking credentials.

### No secrets or identifiers in committed code

| What | Rule |
|------|------|
| Subscription IDs | Never hardcode. Always load via `Get-SubscriptionId -Key $SubscriptionKey -RepoRoot $RepoRoot` |
| Tenant IDs | Never appear in `.ps1` or `.json` files. Resolved at runtime via `az account show` |
| Account / UPN / email | Never hardcode. Read with `az account show --query "user.name"` if needed for tags |
| Client IDs / secrets | Never appear anywhere in the repo |
| Access tokens / API keys | Never appear anywhere in the repo |
| AWS credentials | Never appear in `.ps1` files. Must come from user's local AWS CLI profile |
| `.data/` directory | Gitignored. Contains `subs.json`, outputs, and any runtime-generated identifiers |

If you find yourself about to write a GUID, email address, account name, or secret into a `.ps1` or `.json` file that is not inside `.data/`, stop and load it from the runtime environment instead.

### Self-contained per-user setup

Every lab must work end-to-end for a new user who has only:
1. Cloned the repo
2. Logged in with `az login`
3. Created `.data/subs.json` with their own subscription key (see `docs/ops/ONBOARDING.md`)

No lab should require manual Azure portal pre-configuration, custom role assignments, or out-of-band steps beyond what its own `README.md` documents in the **Prereqs** section.

### Automated Azure-side setup (within lab scope)

Scripts may and should automate any Azure configuration that is within the lab's own resource group and subscription scope:

- **Allowed**: creating resource groups, VNets, peerings, NSGs, route tables, policy assignments scoped to the lab RG, RBAC role assignments scoped to the lab RG, enabling required resource providers
- **Not allowed**: modifying subscription-level policies, changing AAD/Entra directory settings, assigning Owner/Contributor at subscription scope, modifying other users' resources, creating service principals with broad permissions

If a lab requires a subscription-level prerequisite (e.g., a resource provider registration), Phase 0 must check for it and print a clear actionable message rather than failing silently or attempting unauthorized changes.

### Secrets scanning awareness

When writing or reviewing scripts, actively check for:
- Any string that looks like a GUID (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`) — must be a variable, not a literal
- Any string containing `@` that could be an email/UPN — must come from `az account show`
- Any string that looks like a key, token, password, or connection string — must never appear in source

---

## DO NOT

- **Deploy resources** unless explicitly asked — describe and plan only by default
- **Commit `.data/` files** — they contain real subscription IDs and outputs
- **Hardcode subscription IDs** in scripts — always load from `Get-SubscriptionId`
- **Use PS 7-only syntax** — all scripts must work on PS 5.1
- **Leave billable resources running** — always end examples with `.\lab.ps1 -Destroy <lab-id>`
- **Use em-dashes in .ps1 files** — use ` - ` (hyphen) instead
- **Let README.md fall behind** — update it in the same commit whenever `lab.ps1` commands, flags, or labs change
- **Let VERSION fall behind** — bump it in the same commit/PR that introduces the change

---

## README.md Maintenance (REQUIRED)

The root `README.md` is the public face of the repo. It must stay in sync with the actual state of `lab.ps1` and the lab catalog. **Whenever any of the following change, update README.md in the same commit:**

| Change | What to update in README |
|--------|--------------------------|
| New `lab.ps1` command or flag | Add to the CLI reference block |
| New lab added | Add row to the Labs table |
| Lab removed or renamed | Update or remove the row |
| New framework capability (e.g. research mode) | Add a named section with usage examples |
| Cost estimate changes | Update the Labs table cost column |

---

## Versioning (`VERSION` file)

The `VERSION` file at the repo root uses **semantic versioning** (`MAJOR.MINOR.PATCH`). It is read by `lab.ps1 -Settings` and should always reflect what is currently in `main`.

| Increment | When |
|-----------|------|
| **PATCH** (`0.7.x`) | Bug fixes, doc corrections, refactors with no user-visible behavior change |
| **MINOR** (`0.x.0`) | New user-visible feature: new `lab.ps1` command, new lab, new framework capability |
| **MAJOR** (`x.0.0`) | Breaking changes: renamed/removed commands, incompatible parameter interface |

**Rules:**
- Bump `VERSION` in the same commit that introduces the change.
- MINOR bump when a PR adds a new feature; PATCH bump for fixes and docs.
- `0.x` = pre-1.0 active development. Reach `1.0.0` when the CLI and lab catalog are stable.

---

## Lab CLI (`lab.ps1`)

`lab.ps1` at the repo root is the single entry point for all lab operations. It is a dispatcher — it delegates to existing scripts and contains no deployment logic of its own.

| Command | Delegates to |
|---------|-------------|
| `.\lab.ps1 -Setup [-Aws]` | `setup.ps1 -Azure` or `setup.ps1 -Aws` |
| `.\lab.ps1 -Status` | `setup.ps1 -Status` |
| `.\lab.ps1 -Login` | `az login` directly |
| `.\lab.ps1 -List` | Scans `labs/` dir + `az group list` for live status |
| `.\lab.ps1 -Deploy <lab>` | `labs/<lab>/deploy.ps1` |
| `.\lab.ps1 -Destroy <lab>` | `labs/<lab>/destroy.ps1` |
| `.\lab.ps1 -Inspect <lab>` | `labs/<lab>/inspect.ps1` |
| `.\lab.ps1 -Research <lab> [-Scenario <name>] [-Background]` | `labs/<lab>/research/<name>.ps1` |
| `.\lab.ps1 -Cost [-Lab] [-AwsProfile]` | `tools/cost-check.ps1` |
| `.\lab.ps1 -Settings` | Reads `az account show` + `.data/subs.json` + git state |
| `.\lab.ps1 -Update` | `scripts/update-labs.ps1` |

**Pass-through parameters** forwarded to deploy/destroy scripts: `-SubscriptionKey`, `-Location`, `-Force`.

**Lab ID resolution**: `-Deploy lab-001`, `-Deploy 001`, and `-Deploy 1` all resolve to the same lab directory. Matching is prefix-based against the `labs/` directory.

**DO NOT** duplicate logic from `lab.ps1` into individual lab scripts or new tooling. If a new repo-level operation is needed, add it to `lab.ps1` as a new action switch.

---

## Lab Directory Structure

```
labs/lab-NNN-<name>/
  deploy.ps1         # Phased deployment (phases 0-6)
  destroy.ps1        # Idempotent teardown
  inspect.ps1        # Post-deploy validation (recommended)
  README.md          # Goal, Architecture, Cost, Prereqs, Deploy, Validate, Destroy, Troubleshooting
  lab.config.example.json   # If lab needs config overrides
  research/          # Research scenarios (optional)
    <scenario>.ps1   # One file per scenario
```

---

## Research Framework

Research scenarios are scripts that run on top of a deployed lab to investigate specific networking behaviors. They are invoked via `lab.ps1 -Research` and are completely separate from deploy/destroy.

### Scenario location

```
labs/<lab-id>/research/<scenario-name>.ps1
```

### Scenario interface

Every research script must accept these parameters:

```powershell
param(
  [string]$OutputDir,        # Where to write JSON reports (set by lab.ps1 to outputs/<lab-id>/)
  [string]$StatusFile,       # Progress file path for background polling
  [string]$LabOutputsPath,   # Path to .data/<lab-id>/outputs.json (lab context)
  [string]$SubscriptionKey,  # Passed through from lab.ps1
  ...                        # Scenario-specific params with defaults
)
```

### Output conventions

- Reports go to `outputs/<lab-id>/` at the repo root (NOT `.data/`)
- `outputs/` is gitignored (generated, may contain IPs and resource IDs)
- Report files are timestamped JSON: `<scenario>-<yyyyMMdd-HHmmss>.json`
- Status file is overwritten in place for background polling: `<scenario>-status.json`

### Background jobs

When `-Background` is passed, `lab.ps1` launches the scenario via `Start-Job`. The scenario updates `$StatusFile` with a JSON object containing at minimum:

```json
{ "status": "running|complete|error", "phase": "CR-3", "startTime": "...", "outputDir": "..." }
```

Poll with: `Get-Content '<path>/<scenario>-status.json' | ConvertFrom-Json`

### Phase naming

Research phases use a scenario prefix + number, e.g. `CR-0` through `CR-8` for `cache-recovery`. This keeps them distinct from lab deploy phases (0-6).

### ErrorActionPreference in scenarios

Use `$ErrorActionPreference = "Continue"` in research scripts (not `"Stop"`). Scenarios should collect partial results on failure, not abort — the point is to observe behavior.

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
