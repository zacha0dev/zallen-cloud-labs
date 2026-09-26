# Rule: scope and naming

Edit this file when you adopt the package in your own repo. It is the one place that says
what this repo is allowed to own.

## What this repo owns

| Setting | This repo | Your repo (example) |
|---|---|---|
| Resource group pattern | `rg-lab-NNN-*` | `rg-acme-<env>-<app>` |
| Allowed regions | the allowlist in each lab's Phase 0 | `eastus2`, `centralus` |
| Required tags | `project`, `lab`, `owner`, `environment`, `cost-center` | same five, your values |
| IaC location | `labs/<lab>/infra/*.bicep` and phased `deploy.ps1` | `infra/` |
| Single entry point | `.\lab.ps1` | your deploy script or workflow |

A resource is **ours** only if it carries `project=azure-labs` (or your project value) **and**
sits in a resource group matching the pattern above. Anything else is out of scope: read it if
useful, never change it.

## Names

- Names are derived, never invented per run: `<type>-<lab or app>-<role>`, e.g. `vnet-lab-007-hub`,
  `vm-acme-web-01`.
- One naming helper per repo (here: `scripts/labs-common.ps1`). New code calls the helper; it
  does not build names or tag strings by hand.

## Records

- One fact, one home. The lab catalog lives in `docs/LABS/README.md` and the README table;
  conventions live in `CLAUDE.md` and `docs/ops/LAB-STANDARD.md`; known issues live in
  `docs/AUDIT.md`.
- When a change affects any of those, update them in the same commit (`agents/records-librarian.md`).
