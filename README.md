# Zallen Cloud Labs

Personal lab collection for cloud networking and hybrid connectivity. Mostly Azure vWAN, some AWS.

> Independent project. Not affiliated with Microsoft or Amazon.

## Quick Start (Azure Only)

Three commands from clone to first lab:

```powershell
# 1. Clone and enter the repo
git clone https://github.com/zacha0dev/zallen-cloud-labs.git
cd zallen-cloud-labs

# 2. Set up Azure tools + pick your subscription (guided)
.\setup.ps1 -Azure

# 3. Run the free baseline lab to verify everything works
cd labs\lab-000_resource-group
.\deploy.ps1
.\destroy.ps1    # Always clean up!
```

No AWS account needed. No manual JSON editing required.

> New here? See the full [Onboarding Guide](docs/ops/ONBOARDING.md).

---

## Setup Commands Reference

```powershell
.\setup.ps1 -Azure           # Azure setup + subscription wizard (run once)
.\setup.ps1 -ConfigureSubs   # Re-run subscription wizard any time
.\setup.ps1 -Status          # Quick environment check
.\setup.ps1 -SubscriptionId "00000000-..."  # Non-interactive config
```

---

## Cost Safety

Some labs deploy **billable resources** (vWAN hubs, VPN gateways, VMs).

- **Always run `.\destroy.ps1`** when done
- Run `.\tools\cost-check.ps1` to find leftover resources
- Check cost estimates in each lab's README before deploying

---

## Labs

| Lab | Description | Cloud | Cost |
|-----|-------------|-------|------|
| [lab-000](labs/lab-000_resource-group/) | Resource Group + VNet basics | Azure | Free |
| [lab-001](labs/lab-001-virtual-wan-hub-routing/) | vWAN hub routing | Azure | ~$0.26/hr |
| [lab-002](labs/lab-002-l7-fastapi-appgw-frontdoor/) | App Gateway + Front Door | Azure | ~$0.30/hr |
| [lab-003](labs/lab-003-vwan-aws-bgp-apipa/) | vWAN to AWS VPN (BGP/APIPA) | Azure + AWS | ~$0.70/hr |
| [lab-004](labs/lab-004-vwan-default-route-propagation/) | vWAN default route propagation | Azure | ~$0.60/hr |
| [lab-005](labs/lab-005-vwan-s2s-bgp-apipa/) | vWAN S2S BGP/APIPA (reference) | Azure | ~$0.61/hr |
| [lab-006](labs/lab-006-vwan-spoke-bgp-router-loopback/) | vWAN spoke BGP router + loopback | Azure | ~$0.37/hr |

---

## Documentation

| Doc | Description |
|-----|-------------|
| [Onboarding Guide](docs/ops/ONBOARDING.md) | Start here - Azure-only setup walkthrough |
| [Lab Standard](docs/ops/LAB-STANDARD.md) | Lab interface contract and conventions |
| [Setup Overview](docs/setup-overview.md) | Detailed setup reference |
| [Configuration](docs/labs-config.md) | Subscription and config file guide |
| [Observability](docs/observability-index.md) | Health gates and troubleshooting patterns |
| [Tools](tools/README.md) | Cost-check and utilities |

---

## Advanced: AWS Setup (lab-003 Only)

AWS is only needed for the hybrid lab. Skip this unless you plan to run lab-003.

```powershell
# One-time AWS CLI + SSO setup
aws configure sso --profile aws-labs

# Login when token expires
aws sso login --profile aws-labs

# Run AWS setup check
.\setup.ps1 -Aws
```

See [docs/aws-setup.md](docs/aws-setup.md) for detailed instructions.

---

## Security

**Public repository** - no secrets committed.

- Config files with real IDs are **gitignored** (`.data/subs.json`, etc.)
- Only templates with placeholders (`00000000-...`) are tracked
- Run `git status` before committing to verify

---

Zachary Allen - 2026
