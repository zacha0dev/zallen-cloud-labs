// labs/lab-007-azure-dns-foundations/infra/main.bicep
// Deploys VNet, Subnet, Linux VM, Private DNS Zone, VNet Link, and A record

@description('Azure region for all resources')
param location string = 'centralus'

@description('Admin username for the test VM')
param adminUser string = 'azureuser'

@description('Admin password for the test VM')
@secure()
param adminPassword string

@description('Owner tag value')
param owner string = 'lab'

// ─── Networking ─────────────────────────────────────────────────────────────
var vnetName = 'vnet-lab-007'
var vnetCidr = '10.70.0.0/16'
var subnetName = 'snet-workload-007'
var subnetCidr = '10.70.1.0/24'

// ─── DNS ─────────────────────────────────────────────────────────────────────
var dnsZoneName = 'internal.lab'
var vnetLinkName = 'link-vnet-lab-007'
var aRecordName = 'webserver'
// A record target — VM gets 10.70.1.4 as first dynamic assignment in a /24
var aRecordIp = '10.70.1.4'

// ─── Compute ──────────────────────────────────────────────────────────────────
var vmName = 'vm-test-007'
var nicName = 'nic-vm-test-007'
var nsgName = 'nsg-workload-007'

// ─── Tags ─────────────────────────────────────────────────────────────────────
var tags = {
  project: 'azure-labs'
  lab: 'lab-007'
  owner: owner
  environment: 'lab'
  'cost-center': 'learning'
}

// ─── NSG (no public inbound, allows SSH from within VNet only) ────────────────
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-ssh-intra-vnet'
        properties: {
          priority: 1000
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'deny-all-inbound'
        properties: {
          priority: 4096
          protocol: '*'
          access: 'Deny'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ─── Virtual Network ──────────────────────────────────────────────────────────
resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ vnetCidr ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetCidr
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

// ─── NIC ──────────────────────────────────────────────────────────────────────
resource nic 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnet.properties.subnets[0].id
          }
        }
      }
    ]
  }
}

// ─── Linux Test VM ────────────────────────────────────────────────────────────
resource vm 'Microsoft.Compute/virtualMachines@2023-07-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B1s'
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUser
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
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
  }
}

// ─── Private DNS Zone ─────────────────────────────────────────────────────────
// Private DNS zones are global (no location)
resource dnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: dnsZoneName
  location: 'global'
  tags: tags
}

// ─── VNet Link ────────────────────────────────────────────────────────────────
resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsZone
  name: vnetLinkName
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: true           // auto-register VM hostnames
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// ─── Static A Record ──────────────────────────────────────────────────────────
resource aRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: dnsZone
  name: aRecordName
  properties: {
    ttl: 300
    aRecords: [
      {
        ipv4Address: aRecordIp
      }
    ]
  }
}

// ─── Outputs ─────────────────────────────────────────────────────────────────
output vnetId string = vnet.id
output subnetId string = vnet.properties.subnets[0].id
output vmId string = vm.id
output vmName string = vm.name
output nicName string = nic.name
output dnsZoneId string = dnsZone.id
output dnsZoneName string = dnsZone.name
output vnetLinkId string = vnetLink.id
output aRecordFqdn string = '${aRecordName}.${dnsZoneName}'
