---
name: measure-before-claiming
description: Use right before saying anything is deployed, working, healthy, connected, resolving, fixed, cleaned up, cheap or free, and before writing a status update, PR description or README claim. Every such statement needs a read-only measurement shown alongside it.
---

# Measure before claiming

A claim is anything the reader will act on: "it's deployed", "BGP is up", "the zone resolves",
"nothing is left running". Agents are fluent, and fluency sounds like certainty, so this lab
holds one rule: **no claim without the measurement next to it.**

## The pattern

1. Write the claim you want to make, as one sentence.
2. Pick the read-only command whose output would prove it.
3. Run it (or ask the `measurer` agent).
4. Say the claim **with** the evidence, or say what you found instead.

| Claim | Measurement |
|---|---|
| "lab-001 is deployed" | `az group show -n <rg> --query properties.provisioningState` → `Succeeded`, plus `.\lab.ps1 -Inspect lab-001` passing |
| "the VPN tunnel is up" | `az network vpn-connection show ... --query connectionStatus` → `Connected` |
| "BGP learned the route" | `az network vhub get-effective-routes ...` shows the prefix |
| "the private zone resolves" | an in-VM `getent hosts app.acme.internal` returns the expected IP (see `CLAUDE.md` for the run-command pattern) |
| "it's cleaned up" | `az group show` returns not-found **and** `.\lab.ps1 -Cost -Lab <lab>` is empty |
| "it costs ~$0.26/hr" | the lab README's cost table, with its date; say "estimate" |

## Words to watch

- **"Should"** ("should be up", "should resolve") means you didn't measure. Measure, then
  drop the word.
- **"Done"** covers the whole request. If only part is measured, say which part.
- **"Fixed"** needs a before (the failure) and an after (the same check passing).

## When the measurement disagrees

Report the disagreement first, plainly: "The deploy script finished, but the tunnel shows
`NotConnected`." Then investigate. Never smooth it over to keep the story tidy.
