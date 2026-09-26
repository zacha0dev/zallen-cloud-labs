---
name: lab-authoring
description: Use when adding a new lab, a research scenario, or a new lab.ps1 capability, e.g. "build a lab that proves X", "add an inspect script to lab-005". Follows docs/ops/LAB-STANDARD.md so every lab deploys, validates and destroys the same way.
---

# Lab authoring

A lab is a question you can answer with real infrastructure, then tear down. Start from the
question, not the resources.

## 1. Write the question first

One sentence, falsifiable: *"Does a vWAN custom route table propagate 0.0.0.0/0 to spokes
associated with the Default route table?"* The lab exists to answer it; the validation phase is
where it gets answered.

## 2. Copy the shape

```
labs/lab-NNN-<short-name>/
  deploy.ps1                 # phases 0-6 (docs/ops/LAB-STANDARD.md)
  destroy.ps1                # idempotent; ends with cleanup verification + cost hint
  inspect.ps1                # read-only validation, runnable any time
  README.md                  # Goal, Architecture, Cost, Prereqs, Deploy, Validate, Destroy, Troubleshooting
  infra/main.bicep           # preferred for anything beyond a handful of az commands
  lab.config.example.json    # only if the lab has overrides
  research/<scenario>.ps1    # optional deeper experiments
```

Start by reading the closest existing lab; copying its Phase 0 is faster and safer than writing
one.

## 3. Non-negotiables

- **Phase 0** prints an itemised cost estimate and waits for `DEPLOY` unless `-Force`.
- **Tags** via `Get-LabTags` / `Get-LabTagString` / `Get-LabTagArgs` (`skills/tagging-as-addressing`).
- **Subscription** via `Get-SubscriptionId`; no identifiers in the code (`rules/safety.md`).
- **PowerShell 5.1 + 7**: no ternaries, no `?.`, no em-dashes in `.ps1`, two-segment `Join-Path`,
  pre-initialise pipeline variables. The full list, learned the hard way, is in `CLAUDE.md`.
- **Validation answers the question**: Phase 5 / `inspect.ps1` prints PASS or FAIL for the
  exact claim in step 1 (`skills/measure-before-claiming`).
- **Destroy is proven** by `.\lab.ps1 -Cost -Lab <lab>` coming back empty.

## 4. Before calling it done

1. Parse-check every script:
   `[System.Management.Automation.Language.Parser]::ParseFile("$PWD\labs\lab-NNN-x\deploy.ps1",[ref]$null,[ref]$null)`
2. Deploy once, run `inspect.ps1`, destroy, run the cost scan. Only then does the README say it works.
3. Hand the records to `records-librarian`: README labs table, `docs/LABS/README.md`, VERSION
   (MINOR bump for a new lab), `docs/CHANGELOG.md`.
4. Run `claim-auditor` over the new README.
