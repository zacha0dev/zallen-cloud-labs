---
name: infra-lane
description: Use whenever infrastructure is about to be created, changed or removed: deploying or destroying a lab, editing a Bicep file, changing a network, DNS or gateway resource, or someone says "just create it in the portal". The one path for infra changes is code in the repo, what-if, apply, verify.
---

# Infra lane: code → what-if → apply → verify

Infrastructure changes happen one way: **from code in this repo**, previewed, applied by a
script or workflow, then measured. Never by hand in the portal, never by a one-off
`az ... create` typed into a shell. Hand changes drift, can't be reviewed, and can't be torn
down cleanly.

## 1. Code

- The change lives in the lab's IaC: `labs/<lab>/infra/main.bicep` (+ modules) where the lab
  has one, otherwise the phased `labs/<lab>/deploy.ps1`.
- Names and tags come from the shared helpers (`scripts/labs-common.ps1`): `Get-LabTags`,
  `Get-LabTagString`, `Get-LabTagArgs`. Never a hand-built tag string.
- No identifiers in the code (see `rules/safety.md`). Subscription comes from `-SubscriptionKey`.

## 2. What-if (preview, changes nothing)

For Bicep-based labs, preview before applying. This repo's scripts apply directly, so run the
preview yourself when the change is non-trivial:

```powershell
az deployment group what-if `
  --resource-group rg-lab-007-dns-foundations `
  --template-file labs/lab-007-azure-dns-foundations/infra/main.bicep `
  --parameters labs/lab-007-azure-dns-foundations/infra/main.parameters.json `
  --parameters adminPassword=$env:LAB_ADMIN_PASSWORD   # the file only holds a placeholder
```

Read the diff out loud to the person: what is **created**, **modified**, **deleted**. Any
delete or any change outside the lab's resource group stops the lane until they confirm.

## 3. Apply (only after an explicit ask)

```powershell
.\lab.ps1 -Deploy lab-007          # interactive: prints cost, asks for DEPLOY
.\lab.ps1 -Deploy lab-007 -Force   # only when the person already said go in this session
```

In a team repo, apply from a workflow instead of a laptop: see
`examples/github-actions/infra-lane.yml` (what-if on pull request, apply on manual approval,
federated credentials, no stored secrets).

## 4. Verify

Hand off to the `measurer` agent, or run the checks yourself, read-only:

```powershell
.\lab.ps1 -Inspect lab-007
az group show -n rg-lab-007-dns-foundations --query properties.provisioningState -o tsv
az resource list --tag lab=lab-007 -o table
```

"Deployed" is said only when these pass (see `skills/measure-before-claiming`).

## Removing infra

Same lane, reversed: `.\lab.ps1 -Destroy <lab>`, then verify with `.\lab.ps1 -Cost -Lab <lab>`.
Destroy scripts are idempotent, so re-running after a partial failure is safe.

## If the portal is the only way

Some settings genuinely have no CLI or Bicep path yet. Then: do it once, write the exact steps
into the lab's README under **Manual steps**, and add a `docs/AUDIT.md` entry so it gets
automated later.
