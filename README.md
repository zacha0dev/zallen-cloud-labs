# Zallen Cloud Labs

Personal lab collection for cloud networking and hybrid connectivity. Mostly Azure vWAN, some AWS.

> Independent project. Not affiliated with Microsoft or Amazon.

---

## Quick Start (Azure Only)

Three commands from clone to first lab:

```powershell
# 1. Clone and enter the repo
git clone https://github.com/zacha0dev/zallen-cloud-labs.git
cd zallen-cloud-labs

# 2. Set up Azure tools + pick your subscription (guided)
.\setup.ps1 -Azure

# 3. Run the free baseline lab
cd labs\lab-000_resource-group
.\deploy.ps1
.\destroy.ps1    # Always clean up!
```

No AWS account needed. No manual JSON editing required.

Full onboarding guide: [docs/ops/ONBOARDING.md](docs/ops/ONBOARDING.md)

---

## Documentation

All documentation is at: **[docs/README.md](docs/README.md)**

| I want to... | Go to |
|-------------|-------|
| Get started (Azure-only) | [docs/ops/ONBOARDING.md](docs/ops/ONBOARDING.md) |
| Browse all labs | [docs/LABS/README.md](docs/LABS/README.md) |
| Learn vWAN concepts | [docs/DOMAINS/vwan.md](docs/DOMAINS/vwan.md) |
| Set up AWS (lab-003 only) | [docs/DOMAINS/aws-hybrid.md](docs/DOMAINS/aws-hybrid.md) |
| Validate / troubleshoot | [docs/DOMAINS/observability.md](docs/DOMAINS/observability.md) |
| Check current status / known issues | [docs/AUDIT.md](docs/AUDIT.md) |

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

---

## Cost Safety

**Always run `.\destroy.ps1`** when done. Run `.\tools\cost-check.ps1` to find leftover resources.

---

## Advanced: AWS Setup (lab-003 Only)

See [docs/DOMAINS/aws-hybrid.md](docs/DOMAINS/aws-hybrid.md).

---

Zachary Allen - 2026
