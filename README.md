# AI-Driven Cloud Labs

> Azure networking labs you can run by prompt: a Claude Code package that plans, previews, applies and **measures** real infrastructure changes, with guard rails so nothing reaches the cloud without your yes.

**Topics:** Claude Code Azure infrastructure · prompt-based infrastructure management · agentic IaC · AI-driven cloud operations lab · Azure Virtual WAN · BGP · Azure DNS · Bicep · PowerShell

A personal lab collection focused on Azure Virtual WAN, hybrid connectivity, and cloud networking patterns. Built using an AI-driven approach: every lab, script, and doc in this repository was designed and iterated with Claude Code as a coding partner.

---

## Why This Exists

Two goals:

**1. Learn by building.** Real Azure infrastructure, real costs, real BGP sessions. No sandboxes, no simulations.

**2. Show the AI-driven IaC workflow.** Every commit in this repo reflects a human-AI collaboration — prompting, reviewing, refining. If you want to build your own labs using Claude Code, this is a working reference for how to do it.

---

## Run It by Prompt: the Claude Code Package

The [`.claude/`](.claude/README.md) folder turns this repo into an agentic ops workspace. It solves the usual problems with letting an AI agent touch real cloud infrastructure: silent changes, confident-but-wrong claims, forgotten billable resources, and drift.

| Piece | What it does |
|-------|--------------|
| **Agents** | `orchestrator` plans in lanes with a confirm step; `measurer` proves claims read-only; `records-librarian` keeps docs in step; `claim-auditor` checks before anything is published |
| **Skills** | infra-lane (code, what-if, apply, verify), deploy-lane, tagging-as-addressing, measure-before-claiming, cost-guard, lab-authoring, session-closeout |
| **Rules** | No cloud change without an explicit ask; no identifiers in commits; every claim needs a measurement |
| **Hooks** | A session-start briefing of live labs, and a guard that pauses raw `az ... create/delete` for your approval |

```powershell
.\.claude\setup.ps1     # checks the tools, prints first prompts
claude                  # then: "Deploy lab-000, prove it worked, then destroy it and prove nothing is left."
```

Full guide: **[docs/AGENTIC-OPS.md](docs/AGENTIC-OPS.md)** · CI example: [examples/github-actions/infra-lane.yml](examples/github-actions/infra-lane.yml)

---

## Quick Start (Azure Only)

Three commands from clone to first lab:

```powershell
# 1. Clone and enter the repo
git clone https://github.com/zacha0dev/zallen-cloud-labs.git
cd zallen-cloud-labs

# 2. Set up Azure tools + pick your subscription (guided wizard)
.\lab.ps1 -Setup

# 3. Run the free baseline lab to verify everything works
.\lab.ps1 -Deploy lab-000
.\lab.ps1 -Destroy lab-000    # Always clean up!
```

No AWS account needed. No manual JSON editing. The setup wizard auto-detects your Azure subscriptions.

### Lab CLI (`lab.ps1`)

All operations go through a single entry point at the repo root:

```powershell
.\lab.ps1 -Help                       # All commands and options
.\lab.ps1 -Status                     # Check CLI tools, auth, and config
.\lab.ps1 -List                       # Browse labs with cost and live deployment status
.\lab.ps1 -Deploy lab-001             # Deploy a lab
.\lab.ps1 -Deploy lab-001 -Force      # Deploy without confirmation prompt
.\lab.ps1 -Destroy lab-001            # Tear down cleanly
.\lab.ps1 -Inspect lab-001            # Post-deploy validation
.\lab.ps1 -Research lab-008                              # List research scenarios for a lab
.\lab.ps1 -Research lab-008 -Scenario cache-recovery    # Run a research scenario
.\lab.ps1 -Research lab-008 -Scenario cache-recovery -Background  # Run in background
.\lab.ps1 -Cost                       # Scan for leftover billable resources
.\lab.ps1 -Settings                   # Account, subscriptions, and repo sync state
.\lab.ps1 -Update                     # Pull latest lab updates from GitHub
.\lab.ps1 -Setup -Aws                 # AWS setup (lab-003 only)
.\lab.ps1 -Watch -WatchTarget "myapp.azure.com"   # Watch DNS/TCP/TLS/HTTP over time
```

### Research Mode

Labs include **research scenarios** — scripts that run on top of a deployed lab to investigate specific networking behaviors and generate structured JSON reports.

```powershell
.\lab.ps1 -Research lab-008                                            # list scenarios
.\lab.ps1 -Research lab-008 -Scenario cache-recovery                   # run (foreground)
.\lab.ps1 -Research lab-008 -Scenario cache-recovery -Background       # run (background job)
```

Reports are written to `outputs/<lab-id>/` at the repo root. Background jobs write a status file you can poll with `Get-Content outputs/lab-008/cache-recovery-status.json | ConvertFrom-Json`.

---

## Documentation

Everything is organized at: **[docs/README.md](docs/README.md)**

| I want to... | Go to |
|-------------|-------|
| Get started (Azure-only) | [docs/ops/ONBOARDING.md](docs/ops/ONBOARDING.md) |
| Browse all labs | [docs/LABS/README.md](docs/LABS/README.md) |
| Learn vWAN concepts | [docs/DOMAINS/vwan.md](docs/DOMAINS/vwan.md) |
| Set up AWS (lab-003 only) | [docs/DOMAINS/aws-hybrid.md](docs/DOMAINS/aws-hybrid.md) |
| Validate / troubleshoot | [docs/DOMAINS/observability.md](docs/DOMAINS/observability.md) |
| Check current known issues | [docs/AUDIT.md](docs/AUDIT.md) |
| Build your own labs with AI | [CONTRIBUTING.md](CONTRIBUTING.md) |
| Run the labs by prompt (Claude Code) | [docs/AGENTIC-OPS.md](docs/AGENTIC-OPS.md) |

---

## Labs

| Lab | Description | Cloud | Cost |
|-----|-------------|-------|------|
| [lab-000](labs/lab-000_resource-group/) | Resource Group + VNet baseline | Azure | Free |
| [lab-001](labs/lab-001-virtual-wan-hub-routing/) | vWAN hub routing | Azure | ~$0.26/hr |
| [lab-002](labs/lab-002-l7-fastapi-appgw-frontdoor/) | App Gateway + Front Door | Azure | ~$0.30/hr |
| [lab-003](labs/lab-003-vwan-aws-bgp-apipa/) | vWAN to AWS VPN (BGP/APIPA) | Azure + AWS | ~$0.70/hr |
| [lab-004](labs/lab-004-vwan-default-route-propagation/) | vWAN default route propagation | Azure | ~$0.60/hr |
| [lab-005](labs/lab-005-vwan-s2s-bgp-apipa/) | vWAN S2S BGP/APIPA reference | Azure | ~$0.61/hr |
| [lab-006](labs/lab-006-vwan-spoke-bgp-router-loopback/) | vWAN spoke BGP router + loopback | Azure | ~$0.37/hr |
| [lab-007](labs/lab-007-azure-dns-foundations/) | Azure Private DNS Zones + auto-registration | Azure | ~$0.02/hr |
| [lab-008](labs/lab-008-azure-dns-private-resolver/) | Azure DNS Private Resolver + forwarding ruleset | Azure | ~$0.03/hr |
| [lab-009](labs/lab-009-avnm-hub-spoke-global-mesh/) | AVNM dual-region hub-spoke + Global Mesh | Azure | ~$0.01/hr |
| [lab-010](labs/lab-010-vwan-route-maps/) | vWAN Route Maps: community tagging, route filtering, AS path prepend | Azure | ~$0.26/hr |

---

## Cost Safety

**Always run `.\lab.ps1 -Destroy <lab-id>`** when done. Run `.\lab.ps1 -Cost` to scan for leftover billable resources.

---

## Advanced: AWS Setup (lab-003 Only)

See [docs/DOMAINS/aws-hybrid.md](docs/DOMAINS/aws-hybrid.md) for complete AWS account, SSO, and CLI setup instructions.

---

## Want to Build Your Own Labs?

See [CONTRIBUTING.md](CONTRIBUTING.md) for the AI-driven workflow that built this repo — prompting patterns, lab structure conventions, and how to fork or start fresh with Claude Code.

---

> Built with [Claude Code](https://claude.ai/code) by [Zachary Allen](https://github.com/zacha0dev) - 2026
