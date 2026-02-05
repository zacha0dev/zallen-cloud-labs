# Azure Labs

Hands-on Azure networking labs with repeatable deploy/validate/destroy workflows. Includes vWAN, routing, VPN, and one optional Azure↔AWS hybrid lab.

## Quick Start

```powershell
# Clone
git clone https://github.com/zacha0dev/azure-labs.git
cd azure-labs

# Setup
.\setup.ps1 -Status        # Check environment
.\setup.ps1 -DoLogin       # Login if needed

# Configure subscription
copy .data\subs.example.json .data\subs.json
notepad .data\subs.json    # Add your subscription ID

# Run a lab
cd labs\lab-000_resource-group
.\deploy.ps1
.\destroy.ps1              # Always clean up!
```

## ⚠️ Cost Safety

Some labs deploy **billable resources** (vWAN hubs, VPN gateways, VMs).

- **Always run `.\destroy.ps1`** when done
- Run `.\tools\cost-check.ps1` to find leftover resources
- Check cost estimates in each lab's README before deploying

## Labs

| Lab | Description | Cloud | Cost |
|-----|-------------|-------|------|
| [lab-000](labs/lab-000_resource-group/) | Resource Group + VNet basics | Azure | Free |
| [lab-001](labs/lab-001-virtual-wan-hub-routing/) | vWAN hub routing | Azure | ~$0.25/hr |
| [lab-002](labs/lab-002-l7-fastapi-appgw-frontdoor/) | App Gateway + Front Door | Azure | ~$0.50/hr |
| [lab-003](labs/lab-003-vwan-aws-bgp-apipa/) | vWAN ↔ AWS VPN (BGP/APIPA) | Azure + AWS | ~$0.70/hr |
| [lab-004](labs/lab-004-vwan-default-route-propagation/) | vWAN default route propagation | Azure | ~$0.60/hr |
| [lab-005](labs/lab-005-vwan-s2s-bgp-apipa/) | vWAN S2S BGP/APIPA (reference) | Azure | ~$0.60/hr |

## Documentation

| Doc | Description |
|-----|-------------|
| [Setup Overview](docs/setup-overview.md) | Full setup walkthrough |
| [Configuration](docs/labs-config.md) | Subscription & config files |
| [AWS Setup](docs/aws-setup.md) | AWS CLI profile for lab-003 |
| [Observability](docs/observability-index.md) | Health gates & troubleshooting |
| [Tools](tools/README.md) | Cost-check and utilities |

## AWS (lab-003 only)

AWS is only needed for the hybrid lab. Quick setup:

```powershell
# Create SSO profile (one-time)
aws configure sso --profile aws-labs

# Login via browser (run when token expires)
aws sso login --profile aws-labs
```

See [docs/aws-setup.md](docs/aws-setup.md) for detailed instructions.

## Security

**Public repository** - no secrets committed.

- Config files with real IDs are **gitignored**
- Only templates with placeholders (`00000000-...`) are tracked
- Run `git status` before committing to verify

---

Zachary Allen - 2026
