# Building Labs with Claude Code

> How this repo was built — and how you can build your own.

This repository is as much about **how it was built** as what it contains. Every lab, script, and documentation file was designed and iterated through an AI-driven workflow using [Claude Code](https://claude.ai/code).

This guide explains how that workflow operates, so you can fork this repo, build on top of it, or start your own from scratch.

---

## The AI-Driven IaC Workflow

### What "AI-Driven" Actually Means

Not: "AI wrote everything and I clicked approve."

More like: **pair programming with a senior engineer who never gets tired and doesn't charge by the hour.**

The typical cycle for any lab in this repo:

```
1. Define the goal
   "I want to prove that Azure vWAN custom route tables don't propagate
    0/0 to spokes associated with the Default RT."

2. Prompt for structure
   "Design a lab that demonstrates this. Use a 2-hub vWAN topology,
    4 spoke VNets per hub, phased deployment, PS 5.1 compatible."

3. Review and refine
   - Read the output carefully
   - Catch logical errors, naming inconsistencies, missing phases
   - "Phase 3 creates the VMs before the hub connections exist.
     Swap phases 3 and 4."

4. Iterate on details
   - "Add a -Force flag to skip the DEPLOY confirmation"
   - "The cost warning should show itemized estimates, not just totals"
   - "validate.ps1 should exit with code 1 if any check fails"

5. Test locally (dry run)
   - Parse-check the script
   - Walk through Phase 0 preflight manually
   - Deploy to Azure once, validate, destroy

6. Doc pass
   - "Write the README for this lab. Use the Lab Standard."
   - Review for accuracy and completeness
```

The key is that you're **reviewing, not just accepting**. The AI handles boilerplate, remembers conventions, and writes fast. You provide domain knowledge, make judgment calls, and catch things the AI doesn't know about your environment.

---

## Option 1: Fork This Repo and Add Labs

The fastest way to start. Fork, clone, set up your Azure subscription, then start adding labs.

```powershell
# 1. Fork on GitHub, then clone your fork
git clone https://github.com/<your-username>/zallen-cloud-labs.git
cd zallen-cloud-labs

# 2. Set up your Azure subscription
.\setup.ps1 -Azure

# 3. Run lab-000 to confirm everything works
cd labs\lab-000_resource-group
.\deploy.ps1
.\destroy.ps1
```

Then ask Claude Code to generate a new lab:

```
I want to add a new lab to this repo. Look at the existing lab structure,
especially lab-001 and lab-006. Then build lab-007: it should deploy an
Azure Load Balancer (Standard) in front of two Ubuntu VMs running a
simple Python HTTP server. Follow the lab standard at docs/ops/LAB-STANDARD.md.
Make it PS 5.1 compatible.
```

---

## Option 2: Start a Fresh Repo with Claude Code

If you want a clean slate with your own theme (different cloud focus, different company patterns, etc.):

```
1. Create a new empty GitHub repo
2. Connect Claude Code to it (https://claude.ai/code)
3. Start with a prompt like:
```

```
Create a new cloud labs repository focused on Azure App Service and
Azure Container Apps. I want the same patterns as zallen-cloud-labs
(phased deploy scripts, destroy scripts, cost-check tool, guided setup wizard)
but adapted for PaaS workloads instead of vWAN networking.

Start by:
1. Designing the repo structure (scripts/, labs/, docs/, tools/)
2. Writing setup.ps1 with -Azure and -ConfigureSubs flags
3. Creating the first baseline lab: deploy an App Service Plan + Web App
4. Writing docs/ops/ONBOARDING.md and docs/LABS/README.md
```

---

## Prompting Patterns That Work Well

### For New Labs

```
Create a lab called lab-NNN-<short-name>. The goal is: <goal>.

Requirements:
- Phased deployment (0=Preflight, 1=Core Fabric, 2=Primary Resources,
  3=Secondary, 4=Connections, 5=Validation, 6=Summary)
- PS 5.1 compatible (no ternary, no em-dashes, no null-conditional)
- Accept -SubscriptionKey, -Location, -Force parameters
- Phase 0 must show cost estimate and require "Type DEPLOY to proceed"
- Phase 5 must validate all resources and exit with code 1 if any check fails
- Save outputs to .data/lab-NNN/outputs.json
- Follow naming conventions in docs/REFERENCE.md
- Follow docs/ops/LAB-STANDARD.md

Resources to create:
<list your Azure resources>

APIPA/BGP config (if applicable):
<any specific network config>
```

### For Documentation

```
Write the README for lab-NNN. Follow the required sections in
docs/ops/LAB-STANDARD.md: Goal, Architecture (ASCII diagram), Cost,
Prerequisites, Deploy, Validate, Destroy, Troubleshooting.

Link to docs/DOMAINS/vwan.md for vWAN concepts instead of repeating them.
```

### For Fixes and Refactoring

```
Review lab-NNN/deploy.ps1. It currently has these issues:
- <specific issue 1>
- <specific issue 2>

Fix them without changing the phase structure or parameter interface.
```

### For Infrastructure as Code Reviews

```
Review this Bicep module for:
1. Security issues (no public IPs unless required, least-privilege RBAC)
2. Cost inefficiencies
3. Naming convention violations per docs/REFERENCE.md
4. Missing outputs
```

---

## Conventions to Keep Consistent

When working with Claude Code on this repo, remind it of these conventions:

| Convention | Detail |
|------------|--------|
| PS compatibility | PS 5.1 + PS 7. No ternary, no `?.`, no em-dashes |
| Naming | `rg-lab-NNN-*`, `vwan-lab-NNN`, `vhub-lab-NNN` etc. |
| Phase structure | 0-Preflight, 1-Core, 2-Primary, 3-Secondary, 4-Connect, 5-Validate, 6-Summary |
| Config loading | Always via `Get-LabConfig` and `Get-SubscriptionId` from `scripts/labs-common.ps1` |
| Cost warnings | Phase 0, before DEPLOY prompt, itemized estimate |
| Outputs | Saved to `.data/lab-NNN/outputs.json` |
| Tags | `project=azure-labs lab=lab-NNN owner=... environment=lab cost-center=learning` |
| Cleanup | `destroy.ps1` must be idempotent; ends with cleanup verification + cost-check hint |

Put these in a `CLAUDE.md` file at the repo root and Claude Code will load them automatically as instructions for every session.

---

## CLAUDE.md: Persistent Instructions for Claude Code

Create a `CLAUDE.md` at your repo root to give Claude Code persistent context about your conventions. Claude Code reads this file at the start of every session.

Example for this repo:

```markdown
# CLAUDE.md

This is an Azure networking labs repository. All labs use PowerShell (PS 5.1 + 7 compatible).

## Key Conventions
- Lab structure: docs/ops/LAB-STANDARD.md
- Naming: docs/REFERENCE.md
- No ternary operators, no em-dashes, no null-conditional operators
- Azure setup: .\setup.ps1 -Azure or .\setup.ps1 -ConfigureSubs
- Scripts load config via Get-LabConfig and Get-SubscriptionId from scripts/labs-common.ps1

## Do Not
- Deploy resources (describe/plan only unless explicitly asked)
- Commit .data/ files (they contain real subscription IDs)
- Use hardcoded subscription IDs in scripts
```

---

## Repository Structure Reference

When prompting, give Claude Code the structure as context:

```
scripts/labs-common.ps1     Shared helpers: Get-LabConfig, Get-SubscriptionId, Ensure-AzureAuth
setup.ps1                   Root setup: -Azure, -ConfigureSubs, -SubscriptionId, -Status
tools/cost-check.ps1        Read-only cost audit (Azure + AWS)
docs/ops/LAB-STANDARD.md    Lab interface contract
docs/ops/ONBOARDING.md      User onboarding
docs/DOMAINS/               Conceptual references per technology area
docs/LABS/README.md         Lab catalog
docs/AUDIT.md               Living audit log
```

---

## Resources

- [Claude Code](https://claude.ai/code) - The AI coding environment used to build this repo
- [Claude Code Docs](https://docs.anthropic.com/claude/docs/claude-code) - How to use Claude Code effectively
- [Azure CLI Reference](https://learn.microsoft.com/cli/azure/) - Azure CLI commands used in labs
- [Bicep Documentation](https://learn.microsoft.com/azure/azure-resource-manager/bicep/) - IaC language for some labs

---

> Questions, suggestions, or labs you've built? Open an issue or PR on GitHub.
