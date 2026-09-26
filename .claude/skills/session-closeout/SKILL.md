---
name: session-closeout
description: Use when a working session is ending ("that's it for today", "wrap up", "let's stop here") or before handing work to someone else. Leaves no billable surprises, no undocumented changes, and a short note that lets the next session start in minutes.
---

# Session closeout

Five checks, in order. Each is quick; skipping any of them is how labs quietly cost money or
lose what was learned.

## 1. What is still running?

```powershell
.\lab.ps1 -List
.\lab.ps1 -Cost
```

For anything live, ask: destroy now, or keep until a stated time? (`skills/cost-guard`)

## 2. What changed, and is it measured?

List each change made this session with the check that proves it
(`skills/measure-before-claiming`). Anything unmeasured is written down as **unverified**, not
dropped.

## 3. What did we learn?

A new PowerShell 5.1 or Azure CLI pitfall, a service behaving differently than the docs say, a
faster validation: add it where it will be found next time.

- A convention or pitfall → `CLAUDE.md` (the "Learned Rules" section)
- A lab-specific surprise → that lab's `docs/troubleshooting.md` or `docs/validation.md`
- An open problem → `docs/AUDIT.md`

Write the rule, the symptom that revealed it, and the fix, the way the existing entries in
`CLAUDE.md` do.

## 4. Are the records in step?

Hand to `records-librarian` if a lab, a flag, a cost or a known issue changed: README, VERSION,
CHANGELOG, lab catalog.

## 5. The handover note

Five lines, in the session's final message:

```
Running:   lab-006 (rg-lab-006-*), ~$0.37/hr, keep until Fri 17:00 (or: nothing running)
Changed:   <file or resource> - <verified by ...>
Learned:   <one line, and where it was written down>
Open:      <anything unverified or blocked, with the next command to run>
Next:      <the first thing to do next session>
```
