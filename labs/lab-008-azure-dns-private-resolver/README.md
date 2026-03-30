# Lab 008: Azure DNS Private Resolver + Security Policy

Deploy a hub-spoke DNS architecture with a DNS Private Resolver and DNS Security Policy, then explore how they work together in the Azure portal.

---

## Goal

| What you learn | How |
|---|---|
| DNS Private Resolver architecture | Inbound + outbound endpoints in dedicated subnets |
| Forwarding Ruleset | Domain-scoped forwarding rules directing spoke DNS through the resolver |
| DNS Security Policy | Block specific domains before they reach the resolver |
| Resolution path isolation | Spoke resolves private zones via resolver, not direct zone access |
| Portal exploration | Each resource has a clear portal view showing config and linked resources |

---

## What gets deployed

| Resource | Name | Purpose |
|---|---|---|
| Hub VNet | vnet-hub-008 | Hosts the DNS Private Resolver |
| Spoke VNet | vnet-spoke-008 | Has test VM, linked to forwarding ruleset and security policy |
| DNS Private Resolver | dnsresolver-008 | Inbound + outbound endpoints |
| Forwarding Ruleset | ruleset-008 | Routes internal.lab + onprem.example.com through resolver |
| Private DNS Zone | internal.lab | Authoritative zone for app.internal.lab |
| DNS Security Policy | dnspolicy-lab-008 | Blocks blocked.lab + malware.internal.lab with SERVFAIL |
| Domain List | domainlist-lab-008-blocked | The list of blocked domains |
| Test VM | vm-spoke-008 | Ubuntu 22.04, no public IP - serial console access only |

---

## Architecture

```
+------------------------------------------------------------------+
|  Resource Group: rg-lab-008-dns-resolver                         |
|                                                                  |
|  +-----------------------------+   +-------------------------+   |
|  | Hub VNet: vnet-hub-008      |   | Spoke VNet:             |   |
|  | 10.80.0.0/16                |   | vnet-spoke-008          |   |
|  |                             |<->| 10.81.0.0/16            |   |
|  | snet-workload-hub           |   |                         |   |
|  | (10.80.1.0/24)              |   | snet-workload-spoke     |   |
|  |                             |   | (10.81.1.0/24)          |   |
|  | DNS Private Resolver        |   |                         |   |
|  |  snet-dns-inbound           |   |  vm-spoke-008           |   |
|  |  (10.80.2.0/28)             |   |  (Standard_B1s)         |   |
|  |  Inbound EP: 10.80.2.x <---+---+--                        |   |
|  |                             |   +-------------------------+   |
|  |  snet-dns-outbound          |                                 |
|  |  (10.80.3.0/28)             |   DNS Forwarding Ruleset        |
|  |  Outbound EP                |   ruleset-008                   |
|  |                             |   (linked to spoke VNet)        |
|  | Private DNS Zone:           |   - internal.lab. -> inbound EP |
|  |  internal.lab               |   - onprem.example.com -> sim.  |
|  |  (linked to hub)            |                                 |
|  |  A: app -> 10.80.1.10       |   DNS Security Policy           |
|  +-----------------------------+   dnspolicy-lab-008             |
|                                    (linked to spoke VNet)        |
|                                    Domain list: blocked domains  |
|                                    Rule: SERVFAIL for matches    |
+------------------------------------------------------------------+
```

---

## DNS resolution flow

### app.internal.lab (resolves successfully)

```
spoke VM
  -> Azure DNS (168.63.129.16)
     -> forwarding ruleset linked to spoke VNet
        -> rule: internal.lab. matches
           -> forward to inbound endpoint IP:53
              -> resolver queries private DNS zone
                 -> returns 10.80.1.10
```

### blocked.lab (blocked by security policy)

```
spoke VM
  -> Azure DNS (168.63.129.16)
     -> DNS Security Policy evaluated first (linked to spoke VNet)
        -> domain list matches blocked.lab.
           -> SERVFAIL returned immediately
              (query never reaches the forwarding ruleset or resolver)
```

---

## Evaluation order

Security Policy evaluates **before** the forwarding ruleset. For any VNet linked to a policy:

1. Azure DNS checks security policy rules for the queried domain
2. If a block rule matches, SERVFAIL is returned (query never reaches the resolver)
3. If no match, the forwarding ruleset is consulted normally

---

## Cost

| Resource | Rate |
|---|---|
| VM (Standard_B1s) | ~$0.01/hr |
| DNS Private Resolver (2 endpoints) | ~$0.014/hr |
| Private DNS Zone | ~$0.004/hr |
| VNet peering (2 links) | ~$0.01/hr per GB transferred |
| DNS Security Policy + domain list | no additional cost at lab scale |
| **Estimated total** | **~$0.03/hr while running** |

> Run `.\lab.ps1 -Cost -Lab lab-008` to audit live resources.

---

## Prerequisites

- Azure CLI installed (`az version`)
- `.data/subs.json` configured (`.\lab.ps1 -Setup`)
- PowerShell 5.1 or 7+
- Subscription with DNS Private Resolver available
  - Supported in: eastus, eastus2, westus2, centralus, northeurope, westeurope

---

## Deploy

```powershell
.\lab.ps1 -Deploy lab-008 -AdminPassword "YourLabPass123!"
```

Or with explicit parameters:

```powershell
.\lab.ps1 -Deploy lab-008 -Location eastus2 -Force -AdminPassword "YourLabPass123!"
```

| Flag | Default | Notes |
|---|---|---|
| `-SubscriptionKey` | default from subs.json | key name in subs.json |
| `-Location` | eastus2 | DNS Resolver must be supported |
| `-AdminUser` | azureuser | VM OS username |
| `-Owner` | `$env:USERNAME` | tag value |
| `-Force` | off | skip confirmation prompt |

Deployment time: **~8-12 minutes** (resolver endpoint provisioning takes the most time).

---

## Explore in the portal

After deployment, open the resource group URL printed in the summary output. Then:

### 1. Resource group overview

Open `rg-lab-008-dns-resolver` and browse the resource list. You should see the hub VNet, spoke VNet, resolver, ruleset, private DNS zone, security policy, domain list, and VM all in one place.

### 2. DNS Private Resolver

Click on `dnsresolver-008`:
- **Inbound endpoints** tab: shows `ep-inbound-008` with its private IP in `snet-dns-inbound`. This is the IP that forwarding rules point to.
- **Outbound endpoints** tab: shows `ep-outbound-008` in `snet-dns-outbound`. This is the exit point for queries forwarded to external servers.

### 3. DNS Forwarding Ruleset

Click on `ruleset-008`:
- **Forwarding rules** tab: shows two rules - `internal.lab.` pointing to the inbound endpoint IP, and `onprem.example.com.` pointing to `10.0.0.1` (simulated upstream).
- **Virtual network links** tab: shows the spoke VNet linked here. Only VNets linked to this ruleset use it for DNS forwarding.

### 4. Private DNS Zone

Click on `internal.lab`:
- **Overview**: shows the `app` A record pointing to `10.80.1.10`.
- **Virtual network links** tab: shows only the hub VNet linked here. The spoke does NOT have direct access - it reaches this zone only through the forwarding path via the resolver.

### 5. DNS Security Policy

Click on `dnspolicy-lab-008`:
- **Domain lists** tab: shows `domainlist-lab-008-blocked` attached to this policy.
- **DNS security rules** tab: shows `rule-block-lab-domains` with SERVFAIL action.
- **Virtual network links** tab: shows the spoke VNet. DNS queries from VMs in this VNet are evaluated against this policy.

### 6. Domain List

Click on `domainlist-lab-008-blocked`:
- **Domains** tab: shows `blocked.lab.` and `malware.internal.lab.` as the blocked entries.

---

## Validate from the VM (optional)

The test VM has no public IP. Use Azure Serial Console to access it:

1. In the portal, open `vm-spoke-008`
2. Click **Serial console** in the left menu
3. Log in as `azureuser` with the password you provided at deploy time

From the serial console, test DNS resolution:

```bash
# Should resolve to 10.80.1.10 via the forwarding chain
getent hosts app.internal.lab

# Should return SERVFAIL (blocked by security policy)
getent hosts blocked.lab

# Should return SERVFAIL (malware subdomain, blocked)
getent hosts malware.internal.lab

# Should resolve normally (not in forwarding rules, goes direct to Azure DNS)
getent hosts azure.microsoft.com
```

You can also use `dig` (pre-installed):

```bash
# Direct query against inbound endpoint
dig app.internal.lab @<inbound-endpoint-ip>

# Show which DNS server the VM is configured to use
resolvectl status
```

> The inbound endpoint IP is shown in the deployment summary and saved in `.data/lab-008/outputs.json`.

---

## Troubleshooting

### `az dns-resolver` command not found

```bash
az extension add --name dns-resolver
```

### Resolver endpoint provisioning fails

DNS Private Resolver requires:
1. Endpoint subnets delegated to `Microsoft.Network/dnsResolvers`
2. No NSG on endpoint subnets (Azure rejects them)
3. The region supports the feature

### DNS Security Policy not available

The `Microsoft.Network/dnsResolverPolicies` resource type requires feature registration in some subscriptions:

```bash
az feature register --namespace Microsoft.Network --name dnsResolverPolicies
az provider register --namespace Microsoft.Network
```

### app.internal.lab returns NXDOMAIN from spoke VM

1. Verify the forwarding ruleset is linked to the spoke VNet:
   ```bash
   az dns-resolver vnet-link list -g rg-lab-008-dns-resolver \
     --ruleset-name ruleset-008 -o table
   ```
2. Verify the rule target IP matches the inbound endpoint's private IP:
   ```bash
   az dns-resolver forwarding-rule show -g rg-lab-008-dns-resolver \
     --ruleset-name ruleset-008 -n rule-internal-lab --query targetDnsServers
   ```
3. Verify the zone is linked to hub VNet (not spoke):
   ```bash
   az network private-dns link vnet list -g rg-lab-008-dns-resolver \
     --zone-name internal.lab -o table
   ```

### VNet peering state is not Connected

```bash
az network vnet peering list -g rg-lab-008-dns-resolver \
  --vnet-name vnet-hub-008 -o table
az network vnet peering list -g rg-lab-008-dns-resolver \
  --vnet-name vnet-spoke-008 -o table
```

---

## Destroy

```powershell
.\lab.ps1 -Destroy lab-008
```

Removes the resource group `rg-lab-008-dns-resolver` and all resources within it, plus local `.data/lab-008/`.

DNS Private Resolver teardown takes 3-5 minutes. The script waits up to 12 minutes.

After destroying, confirm no billable resources remain:

```powershell
.\lab.ps1 -Cost -Lab lab-008
```

---

## Files

```
lab-008-azure-dns-private-resolver/
├── deploy.ps1          # Phased deployment (phases 0-3)
├── destroy.ps1         # Idempotent cleanup
├── inspect.ps1         # Post-deploy resource health check
├── README.md           # This file
└── infra/
    ├── main.bicep      # Infrastructure definition
    └── main.parameters.json
```

Outputs saved to `.data/lab-008/outputs.json` after deployment.

---

## Key learnings

1. **Inbound endpoint** accepts DNS queries from peered networks. Needs a `/28` minimum subnet, delegated to `Microsoft.Network/dnsResolvers`, no NSG.
2. **Outbound endpoint** is the exit point for queries forwarded to external DNS servers. Same subnet requirements.
3. **Forwarding Ruleset** links the resolver to VNets. Only VNets linked to the ruleset use it for forwarding.
4. **No wildcard `'.'` rule** - only `internal.lab.` and `onprem.example.com.` are forwarded. All other queries go directly to Azure DNS, preserving platform DNS for all services.
5. **Resolution path isolation** - the spoke cannot see the hub's private zone directly (zone linked only to hub). Spoke resolves it only via the forwarding path through the resolver. This is an explicit, auditable security boundary.
6. **DNS Security Policy evaluates first** - before the forwarding ruleset and before private DNS zone lookup. A block rule short-circuits the query immediately.

---

## Next labs (DNS series)

| Lab | Coverage |
|-----|----------|
| [lab-007](../lab-007-azure-dns-foundations/README.md) | Single-VNet private zone + auto-registration |
| lab-008 | Hub resolver + spoke forwarding ruleset + DNS Security Policy - you are here |

---

## References

- [Azure DNS Private Resolver overview](https://docs.microsoft.com/azure/dns/dns-private-resolver-overview)
- [Resolver endpoint subnet requirements](https://docs.microsoft.com/azure/dns/dns-private-resolver-overview#subnet-restrictions)
- [DNS Forwarding Rulesets](https://docs.microsoft.com/azure/dns/private-resolver-endpoints-rulesets)
- [DNS Security Policy](https://docs.microsoft.com/azure/dns/dns-security-policy)
- Domain guide: [docs/DOMAINS/dns.md](../../docs/DOMAINS/dns.md)
