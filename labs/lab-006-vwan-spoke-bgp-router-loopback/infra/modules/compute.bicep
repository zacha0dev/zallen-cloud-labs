// infra/modules/compute.bicep
// Router VM (2 NICs) + Client VMs
//
// Status: PLACEHOLDER — structure only. Full implementation TBD.
//         deploy.ps1 uses az CLI for phased VM creation with resume support.

param location string
param tags object
param vmSize string = 'Standard_B2s'

@secure()
param sshPublicKey string

param spokeAVnetName string
param spokeBVnetName string

// TODO: Implement VM resources with:
// - Router VM: 2 NICs (IP forwarding), cloud-init for FRR
// - Client A VM: single NIC in Spoke A
// - Client B VM: single NIC in Spoke B
// - SSH key auth (no passwords)
// - Custom script extension for bootstrap

output routerVmId string = 'placeholder'
output clientAVmId string = 'placeholder'
output clientBVmId string = 'placeholder'
