# Lab 011: vWAN P2S and S2S on the Default Route Table, Hub vs Spoke Firewall

Can one vWAN hub send site-to-site (S2S) traffic through an Azure Firewall in a spoke and
point-to-site (P2S) traffic through an Azure Firewall in the hub, when both branches use the
Default route table? This lab builds that design, then measures it.

## Goal

Answer one falsifiable question with measurements, not diagrams:

> With S2S and P2S both associated with the hub's **Default** route table, the app prefix
> reaching Default through a **VNet-connection static route** to a spoke Azure Firewall, can a
> Default route table static route send **P2S** traffic to the **hub** Azure Firewall while
> **S2S** traffic keeps using the **spoke** firewall? And does the P2S client get the routes
> it needs?

What the lab measures, in each scenario:

| Layer | Measurement |
|-------|-------------|
| Association | Which route table the S2S connection and the P2S configuration are associated with |
| Hub control plane | Effective routes of `defaultRouteTable`: next hop for the app prefix, on-prem prefix, P2S pool |
| On-prem control plane | What the on-prem VPN gateway learned over BGP (on-prem VM NIC effective routes) |
| P2S client | The gateway's OpenVPN `PUSH_REPLY` and the kernel routes on `tun0` of a real P2S client |
| Data plane | TCP/22 and ping from the on-prem VM and from the P2S client to the app VM |
| Path proof | Azure Firewall `AZFWNetworkRule` logs: which firewall saw S2S flows and which saw P2S flows |

## What Microsoft documents (the hypothesis)

From *About virtual hub routing* (Azure Virtual WAN docs, Additional considerations):

- "All branch connections (Point-to-site, Site-to-site, and ExpressRoute) need to be associated
  to the Default route table. That way, all branches learn the same prefixes."
- "All branch connections need to propagate their routes to the same set of route tables."
- "Routes added statically take precedence over dynamically learned routes for the same prefixes."

So the expectation is that any Default route table static route for the app prefix applies to
**both** branches. Route tables match on destination only, and both branches look up the same
table. The lab checks whether the platform behaves that way, and what breaks (asymmetry, missing
client routes) along the way.

## Architecture

```
                         Virtual WAN (Standard)  vwan-lab-011
                                    |
               +--------------------+---------------------+
               |        Virtual hub vhub-lab-011          |
               |             10.110.0.0/24                |
               |                                          |
               |   defaultRouteTable  <-- S2S assoc+prop  |
               |                      <-- P2S assoc+prop  |
               |                      <-- conn-vnet-fw    |
               |                                          |
               |   S2S VPN GW   P2S VPN GW   Azure FW     |
               |   (1 SU)       (1 SU)       (hub)        |
               +----+--------------+-------------+--------+
                    |              |             |
        IPsec + BGP |              | OpenVPN     |  conn-vnet-fw
                    |              |             |  static route:
   +----------------+--+   +-------+--------+    |  10.112.0.0/24 -> 10.111.0.4
   | vnet-lab-011-onprem|   | vnet-lab-011-  |    |
   | 10.120.0.0/24      |   | client         |  +-+---------------------+
   |  VpnGw1AZ ASN 65010|   | 10.130.0.0/24  |  | vnet-lab-011-fw        |
   |  vm-...-onprem     |   |  vm-...-client |  | 10.111.0.0/24          |
   |  10.120.0.68       |   |  pool          |  |  Azure FW (spoke)      |
   +--------------------+   |  172.16.110/24 |  |  10.111.0.4            |
                            +----------------+  +-----------+------------+
                                                            | VNet peering
                                                +-----------+------------+
                                                | vnet-lab-011-app       |
                                                | 10.112.0.0/24          |
                                                |  UDR 10/8, 172.16/12   |
                                                |   -> spoke FW          |
                                                |  vm-lab-011-app        |
                                                |  10.112.0.4            |
                                                +------------------------+
```

The app VNet is **not** connected to the hub. It is reachable only through the spoke firewall,
via the static route on the `conn-vnet-fw` hub connection. That is the "VNet connection static
route propagated to an Azure Firewall in a spoke" part of the design.

## Scenarios

`scenario.ps1` switches the static routes this lab owns in `defaultRouteTable`. Routes from
anything else are left alone.

| Mode | defaultRouteTable static routes | Tests |
|------|----------------------------------|-------|
| `Baseline` (after deploy) | none | Both branches reach the app via the spoke FW (control case) |
| `HubFwForP2S` | `10.112.0.0/24 -> hub Azure Firewall` | The design as asked: "push P2S to the hub firewall" |
| `HubFwSymmetric` | above + `172.16.110.0/24 -> hub Azure Firewall` | Same, plus forcing the return path back through the hub FW |
| `HubFwAggregate` | `10/8, 172.16/12, 192.168/16 -> hub Azure Firewall` | Firewall Manager's `private_traffic` pattern: does a broader Default static route leave the propagated `/24` VNet-connection route in charge? |

## Known issues and documented behavior (researched 2026-10-06)

Does a static route on `defaultRouteTable` break VNet-connection static routes that propagate into
`defaultRouteTable`? The docs say it does not remove or withdraw them, but it can **shadow** them:

| Default RT static route vs propagated VNet-connection route | Documented result | Lab scenario |
|---|---|---|
| Different, non-overlapping prefix | Both coexist; Microsoft's own hybrid design uses exactly this | n/a |
| Broader aggregate (e.g. 10.0.0.0/8 -> hub FW) | Longest prefix match is step 1 of hub route selection, so the propagated `/24` still wins for the app | `HubFwAggregate` |
| Same prefix | "Prefer static routes learned from the virtual hub route table over BGP routes" (step 2), so the Default static route wins for **every** connection associated with Default, S2S included | `HubFwForP2S` |
| More specific than the propagated route | LPM, so the Default static route wins for that sub-range | n/a |

Other documented constraints that hit this design:

- **Hub FW then spoke NVA (double inspection) is not supported without routing intent.** From
  *Combine static routing to Azure Firewall and spoke NVAs*: "This architecture doesn't support
  double-inspection scenarios ... routed to and inspected by Azure Firewall in the Virtual WAN hub
  and then forwarded to an NVA in a spoke". P2S -> hub FW -> spoke FW -> app is that path.
- **Branch-to-branch traffic (P2S <-> S2S) is not inspected by the hub firewall with static routes.**
  That needs routing intent.
- **Mixing static routes to Azure Firewall and routing intent is not supported** ("two disjoint ways").
- **Option 1 static routes** (VNet connection, propagate = true) "can't be used for inspection
  scenarios between a Virtual WAN on-premises connection and spoke Virtual Network". Indirect
  spokes peered behind the NVA, as in this lab, are a supported Option 1 use case.
- **Branches must share one routing config.** P2S concepts: "Having different propagations for
  branches connections might result in unexpected routing behaviors, as Virtual WAN will choose the
  routing configuration for one branch and apply it to all branches."
- **Bypass next hop is ignored** when propagate static routes is on and routing intent is used
  (treated as `equals`). It can only be set when the connection is created.
- Release-notes known issues: no open item matches this exact case. Related ones are #9 (concurrent
  spoke address-space updates not synced to the hub), #10 (portal fails to update branch routing
  config when hub and gateways sit in different resource groups; use CLI/REST) and #13 (incomplete
  activity log for hub changes, so route edits may not show in change history).

Sources (MicrosoftDocs/azure-docs, `articles/virtual-wan/`): `about-virtual-hub-routing.md`,
`about-virtual-hub-routing-preference.md`, `static-routes.md`, `static-routes-firewall-basic.md`,
`hybrid-firewall-spoke-static.md`, `point-to-site-concepts.md`, `how-to-routing-policies.md`,
`whats-new.md` (Known issues).

## Cost

| Resource | Est. Cost |
|----------|-----------|
| Virtual hub (Standard) | ~$0.25/hr |
| S2S VPN gateway, 1 scale unit + 1 connection | ~$0.41/hr |
| P2S VPN gateway, 1 scale unit + 1 user | ~$0.37/hr |
| Azure Firewall in hub (Basic) | ~$0.40/hr |
| Azure Firewall in spoke (Basic) | ~$0.40/hr |
| On-prem simulator VPN gateway (VpnGw1AZ) | ~$0.36/hr |
| 3 x Standard_B1s VMs, public IPs, Log Analytics | ~$0.08/hr |
| **Total** | **~$2.26/hr** |

With `-FirewallTier Standard` the two firewalls are ~$1.25/hr each (total ~$3.97/hr).
Deploy takes 75-100 minutes, so a full session (deploy, three scenarios, destroy) is ~3 hours,
about $7 at Basic tier. Prices are list-price estimates and vary by region.

Always run `.\lab.ps1 -Destroy lab-011` when done. Check with `.\tools\cost-check.ps1`.

## Prerequisites

- Azure subscription configured: `.\lab.ps1 -Setup` (a Visual Studio subscription works; its
  monthly credit covers a session)
- Azure CLI 2.54+ with Bicep: `.\setup.ps1 -Azure`
- The deploy script adds the `virtual-wan` and `log-analytics` az extensions if missing
- Quota in the region for 3 x B-series vCPUs, 2 Azure Firewalls and 3 VPN gateways
- lab-001 recommended (vWAN basics)

## Deploy

```powershell
.\lab.ps1 -Deploy lab-011
# options
.\labs\lab-011-vwan-p2s-s2s-firewall-split\deploy.ps1 -Location eastus2 -FirewallTier Basic
```

| Phase | What happens |
|-------|--------------|
| 0 | Tools, auth, region allowlist, itemized cost estimate, `DEPLOY` prompt |
| 1 | Resource group; P2S client VM (`infra/client.bicep`); root + client certs generated **on the VM** (private keys never leave it) |
| 2 | `infra/main.bicep`: vWAN, hub, firewall-spoke connection with static route, S2S GW, P2S GW, hub firewall, S2S connection (hub writes chained); spoke firewall, app/on-prem VNets, on-prem VPN GW, VMs, Log Analytics in parallel |
| 4 | Waits for the S2S tunnel to show `Connected`, then 2 min for BGP |
| 5 | Runs `inspect.ps1` in Baseline |
| 6 | Writes `.data/lab-011/outputs.json`, prints next steps |

Re-running deploy is safe. Bicep is incremental, and the S2S key and certificates are reused.

## Validate (the experiment)

```powershell
# 1. Baseline was measured by deploy. Now apply the design under test:
.\labs\lab-011-vwan-p2s-s2s-firewall-split\scenario.ps1 -Mode HubFwForP2S
.\lab.ps1 -Inspect lab-011            # ~15 min: waits for firewall flow logs

# 2. Aggregate (Firewall Manager style) - checks the /24 is NOT shadowed
.\labs\lab-011-vwan-p2s-s2s-firewall-split\scenario.ps1 -Mode HubFwAggregate
.\lab.ps1 -Inspect lab-011

# 3. Symmetric variant
.\labs\lab-011-vwan-p2s-s2s-firewall-split\scenario.ps1 -Mode HubFwSymmetric
.\lab.ps1 -Inspect lab-011

# 4. Back to the control case (also proves the propagated route comes back)
.\labs\lab-011-vwan-p2s-s2s-firewall-split\scenario.ps1 -Mode Baseline
```

`inspect.ps1` reconnects the P2S client every run, because P2S routes are pushed at connect time.
Each run is saved to `.data/lab-011/inspect-<scenario>-<time>.json`. The verdict block at the end
answers the design question directly:

| Verdict check | Design goal |
|---------------|-------------|
| S2S -> app crosses the spoke firewall | must PASS |
| S2S -> app does NOT cross the hub firewall | must PASS |
| P2S -> app crosses the hub firewall | must PASS |
| P2S client routes to the app and connects | must PASS |

A FAIL in this block is a finding, not a broken lab. For example, `HubFwForP2S` is expected to
show S2S flows on the hub firewall too, which is the documented branch-sharing behavior.
`-LogWaitMinutes 0` skips the log wait. `-SkipDataPlane` measures the control plane only.

### Expected (unverified) outcomes to check against

These are predictions from the docs and are **not yet measured**. Fill the table from the
inspect JSON after a run.

| Scenario | Prediction | Measured |
|----------|-----------|----------|
| Baseline | Both branches via spoke FW; hub FW sees nothing | _pending_ |
| HubFwForP2S | Static route beats the propagated one, so **S2S also** goes to the hub FW (design goal not met); return path from the app bypasses the hub FW (asymmetric) | _pending_ |
| HubFwSymmetric | Return path also via hub FW; S2S still shares the hub FW path | _pending_ |
| HubFwAggregate | `10.112.0.0/24` stays on conn-vnet-fw (LPM); only destinations with no more specific route go to the hub FW | _pending_ |
| Baseline after any mode | Removing the Default static route restores `10.112.0.0/24 -> conn-vnet-fw` | _pending_ |
| All | P2S client gets the hub, firewall VNet, on-prem prefixes; whether it gets `10.112.0.0/24` (a static-route-only prefix) is an open question | _pending_ |

### If the measurement confirms branches cannot be split

Ways to get "S2S via spoke FW, P2S via hub FW" that work within the documented rules:

1. **Separate hubs per branch type.** Put the P2S gateway in a second hub whose Default route
   table points the app prefix at that hub's firewall. Static routes do not cross hubs, so S2S
   in hub 1 keeps the spoke firewall path.
2. **Separate destinations.** If P2S users only need prefixes S2S does not use, static routes
   for those prefixes can point at the hub firewall without touching S2S.
3. **Routing intent (private traffic -> hub FW).** Sends all branch and VNet traffic through the
   hub firewall. Routing intent can't coexist with custom route tables or with Default static
   routes to a VNet connection, but VNet-connection static routes still apply behind the hub
   firewall. S2S then crosses both firewalls (hub, then spoke).
4. **Source-aware policy in the spoke firewall.** Keep one path and enforce P2S rules by source
   (`172.16.110.0/24`) in the spoke firewall policy.

## Destroy

```powershell
.\lab.ps1 -Destroy lab-011
```

Deletes the resource group (20-40 min with a hub, gateways and a firewall), then verifies it
is gone. Keeps `.data/lab-011/inspect-*.json` and removes the S2S key and outputs.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Deploy fails with `AnotherOperationInProgress` on the hub | Wait 5 min, re-run deploy (idempotent) |
| Basic firewall rejected in the hub | Re-run with `-FirewallTier Standard` |
| `SkuNotAvailable` for VMs | `-VmSize Standard_B2ats_v2` or another region |
| S2S connection never `Connected` | `az network vpn-connection show -g rg-lab-011-vwan-fw-split -n cn-lab-011-onprem-to-vwan`; re-run deploy (it re-applies the shared key) |
| `P2S tunnel up` FAIL | The inspect output prints the OpenVPN log tail; check the root cert on `vpnsc-lab-011` matches `/etc/p2s/root.crt` on the client VM |
| Verdicts stay PENDING | Firewall logs lag 5-15 min; re-run `.\lab.ps1 -Inspect lab-011` |
| Hub routing status Failed after a scenario switch | Portal: hub, **Reset router**, then re-run `scenario.ps1` |

## Files

| File | Purpose |
|------|---------|
| `deploy.ps1` | Phases 0-6 |
| `inspect.ps1` | Read-only measurements and the verdict (also run by deploy Phase 5) |
| `scenario.ps1` | Switches the Default route table static routes (Baseline / HubFwForP2S / HubFwSymmetric) |
| `destroy.ps1` | Idempotent teardown with verification |
| `infra/client.bicep` | P2S client VM + VNet |
| `infra/main.bicep` | Everything else |
| `scripts/*.sh` | Run on lab VMs via `az vm run-command`: certs, OpenVPN connect, probe |
| `scripts/lab-011-helpers.ps1` | Names, address plan and shared helpers |
