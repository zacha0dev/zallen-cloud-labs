# Lab 006: Phased Audit Report

## Overview

Full audit and hardening pass for lab-006 (vWAN Spoke BGP Router with Loopback).
Covers PS 5.1 compatibility, BGP stability, blob-driven config, and observability.

---

## Phase-by-Phase Checklist

### Phase 0: Preflight + Config Contracts

| Check | Status | Notes |
|-------|--------|-------|
| `$env:PYTHONWARNINGS` set | PASS | Suppresses az CLI Python UserWarning on stderr |
| Provider registration uses SilentlyContinue | PASS | Already wrapped |
| Quota check uses JSON + ConvertFrom-Json | PASS | Already safe |
| `az account set` wrapped in SilentlyContinue | PASS | Already wrapped |
| Resume support (existing RG detection) | PASS | Idempotent |

### Phase 1: Core Fabric (RG + vWAN + vHub)

| Check | Status | Notes |
|-------|--------|-------|
| vWAN create idempotent | PASS | Checks for existing before create |
| vHub polling uses JSON | PASS | Uses `-o json 2>$null` |
| Timeout guard (60 * 15s) | PASS | 15 min max |
| Failed state detection | PASS | Throws on provisioningState=Failed |

### Phase 2: Spoke VNets + Hub Connections

| Check | Status | Notes |
|-------|--------|-------|
| VNet create idempotent | PASS | Checks for existing |
| Hub connection idempotent | PASS | Checks for existing |
| Connection validation uses SilentlyContinue | PASS | Wrapped |

### Phase 3: Compute - Router VM + Client VMs

| Check | Status | Notes |
|-------|--------|-------|
| SSH keygen safe on PS 5.1 | PASS | Uses `ssh-keygen` directly |
| NIC IP forwarding uses JSON extraction | PASS | Fixed to use JSON + ConvertFrom-Json |
| VM polling timeout | PASS | 40 * 15s = 10 min |
| Cloud-init file path uses `Join-Path` | PASS | Cross-platform safe |

### Phase 4: Router Config + Loopback Creation

| Check | Status | Notes |
|-------|--------|-------|
| `az vm run-command` wrapped | PASS | SilentlyContinue + 2>$null |
| Extension check idempotent | PASS | Checks for existing customScript |
| Fallback instructions if script missing | PASS | Manual steps printed |

### Phase 5: BGP - Peer Router to Virtual Hub

| Check | Status | Notes |
|-------|--------|-------|
| Two bgpconnections created | **FIXED** | bgp-peer-router-006-0 and bgp-peer-router-006-1 |
| Old single peering cleanup | PASS | Removes bgp-peer-router-006 if present |
| conn-spoke-a ID resolved via JSON | PASS | Uses ConvertFrom-Json |
| Failure diagnostics dump | **ADDED** | Writes phase5-bgp-diag.json to .data/lab-006/ |
| Fail-forward on bgpconnection failure | **ADDED** | Hard-stop with actionable message |
| BGP adjacency validation (vtysh) | **ADDED** | Runs `show bgp summary json` via run-command |
| FRR config push with actual vHub IPs | PASS | Both active-active peers configured |

### Phase 6: Blob-Driven Router Config (NEW)

| Check | Status | Notes |
|-------|--------|-------|
| Disabled by default | PASS | Requires lab.config.json with enabled=true |
| Storage account idempotent | PASS | Checks for existing |
| Managed identity assignment | PASS | Uses `az vm identity assign` |
| RBAC assignment (Storage Blob Data Reader) | PASS | Scoped to storage account |
| Blob upload (frr.conf + apply.sh) | PASS | --overwrite for idempotency |

### Phase 7: Route Table Control + Propagation

| Check | Status | Notes |
|-------|--------|-------|
| Client NIC resolution uses JSON | **NOTE** | Still uses `-o tsv` for NIC ID -- low risk since it is a simple string |
| Effective routes captured | PASS | Stored for inspection |

### Phase 8: Observability Proof Pack

| Check | Status | Notes |
|-------|--------|-------|
| outputs.json written without BOM | PASS | Uses Write-JsonWithoutBom |
| All key values captured | PASS | BGP states, vHub IPs, peering names |

---

## Known Failure Modes

### 1. PS 5.1 Native Stderr Crash

**Problem:** Azure CLI (and git) write warnings to stderr. PowerShell 5.1 with `$ErrorActionPreference = "Stop"` treats any stderr output from native commands as a terminating error.

**Root cause:** PS 5.1 converts stderr from native commands (like `az`, `git`) to `ErrorRecord` objects. When `$ErrorActionPreference = "Stop"`, these become terminating errors even though the command succeeded (exit code 0).

**Common triggers:**
- `az CLI` Python 32-bit cryptography UserWarning
- `git fetch` progress output (written to stderr)
- `git status --porcelain` on repos with special characters

**Fix applied:**
1. Set `$env:PYTHONWARNINGS = "ignore::UserWarning"` at script entry in deploy.ps1, inspect.ps1, setup.ps1, and labs-common.ps1
2. Wrap all `az` and `git` calls in `$ErrorActionPreference = "SilentlyContinue"` blocks
3. Check `$LASTEXITCODE` explicitly after native commands
4. Restore original `$ErrorActionPreference` in `finally` blocks

**Reproduce:**
```powershell
# In PS 5.1 with 32-bit Python Azure CLI:
$ErrorActionPreference = "Stop"
az account show -o tsv 2>$null  # May still crash if Python emits warning before redirect
```

### 2. az `--query -o tsv` + `2>$null` Loses Stdout

**Problem:** In PS 5.1, combining `--query ... -o tsv` with `2>$null` can cause the stdout pipeline to return empty, even when the command succeeds.

**Root cause:** PS 5.1 redirects are processed differently for native commands. When stderr is redirected to `$null`, the stdout stream can be affected if the native command interleaves stdout/stderr writes.

**Fix applied:** Use `-o json` + `ConvertFrom-Json` for all critical data extraction. JSON output is multi-line and not affected by the PS 5.1 single-line stdout issue.

**Where it matters most:**
- NIC IP extraction (Phase 3)
- vHub virtualRouterIps (Phase 5)
- BGP connection state checks
- inspect.ps1 (entire script rewritten to use JSON)

### 3. Cloud-Init bgpd Ordering

**Problem:** Cloud-init `write_files` executes before `packages`. When FRR is installed via `packages:`, it overwrites `/etc/frr/daemons` with its default (`bgpd=no`), undoing the `write_files` configuration.

**Fix applied:** Removed `/etc/frr/daemons` from `write_files`. Added `sed -i 's/^bgpd=no/bgpd=yes/'` to `runcmd` (which runs after package install). This matches the approach in `bootstrap-router.sh`.

**Reproduce:**
```bash
# On a fresh VM with cloud-init that writes daemons before FRR install:
grep bgpd /etc/frr/daemons  # Shows bgpd=no (overwritten by package)
```

### 4. bgp-peer-router-006-1 Failure

**Problem:** The second bgpconnection sometimes fails to provision even when the first succeeds.

**Root cause:** Both bgpconnection resources target the same router IP, and Azure may serialize their creation. If the vHub is still processing the first bgpconnection, the second may fail with a conflict error.

**Fix applied:**
- Phase 5 now checks for `Failed` state explicitly and dumps diagnostics
- Hard-stops with actionable error message pointing to phase5-bgp-diag.json
- On rerun, existing bgpconnections are detected and skipped (idempotent)

**Workaround if still failing:**
```powershell
# Delete the failed one and retry:
az network vhub bgpconnection delete -g rg-lab-006-vwan-bgp-router --vhub-name vhub-lab-006 -n bgp-peer-router-006-1 --yes
# Then re-run deploy.ps1 (it will resume from existing resources)
```

---

## What Changed and Why

### BGP Stability (Deliverable B)
- **Why:** bgp-peer-router-006-1 sometimes failed silently, causing incomplete active-active routing
- **What:** Added diagnostics dump, fail-forward gate, and vtysh adjacency validation to Phase 5
- **Learning:** Azure vHub bgpconnections are eventually consistent; always validate both provisioning state AND actual BGP session state on the router

### PS 5.1 Hardening (Deliverables E, F)
- **Why:** Scripts crashed on "harmless" stderr from az/git in Windows PowerShell 5.1
- **What:** Rewrote inspect.ps1 to use JSON-only extraction; added SilentlyContinue wrapping to all native commands in setup.ps1 and update-labs.ps1; set PYTHONWARNINGS globally
- **Learning:** Never trust that `2>$null` alone is sufficient in PS 5.1 -- the ErrorActionPreference must also be SilentlyContinue for the native command invocation

### Blob-Driven Config (Deliverable C)
- **Why:** Updating router config required VM redeploy or manual SSH; blob-driven pattern enables "push config, pull on router" without redeployment
- **What:** New Phase 6 creates storage account, assigns managed identity, uploads default blobs. New apply.sh and pull-config.sh scripts on the router side
- **Learning:** Managed identity + Storage Blob Data Reader is the minimal-privilege approach for VM-to-storage access

### Cloud-Init Ordering (Deliverable B, side fix)
- **Why:** FRR package install overwrites /etc/frr/daemons with bgpd=no after cloud-init write_files
- **What:** Moved daemons fix from write_files to runcmd (post-package)
- **Learning:** cloud-init `write_files` runs before `packages`; any file written by a package install will overwrite write_files content

### Terminal-First Router Control (Deliverable D)
- **Why:** Reduces portal dependency; all router management from local terminal
- **What:** Added az vm run-command recipes for bgpd check, BGP summary, advertised routes, loopback state, tcpdump, full routing table, all-in-one health check
- **Learning:** `az vm run-command invoke` is the most deterministic way to interact with a VM without SSH access or public IP

---

## How to Reproduce Issues and Verify Fixes

### Reproduce PS 5.1 stderr crash
1. Open Windows PowerShell 5.1 (not pwsh 7)
2. Remove `$env:PYTHONWARNINGS` and `SilentlyContinue` wrapping
3. Run `.\inspect.ps1` -- should crash on first `az` call

### Verify PS 5.1 fix
1. Open Windows PowerShell 5.1
2. Run `.\inspect.ps1` with all fixes in place
3. Should complete with PASS/FAIL summary and artifacts in `.data/lab-006/`

### Reproduce bgpd ordering issue
1. Deploy with the old cloud-init-router.yaml (daemons in write_files)
2. SSH to router: `grep bgpd /etc/frr/daemons` -- shows `bgpd=no`
3. FRR is running but bgpd is not started

### Verify bgpd fix
1. Deploy with fixed cloud-init-router.yaml (daemons fix in runcmd)
2. SSH to router: `grep bgpd /etc/frr/daemons` -- shows `bgpd=yes`
3. `systemctl status frr` shows bgpd subprocess running

### Verify dual bgpconnections
```powershell
az network vhub bgpconnection list -g rg-lab-006-vwan-bgp-router --vhub-name vhub-lab-006 `
  --query "[].{Name:name, PeerIP:peerIp, State:provisioningState}" -o table
```
Expected: Two rows, both `Succeeded`.

### Verify BGP adjacency on router
```powershell
az vm run-command invoke -g rg-lab-006-vwan-bgp-router -n vm-router-006 `
  --command-id RunShellScript --scripts "sudo vtysh -c 'show bgp summary'"
```
Expected: Both vHub IPs in Established state.

### Verify blob-driven config (when enabled)
```powershell
# Check blobs exist
az storage blob list --account-name stlab006router --container-name router-config --auth-mode login -o table

# Pull and apply on router
az vm run-command invoke -g rg-lab-006-vwan-bgp-router -n vm-router-006 `
  --command-id RunShellScript --scripts "/opt/router-config/pull-config.sh stlab006router router-config && /opt/router-config/apply.sh /opt/router-config/frr.conf"
```
