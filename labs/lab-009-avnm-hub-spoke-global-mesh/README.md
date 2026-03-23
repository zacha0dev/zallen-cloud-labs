# Lab 009: AVNM Dual-Region Hub-Spoke + Global Mesh

Deploy two independent regional hub-and-spoke topologies managed entirely by **Azure Virtual Network Manager (AVNM)**, then manually enable **Global Mesh** via the Azure Portal to observe cross-region connectivity transitions.

---

## Goal

- Understand how AVNM manages VNet peerings declaratively (no manual peering commands)
- Deploy two isolated hub-spoke topologies across two regions via a single AVNM instance
- Observe AVNM reconciliation timing and deployment state
- Manually trigger Global Mesh in the portal and validate cross-region connectivity
- Capture the behavior of adding mesh connectivity to an existing hub-spoke deployment

---

## Architecture

```
Azure Virtual Network Manager (avnm-lab-009)
Scope: subscription
Feature: Connectivity
│
├── Network Group: ng-hub-spoke-r1
│     Members: vnet-hub-lab-009-r1, vnet-spoke-lab-009-r1
│     Config:  cc-hub-spoke-r1  (HubAndSpoke, hub = vnet-hub-lab-009-r1)
│
├── Network Group: ng-hub-spoke-r2
│     Members: vnet-hub-lab-009-r2, vnet-spoke-lab-009-r2
│     Config:  cc-hub-spoke-r2  (HubAndSpoke, hub = vnet-hub-lab-009-r2)
│
└── [Portal Step] Network Group: ng-global-mesh
      Members: vnet-hub-lab-009-r1, vnet-hub-lab-009-r2
      Config:  cc-global-mesh  (Mesh, isGlobal=true)

Region 1 (eastus)                  Region 2 (westus2)
┌─────────────────────┐            ┌─────────────────────┐
│  vnet-hub-lab-009-r1│            │  vnet-hub-lab-009-r2│
│  10.10.0.0/16       │            │  10.20.0.0/16       │
│    [AVNM-managed    │            │    [AVNM-managed    │
│     peering]        │            │     peering]        │
│  vnet-spoke-lab-009 │            │  vnet-spoke-lab-009 │
│  -r1                │            │  -r2                │
│  10.11.0.0/16       │            │  10.21.0.0/16       │
└─────────────────────┘            └─────────────────────┘
          │                                   │
          └──────── [Global Mesh] ────────────┘
                   (enabled in portal)

IP Address Plan (no overlaps):
  10.10.0.0/16  Hub,   Region 1
  10.11.0.0/16  Spoke, Region 1
  10.20.0.0/16  Hub,   Region 2
  10.21.0.0/16  Spoke, Region 2
```

---

## Cost

| Resource | Est. Cost |
|----------|-----------|
| AVNM connected VNet-hours (4 VNets) | ~$0.004–0.008/hr |
| VNets (no gateways, no VMs) | Free |
| **Total** | **~$0.01/hr** |

This lab is near-free. No VMs, no gateways, no VPN tunnels.

Always run `.\destroy.ps1` when done. Check with `..\..\tools\cost-check.ps1`.

---

## Prerequisites

- Azure subscription configured: `.\setup.ps1 -ConfigureSubs`
- Azure CLI: `.\setup.ps1 -Azure`
- Azure CLI version 2.51+ (AVNM commands require recent CLI)
- lab-000 passing recommended

Verify Azure CLI version:
```powershell
az version
```

---

## Deploy

```powershell
cd labs\lab-009-avnm-hub-spoke-global-mesh
.\deploy.ps1
```

With explicit region overrides:
```powershell
.\deploy.ps1 -Location eastus -Location2 westeurope
```

Skip the confirmation prompt:
```powershell
.\deploy.ps1 -Force
```

**What this deploys:**
- Resource group `rg-lab-009-avnm` in `eastus`
- 4 VNets across 2 regions (2 hubs + 2 spokes, no overlapping CIDRs)
- AVNM instance `avnm-lab-009` scoped to your subscription
- 2 network groups with static members
- 2 hub-spoke connectivity configurations
- AVNM post-commit deployment (triggers managed peering creation)

**What this does NOT deploy:**
- Global Mesh (intentional — this is your manual portal step)
- VMs, gateways, or public IPs

---

## Validate (CLI)

After deployment, run the inspection script:

```powershell
.\inspect.ps1
```

Expected output:
- AVNM instance found with Connectivity scope
- Both network groups present with correct static members
- Both connectivity configs (HubAndSpoke) present
- 4 AVNM-managed peerings in Connected state (2 per region, bidirectional = 4 objects)
- No Global Mesh config found yet (expected at this stage)

---

## Section 4: Enable Global Mesh (Manual Portal Steps)

This is the key learning experiment. Follow these steps in the Azure Portal.

### Step 4a — Create the Global Mesh Network Group

1. Open [Azure Portal](https://portal.azure.com) → search **"Virtual Network Managers"**
2. Click **avnm-lab-009**
3. Left menu → **Network groups** → **+ Create**
4. Name: `ng-global-mesh`
5. Description: `Cross-region mesh group (hub VNets only)`
6. Click **Create**

### Step 4b — Add Hub VNets as Static Members

After creating `ng-global-mesh`:

1. Click **ng-global-mesh** → **Add static members**
2. Add: `vnet-hub-lab-009-r1`
3. Add: `vnet-hub-lab-009-r2`
4. Click **Save**

### Step 4c — Create Global Mesh Connectivity Configuration

1. Left menu → **Configurations** → **+ Create** → **Connectivity configuration**
2. Fill in:
   - **Name**: `cc-global-mesh`
   - **Description**: `Cross-region mesh between regional hubs`
3. Click **Next: Topology settings**
4. Topology: **Mesh**
5. Check: **Enable mesh connectivity across regions** (this sets `isGlobal=true`)
6. Under **Network groups**: click **+ Add** → select `ng-global-mesh`
7. Click **Add** → **Review + Create** → **Create**

### Step 4d — Deploy the Global Mesh Configuration

1. Left menu → **Deployments** → **Deploy configurations**
2. **Deployment type**: Connectivity
3. Select configuration: `cc-global-mesh`
4. Select regions: `East US` and `West US 2` (or your chosen regions)
5. Click **Deploy**

### Step 4e — Validate Global Mesh

After deployment (allow 1–3 minutes for reconciliation):

```powershell
.\inspect.ps1
```

Expect:
- `cc-global-mesh` config listed with `isGlobal = true`
- Cross-region peering detected: `vnet-hub-lab-009-r1 <-> vnet-hub-lab-009-r2 : Connected`

You can also verify in the Portal:
- Navigate to **vnet-hub-lab-009-r1** → **Peerings**
- You should see a peering to `vnet-hub-lab-009-r2` managed by AVNM
- The peering name will contain `AVNM` in the prefix

### What to Observe

| State | Expected |
|-------|---------|
| Before Global Mesh | Hub-r1 has no peering to Hub-r2. Spoke-r1 cannot reach Spoke-r2. |
| After Global Mesh  | Hub-r1 has AVNM-managed peering to Hub-r2. Cross-region path exists via hubs. |
| Spoke-to-spoke cross-region | Not directly peered. Traffic must traverse hub-r1 → hub-r2 (if UDRs/NVA in path). |

---

## Teardown

```powershell
.\destroy.ps1
```

The destroy script:
1. Sends an empty AVNM post-commit to remove all managed peerings cleanly
2. Deletes the resource group (removes all VNets, AVNM, and any portal-created configs)
3. Cleans up local `.data/lab-009/`

> If you created `cc-global-mesh` via the portal, it will be deleted as part of the resource group deletion.

Check for remaining resources:
```powershell
..\..\tools\cost-check.ps1
```

---

## Troubleshooting

### Peerings stuck in "Initiated" or "Disconnected"

AVNM peering reconciliation can take 2–5 minutes. Wait and re-run `.\inspect.ps1`.

If still stuck after 10 minutes:
```bash
az network manager post-commit \
  --name avnm-lab-009 \
  --resource-group rg-lab-009-avnm \
  --commit-type Connectivity \
  --target-locations eastus westus2 \
  --configuration-ids <cc-r1-id> <cc-r2-id>
```

### `az network manager connect-config: command not found`

Requires Azure CLI 2.51+. Update with:
```bash
az upgrade
```
Or on Linux:
```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

### Global Mesh toggle greyed out in portal

The **"Enable mesh connectivity across regions"** checkbox only appears when Topology is set to **Mesh**. Ensure you selected Mesh (not Hub and Spoke) before looking for the checkbox.

### `az network manager post-commit` returns 400 with "configuration not found"

The configuration IDs must be the full ARM resource ID. Verify with:
```bash
az network manager connect-config list \
  --network-manager-name avnm-lab-009 \
  --resource-group rg-lab-009-avnm \
  --query "[].id" -o tsv
```

### Destroy script leaves resource group

If the empty post-commit during destroy doesn't complete before group deletion starts, some managed peering artifacts may linger. Retry destroy or delete the resource group manually in the portal.

---

## Key Concepts

| Concept | What this lab shows |
|---------|---------------------|
| AVNM as peering controller | All VNet peerings created/removed by AVNM — no `az network vnet peering create` needed |
| Network groups | Logical containers that AVNM policies apply to |
| Static membership | Explicit VNet assignment vs. dynamic (Azure Policy-based) |
| Hub-spoke topology | AVNM enforces hub ↔ spoke peering; spoke ↔ spoke traffic goes via hub |
| Post-commit deployment | Changes are staged in configs; only effective when deployed to target regions |
| Global Mesh | Cross-region mesh requires `isGlobal=true`; overlaid on existing hub-spoke without conflict |
| Reconciliation timing | AVNM is eventually consistent; deployment state transitions take 1–5 minutes |
