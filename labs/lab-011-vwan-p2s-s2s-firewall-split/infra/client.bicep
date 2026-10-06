// lab-011 Phase 1: the P2S test client.
// A small Ubuntu VM in its own VNet (NOT connected to the hub) that acts as a remote
// user. It generates the P2S root and client certificates and later dials the
// P2S gateway with OpenVPN, so the routes it receives can be read from `ip route`.

param location string
param tags object
param adminUsername string
@secure()
param adminPassword string
param vmSize string = 'Standard_B1s'

var vnetName = 'vnet-lab-011-client'
var vnetCidr = '10.130.0.0/24'
var vmName = 'vm-lab-011-client'
var vmIp = '10.130.0.4'

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-lab-011-client'
  location: location
  tags: tags
  properties: {
    securityRules: [] // default rules only: no inbound from the internet
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ vnetCidr ] }
    subnets: [
      {
        name: 'snet-client'
        properties: {
          addressPrefix: vnetCidr
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

// Public IP gives the client outbound internet to reach the P2S gateway.
resource pip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-lab-011-client'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-lab-011-client'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: vmIp
          subnet: { id: vnet.properties.subnets[0].id }
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: { disablePasswordAuthentication: false }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Standard_LRS' }
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nic.id, properties: { deleteOption: 'Delete' } } ]
    }
  }
}

output clientVmName string = vm.name
output clientPrivateIp string = vmIp
