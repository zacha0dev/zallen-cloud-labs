# Lab 002: L7 Load Balancing with Application Gateway + Front Door

Deploy a FastAPI application behind Azure Application Gateway and Azure Front Door. Learn Layer 7 load balancing, health probes, and global CDN distribution.

## Purpose

- Deploy a FastAPI app on an Ubuntu VM (port 8000)
- Create Application Gateway (Standard_v2) as regional L7 load balancer
- Add Azure Front Door (Standard) for global distribution
- Configure health probes at `/health` endpoint

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│    Internet                                                     │
│        │                                                        │
│        ▼                                                        │
│  ┌─────────────────────────────────────┐                       │
│  │      Azure Front Door (CDN)         │                       │
│  │      afd-endpoint-xxx.azurefd.net   │                       │
│  └──────────────┬──────────────────────┘                       │
│                 │                                               │
│                 ▼                                               │
│  ┌─────────────────────────────────────┐                       │
│  │     Application Gateway (L7 LB)     │                       │
│  │     pip-agw-lab-002                 │                       │
│  │     ┌─────────────────────┐         │                       │
│  │     │ Listener: Port 80   │         │                       │
│  │     │ Backend: Port 8000  │         │                       │
│  │     │ Probe: /health      │         │                       │
│  │     └─────────────────────┘         │                       │
│  └──────────────┬──────────────────────┘                       │
│                 │                                               │
│                 ▼                                               │
│  ┌─────────────────────────────────────┐                       │
│  │           VNet (10.72.0.0/16)       │                       │
│  │  ┌─────────────┐  ┌─────────────┐   │                       │
│  │  │ snet-agw    │  │ snet-vm     │   │                       │
│  │  │ 10.72.1.0/24│  │ 10.72.2.0/24│   │                       │
│  │  └─────────────┘  └──────┬──────┘   │                       │
│  │                          │          │                       │
│  │                   ┌──────▼──────┐   │                       │
│  │                   │  FastAPI VM │   │                       │
│  │                   │  Port 8000  │   │                       │
│  │                   └─────────────┘   │                       │
│  └─────────────────────────────────────┘                       │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

```powershell
cd labs/lab-002-l7-fastapi-appgw-frontdoor
./deploy.ps1 -AdminPassword "YourPassword123!"
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SubscriptionKey` | (from config) | Subscription key from `.data/subs.json` |
| `-Location` | `centralus` | Azure region |
| `-AdminPassword` | *required* | VM admin password |
| `-Owner` | (from env) | Owner tag value |
| `-Force` | (switch) | Skip confirmation prompts |

## Deployment Phases

| Phase | Description | Duration |
|-------|-------------|----------|
| 0 | Preflight Checks | ~5s |
| 1 | Core Fabric (RG + VNet) | ~30s |
| 2 | FastAPI VM | ~2-3 min |
| 3 | Application Gateway | ~5-8 min |
| 4 | Azure Front Door | ~2-3 min |
| 5 | Validation | ~30s |
| 6 | Summary | ~5s |

**Total: ~10-15 minutes** (AGW provisioning dominates)

## Resources Created

| Resource | Name | Notes |
|----------|------|-------|
| Resource Group | `rg-lab-002-l7-lb` | Contains all resources |
| Virtual Network | `vnet-lab-002` | 10.72.0.0/16 |
| Application Gateway | `agw-lab-002` | Standard_v2, 1 instance |
| Front Door | `afd-lab-002` | Standard SKU |
| VM | `vm-fastapi-002` | Ubuntu 22.04 with FastAPI |
| Public IP | `pip-agw-lab-002` | For App Gateway |
| NSG | `nsg-lab-002-vm` | Controls VM access |

## Cost Estimate

| Resource | Approximate Cost |
|----------|------------------|
| Application Gateway (Standard_v2) | ~$0.25/hour |
| Front Door (Standard) | ~$0.03/hour + data |
| VM (Standard_B1s) | ~$0.01/hour |

**Estimated total: ~$0.30/hour (~$7.20/day)**

Run `destroy.ps1` when done to avoid ongoing charges.

## Tags Applied

```json
{
  "project": "azure-labs",
  "lab": "lab-002",
  "owner": "<from config>",
  "environment": "lab",
  "cost-center": "learning"
}
```

## Validation

Quick validation:
```powershell
# Check Application Gateway status
az network application-gateway show -g rg-lab-002-l7-lb -n agw-lab-002 --query provisioningState -o tsv

# Check Front Door status
az afd profile show -g rg-lab-002-l7-lb --profile-name afd-lab-002 --query provisioningState -o tsv

# Test endpoints
afdHost=$(az afd endpoint show -g rg-lab-002-l7-lb --profile-name afd-lab-002 --endpoint-name afd-endpoint-lab-002 --query hostName -o tsv)
curl http://$afdHost/health
```

See [docs/validation.md](docs/validation.md) for comprehensive validation commands.

**Operational Observability:** See [docs/observability.md](docs/observability.md) for health gates, troubleshooting patterns, and what NOT to look at.

## Endpoints

After deployment:

| Endpoint | URL | Description |
|----------|-----|-------------|
| Front Door | `http://afd-endpoint-xxx.azurefd.net/` | Global CDN entry point |
| App Gateway | `http://<pip-agw-lab-002>/` | Regional L7 load balancer |
| Health Check | `*/health` | Returns `{"ok": true}` |

## FastAPI App

The VM runs a simple FastAPI app:

```python
from fastapi import FastAPI
app = FastAPI()

@app.get("/health")
def health():
    return {"ok": True}

@app.get("/")
def root():
    return {"message": "Hello from FastAPI behind App Gateway + Front Door"}
```

## Cleanup

```powershell
./destroy.ps1
```

Run the cost audit tool to confirm no billable resources remain:

```powershell
.\tools\cost-check.ps1
```

## Files

```
lab-002-l7-fastapi-appgw-frontdoor/
├── deploy.ps1      # Main deployment script (7 phases)
├── destroy.ps1     # Cleanup script
├── allow-myip.ps1  # Add your IP to NSG for SSH
├── README.md       # This file
├── docs/
│   └── validation.md
├── logs/           # Runtime logs
└── outputs/        # Generated outputs (outputs.json)
```

## Key Learnings

1. **Application Gateway** provides L7 load balancing with URL-based routing
2. **Health probes** verify backend health before routing traffic
3. **Front Door** adds global CDN, SSL termination, and WAF capabilities
4. **Backend port mapping**: Front Door (80) -> App Gateway (80) -> VM (8000)

## Troubleshooting

**"Backend unhealthy" in App Gateway:**
- Wait 2-3 minutes for FastAPI to start (cloud-init)
- SSH to VM and check: `sudo systemctl status fastapi`

**Front Door returns 503:**
- Check App Gateway backend pool health
- Verify Front Door origin is pointing to correct IP

**Can't SSH to VM:**
- Run `allow-myip.ps1` to add your public IP to NSG

## References

- [Application Gateway overview](https://learn.microsoft.com/azure/application-gateway/overview)
- [Azure Front Door](https://learn.microsoft.com/azure/frontdoor/front-door-overview)
- [Health probes](https://learn.microsoft.com/azure/application-gateway/application-gateway-probe-overview)
