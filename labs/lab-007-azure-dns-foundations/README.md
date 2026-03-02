# Lab 007: Azure DNS Foundations

Learn Azure Private DNS Zones — zone creation, VNet linking, auto-registration, and static A records — in a minimal single-VNet topology.

---

## Goal

| What you learn | How |
|---|---|
| Create a Private DNS Zone | Bicep + Azure CLI |
| Link a zone to a VNet | `registrationEnabled: true` |
| Auto-register VM hostnames | Platform does it at boot |
| Create a static A record | Explicit record set in zone |
| Validate resolution | `nslookup` / `dig` from inside the VNet |

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Resource Group: rg-lab-007-dns-foundations          │
│                                                     │
│  VNet: vnet-lab-007 (10.70.0.0/16)                  │
│  └── Subnet: snet-workload-007 (10.70.1.0/24)       │
│       └── vm-test-007 (Standard_B1s, no public IP)  │
│                                                     │
│  Private DNS Zone: internal.lab                     │
│  ├── VNet Link: link-vnet-lab-007                   │
│  │   └── registrationEnabled: true                  │
│  │       (vm-test-007.internal.lab auto-registered) │
│  └── A record: webserver.internal.lab → 10.70.1.4   │
└─────────────────────────────────────────────────────┘

Resolution path (from vm-test-007):
  nslookup webserver.internal.lab
    → Azure DNS 168.63.129.16 → private zone → 10.70.1.4

  nslookup vm-test-007.internal.lab
    → Azure DNS 168.63.129.16 → auto-registered → VM private IP
```

---

## Cost

| Resource | Rate |
|---|---|
| VM (Standard_B1s) | ~$0.01/hr |
| Private DNS Zone | ~$0.50/month per zone + $0.40/million queries |
| VNet, NIC, NSG | free |
| **Estimated total** | **~$0.02/hr while running** |

> Run `.\..\..\tools\cost-check.ps1 -Lab lab-007` to audit live resources.

---

## Prerequisites

- Azure CLI installed (`az version`)
- `.data/subs.json` configured (`.\setup.ps1 -ConfigureSubs`)
- PowerShell 7+ (Linux/macOS: `pwsh`)

---

## Deploy

```powershell
cd labs/lab-007-azure-dns-foundations

.\deploy.ps1 `
  -AdminPassword "YourLabPass123!" `
  -Location centralus
```

Optional flags:
| Flag | Default | Notes |
|---|---|---|
| `-SubscriptionKey` | default from subs.json | key name in subs.json |
| `-Location` | centralus | see allowed regions in script |
| `-AdminUser` | azureuser | VM OS username |
| `-Owner` | `$env:USERNAME` | tag value |
| `-Force` | off | skip DEPLOY/DELETE confirmations |

Deployment time: **~5-8 minutes** (Bicep ARM deployment).

### Phases

| Phase | What happens | ~Time |
|---|---|---|
| 0 — Preflight | auth, config, cost warning | <1 min |
| 1 — Resource Group | create RG | <1 min |
| 2 — Bicep deploy | VNet, NSG, VM, DNS Zone, link, A record | 4-6 min |
| 5 — Validation | verify all resources + DNS records | <1 min |
| 6 — Summary | write outputs.json | <1 min |

---

## Validate

### From Azure CLI (control plane)

```bash
# List all records in the zone
az network private-dns record-set list \
  -g rg-lab-007-dns-foundations \
  --zone-name internal.lab -o table

# Show the static A record
az network private-dns record-set a show \
  -g rg-lab-007-dns-foundations \
  --zone-name internal.lab -n webserver

# Check VNet link and auto-registration status
az network private-dns link vnet show \
  -g rg-lab-007-dns-foundations \
  --zone-name internal.lab \
  -n link-vnet-lab-007 \
  --query "{state:virtualNetworkLinkState, regEnabled:registrationEnabled}"
```

### From inside the VM (data plane — true DNS test)

Connect via Azure Serial Console:
```bash
az serial-console connect -g rg-lab-007-dns-foundations --name vm-test-007
```

Then inside the VM:
```bash
# Test static A record
nslookup webserver.internal.lab
dig webserver.internal.lab

# Test auto-registered VM hostname
nslookup vm-test-007.internal.lab
dig vm-test-007.internal.lab

# Confirm Azure platform resolver is used
cat /etc/resolv.conf
# nameserver should be 168.63.129.16
```

Expected results:
```
webserver.internal.lab   → 10.70.1.4
vm-test-007.internal.lab → 10.70.1.4 (same VM, DHCP-assigned)
```

---

## Outputs

After deployment, `.data/lab-007/outputs.json` contains:

```json
{
  "metadata": { "lab": "lab-007", "status": "PASS", ... },
  "azure": {
    "resourceGroup": "rg-lab-007-dns-foundations",
    "vnet": { "name": "vnet-lab-007", "cidr": "10.70.0.0/16" },
    "vm": { "name": "vm-test-007", "privateIp": "...", "noPublicIp": true },
    "dns": {
      "zoneName": "internal.lab",
      "autoRegistration": true,
      "aRecord": { "fqdn": "webserver.internal.lab", "ip": "10.70.1.4" }
    }
  },
  "validationTests": { "fromVm": ["nslookup webserver.internal.lab", ...] }
}
```

---

## Destroy

```powershell
.\destroy.ps1
# Type DELETE to confirm, or use -Force to skip prompt
```

Removes:
- Resource group `rg-lab-007-dns-foundations` (all resources)
- Local `.data/lab-007/` directory
- Log files (unless `-KeepLogs`)

---

## Troubleshooting

### DNS resolution returns NXDOMAIN

1. Confirm VNet link state is `Completed`:
   ```bash
   az network private-dns link vnet show \
     -g rg-lab-007-dns-foundations \
     --zone-name internal.lab \
     -n link-vnet-lab-007 \
     --query virtualNetworkLinkState
   ```
2. Allow 1-2 minutes after VM boot for auto-registration to propagate.
3. Verify `/etc/resolv.conf` on the VM points to `168.63.129.16`.

### VM hostname not auto-registered

- Auto-registration requires `registrationEnabled: true` on the VNet link.
- The VM must be in a subnet of the **linked VNet**.
- Only one zone per VNet can have auto-registration enabled.

### VM unreachable via SSH from outside

By design — no public IP, no inbound public SSH rule. Use:
- Azure Serial Console (`az serial-console connect`)
- Azure Bastion (not deployed in this lab to keep cost minimal)
- Run-Command:
  ```bash
  az vm run-command invoke -g rg-lab-007-dns-foundations \
    -n vm-test-007 --command-id RunShellScript \
    --scripts "nslookup webserver.internal.lab"
  ```

### Bicep deployment fails

```bash
az deployment group list -g rg-lab-007-dns-foundations -o table
az deployment group show -g rg-lab-007-dns-foundations \
  -n <deployment-name> --query properties.error
```

---

## Files

```
lab-007-azure-dns-foundations/
├── deploy.ps1          # Phased deployment (phases 0,1,2,5,6)
├── destroy.ps1         # Idempotent cleanup
├── README.md           # This file
├── infra/
│   ├── main.bicep      # VNet, NSG, VM, DNS Zone, link, A record
│   └── main.parameters.json
└── logs/               # Deployment logs (gitignored)
```

---

## Key Learnings

1. **Private DNS Zones are global resources** — `location: 'global'` in Bicep/ARM.
2. **VNet link with `registrationEnabled: true`** auto-registers VM hostnames as `<computername>.<zone>`.
3. **Azure platform resolver** (`168.63.129.16`) is the default DNS server for all VMs — it forwards to private zones automatically.
4. **Static A records** coexist with auto-registered records in the same zone.
5. **No public IP needed** to validate private DNS — use Serial Console or Run-Command.

---

## References

- [Azure Private DNS Zones overview](https://docs.microsoft.com/azure/dns/private-dns-overview)
- [Private DNS auto-registration](https://docs.microsoft.com/azure/dns/private-dns-autoregistration)
- [Azure DNS 168.63.129.16](https://docs.microsoft.com/azure/virtual-network/what-is-ip-address-168-63-129-16)
- Domain guide: `docs/DOMAINS/observability.md`
