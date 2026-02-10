// infra/modules/spoke-a.bicep
// Spoke A VNet — BGP spoke with router subnets + client subnet
//
// Status: PLACEHOLDER — structure only.

param location string
param tags object
param addressPrefix string = '10.61.0.0/16'
param vnetName string = 'vnet-spoke-a'

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
        name: 'snet-router-hubside'
        properties: {
          addressPrefix: '10.61.1.0/24'
        }
      }
      {
        name: 'snet-router-spokeside'
        properties: {
          addressPrefix: '10.61.2.0/24'
        }
      }
      {
        name: 'snet-client-a'
        properties: {
          addressPrefix: '10.61.10.0/24'
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
