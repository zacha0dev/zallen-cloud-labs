// labs/lab-003-vwan-aws-vpn-bgp-apipa/azure/main.bicep
// Azure Virtual WAN + VPN Gateway for AWS S2S VPN with BGP over APIPA

@description('Azure region for all resources')
param location string = 'eastus2'

@description('BGP ASN for Azure VPN Gateway (default 65515)')
param azureBgpAsn int = 65515

@description('Address prefix for the Virtual Hub')
param vhubAddressPrefix string = '10.100.0.0/24'

@description('Spoke VNet address space')
param spokeAddressPrefix string = '10.200.0.0/24'

@description('Spoke VNet subnet prefix')
param spokeSubnetPrefix string = '10.200.0.0/26'

@description('Admin username for test VM')
param adminUsername string = 'azureuser'

@secure()
@description('Admin password for test VM')
param adminPassword string

@description('Lab prefix for resource naming')
param labPrefix string = 'lab-003'

@description('Owner tag for resource tracking (optional)')
param owner string = ''

@description('Allowed Azure regions for this lab')
param allowedLocations array = ['eastus', 'eastus2', 'westus2', 'northeurope', 'westeurope']

// Tags - consistent with AWS side (lowercase keys)
var baseTags = {
  project: 'azure-labs'
  lab: 'lab-003'
  env: 'lab'
}
var tags = owner != '' ? union(baseTags, { owner: owner }) : baseTags

// Resource naming
var vwanName = 'vwan-${labPrefix}'
var vhubName = 'vhub-${labPrefix}'
var vpnGatewayName = 'vpngw-${labPrefix}'
var spokeVnetName = 'vnet-spoke-${labPrefix}'
var vmName = 'vm-spoke-${labPrefix}'
var nicName = 'nic-${vmName}'

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

// Virtual Hub
resource vhub 'Microsoft.Network/virtualHubs@2023-09-01' = {
  name: vhubName
  location: location
  tags: tags
  properties: {
    virtualWan: {
      id: vwan.id
    }
    addressPrefix: vhubAddressPrefix
    hubRoutingPreference: 'VpnGateway'
  }
}

// VPN Gateway in Hub
resource vpnGateway 'Microsoft.Network/vpnGateways@2023-09-01' = {
  name: vpnGatewayName
  location: location
  tags: tags
  properties: {
    virtualHub: {
      id: vhub.id
    }
    bgpSettings: {
      asn: azureBgpAsn
    }
    vpnGatewayScaleUnit: 1
  }
}

// Spoke VNet
resource spokeVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: spokeVnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [spokeAddressPrefix]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: spokeSubnetPrefix
        }
      }
    ]
  }
}

// Hub-to-Spoke Connection
resource hubConnection 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-09-01' = {
  parent: vhub
  name: 'conn-${spokeVnetName}'
  properties: {
    remoteVirtualNetwork: {
      id: spokeVnet.id
    }
    allowHubToRemoteVnetTransit: true
    allowRemoteVnetToUseHubVnetGateways: true
    enableInternetSecurity: true
  }
  dependsOn: [vpnGateway]
}

// NIC for test VM
resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: spokeVnet.properties.subnets[0].id
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

// Test VM in spoke
resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B1s'
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
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
          id: nic.id
        }
      ]
    }
  }
}

// Outputs for AWS deployment
output vwanId string = vwan.id
output vhubId string = vhub.id
output vpnGatewayId string = vpnGateway.id
output vpnGatewayName string = vpnGateway.name
output spokeVnetId string = spokeVnet.id
output spokeVmPrivateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output azureBgpAsn int = azureBgpAsn
