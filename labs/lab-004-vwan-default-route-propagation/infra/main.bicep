// labs/lab-004-vwan-default-route-propagation/infra/main.bicep
// Demonstrates vWAN default route (0/0) propagation behavior

@description('Azure region for all resources')
param location string = 'eastus2'

@description('Resource group name')
param rgName string = 'rg-lab-004-vwan-route-prop'

@description('Virtual WAN name')
param vwanName string = 'vwan-lab-004'

@description('Hub A name')
param hubAName string = 'vhub-a-lab-004'

@description('Hub B name')
param hubBName string = 'vhub-b-lab-004'

@description('VM admin username')
param adminUsername string = 'azureuser'

@description('VM admin password')
@secure()
param adminPassword string

@description('VM size')
param vmSize string = 'Standard_B1s'

// Address spaces
var hubACidr = '10.100.0.0/24'
var hubBCidr = '10.101.0.0/24'

var vnetFwCidr = '10.110.0.0/24'
var vnetFwSubnetCidr = '10.110.0.0/26'

var spokeA1Cidr = '10.111.0.0/24'
var spokeA2Cidr = '10.112.0.0/24'
var spokeA3Cidr = '10.113.0.0/24'
var spokeA4Cidr = '10.114.0.0/24'

var spokeB1Cidr = '10.121.0.0/24'
var spokeB2Cidr = '10.122.0.0/24'

var tags = {
  owner: 'azure-labs'
  project: 'azure-labs'
  lab: 'lab-004'
  purpose: 'vwan-route-propagation'
  ttlHours: '8'
}

// Virtual WAN
resource vwan 'Microsoft.Network/virtualWans@2023-09-01' = {
  name: vwanName
  location: location
  tags: tags
  properties: {
    type: 'Standard'
    allowBranchToBranchTraffic: true
    allowVnetToVnetTraffic: true
  }
}

// Hub A
resource hubA 'Microsoft.Network/virtualHubs@2023-09-01' = {
  name: hubAName
  location: location
  tags: tags
  properties: {
    virtualWan: {
      id: vwan.id
    }
    addressPrefix: hubACidr
    hubRoutingPreference: 'VpnGateway'
  }
}

// Hub B
resource hubB 'Microsoft.Network/virtualHubs@2023-09-01' = {
  name: hubBName
  location: location
  tags: tags
  properties: {
    virtualWan: {
      id: vwan.id
    }
    addressPrefix: hubBCidr
    hubRoutingPreference: 'VpnGateway'
  }
}

// Custom route table on Hub A for firewall default route
// Includes static 0.0.0.0/0 pointing to VNet-FW (simulated firewall)
resource rtFwDefault 'Microsoft.Network/virtualHubs/hubRouteTables@2023-09-01' = {
  parent: hubA
  name: 'rt-fw-default'
  properties: {
    labels: ['fw-default']
    routes: [
      {
        name: 'default-to-fw'
        destinationType: 'CIDR'
        destinations: ['0.0.0.0/0']
        nextHop: vnetFwConnection.id
        nextHopType: 'ResourceId'
      }
    ]
  }
}

// VNet-FW (simulated firewall VNet)
resource vnetFw 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-fw-lab-004'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [vnetFwCidr]
    }
    subnets: [
      {
        name: 'snet-fw'
        properties: {
          addressPrefix: vnetFwSubnetCidr
        }
      }
    ]
  }
}

// Spoke VNets for Hub A
resource spokeA1 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-spoke-a1'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [spokeA1Cidr]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: spokeA1Cidr
        }
      }
    ]
  }
}

resource spokeA2 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-spoke-a2'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [spokeA2Cidr]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: spokeA2Cidr
        }
      }
    ]
  }
}

resource spokeA3 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-spoke-a3'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [spokeA3Cidr]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: spokeA3Cidr
        }
      }
    ]
  }
}

resource spokeA4 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-spoke-a4'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [spokeA4Cidr]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: spokeA4Cidr
        }
      }
    ]
  }
}

// Spoke VNets for Hub B
resource spokeB1 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-spoke-b1'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [spokeB1Cidr]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: spokeB1Cidr
        }
      }
    ]
  }
}

resource spokeB2 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-spoke-b2'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [spokeB2Cidr]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: spokeB2Cidr
        }
      }
    ]
  }
}

// Hub A VNet connections
resource vnetFwConnection 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-09-01' = {
  parent: hubA
  name: 'conn-vnet-fw'
  properties: {
    remoteVirtualNetwork: {
      id: vnetFw.id
    }
    allowHubToRemoteVnetTransit: true
    allowRemoteVnetToUseHubVnetGateways: true
    enableInternetSecurity: false
  }
}

// Spoke A1 & A2: propagate to rt-fw-default (will learn 0/0)
resource connSpokeA1 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-09-01' = {
  parent: hubA
  name: 'conn-spoke-a1'
  properties: {
    remoteVirtualNetwork: {
      id: spokeA1.id
    }
    allowHubToRemoteVnetTransit: true
    allowRemoteVnetToUseHubVnetGateways: true
    enableInternetSecurity: false
    routingConfiguration: {
      associatedRouteTable: {
        id: rtFwDefault.id
      }
      propagatedRouteTables: {
        ids: [
          { id: rtFwDefault.id }
        ]
        labels: ['fw-default']
      }
    }
  }
  dependsOn: [
    rtFwDefault
  ]
}

resource connSpokeA2 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-09-01' = {
  parent: hubA
  name: 'conn-spoke-a2'
  properties: {
    remoteVirtualNetwork: {
      id: spokeA2.id
    }
    allowHubToRemoteVnetTransit: true
    allowRemoteVnetToUseHubVnetGateways: true
    enableInternetSecurity: false
    routingConfiguration: {
      associatedRouteTable: {
        id: rtFwDefault.id
      }
      propagatedRouteTables: {
        ids: [
          { id: rtFwDefault.id }
        ]
        labels: ['fw-default']
      }
    }
  }
  dependsOn: [
    rtFwDefault
    connSpokeA1
  ]
}

// Spoke A3 & A4: propagate to Default only (will NOT learn 0/0)
resource connSpokeA3 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-09-01' = {
  parent: hubA
  name: 'conn-spoke-a3'
  properties: {
    remoteVirtualNetwork: {
      id: spokeA3.id
    }
    allowHubToRemoteVnetTransit: true
    allowRemoteVnetToUseHubVnetGateways: true
    enableInternetSecurity: false
  }
  dependsOn: [
    connSpokeA2
  ]
}

resource connSpokeA4 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-09-01' = {
  parent: hubA
  name: 'conn-spoke-a4'
  properties: {
    remoteVirtualNetwork: {
      id: spokeA4.id
    }
    allowHubToRemoteVnetTransit: true
    allowRemoteVnetToUseHubVnetGateways: true
    enableInternetSecurity: false
  }
  dependsOn: [
    connSpokeA3
  ]
}

// Hub B VNet connections (Default route table only)
resource connSpokeB1 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-09-01' = {
  parent: hubB
  name: 'conn-spoke-b1'
  properties: {
    remoteVirtualNetwork: {
      id: spokeB1.id
    }
    allowHubToRemoteVnetTransit: true
    allowRemoteVnetToUseHubVnetGateways: true
    enableInternetSecurity: false
  }
}

resource connSpokeB2 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-09-01' = {
  parent: hubB
  name: 'conn-spoke-b2'
  properties: {
    remoteVirtualNetwork: {
      id: spokeB2.id
    }
    allowHubToRemoteVnetTransit: true
    allowRemoteVnetToUseHubVnetGateways: true
    enableInternetSecurity: false
  }
  dependsOn: [
    connSpokeB1
  ]
}

// VMs - one per spoke + one in VNet-FW
resource nicFw 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-vm-fw'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${vnetFw.id}/subnets/snet-fw'
          }
        }
      }
    ]
    enableIPForwarding: true
  }
}

resource vmFw 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-fw'
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'vm-fw'
      adminUsername: adminUsername
      adminPassword: adminPassword
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
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nicFw.id
        }
      ]
    }
  }
}

// Helper function to create spoke VMs
resource nicA1 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-vm-a1'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${spokeA1.id}/subnets/default'
          }
        }
      }
    ]
  }
}

resource vmA1 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-a1'
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: 'vm-a1'
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'Standard_LRS' } }
    }
    networkProfile: { networkInterfaces: [ { id: nicA1.id } ] }
  }
}

resource nicA2 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-vm-a2'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [ { name: 'ipconfig1', properties: { privateIPAllocationMethod: 'Dynamic', subnet: { id: '${spokeA2.id}/subnets/default' } } } ]
  }
}

resource vmA2 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-a2'
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: { computerName: 'vm-a2', adminUsername: adminUsername, adminPassword: adminPassword }
    storageProfile: { imageReference: { publisher: 'Canonical', offer: '0001-com-ubuntu-server-jammy', sku: '22_04-lts-gen2', version: 'latest' }, osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'Standard_LRS' } } }
    networkProfile: { networkInterfaces: [ { id: nicA2.id } ] }
  }
}

resource nicA3 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-vm-a3'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [ { name: 'ipconfig1', properties: { privateIPAllocationMethod: 'Dynamic', subnet: { id: '${spokeA3.id}/subnets/default' } } } ]
  }
}

resource vmA3 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-a3'
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: { computerName: 'vm-a3', adminUsername: adminUsername, adminPassword: adminPassword }
    storageProfile: { imageReference: { publisher: 'Canonical', offer: '0001-com-ubuntu-server-jammy', sku: '22_04-lts-gen2', version: 'latest' }, osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'Standard_LRS' } } }
    networkProfile: { networkInterfaces: [ { id: nicA3.id } ] }
  }
}

resource nicA4 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-vm-a4'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [ { name: 'ipconfig1', properties: { privateIPAllocationMethod: 'Dynamic', subnet: { id: '${spokeA4.id}/subnets/default' } } } ]
  }
}

resource vmA4 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-a4'
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: { computerName: 'vm-a4', adminUsername: adminUsername, adminPassword: adminPassword }
    storageProfile: { imageReference: { publisher: 'Canonical', offer: '0001-com-ubuntu-server-jammy', sku: '22_04-lts-gen2', version: 'latest' }, osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'Standard_LRS' } } }
    networkProfile: { networkInterfaces: [ { id: nicA4.id } ] }
  }
}

resource nicB1 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-vm-b1'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [ { name: 'ipconfig1', properties: { privateIPAllocationMethod: 'Dynamic', subnet: { id: '${spokeB1.id}/subnets/default' } } } ]
  }
}

resource vmB1 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-b1'
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: { computerName: 'vm-b1', adminUsername: adminUsername, adminPassword: adminPassword }
    storageProfile: { imageReference: { publisher: 'Canonical', offer: '0001-com-ubuntu-server-jammy', sku: '22_04-lts-gen2', version: 'latest' }, osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'Standard_LRS' } } }
    networkProfile: { networkInterfaces: [ { id: nicB1.id } ] }
  }
}

resource nicB2 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-vm-b2'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [ { name: 'ipconfig1', properties: { privateIPAllocationMethod: 'Dynamic', subnet: { id: '${spokeB2.id}/subnets/default' } } } ]
  }
}

resource vmB2 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-b2'
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: { computerName: 'vm-b2', adminUsername: adminUsername, adminPassword: adminPassword }
    storageProfile: { imageReference: { publisher: 'Canonical', offer: '0001-com-ubuntu-server-jammy', sku: '22_04-lts-gen2', version: 'latest' }, osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'Standard_LRS' } } }
    networkProfile: { networkInterfaces: [ { id: nicB2.id } ] }
  }
}

// Outputs
output vwanId string = vwan.id
output hubAId string = hubA.id
output hubBId string = hubB.id
output rtFwDefaultId string = rtFwDefault.id
output vnetFwId string = vnetFw.id
output vmFwPrivateIp string = nicFw.properties.ipConfigurations[0].properties.privateIPAddress
