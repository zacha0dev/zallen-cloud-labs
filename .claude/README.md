# `.claude/` — a prompt-based cloud operations package

This folder turns [Claude Code](https://claude.ai/code) into a careful operator for this lab repo.
You describe what you want in plain language ("stand up lab-007, prove the private zone
resolves, then tear it down"), and the agents, skills, rules and hooks here keep the work
inside a small set of safe, repeatable lanes.

It is written to be **copied into your own infrastructure repo**. Nothing in it is specific to
one organisation: examples use a fictional company, **acme**, and every identifier is resolved
at runtime from your own `az login`.

---

## How the pieces fit

| Piece | What it is | When it acts |
|---|---|---|
| **Rules** (`rules/`) | Always-on constraints: what may change, what must never be committed, when to stop and ask. | Every session. |
| **Skills** (`skills/`) | Playbooks. Each description names the moment it fires, so Claude loads the right one on its own. | When the task matches. |
| **Agents** (`agents/`) | Focused sub-agents with narrow tools: one plans, one keeps docs true, one only measures, one audits claims. | When a task is big enough to split, or a claim needs checking. |
| **Hooks** (`hooks/`) | Small scripts Claude Code runs at fixed points: a session-start briefing and a guard in front of destructive `az` commands. | Session start; before every shell command. |
| **Settings** (`settings.json`) | Wires the hooks in and pre-approves read-only commands. | Loaded by Claude Code. |

## The lanes

Everything that changes a cloud environment goes through one of two lanes. There is no third,
"just click it in the portal" lane.

1. **Infra lane**: infrastructure lives as code in the repo (Bicep, or the phased `deploy.ps1`
   scripts). A change is previewed (**what-if**), applied, then **verified** by measurement.
   See `skills/infra-lane`.
2. **Deploy lane**: application code is **built**, passes a **gate** (tests, a health check),
   is **rolled** out, then **verified** against the running endpoint. See `skills/deploy-lane`.

Around both lanes:

- **Tags are the address book**: every resource carries the lab tags, so "what is running,
  who owns it, what does it cost" is a query, not a memory exercise (`skills/tagging-as-addressing`).
- **Measure before claiming**: "deployed", "healthy" and "cleaned up" are only said after a
  read-only check proves them (`skills/measure-before-claiming`, `agents/measurer.md`).
- **Cost guard**: estimate before deploy, destroy after, scan for leftovers (`skills/cost-guard`).

## The agents

| Agent | Can change things? | Job |
|---|---|---|
| `orchestrator` | Plans only; hands work to the lanes | Breaks a request into infra, deploy, measure and record steps, in order, with the confirmation points marked. |
| `records-librarian` | Docs only | Keeps README, VERSION, CHANGELOG, the lab catalog and `docs/AUDIT.md` in step with what changed. |
| `measurer` | **No**: read-only | Runs `az ... show/list`, `inspect.ps1` and the cost check, and returns evidence, not opinions. |
| `claim-auditor` | **No**: read-only | Reads a draft (README, PR description, report) and flags every claim that has no evidence behind it. |

## Setup

```powershell
.\.claude\setup.ps1          # checks claude, az, node, git, bicep; prints first prompts
```

Then open the repo in Claude Code and try the prompts in [docs/AGENTIC-OPS.md](../docs/AGENTIC-OPS.md).

## Adapting it to your repo

1. Copy `.claude/` into your repo.
2. Edit `rules/scope.md`: set your resource-group prefix, allowed regions and tag schema.
3. Point `skills/infra-lane` at your IaC folder and deploy entry point.
4. Keep the rule that nothing identifying (subscription, tenant, object IDs, hostnames, emails)
   is ever written into a committed file.
