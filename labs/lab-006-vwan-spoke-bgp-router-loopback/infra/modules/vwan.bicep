// infra/modules/vwan.bicep
// Virtual WAN + Virtual Hub
//
// Status: PLACEHOLDER — structure only, not fully parameterized yet.

param location string
param tags object

param vwanName string = 'vwan-lab-006'
param vhubName string = 'vhub-lab-006'
param vhubPrefix string = '10.0.0.0/24'

resource vwan 'Microsoft.Network/virtualWans@2023-09-01' = {
  name: vwanName
  location: location
  tags: tags
  properties: {
    type: 'Standard'
    disableVpnEncryption: false
    allowBranchToBranchTraffic: true
  }
}

resource vhub 'Microsoft.Network/virtualHubs@2023-09-01' = {
  name: vhubName
  location: location
  tags: tags
  properties: {
    virtualWan: {
      id: vwan.id
    }
    addressPrefix: vhubPrefix
  }
}

output vwanId string = vwan.id
output vhubId string = vhub.id
output vhubName string = vhub.name
