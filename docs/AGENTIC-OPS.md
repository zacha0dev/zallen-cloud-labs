# Agentic Ops with Claude Code

How to run this repo's Azure labs by prompt, safely: plan in plain words, preview every change,
apply only when you say so, and prove each result with a measurement.

Everything here lives in [`.claude/`](../.claude/README.md) and works with any Claude Code
install. It is a personal lab project; the patterns are the point, and you are welcome to copy
them into your own repos.

---

## What Problem This Solves

Letting an AI agent touch real cloud infrastructure goes wrong in predictable ways:

| Failure | What it looks like | What stops it here |
|---|---|---|
| **Silent changes** | The agent "fixes" something with a raw `az ... delete` | A pre-tool hook pauses direct cloud-changing commands run through the Bash or PowerShell tools and asks you ([`hooks/guard-cloud-changes.mjs`](../.claude/hooks/guard-cloud-changes.mjs)) |
| **Confident, wrong claims** | "Deployed and working!" when BGP never came up | Every claim needs a measurement; a `measurer` agent runs read-only checks and reports PASS/FAIL |
| **Forgotten resources** | A lab left running over a weekend | A session-start briefing lists live labs by tag; `cost-guard` and `session-closeout` check before and after |
| **Drift** | Portal clicks nobody wrote down | One path for change: code, what-if, apply, verify (`skills/infra-lane`) |
| **Leaked identifiers** | Subscription IDs or work details in a public commit | `rules/safety.md` plus a `claim-auditor` pass before anything is published |

---

## Five-Minute Quickstart (Free)

`lab-000` is a resource group and a VNet. It costs nothing, so it is the right first run.

```powershell
git clone https://github.com/zacha0dev/zallen-cloud-labs.git
cd zallen-cloud-labs
.\lab.ps1 -Setup            # Azure CLI, sign-in, subscription picker
.\.claude\setup.ps1         # checks claude, az, node, git; prints first prompts
claude
```

Claude Code opens with a short briefing (repo version, whether you are signed in, which labs
are live). Then try:

> Deploy lab-000, prove it worked, then destroy it and prove nothing is left.

What you should see:

1. A plan with lanes and a **[CONFIRM]** on each step that touches Azure.
2. You say yes. It runs `.\lab.ps1 -Deploy lab-000`, which prints its own cost estimate and asks
   again.
3. A measurement table: `CLAIM / CHECK / RESULT / VERDICT`, e.g. the resource group exists and
   carries `project=azure-labs`.
4. Destroy, then `.\lab.ps1 -Cost -Lab lab-000` coming back empty as the proof.

---

## Prompts That Work Well

| You want | Say |
|---|---|
| Know what is costing money | "What labs are live right now, and what are they costing me?" |
| A plan before anything happens | "Plan a deploy of lab-007. Don't run anything yet." |
| A change to infrastructure | "Add a second private DNS zone to lab-007. Show me the what-if first." |
| Proof, not vibes | "Prove the spoke in lab-004 learns 0.0.0.0/0 from the hub." |
| Understanding | "Explain lab-010 in plain words: what question does it answer?" |
| A new lab | "Build a lab that proves whether a Private Resolver outbound endpoint can forward to on-prem DNS over S2S." |
| Clean records | "We changed lab-008's cost. Update everything that mentions it." |
| An end-of-day stop | "Wrap up." |

---

## How It Fits Together

```
you ──prompt──> orchestrator ──plan with [CONFIRM] steps──> you say yes
                     │
      ┌──────────────┼──────────────────────┬──────────────────┐
  infra lane     deploy lane           records-librarian    claim-auditor
  code→what-if   build→gate→roll       README, VERSION,     no unmeasured claims,
  →apply→verify  →verify               CHANGELOG in step    no identifiers
      └──────────────┴────────> measurer (read-only) <──────┘
                                 CLAIM / CHECK / RESULT / VERDICT
```

- **Agents** (`.claude/agents/`) are specialists with narrow tool access. The measurer can only
  read; the orchestrator plans but does not deploy.
- **Skills** (`.claude/skills/`) are the procedures: infra-lane, deploy-lane,
  tagging-as-addressing, measure-before-claiming, cost-guard, lab-authoring, session-closeout.
- **Rules** (`.claude/rules/`) are always on: what needs your yes, what never goes in a commit,
  what this repo owns.
- **Hooks** (`.claude/hooks/`) are the guard rails that do not depend on the model remembering
  a rule.

### Tags Are the Address Book

Every resource carries `project=azure-labs`, `lab=<lab-id>`, `owner`, `environment=lab` and
`cost-center=learning`. That one convention is what makes "what's live?", "what does this lab
cost?" and "is it really gone?" single read-only queries:

```powershell
az group list --tag project=azure-labs --query "[].{rg:name, lab:tags.lab}" -o table
az resource list --tag lab=lab-007 -o table
```

---

## Taking It to CI

[`examples/github-actions/infra-lane.yml`](../examples/github-actions/infra-lane.yml) is the same
lane as a workflow: what-if on every pull request, apply only after a person approves the `lab`
environment, then a read-only verify. It signs in with OpenID Connect, so no passwords are stored
in the repo.

---

## Adapting It to Your Own Repo

1. Copy `.claude/` into your repo.
2. Edit `rules/scope.md`: your resource-group pattern, your tag schema, where your IaC lives,
   your single entry point (ours is `lab.ps1`).
3. Replace the `lab.ps1` commands in the skills with yours. The shape (preview, confirm, apply,
   measure) is what matters.
4. Keep `rules/safety.md` as is. It is the part that makes the rest safe to use.

---

## Lessons Worth Keeping

- **A hook beats a rule.** Rules in prompts get skipped under pressure; a pre-tool hook that
  pauses `az ... delete` does not.
- **"Done" is a measurement.** Asking for the check alongside the claim changed the quality of
  every session more than any prompt wording did.
- **Tags first, names second.** Names drift; a tag query finds everything a lab created,
  including the things a script forgot to name consistently.
- **The cheapest lab that answers the question.** Most questions can be answered at cents per
  hour; tear it down the same session.
- **Write the lesson where it will be found.** PowerShell 5.1 pitfalls go in `CLAUDE.md`, lab
  surprises in that lab's docs, open problems in `docs/AUDIT.md`.
