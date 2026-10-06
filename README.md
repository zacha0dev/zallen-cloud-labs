# AI-Driven Cloud Labs

> Azure networking labs you can run by prompt: a Claude Code package that plans, previews,
> applies and **measures** real infrastructure changes, with guard rails so cloud changes wait
> for your yes.

A personal project: twelve hands-on labs covering Azure Virtual WAN, BGP, site-to-site VPN
(including Azure to AWS), Azure DNS and Azure Virtual Network Manager. Each one deploys,
proves a specific behavior, and tears itself down through a single PowerShell CLI. Every lab,
script and doc was designed and iterated with [Claude Code](https://claude.ai/code) as a
coding partner, and the repo ships the agents, skills and hooks that make that workflow safe
to repeat.

---

## What This Project Shows

- **Real infrastructure, real answers.** Each lab starts from one falsifiable question (for
  example, *does a custom vWAN route table propagate 0.0.0.0/0 to spokes on the Default table?*)
  and ends with a validation phase that prints PASS or FAIL for it.
- **Networking depth.** vWAN hub routing, BGP over APIPA link-local addresses, dual-instance
  VPN gateways, an FRR router VM peering with a vWAN hub, Route Maps, DNS Private Resolver with
  forwarding rulesets and DNS Security Policy, AVNM hub-spoke with Global Mesh, and a hybrid
  Azure to AWS VPN.
- **Operational discipline.** One entry point (`lab.ps1`), itemized cost estimates before every
  deploy, tag-based discovery of anything left running, idempotent teardown, and scripts that
  run on both Windows PowerShell 5.1 and PowerShell 7.
- **Agentic IaC done carefully.** The [`.claude/`](.claude/README.md) package lets an AI agent
  operate the labs by prompt, but every cloud change goes through preview and an explicit
  confirmation, and "done" means a measurement, not a claim.

*Terms:* **vWAN** = Azure Virtual WAN, **S2S** = site-to-site VPN, **BGP** = Border Gateway
Protocol, **APIPA** = the 169.254.x.x link-local range used for BGP peering addresses,
**AVNM** = Azure Virtual Network Manager.

---

## Run It by Prompt: the Claude Code Package

The [`.claude/`](.claude/README.md) folder turns this repo into an agentic ops workspace. It
targets the usual problems with letting an AI agent touch real cloud infrastructure: silent
changes, confident-but-wrong claims, forgotten billable resources, and drift.

| Piece | What it does |
|-------|--------------|
| **Agents** | `orchestrator` plans in lanes with a confirm step; `measurer` proves claims read-only; `records-librarian` keeps docs in step; `claim-auditor` checks before anything is published |
| **Skills** | infra-lane (code, what-if, apply, verify), deploy-lane, tagging-as-addressing, measure-before-claiming, cost-guard, lab-authoring, session-closeout |
| **Rules** | No cloud change without an explicit ask; no identifiers in commits; every claim needs a measurement |
| **Hooks** | A session-start briefing of live labs, and a guard that pauses cloud-changing commands (`az`, Azure PowerShell, Terraform, AWS CLI, `lab.ps1 -Destroy`) for your approval |

```powershell
.\.claude\setup.ps1     # checks the tools, prints first prompts
claude                  # then: "Deploy lab-000, prove it worked, then destroy it and prove nothing is left."
```

Full guide: **[docs/AGENTIC-OPS.md](docs/AGENTIC-OPS.md)** · CI example: [examples/github-actions/infra-lane.yml](examples/github-actions/infra-lane.yml)

---

## Quick Start (Azure Only)

Three steps from clone to first lab:

```powershell
# 1. Clone and enter the repo
git clone https://github.com/zacha0dev/zallen-cloud-labs.git
cd zallen-cloud-labs

# 2. Set up Azure tools and pick your subscription (guided wizard)
.\lab.ps1 -Setup

# 3. Run the free baseline lab to verify everything works, then clean up
.\lab.ps1 -Deploy lab-000
.\lab.ps1 -Destroy lab-000
```

No AWS account needed. No manual JSON editing. The setup wizard detects your Azure subscriptions.

### Lab CLI (`lab.ps1`)

All operations go through a single entry point at the repo root:

```powershell
.\lab.ps1 -Help                       # All commands and options
.\lab.ps1 -Status                     # Check CLI tools, auth, and config
.\lab.ps1 -List                       # Browse labs with cost and live deployment status
.\lab.ps1 -Deploy lab-001             # Deploy a lab (prints a cost estimate, asks for DEPLOY)
.\lab.ps1 -Deploy lab-001 -Force      # Deploy without the confirmation prompt
.\lab.ps1 -Inspect lab-001            # Post-deploy validation (alias: -Validate)
.\lab.ps1 -Destroy lab-001            # Tear down cleanly
.\lab.ps1 -Cost                       # Scan for leftover billable resources
.\lab.ps1 -Cost -Lab lab-001          # ...for one lab
.\lab.ps1 -Settings                   # Account, subscriptions, and repo sync state
.\lab.ps1 -Update                     # Pull latest lab updates from GitHub
.\lab.ps1 -Setup -Aws                 # AWS setup (lab-003 only)
.\lab.ps1 -Watch -WatchTarget "myapp.example.com"   # Watch DNS/TCP/TLS/HTTP over time
```

`lab.ps1 -Research <lab-id>` runs optional research scenarios from `labs/<lab>/research/`; none
ship today, and the framework is documented in [CLAUDE.md](CLAUDE.md).

---

## Labs

| Lab | Description | Cloud | Cost |
|-----|-------------|-------|------|
| [lab-000](labs/lab-000_resource-group/) | Resource Group + VNet baseline | Azure | Free |
| [lab-001](labs/lab-001-virtual-wan-hub-routing/) | vWAN hub routing | Azure | ~$0.26/hr |
| [lab-002](labs/lab-002-l7-fastapi-appgw-frontdoor/) | App Gateway + Front Door | Azure | ~$0.31/hr |
| [lab-003](labs/lab-003-vwan-aws-bgp-apipa/) | vWAN to AWS VPN (BGP/APIPA) | Azure + AWS | ~$0.71/hr |
| [lab-004](labs/lab-004-vwan-default-route-propagation/) | vWAN default route propagation | Azure | ~$0.60/hr |
| [lab-005](labs/lab-005-vwan-s2s-bgp-apipa/) | vWAN S2S BGP/APIPA reference | Azure | ~$0.61/hr |
| [lab-006](labs/lab-006-vwan-spoke-bgp-router-loopback/) | vWAN spoke BGP router + loopback | Azure | ~$0.37/hr |
| [lab-007](labs/lab-007-azure-dns-foundations/) | Azure Private DNS Zones + auto-registration | Azure | ~$0.02/hr |
| [lab-008](labs/lab-008-azure-dns-private-resolver/) | Azure DNS Private Resolver + DNS Security Policy | Azure | ~$0.03/hr |
| [lab-009](labs/lab-009-avnm-hub-spoke-global-mesh/) | AVNM dual-region hub-spoke + Global Mesh | Azure | ~$0.01/hr |
| [lab-010](labs/lab-010-vwan-route-maps/) | vWAN Route Maps: community tagging, route filtering, AS path prepend | Azure | ~$0.26/hr |
| [lab-011](labs/lab-011-vwan-p2s-s2s-firewall-split/) | vWAN P2S + S2S on the Default route table: hub firewall vs spoke firewall | Azure | ~$2.26/hr |

Costs are list-price estimates. Goals, prerequisites and the recommended run order are in the
[lab catalog](docs/LABS/README.md).

---

## Documentation

Everything is organized at: **[docs/README.md](docs/README.md)**

| I want to... | Go to |
|-------------|-------|
| Get started (Azure-only) | [docs/ops/ONBOARDING.md](docs/ops/ONBOARDING.md) |
| Browse all labs | [docs/LABS/README.md](docs/LABS/README.md) |
| Run the labs by prompt (Claude Code) | [docs/AGENTIC-OPS.md](docs/AGENTIC-OPS.md) |
| Learn vWAN concepts | [docs/DOMAINS/vwan.md](docs/DOMAINS/vwan.md) |
| Learn Azure DNS concepts | [docs/DOMAINS/dns.md](docs/DOMAINS/dns.md) |
| Set up AWS (lab-003 only) | [docs/DOMAINS/aws-hybrid.md](docs/DOMAINS/aws-hybrid.md) |
| Validate / troubleshoot | [docs/DOMAINS/observability.md](docs/DOMAINS/observability.md) |
| Check current known issues | [docs/AUDIT.md](docs/AUDIT.md) |
| Build your own labs with AI | [CONTRIBUTING.md](CONTRIBUTING.md) |

---

## Cost Safety

**Always run `.\lab.ps1 -Destroy <lab-id>`** when done, then `.\lab.ps1 -Cost` to confirm
nothing billable is left. Every resource carries `project=azure-labs` and `lab=<lab-id>` tags,
so leftovers are one query away.

---

## Advanced: AWS Setup (lab-003 Only)

See [docs/DOMAINS/aws-hybrid.md](docs/DOMAINS/aws-hybrid.md) for AWS account, SSO, and CLI setup.

---

## Want to Build Your Own Labs?

See [CONTRIBUTING.md](CONTRIBUTING.md) for the AI-driven workflow that built this repo:
prompting patterns, lab structure conventions, and how to fork or start fresh with Claude Code.

---

> Built with [Claude Code](https://claude.ai/code) by [Zachary Allen](https://github.com/zacha0dev) · MIT licensed · 2026
