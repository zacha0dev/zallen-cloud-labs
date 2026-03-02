# Azure Virtual WAN (vWAN)

> Conceptual reference for labs that use Azure Virtual WAN.
> For hands-on labs, see the [Lab Catalog](../LABS/README.md).

---

## What Is Azure Virtual WAN?

Azure Virtual WAN is a networking service that provides optimized, automated branch-to-branch, branch-to-cloud, and cloud-to-cloud connectivity. It acts as a managed hub-and-spoke overlay over the Azure backbone network.

Key characteristics:
- Fully managed by Microsoft (no gateway VMs to maintain)
- Supports VNet connections, S2S VPN, P2S VPN, and ExpressRoute in a single hub
- Standard SKU enables routing between connection types (branch-to-branch, spoke-to-spoke)
- Route tables control which traffic goes where

---

## Core Components

### Virtual WAN (vWAN)

The top-level resource. You typically have one vWAN per deployment. Two SKUs:

| SKU | Use Case |
|-----|----------|
| Basic | Simple hub, no branch-to-branch |
| Standard | Full routing, BGP, multiple connection types |

All labs use **Standard** SKU.

### Virtual Hub (vHub)

The managed hub resource within a vWAN. Each hub:
- Has its own address space (e.g., `10.60.0.0/24`)
- Runs managed router instances (active-active, ASN 65515 by default)
- Contains its own route tables
- Provisions in 10-20 minutes on first creation

### Hub Virtual Network Connections

Links a spoke VNet to a vHub. The hub then propagates routes to/from the spoke. Connection state should be `Succeeded` before validating routing.

### VPN Gateway (S2S)

A managed VPN gateway that runs two active-active instances inside the hub. Key properties:

- Each instance has a public IP and private BGP addresses
- Supports BGP with APIPA (`169.254.x.x`) addresses for peering
- Provisioning takes 20-35 minutes
- ASN is fixed at **65515** for the Azure side

### Route Tables

Every hub has a **Default** route table. Standard SKU hubs support **custom** route tables. Key concepts:

| Concept | Description |
|---------|-------------|
| Association | A connection is "associated" with one route table (routes in that RT apply to it) |
| Propagation | A connection propagates its routes to one or more route tables |
| Static routes | Manually added prefixes to a route table (e.g., `0.0.0.0/0` for default route) |

**Lab-004** specifically explores how static routes in custom route tables do NOT propagate to connections associated with a different route table.

---

## BGP in vWAN

### Hub BGP ASN

The vHub runs BGP with ASN **65515** (Microsoft reserved). You cannot change this. External peers (VPN sites, BGP connections) must use a different ASN.

### Hub Router (BGP Connections)

Standard vWAN supports a "hub router" feature that allows a VNet-connected router VM to peer directly with the hub via BGP. The hub creates two BGP sessions (one per active-active router instance). Used in **lab-006**.

```
Hub router instances
  Instance 0 --> BGP peer --> Router VM NIC
  Instance 1 --> BGP peer --> Router VM NIC
```

### VPN Gateway BGP (S2S)

S2S VPN gateways support BGP over both regular and APIPA IP addresses. Labs 003 and 005 use APIPA-only BGP.

---

## APIPA in vWAN VPN

Automatic Private IP Addressing (APIPA) in the `169.254.x.x/16` range is used for BGP peering addresses on VPN links. This avoids conflicts with private address space.

### Why APIPA?

When connecting Azure vWAN to AWS VGW, you cannot use private IPs that overlap with on-premises or cloud VNets. APIPA (`169.254.0.0/16`) is link-local and does not route, making it safe for VPN BGP peering.

### Address Allocation Pattern (Labs 003 and 005)

The labs use deterministic `/30` subnets from the APIPA range:

| Subnet | Azure IP (BGP) | Peer IP | vHub Instance |
|--------|---------------|---------|---------------|
| `169.254.21.0/30` | `.2` | `.1` | Instance 0 |
| `169.254.21.4/30` | `.6` | `.5` | Instance 0 |
| `169.254.22.0/30` | `.2` | `.1` | Instance 1 |
| `169.254.22.4/30` | `.6` | `.5` | Instance 1 |

**Rule:** `169.254.21.x` = Instance 0, `169.254.22.x` = Instance 1.

The `.2` and `.6` addresses (Azure side) follow from standard `/30` allocation (network + 2 usable hosts).

---

## Route Propagation Patterns

### Default Behavior

All connections propagate their routes to the Default route table and associate with the Default route table. This means all connected VNets and branches learn each other's routes automatically.

### Custom Route Table Pattern (Lab-004)

```
Custom RT "rt-fw-default"
  - has static route: 0.0.0.0/0 -> NVA VNet
  - associated with: Spoke A1, Spoke A2
  - NOT associated with: Spoke A3, A4 (these use Default RT)

Result:
  - A1, A2: HAVE 0.0.0.0/0 in effective routes
  - A3, A4: do NOT have 0.0.0.0/0
```

**Key insight:** Static routes in a custom route table only affect connections *associated* with that RT, not all connections that propagate to it.

### Hub-to-Hub Route Isolation

Routes in a custom RT on Hub A do not propagate to Hub B's Default RT automatically. Each hub maintains independent routing unless explicitly configured otherwise.

---

## Key CLI Commands

### Hub Status

```powershell
az network vhub show -g <rg> -n <hub-name> --query "{state:routingState, ip:virtualRouterIps}" -o json
# routingState should be: Provisioned
```

### Effective Routes (from the hub's perspective)

```powershell
az network vhub get-effective-routes -g <rg> -n <hub-name> \
  --resource-type VirtualNetworkConnection \
  --resource-id "<connection-resource-id>"
```

### VNet Connection Status

```powershell
az network vhub connection list -g <rg> --vhub-name <hub-name> \
  --query "[].{name:name, state:provisioningState}" -o table
```

### VPN Gateway BGP Peers

```powershell
az network vpn-gateway show -g <rg> -n <gw-name> \
  --query "bgpSettings.bgpPeeringAddresses[*].{instance:ipconfigurationId, addrs:customBgpIpAddresses}" \
  -o table
```

### Custom Route Tables

```powershell
az network vhub route-table list -g <rg> --vhub-name <hub-name> -o table
az network vhub route-table show -g <rg> --vhub-name <hub-name> -n <rt-name>
```

### Effective Routes on a VM NIC

```powershell
az network nic show-effective-route-table -g <rg> -n <nic-name> \
  --query "value[].{prefix:addressPrefix[0], nextHop:nextHopType}" -o table
```

---

## Labs Using vWAN

| Lab | vWAN Features |
|-----|--------------|
| [lab-001](../../labs/lab-001-virtual-wan-hub-routing/README.md) | Basic hub + spoke VNet connection |
| [lab-003](../../labs/lab-003-vwan-aws-bgp-apipa/README.md) | S2S VPN Gateway, BGP over APIPA, AWS hybrid |
| [lab-004](../../labs/lab-004-vwan-default-route-propagation/README.md) | Custom route tables, default route propagation |
| [lab-005](../../labs/lab-005-vwan-s2s-bgp-apipa/README.md) | S2S VPN, dual-instance BGP/APIPA reference |
| [lab-006](../../labs/lab-006-vwan-spoke-bgp-router-loopback/README.md) | Hub BGP connections, FRR router, loopback propagation |

---

## Related Resources

| Resource | Description |
|----------|-------------|
| [AWS Hybrid](aws-hybrid.md) | AWS VPN side of lab-003 |
| [Observability](observability.md) | How to validate vWAN hub routing |
| [REFERENCE.md](../REFERENCE.md) | BGP ASN patterns, cost safety |
| [Microsoft Docs: vWAN overview](https://learn.microsoft.com/azure/virtual-wan/virtual-wan-about) | Official reference |
| [Microsoft Docs: Hub routing](https://learn.microsoft.com/azure/virtual-wan/about-virtual-hub-routing) | Route table deep dive |
