# Reference

> Quick-reference material that applies across multiple labs and domains.
> This is not a tutorial; link out to domain docs for depth.

---

## BGP ASNs Used in Labs

| Lab | Azure ASN | Peer ASN | Notes |
|-----|-----------|---------|-------|
| lab-003 | 65515 (vHub managed) | 65001 (AWS VGW) | Hybrid Azure-AWS |
| lab-005 | 65515 (vHub managed) | Custom per site | Reference APIPA |
| lab-006 | 65515 (vHub managed) | 65100 (Router VM FRR) | Spoke BGP router |

**Rules:**
- Azure vWAN hub is always ASN **65515** (fixed, managed)
- BGP peers must use a different ASN
- AWS VGW uses ASN 65001 in labs (configurable)
- FRR router VM uses ASN 65100 in labs (configurable)

---

## APIPA Address Ranges

APIPA (`169.254.x.x`) is used for BGP peering addresses on S2S VPN links. Labs use these deterministic `/30` subnets:

| Subnet | Azure BGP IP | Peer BGP IP | vHub Instance |
|--------|-------------|------------|---------------|
| `169.254.21.0/30` | `.2` | `.1` | Instance 0 |
| `169.254.21.4/30` | `.6` | `.5` | Instance 0 |
| `169.254.22.0/30` | `.2` | `.1` | Instance 1 |
| `169.254.22.4/30` | `.6` | `.5` | Instance 1 |

Pattern: `169.254.21.x` = Instance 0, `169.254.22.x` = Instance 1.

See [docs/DOMAINS/vwan.md](DOMAINS/vwan.md) for the full APIPA explanation.

---

## Cost Safety Pattern

Every billable lab follows this lifecycle:

```
deploy.ps1 (Phase 0 shows cost estimate)
  -> "Type DEPLOY to proceed"
  -> ... resources created ...
inspect.ps1 / validate
  -> ... learn from the lab ...
destroy.ps1
  -> resources deleted
  -> cleanup verification printed
.\tools\cost-check.ps1
  -> confirm nothing remains
```

**Never leave a hub or VPN gateway running unnecessarily.** A vHub costs ~$0.25/hr even with no traffic. A VPN gateway adds ~$0.36/hr.

Cost estimates are shown in each lab's Phase 0 before deployment. Check them before typing DEPLOY.

---

## Cleanup Discipline

1. Always run `.\destroy.ps1` in the lab directory when done
2. Run `.\tools\cost-check.ps1` after destroy to confirm
3. If `destroy.ps1` fails partway through, re-run it (idempotent by design)
4. If a resource group refuses to delete, check for locks in Azure Portal
5. For AWS resources, use `.\destroy.ps1 -AwsProfile aws-labs`

```powershell
# Quick cleanup check (Azure only)
.\tools\cost-check.ps1

# With AWS
.\tools\cost-check.ps1 -AwsProfile aws-labs

# Scope to a specific lab
.\tools\cost-check.ps1 -Lab lab-003
```

---

## Subscription Config Schema

`.data/subs.json` (gitignored) schema:

```json
{
  "subscriptions": {
    "lab": {
      "id": "<subscription-guid>",
      "name": "My Lab Subscription",
      "tenantId": "<tenant-guid>"
    }
  },
  "default": "lab"
}
```

Multiple subscriptions supported:

```json
{
  "subscriptions": {
    "lab":  { "id": "...", "name": "Lab Sub",  "tenantId": "..." },
    "prod": { "id": "...", "name": "Prod Sub", "tenantId": "..." }
  },
  "default": "lab"
}
```

Create/update via wizard:
```powershell
.\setup.ps1 -ConfigureSubs                    # interactive
.\setup.ps1 -SubscriptionId "<id>"            # non-interactive
.\setup.ps1 -ConfigureSubs -SubscriptionName prod  # add second key
```

---

## Allowed Azure Regions

Lab scripts enforce a region allowlist:

```
centralus, eastus, eastus2, westus2, westus3, northeurope, westeurope
```

Pass `-Location` to deploy scripts. Default is `centralus`.

---

## PowerShell Version Compatibility

All scripts target both **PowerShell 5.1** (built-in Windows) and **PowerShell 7+**.

Compatibility rules enforced in this repo:
- No em-dashes (`-`) in strings - use hyphens
- No null-conditional operators (`?.`)
- No ternary operators
- Use `[int]::TryParse()` for safe integer parsing
- Exit codes via `exit $(if ($ok) { 0 } else { 1 })`

Check your version:
```powershell
$PSVersionTable.PSVersion
```

---

## Git Workflow

```powershell
# Install GitHub CLI (optional)
winget install --id GitHub.cli
gh auth login

# Basic git setup
git config --global user.name "Your Name"
git config --global user.email "you@example.com"

# Normal workflow
git pull
# make changes
git add <specific-files>
git commit -m "descriptive message"
git push
```

**Never commit:**
- `.data/subs.json` (subscription IDs)
- `.aws/credentials` (AWS keys)
- `*.pem`, `*.key`, `*.pfx` (private keys)
- `*.tfstate` (Terraform state)

The `.gitignore` already covers these. Run `git status` before committing.

---

## Tagging Convention

All lab resources are tagged at the resource group level:

```
project=azure-labs  lab=lab-NNN  owner=<username>  environment=lab  cost-center=learning
```

The `cost-check.ps1` tool uses these tags (plus resource group name patterns) to identify lab resources.
