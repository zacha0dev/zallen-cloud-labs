// infra/modules/spoke-b.bicep
// Spoke B VNet -- Control spoke (no BGP, client subnet only)
//
// Status: PLACEHOLDER -- structure only.

param location string
param tags object
param addressPrefix string = '10.62.0.0/16'
param vnetName string = 'vnet-spoke-b'

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: [
      {
        name: 'snet-client-b'
        properties: {
          addressPrefix: '10.62.10.0/24'
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
