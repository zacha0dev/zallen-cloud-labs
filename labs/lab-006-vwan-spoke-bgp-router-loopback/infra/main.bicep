// labs/lab-006-vwan-spoke-bgp-router-loopback/infra/main.bicep
// Orchestrator module for lab-006 infrastructure
//
// Status: PLACEHOLDER -- deploy.ps1 uses az CLI for phased control.
//         This Bicep module is provided for future "single-deploy" mode.

targetScope = 'resourceGroup'

// ============================================
// Parameters
// ============================================

@description('Azure region for all resources')
param location string = 'centralus'

@description('Owner tag (optional)')
param owner string = ''

@description('Virtual Hub address prefix')
param vhubPrefix string = '10.0.0.0/24'

@description('Spoke A VNet address space')
param spokeAPrefix string = '10.61.0.0/16'

@description('Spoke B VNet address space')
param spokeBPrefix string = '10.62.0.0/16'

@description('Router VM BGP ASN')
param routerBgpAsn int = 65100

@description('VM size for all VMs')
param vmSize string = 'Standard_B2s'

@description('SSH public key for VM admin')
@secure()
param sshPublicKey string

// ============================================
// Variables
// ============================================

var baseTags = {
  project: 'azure-labs'
  lab: 'lab-006'
  env: 'lab'
  owner: owner
}

// ============================================
// Modules
// ============================================

module vwan 'modules/vwan.bicep' = {
  name: 'vwan-deployment'
  params: {
    location: location
    tags: baseTags
  }
}

module spokeA 'modules/spoke-a.bicep' = {
  name: 'spoke-a-deployment'
  params: {
    location: location
    addressPrefix: spokeAPrefix
    tags: baseTags
  }
}

module spokeB 'modules/spoke-b.bicep' = {
  name: 'spoke-b-deployment'
  params: {
    location: location
    addressPrefix: spokeBPrefix
    tags: baseTags
  }
}

module compute 'modules/compute.bicep' = {
  name: 'compute-deployment'
  params: {
    location: location
    vmSize: vmSize
    sshPublicKey: sshPublicKey
    spokeAVnetName: spokeA.outputs.vnetName
    spokeBVnetName: spokeB.outputs.vnetName
    tags: baseTags
  }
}

// ============================================
// Outputs
// ============================================

output vwanId string = vwan.outputs.vwanId
output vhubId string = vwan.outputs.vhubId
output spokeAVnetId string = spokeA.outputs.vnetId
output spokeBVnetId string = spokeB.outputs.vnetId
output routerVmId string = compute.outputs.routerVmId
