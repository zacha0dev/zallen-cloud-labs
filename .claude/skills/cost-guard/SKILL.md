---
name: cost-guard
description: Use before deploying anything that bills, when a session is ending, when someone asks "what am I paying for?", or when a lab has been up longer than planned. Estimate before, destroy after, scan for leftovers, and never end a session with a lab running unless the person chose that.
---

# Cost guard

Lab infrastructure bills by the hour whether you are looking at it or not. Virtual WAN hubs and
VPN gateways are the usual surprise. The guard has three moments.

## Before deploy

- Every lab's Phase 0 prints an itemised estimate and waits for `DEPLOY`. Read it to the person;
  don't skip it with `-Force` unless they already agreed to the cost in this session.
- Say the number and the clock together: "~$0.60/hr, so about $5 if we leave it up overnight."
- Prefer the cheapest lab that answers the question. `lab-000` is free and proves your setup.

## After use

```powershell
.\lab.ps1 -Destroy lab-004
.\lab.ps1 -Cost -Lab lab-004        # must come back empty before you say "cleaned up"
```

Some resources (VPN gateways, vWAN hubs) can take many minutes to delete. A destroy that
"finished" may still have deletes in flight; the cost scan is the proof.

## Leftover scan

```powershell
.\lab.ps1 -Cost                                  # every lab
.\lab.ps1 -List                                  # labs with a live resource group
az group list --tag project=azure-labs -o table  # the tag view of the same question
```

Run it at the start of a session too: yesterday's forgotten hub is today's first finding.

## Ending a session

Before signing off, list what is still running and its hourly cost, and ask whether to destroy
it. If the person wants to keep something up, write down what and until when in the session
summary (see `skills/session-closeout`).
