# Lab Standard

This document defines the required structure, naming conventions, and interface for every lab in this repository. All new labs must conform to this standard. Existing labs are being aligned incrementally.

---

## Required Files

Every lab directory must contain:

| File | Required | Purpose |
|------|----------|---------|
| `deploy.ps1` | Yes | Deploys all lab resources in phases |
| `destroy.ps1` | Yes | Removes all lab resources (must be idempotent) |
| `inspect.ps1` | Recommended | Post-deploy validation and route inspection |
| `README.md` | Yes | Lab documentation (see sections below) |
| `lab.config.example.json` | If lab has config | Example config file for lab-specific overrides |

---

## Script Interface: deploy.ps1

Every `deploy.ps1` must accept these common parameters:

```powershell
param(
  [string]$SubscriptionKey,    # Key from .data/subs.json (uses default if omitted)
  [string]$Location,           # Azure region (has a sensible default)
  [switch]$Force               # Skip confirmation prompts
)
```

Additional lab-specific parameters are allowed.

### Deployment Phase Structure

All deploy scripts use a numbered phase structure:

| Phase | Name | Description |
|-------|------|-------------|
| 0 | Preflight | Auth checks, config validation, cost warning, confirmation |
| 1 | Core Fabric | Resource group, VNet, vWAN, vHub |
| 2 | Primary Resources | VMs, gateways, app services, etc. |
| 3 | Secondary Resources | Additional compute, NSGs, etc. |
| 4 | Connections / Bindings | Hub connections, peerings, VPN links |
| 5 | Validation | Confirm all resources exist and are healthy |
| 6 | Summary | Print outputs, save to `.data/<lab-id>/outputs.json` |

Labs may skip phases that are not applicable (mark them N/A with a comment).

### Preflight Requirements (Phase 0)

Every Phase 0 must:
1. Check Azure CLI is installed
2. Validate the Azure region against an allowlist
3. Load and validate `.data/subs.json` via `Get-LabConfig` from `scripts/labs-common.ps1`
4. Call `Ensure-AzureAuth` (from `scripts/labs-common.ps1`)
5. Print a cost estimate (even if "FREE")
6. Require explicit confirmation unless `-Force` is provided

```powershell
# Example cost warning block
Write-Host ""
Write-Host "Cost estimate: ~`$0.26/hr while deployed" -ForegroundColor Yellow
Write-Host "  - Virtual Hub: ~`$0.25/hr" -ForegroundColor Gray
Write-Host "  - VPN Gateway: billed only when deployed" -ForegroundColor Gray
Write-Host "  Always run .\destroy.ps1 when done!" -ForegroundColor Yellow
Write-Host ""
Write-Host "Cost audit: .\tools\cost-check.ps1" -ForegroundColor DarkGray
Write-Host ""

if (-not $Force) {
  $confirm = Read-Host "Type DEPLOY to proceed"
  if ($confirm -ne "DEPLOY") { throw "Cancelled." }
}
```

---

## Script Interface: destroy.ps1

Every `destroy.ps1` must:
- Accept `-SubscriptionKey` parameter
- Be idempotent (safe to run even if resources are already deleted)
- Delete all resources created by `deploy.ps1`
- Print a cleanup verification summary at the end

```powershell
param(
  [string]$SubscriptionKey,
  [switch]$Force
)
```

### Cleanup Verification (end of destroy.ps1)

```powershell
# Verify cleanup
Write-Host ""
Write-Host "Cleanup verification:" -ForegroundColor Yellow
$rg = az group show -n $ResourceGroup -o json 2>$null | ConvertFrom-Json
if ($rg) {
  Write-Host "  [WARN] Resource group still exists: $ResourceGroup" -ForegroundColor Yellow
  Write-Host "         Check Azure Portal for remaining resources." -ForegroundColor Gray
} else {
  Write-Host "  [PASS] Resource group deleted: $ResourceGroup" -ForegroundColor Green
}
Write-Host ""
Write-Host "Run to confirm no billable resources remain:" -ForegroundColor DarkGray
Write-Host "  .\tools\cost-check.ps1" -ForegroundColor Gray
```

---

## Output Artifacts

All labs save outputs to `.data/<lab-id>/outputs.json`. This path is gitignored.

### Required outputs.json Schema

```json
{
  "metadata": {
    "lab": "lab-000",
    "deployedAt": "2026-01-01T00:00:00Z",
    "deploymentTime": "0m 20s",
    "status": "PASS"
  },
  "azure": {
    "subscriptionId": "<id>",
    "subscriptionName": "<name>",
    "location": "centralus",
    "resourceGroup": "rg-lab-000-baseline",
    "deployedResources": ["vnet-lab-000"],
    "timestamps": {
      "phase1": "0m 5s",
      "phase5": "0m 3s"
    }
  }
}
```

Additional fields are allowed. Labs with AWS resources add an `"aws"` block.

---

## README.md Required Sections

Every lab README must contain these sections in this order:

### 1. Title and One-Line Summary

```markdown
# Lab NNN: Short Descriptive Title

One sentence describing what this lab does and what you will learn.
```

### 2. Goal

What the user will learn or validate by running this lab.

### 3. Architecture Diagram

A text diagram (ASCII or Unicode) showing the resources and their relationships.

```
Virtual WAN
  └── Virtual Hub (10.60.0.0/24)
      └── Spoke VNet (10.61.0.0/16)
          └── Test VM
```

### 4. Cost

```markdown
## Cost

| Resource | Est. Cost |
|----------|-----------|
| Virtual Hub | ~$0.25/hr |
| VPN Gateway | ~$0.36/hr |
| **Total** | **~$0.61/hr** |

Always run `.\destroy.ps1` when done. Check with `.\tools\cost-check.ps1`.
```

### 5. Prerequisites

```markdown
## Prerequisites

- Azure subscription configured: `.\setup.ps1 -ConfigureSubs`
- Azure CLI + Bicep: `.\setup.ps1 -Azure`
- (lab-003 only) AWS CLI + Terraform: `.\setup.ps1 -Aws`
```

### 6. Deploy

```markdown
## Deploy

```powershell
cd labs\lab-NNN-name
.\deploy.ps1
```
```

### 7. Validate

What to check after deployment to confirm the lab is working correctly. Reference `inspect.ps1` if it exists.

### 8. Destroy

```markdown
## Destroy

```powershell
.\destroy.ps1
```

Run `.\tools\cost-check.ps1` to confirm no resources remain.
```

### 9. Troubleshooting

Common errors and how to resolve them.

---

## Naming Conventions

| Resource Type | Pattern | Example |
|---------------|---------|---------|
| Resource Group | `rg-lab-NNN-<descriptor>` | `rg-lab-001-vwan` |
| Virtual WAN | `vwan-lab-NNN` | `vwan-lab-001` |
| Virtual Hub | `vhub-lab-NNN` | `vhub-lab-001` |
| VNet | `vnet-<descriptor>-lab-NNN` | `vnet-spoke-lab-001` |
| VM | `vm-<role>-NNN` | `vm-router-006` |
| Public IP | `pip-<resource>-lab-NNN` | `pip-agw-lab-002` |
| NSG | `nsg-<scope>-lab-NNN` | `nsg-vm-lab-002` |

---

## Tagging

All resources must be tagged at the resource group level at minimum:

```powershell
$tags = "project=azure-labs lab=lab-NNN owner=$Owner environment=lab cost-center=learning"
```

---

## Lab Compliance Status

| Lab | deploy.ps1 | destroy.ps1 | inspect.ps1 | Preflight | Cost Warning | outputs.json |
|-----|-----------|------------|------------|----------|-------------|-------------|
| lab-000 | Yes | Yes | - | Yes | Yes | Yes |
| lab-001 | Yes | Yes | Yes | Yes | Yes | Partial |
| lab-002 | Yes | Yes | - | Yes | Yes | Partial |
| lab-003 | Yes | Yes | - | Yes | Yes | Partial |
| lab-004 | Yes | Yes | - | Yes | Yes | Partial |
| lab-005 | Yes | Yes | - | Yes | Yes | Partial |
| lab-006 | Yes | Yes | Yes | Yes | Yes | Yes |
