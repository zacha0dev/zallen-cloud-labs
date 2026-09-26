---
name: tagging-as-addressing
description: Use when creating any resource, when asked "what is running / what does this cost / who owns this / what's left over", or when cleaning up. Tags are the address book of the environment; every resource gets the full set and every question about the environment is answered by a tag query.
---

# Tagging as addressing

Treat tags the way you treat a street address: every resource has one, it follows a fixed
format, and you find things by looking the address up, not by remembering where you put them.

## The schema (this repo)

| Tag | Value | Why it exists |
|---|---|---|
| `project` | `azure-labs` | "Is this ours at all?" |
| `lab` | `lab-NNN` | "Which lab made it?" (and which destroy script owns it) |
| `owner` | OS username at deploy time | "Who ran it?" |
| `environment` | `lab` | Keeps lab resources out of anything production-like |
| `cost-center` | `learning` | Groups spend in Cost Management |

Adopting this in your repo: keep the five keys, change the values
(`project=acme-web`, `environment=dev`, `cost-center=platform`).

## Always use the helpers

```powershell
$tags    = Get-LabTags     -LabId "lab-010" -Owner $Owner
$tagStr  = Get-LabTagString -Tags $tags     # for az ... create --tags
$tagArgs = Get-LabTagArgs   -Tags $tags     # for az group update --tags @tagArgs
```

Hand-built tag strings drift (a typo'd key is an untagged resource). And `az group update`
on Windows needs the array form. See `CLAUDE.md`.

## Questions become queries

```powershell
# What is running for this repo right now?
az resource list --tag project=azure-labs --query "[].{lab:tags.lab, type:type, name:name}" -o table

# What did one lab leave behind?
az resource list --tag lab=lab-006 -o table

# Anything of ours that is NOT in a lab resource group? (drift)
az graph query -q "Resources | where tags.project == 'azure-labs' and resourceGroup !startswith 'rg-lab-'"

# Anything in our resource groups that is missing tags? (someone clicked it in)
az graph query -q "Resources | where resourceGroup startswith 'rg-lab-' and isnull(tags.lab)"
```

(`az graph query` needs the `resource-graph` extension: `az extension add -n resource-graph`.)

## When a resource has no tags

It was created outside the lanes. Don't delete it on sight: report it (name, type, resource
group), find out which lab or person made it, then either add it to that lab's IaC with tags or
remove it through the lab's destroy.
