# Lab 008: Azure DNS Private Resolver + Controlled Forwarding

Deploy Azure DNS Private Resolver in a hub VNet, connect a spoke via VNet peering and a forwarding ruleset, and validate cross-VNet private DNS resolution — without blocking Azure's platform DNS.

---

## Goal

| What you learn | How |
|---|---|
| DNS Private Resolver architecture | Inbound + outbound endpoints in dedicated subnets |
| Forwarding Ruleset | Explicit domain-scoped forwarding rules |
| Cross-VNet resolution | Spoke resolves hub's private zones via resolver |
| Controlled forwarding (no wildcard deny) | Rules only for named domains — Azure DNS preserved |
| Simulated external forwarding | `onprem.example.com` → placeholder target |

**Security model:** No `'.'` (deny-all) rule. Security is achieved via:
- Explicit forwarding rules for known domains only
- Zone visibility isolation (zone linked only to hub)
- Resolution path isolation (spoke routes only named domains through resolver)

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Resource Group: rg-lab-008-dns-resolver                         │
│                                                                  │
│  ┌──────────────────────────────────┐  ┌──────────────────────┐  │
│  │ Hub VNet: vnet-hub-008           │  │ Spoke VNet:          │  │
│  │ 10.80.0.0/16                     │  │ vnet-spoke-008       │  │
│  │                                  │◄─►│ 10.81.0.0/16        │  │
│  │ snet-workload-hub (10.80.1.0/24) │  │                      │  │
│  │                                  │  │ snet-workload-spoke  │  │
│  │ DNS Private Resolver             │  │ (10.81.1.0/24)       │  │
│  │ ┌─────────────────────────────┐  │  │                      │  │
│  │ │ snet-dns-inbound            │  │  │  vm-spoke-008        │  │
│  │ │ (10.80.2.0/28)              │  │  │  (Standard_B1s)      │  │
│  │ │  Inbound EP: 10.80.2.x ◄───┼──┼──┼─ nslookup            │  │
│  │ └─────────────────────────────┘  │  │  app.internal.lab    │  │
│  │ ┌─────────────────────────────┐  │  └──────────────────────┘  │
│  │ │ snet-dns-outbound           │  │                            │
│  │ │ (10.80.3.0/28)              │  │  DNS Forwarding Ruleset    │
│  │ │  Outbound EP ───────────────┼──┼─► linked to spoke VNet    │
│  │ └─────────────────────────────┘  │  ┌──────────────────────┐  │
│  │                                  │  │ internal.lab.        │  │
│  │ Private DNS Zone: internal.lab   │  │  → inbound EP IP     │  │
│  │  (linked to hub, auto-reg OFF)   │  │ onprem.example.com.  │  │
│  │  A: app.internal.lab→10.80.1.10  │  │  → 10.0.0.1 (sim)   │  │
│  └──────────────────────────────────┘  └──────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘

Resolution flow (spoke VM → app.internal.lab):
  1. VM queries Azure DNS (168.63.129.16)
  2. Azure DNS sees forwarding ruleset linked to spoke VNet
  3. Rule: internal.lab. matches → forward to inbound endpoint IP:53
  4. Inbound endpoint resolves against internal.lab private zone
  5. Returns: 10.80.1.10
```

---

## Cost

| Resource | Rate |
|---|---|
| VM (Standard_B1s) | ~$0.01/hr |
| DNS Private Resolver (2 endpoints) | ~$0.014/hr |
| Private DNS Zone | ~$0.004/hr |
| VNet peering (2 links) | ~$0.01/hr per GB transferred |
| **Estimated total** | **~$0.03/hr while running** |

> Run `.\..\..\tools\cost-check.ps1 -Lab lab-008` to audit live resources.

---

## Prerequisites

- Azure CLI installed (`az version`)
- `.data/subs.json` configured (`.\setup.ps1 -ConfigureSubs`)
- PowerShell 7+ (`pwsh`)
- Subscription with DNS Private Resolver feature enabled
  - DNS Private Resolver is generally available in: eastus, eastus2, westus2, centralus, northeurope, westeurope

---

## Modes

Lab 008 supports parameterized deployment modes via `-Mode`:

| Mode | Description |
|------|-------------|
| `Base` (default) | Deploy base infra only — always stable and reliable |
| `StickyBlock` | Base + DNS Security Policy (or forwarding rule redirect) cache persistence test |
| `ForwardingVariants` | Base + forwarding rule variation tests (safe, generic) |

```powershell
# Base deploy (default)
.\deploy.ps1 -Mode Base -AdminPassword "YourLabPass123!"

# StickyBlock — test DNS cache persistence after policy apply/remove
.\deploy.ps1 -Mode StickyBlock -AdminPassword "YourLabPass123!"

# ForwardingVariants — test adding/removing rules and VNet links
.\deploy.ps1 -Mode ForwardingVariants -AdminPassword "YourLabPass123!"

# StickyBlock infra only (skip tests, just wire up base infra)
.\deploy.ps1 -Mode StickyBlock -SkipTests -AdminPassword "YourLabPass123!"
```

> **Note:** Base mode must succeed before running StickyBlock or ForwardingVariants. All modes use the same base infrastructure. If the `-SkipTests` flag is set, Phase 2 (validation) and Phase 3 (mode-specific tests) are skipped regardless of the mode chosen.

---

## Deploy

```powershell
cd labs/lab-008-azure-dns-private-resolver

.\deploy.ps1 `
  -AdminPassword "YourLabPass123!" `
  -Location eastus2
```

Optional flags:
| Flag | Default | Notes |
|---|---|---|
| `-SubscriptionKey` | default from subs.json | key name in subs.json |
| `-Location` | eastus2 | DNS Resolver must be supported |
| `-AdminUser` | azureuser | VM OS username |
| `-Owner` | `$env:USERNAME` | tag value |
| `-Force` | off | skip confirmations |
| `-Mode` | `Base` | `Base`, `StickyBlock`, or `ForwardingVariants` |
| `-SkipTests` | off | infra-only; skip Phase 2 and Phase 3 |

Deployment time: **~8-12 minutes** (resolver endpoint provisioning takes the most time).

### Phases

| Phase | What happens | ~Time |
|---|---|---|
| 0 — Preflight | auth, config, cost warning | <1 min |
| 1 — Deploy Base Infra | resource group + Bicep (VNets, resolver, endpoints, ruleset, zone, VM) | 7-10 min |
| 2 — Base Validation | verify all resources + rules + record (skipped with `-SkipTests`) | <1 min |
| 3 — Mode Execution | StickyBlock or ForwardingVariants test harness (Base: no-op) | varies |
| 4 — Outputs + Evidence | write outputs.json + test-results.json | <1 min |

---

## Validate

### Azure CLI (control plane)

```bash
# Show resolver endpoints
az dns-resolver inbound-endpoint list \
  -g rg-lab-008-dns-resolver \
  --dns-resolver-name dnsresolver-008 \
  --query "[].{name:name, ip:ipConfigurations[0].privateIpAddress}" -o table

# List forwarding rules
az dns-resolver forwarding-rule list \
  -g rg-lab-008-dns-resolver \
  --forwarding-ruleset-name ruleset-008 \
  --query "[].{name:name, domain:domainName, target:targetDnsServers[0].ipAddress}" -o table

# Check ruleset VNet links (should show spoke VNet)
az dns-resolver vnet-link list \
  -g rg-lab-008-dns-resolver \
  --forwarding-ruleset-name ruleset-008 -o table

# List DNS records in the zone
az network private-dns record-set list \
  -g rg-lab-008-dns-resolver \
  --zone-name internal.lab -o table

# Check VNet peering state
az network vnet peering list \
  -g rg-lab-008-dns-resolver \
  --vnet-name vnet-hub-008 \
  --query "[].{name:name, state:peeringState}" -o table
```

### Data plane — DNS resolution (from spoke VM)

Using Azure Run-Command (no SSH required):
```bash
# Test: app.internal.lab via forwarding ruleset path
az vm run-command invoke \
  -g rg-lab-008-dns-resolver \
  -n vm-spoke-008 \
  --command-id RunShellScript \
  --scripts "nslookup app.internal.lab && dig app.internal.lab"

# Test: resolve directly against inbound endpoint
# Replace <INBOUND_IP> with IP from outputs.json
az vm run-command invoke \
  -g rg-lab-008-dns-resolver \
  -n vm-spoke-008 \
  --command-id RunShellScript \
  --scripts "dig app.internal.lab <INBOUND_IP>"

# Confirm Azure DNS is still the default resolver
az vm run-command invoke \
  -g rg-lab-008-dns-resolver \
  -n vm-spoke-008 \
  --command-id RunShellScript \
  --scripts "cat /etc/resolv.conf && nslookup azure.microsoft.com"
```

Expected results:
```
app.internal.lab         → 10.80.1.10   (via ruleset → inbound EP → zone)
azure.microsoft.com      → resolves OK  (Azure DNS unbroken — no wildcard deny)
onprem.example.com       → SERVFAIL     (forwarded to 10.0.0.1, no real server — expected)
```

---

## DNS Security Policy – Sticky Block

The `StickyBlock` mode tests **cache persistence** behavior in Azure DNS Private Resolver. This matters when enforcement policies are applied at the DNS layer.

### What you're testing

When a DNS Security Policy (or a forwarding rule redirect) is applied, it changes what a resolver returns for a given domain. But DNS clients and intermediate resolvers **cache responses for their TTL**. The sticky block test answers:

> *If I block a domain at the resolver level after a client already resolved it — how long does the cached answer persist?*

### How the test works

1. **Before policy:** A test A record (`sticky.internal.lab → 10.80.1.99`) is created and queried from the spoke VM — establishing a baseline resolved answer in the resolver's cache.
2. **Apply block:** The test tries to create a native [Azure DNS Security Policy](https://docs.microsoft.com/azure/dns/). If that feature isn't available in your region/subscription, it falls back to redirecting the zone's forwarding rule to `192.0.2.1` (RFC 5737 TEST-NET — an address that never routes). Either way, subsequent queries should fail.
3. **After policy:** Queries run again. You expect `SERVFAIL` or `NXDOMAIN` — the block is enforced.
4. **Remove block:** The policy or redirecting rule is removed.
5. **Post-removal loop:** Repeated queries run at intervals. If responses still fail after removal, it is evidence the **resolver is serving from cache** rather than re-querying upstream.

### What you should see

| Phase | Expected result |
|-------|----------------|
| Before policy | `10.80.1.99` resolved |
| After policy | `SERVFAIL` or `NXDOMAIN` |
| After removal (immediately) | May still return error (cached NXDOMAIN or cached redirect failure) |
| After removal (30-60s later) | Should resolve again once TTL expires |

> If you see the same failure response immediately after removal, that **is the cache** — not the policy. This is the key learning.

### Proving it's cache, not the policy

Use a **new random subdomain** for each run to bypass any existing cache:
```powershell
# Each run uses a unique subdomain — guaranteed cache miss on first query
.\deploy.ps1 -Mode StickyBlock -AdminPassword "YourLabPass123!"
```

The test script uses `sticky.internal.lab` which is seeded fresh each run. For maximum isolation:
- Use a fresh VM (no prior queries)
- Wait for the TTL window (typically 30 seconds for Azure Private DNS)
- Ensure all queries go through the same resolver path (inbound EP IP, not a bypass)

### Policy eval vs caching — key distinction

| Mechanism | What it controls |
|-----------|-----------------|
| DNS Security Policy | What the **resolver returns** for matching queries |
| DNS response cache | How long that answer is **stored at the resolver** |

The policy can be applied or removed in seconds. The cached answer persists until its TTL expires. This is why you can remove a block and still see "blocked" behavior for 30–300 seconds afterward.

See also: [docs/DOMAINS/dns.md — DNS Security Policy + cache persistence](../../docs/DOMAINS/dns.md#dns-security-policy--cache-persistence)

---

## Outputs

After deployment, two files are written to `.data/lab-008/`:

**`outputs.json`** — base infrastructure snapshot:
```json
{
  "metadata": { "lab": "lab-008", "mode": "Base", "status": "PASS", ... },
  "azure": {
    "resourceGroup": "rg-lab-008-dns-resolver",
    "hubVnet": { "name": "vnet-hub-008", "cidr": "10.80.0.0/16" },
    "spokeVnet": { "name": "vnet-spoke-008", "cidr": "10.81.0.0/16" },
    "dnsResolver": {
      "name": "dnsresolver-008",
      "inboundEndpoint": { "ip": "10.80.2.x" },
      "outboundEndpoint": {}
    },
    "forwardingRuleset": {
      "name": "ruleset-008",
      "rules": ["internal.lab. -> inbound EP", "onprem.example.com. -> 10.0.0.1"],
      "linkedVnets": ["vnet-spoke-008"]
    },
    "dns": {
      "zoneName": "internal.lab",
      "linkedTo": "vnet-hub-008",
      "aRecord": { "fqdn": "app.internal.lab", "ip": "10.80.1.10" }
    }
  }
}
```

**`test-results.json`** — mode-specific test evidence:
```json
{
  "mode": "StickyBlock",
  "base": { "status": "PASS", "allChecks": true },
  "modeResults": {
    "testDomain": "sticky.internal.lab",
    "dnsPolicyMethod": "forwarding-rule-redirect",
    "persistenceDetected": true,
    "phases": {
      "before_policy": { "summary": { "resolved": true } },
      "after_policy":  { "summary": { "resolved": false } },
      "post_removal":  [ ... ]
    }
  },
  "notes": "...",
  "timestamps": { "started": "...", "completed": "...", "elapsed": "..." }
}
```

---

## Destroy

```powershell
.\destroy.ps1
# Type DELETE to confirm, or use -Force to skip prompt
```

Removes:
- Resource group `rg-lab-008-dns-resolver` (all resources including resolver, endpoints, ruleset, peerings, zone, VM)
- Local `.data/lab-008/` directory
- Log files (unless `-KeepLogs`)

Note: DNS Private Resolver teardown can take 3-5 minutes. The script waits up to 12 minutes.

After destroying, run the cost audit to confirm no billable resources remain:

```powershell
.\..\..\tools\cost-check.ps1 -Lab lab-008
```

---

## Troubleshooting

### `az dns-resolver` command not found

```bash
az extension add --name dns-resolver
```

### Resolver endpoint provisioning fails

DNS Private Resolver requires:
1. The endpoint subnets are delegated to `Microsoft.Network/dnsResolvers`
2. The subnets have no NSG (Azure rejects them)
3. The region supports the feature — check `az provider list --query "[?namespace=='Microsoft.Network']"`

### `app.internal.lab` returns NXDOMAIN from spoke VM

1. Verify the forwarding ruleset is linked to the spoke VNet:
   ```bash
   az dns-resolver vnet-link list -g rg-lab-008-dns-resolver \
     --forwarding-ruleset-name ruleset-008 -o table
   ```
2. Verify the rule target IP matches the inbound endpoint's private IP:
   ```bash
   az dns-resolver forwarding-rule show -g rg-lab-008-dns-resolver \
     --forwarding-ruleset-name ruleset-008 -n rule-internal-lab \
     --query "targetDnsServers"
   ```
3. Verify the zone is linked to hub VNet (not spoke):
   ```bash
   az network private-dns link vnet list -g rg-lab-008-dns-resolver \
     --zone-name internal.lab -o table
   ```
4. Test directly against inbound endpoint IP — if this works but VNet path doesn't, the ruleset link is the issue.

### VNet peering state is not `Connected`

This can happen if peering was created only one-way. Bicep creates both directions. Check:
```bash
az network vnet peering list -g rg-lab-008-dns-resolver \
  --vnet-name vnet-hub-008 -o table
az network vnet peering list -g rg-lab-008-dns-resolver \
  --vnet-name vnet-spoke-008 -o table
```

### Azure DNS broken after deployment (other domains fail)

This lab does NOT deploy a `'.'` (wildcard) forwarding rule. Only `internal.lab.` and `onprem.example.com.` are forwarded. All other queries go directly to Azure DNS (`168.63.129.16`) as normal. If something is broken, verify the ruleset rules list has no unexpected wildcard:
```bash
az dns-resolver forwarding-rule list -g rg-lab-008-dns-resolver \
  --forwarding-ruleset-name ruleset-008 -o table
```

---

## Files

```
lab-008-azure-dns-private-resolver/
├── deploy.ps1                          # Phased deployment (phases 0-4); supports -Mode and -SkipTests
├── destroy.ps1                         # Idempotent cleanup (all modes)
├── README.md                           # This file
├── infra/
│   ├── main.bicep                      # Base infrastructure (Bicep)
│   └── main.parameters.json
├── scripts/
│   ├── test-dns.ps1                    # Generic DNS query harness (outputs structured JSON)
│   ├── test-stickyblock.ps1            # StickyBlock mode: policy + cache persistence test
│   └── test-forwarding-variants.ps1   # ForwardingVariants mode: rule/link variation tests
└── logs/                               # Deployment logs (gitignored)
```

Evidence artifacts written to `.data/lab-008/`:
```
.data/lab-008/
├── outputs.json        # Base infrastructure snapshot
└── test-results.json   # Mode-specific test evidence (base + modeResults)
```

---

## Key Learnings

1. **Inbound endpoint** accepts DNS queries from peered networks and forwards them to Azure's private DNS resolver. It needs a `/28` min subnet, dedicated, delegated to `Microsoft.Network/dnsResolvers`, no NSG.
2. **Outbound endpoint** is the exit point for forwarded queries to external DNS servers. Same subnet requirements.
3. **DNS Forwarding Ruleset** is what links the resolver to VNets. Link it to the VNets that need the forwarding behavior.
4. **No wildcard `'.'` rule** — this avoids breaking Azure's internal DNS for platform services, metadata, and public resolution. Only define rules for domains you control.
5. **Resolution path isolation** — the spoke cannot see the hub's private zone directly (zone is only linked to hub), so it can only resolve it via the forwarding path through the resolver. This is an explicit, auditable security boundary.
6. **Private DNS Zone is still in the hub** — the resolver's inbound endpoint acts as a proxy for cross-VNet resolution without requiring the zone to be linked to every spoke.

---

## Next Labs (DNS Series)

| Lab | What you explored before | Where to go next |
|-----|--------------------------|-----------------|
| [lab-007](../lab-007-azure-dns-foundations/README.md) | Single-VNet private zone + auto-registration | ← prerequisite |
| lab-008 | Hub resolver + spoke forwarding ruleset | ← you are here |

With lab-007 and lab-008 complete you have covered the full Azure DNS private resolution stack. Apply these patterns in your own hub-spoke or multi-VNet designs.

---

## References

- [Azure DNS Private Resolver overview](https://docs.microsoft.com/azure/dns/dns-private-resolver-overview)
- [Resolver endpoint subnet requirements](https://docs.microsoft.com/azure/dns/dns-private-resolver-overview#subnet-restrictions)
- [DNS Forwarding Rulesets](https://docs.microsoft.com/azure/dns/private-resolver-endpoints-rulesets)
- [Bicep DNS Resolver reference](https://docs.microsoft.com/azure/templates/microsoft.network/dnsresolvers)
- Domain guide: [docs/DOMAINS/dns.md](../../docs/DOMAINS/dns.md)
