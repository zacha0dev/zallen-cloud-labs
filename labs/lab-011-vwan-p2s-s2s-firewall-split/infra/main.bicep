// lab-011: vWAN hub with S2S + P2S on the Default route table, an Azure Firewall
// in a spoke VNet (reached through a VNet-connection static route) and an Azure
// Firewall in the hub (secured hub, no routing intent).
//
// Hub operations are chained with dependsOn (connection -> S2S GW -> P2S GW ->
// hub firewall) so the hub never receives two writes at once. The on-prem
// simulator, the spoke firewall and the VMs build in parallel with that chain.
//
// Deliberately NOT in this template: static routes in the hub defaultRouteTable.
// Those are the variable under test and are toggled by scenario.ps1.

param location string
param tags object
param adminUsername string
@secure()
param adminPassword string
@secure()
param s2sSharedKey string
@description('Base64 body of the P2S root certificate. Empty = skip the P2S gateway.')
param p2sRootCertData string = ''
@allowed([ 'Basic', 'Standard' ])
param firewallTier string = 'Basic'
param vmSize string = 'Standard_B1s'

// -----------------------------------------------------------------------------
// Names and address plan
// -----------------------------------------------------------------------------
var vwanName = 'vwan-lab-011'
var hubName = 'vhub-lab-011'
var hubCidr = '10.110.0.0/24'

var fwVnetName = 'vnet-lab-011-fw'
var fwVnetCidr = '10.111.0.0/24'
var fwSubnetCidr = '10.111.0.0/26'
var fwMgmtSubnetCidr = '10.111.0.64/26'

var appVnetName = 'vnet-lab-011-app'
var appVnetCidr = '10.112.0.0/24'
var appVmIp = '10.112.0.4'

var onpremVnetName = 'vnet-lab-011-onprem'
var onpremVnetCidr = '10.120.0.0/24'
var onpremGwSubnetCidr = '10.120.0.0/27'
var onpremVmSubnetCidr = '10.120.0.64/26'
var onpremVmIp = '10.120.0.68'
var onpremAsn = 65010

var p2sPoolCidr = '172.16.110.0/24'

var privateRanges = [ '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16' ]
var deployP2s = !empty(p2sRootCertData)

// -----------------------------------------------------------------------------
// Logging (firewall flow logs prove which firewall a flow crossed)
// -----------------------------------------------------------------------------
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-lab-011'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// -----------------------------------------------------------------------------
// Firewall policies: allow all private-to-private traffic, log everything
// -----------------------------------------------------------------------------
resource policyHub 'Microsoft.Network/firewallPolicies@2023-09-01' = {
  name: 'afwp-lab-011-hub'
  location: location
  tags: tags
  properties: {
    sku: { tier: firewallTier }
  }
}

resource policyHubRcg 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: policyHub
  name: 'rcg-private'
  properties: {
    priority: 100
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-private'
        priority: 100
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'private-any'
            ipProtocols: [ 'Any' ]
            sourceAddresses: privateRanges
            destinationAddresses: privateRanges
            destinationPorts: [ '*' ]
          }
        ]
      }
    ]
  }
}

resource policySpoke 'Microsoft.Network/firewallPolicies@2023-09-01' = {
  name: 'afwp-lab-011-spoke'
  location: location
  tags: tags
  properties: {
    sku: { tier: firewallTier }
  }
}

resource policySpokeRcg 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: policySpoke
  name: 'rcg-private'
  properties: {
    priority: 100
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-private'
        priority: 100
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'private-any'
            ipProtocols: [ 'Any' ]
            sourceAddresses: privateRanges
            destinationAddresses: privateRanges
            destinationPorts: [ '*' ]
          }
        ]
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// Firewall spoke VNet + Azure Firewall (the NVA-in-spoke for S2S traffic)
// -----------------------------------------------------------------------------
resource fwVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: fwVnetName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ fwVnetCidr ] }
    subnets: [
      {
        name: 'AzureFirewallSubnet'
        properties: { addressPrefix: fwSubnetCidr }
      }
      {
        name: 'AzureFirewallManagementSubnet'
        properties: { addressPrefix: fwMgmtSubnetCidr }
      }
    ]
  }
}

resource fwSpokePip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-lab-011-fw-spoke'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource fwSpokeMgmtPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = if (firewallTier == 'Basic') {
  name: 'pip-lab-011-fw-spoke-mgmt'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource fwSpoke 'Microsoft.Network/azureFirewalls@2023-09-01' = {
  name: 'afw-lab-011-spoke'
  location: location
  tags: tags
  dependsOn: [ policySpokeRcg ]
  properties: {
    sku: { name: 'AZFW_VNet', tier: firewallTier }
    firewallPolicy: { id: policySpoke.id }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: fwVnet.properties.subnets[0].id }
          publicIPAddress: { id: fwSpokePip.id }
        }
      }
    ]
    managementIpConfiguration: firewallTier == 'Basic' ? {
      name: 'mgmt'
      properties: {
        subnet: { id: fwVnet.properties.subnets[1].id }
        publicIPAddress: { id: fwSpokeMgmtPip.id }
      }
    } : null
  }
}

// -----------------------------------------------------------------------------
// App VNet: an indirect spoke peered to the firewall VNet (not to the hub).
// Its only path to the hub is through the spoke firewall.
// -----------------------------------------------------------------------------
resource appRt 'Microsoft.Network/routeTables@2023-09-01' = {
  name: 'rt-lab-011-app'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'rfc1918-10-via-spoke-fw'
        properties: {
          addressPrefix: '10.0.0.0/8'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: fwSpoke.properties.ipConfigurations[0].properties.privateIPAddress
        }
      }
      {
        name: 'rfc1918-172-via-spoke-fw'
        properties: {
          addressPrefix: '172.16.0.0/12'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: fwSpoke.properties.ipConfigurations[0].properties.privateIPAddress
        }
      }
    ]
  }
}

resource appVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: appVnetName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ appVnetCidr ] }
    subnets: [
      {
        name: 'snet-app'
        properties: {
          addressPrefix: appVnetCidr
          routeTable: { id: appRt.id }
        }
      }
    ]
  }
}

resource peerFwToApp 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: fwVnet
  name: 'peer-fw-to-app'
  properties: {
    remoteVirtualNetwork: { id: appVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}

resource peerAppToFw 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: appVnet
  name: 'peer-app-to-fw'
  properties: {
    remoteVirtualNetwork: { id: fwVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}

// -----------------------------------------------------------------------------
// vWAN + hub, then the serialized hub chain
// -----------------------------------------------------------------------------
resource vwan 'Microsoft.Network/virtualWans@2023-09-01' = {
  name: vwanName
  location: location
  tags: tags
  properties: {
    type: 'Standard'
    allowBranchToBranchTraffic: true
  }
}

resource hub 'Microsoft.Network/virtualHubs@2023-09-01' = {
  name: hubName
  location: location
  tags: tags
  properties: {
    addressPrefix: hubCidr
    virtualWan: { id: vwan.id }
    sku: 'Standard'
  }
}

var defaultRtId = resourceId('Microsoft.Network/virtualHubs/hubRouteTables', hubName, 'defaultRouteTable')

// Firewall VNet connection: associated + propagating to Default, with a static
// route that sends the app prefix to the spoke firewall and propagates it.
resource connFw 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-09-01' = {
  parent: hub
  name: 'conn-vnet-fw'
  dependsOn: [ peerFwToApp, peerAppToFw ]
  properties: {
    remoteVirtualNetwork: { id: fwVnet.id }
    enableInternetSecurity: false
    routingConfiguration: {
      associatedRouteTable: { id: defaultRtId }
      propagatedRouteTables: {
        ids: [ { id: defaultRtId } ]
        labels: [ 'default' ]
      }
      vnetRoutes: {
        staticRoutes: [
          {
            name: 'app-via-spoke-fw'
            addressPrefixes: [ appVnetCidr ]
            nextHopIpAddress: fwSpoke.properties.ipConfigurations[0].properties.privateIPAddress
          }
        ]
        // propagateStaticRoutes is read-only in the API (the platform sets it);
        // inspect.ps1 reads it back and checks the route really reached Default.
        staticRoutesConfig: {
          vnetLocalRouteOverrideCriteria: 'Contains'
        }
      }
    }
  }
}

resource s2sGw 'Microsoft.Network/vpnGateways@2023-09-01' = {
  name: 'vpngw-lab-011'
  location: location
  tags: tags
  dependsOn: [ connFw ]
  properties: {
    virtualHub: { id: hub.id }
    vpnGatewayScaleUnit: 1
    bgpSettings: { asn: 65515 }
  }
}

resource vpnServerConfig 'Microsoft.Network/vpnServerConfigurations@2023-09-01' = if (deployP2s) {
  name: 'vpnsc-lab-011'
  location: location
  tags: tags
  properties: {
    vpnProtocols: [ 'OpenVPN' ]
    vpnAuthenticationTypes: [ 'Certificate' ]
    vpnClientRootCertificates: [
      {
        name: 'lab-011-p2s-root'
        publicCertData: p2sRootCertData
      }
    ]
  }
}

resource p2sGw 'Microsoft.Network/p2svpnGateways@2023-09-01' = if (deployP2s) {
  name: 'p2sgw-lab-011'
  location: location
  tags: tags
  dependsOn: [ s2sGw ]
  properties: {
    virtualHub: { id: hub.id }
    vpnGatewayScaleUnit: 1
    vpnServerConfiguration: { id: vpnServerConfig.id }
    p2SConnectionConfigurations: [
      {
        name: 'p2s-config'
        properties: {
          vpnClientAddressPool: { addressPrefixes: [ p2sPoolCidr ] }
          enableInternetSecurity: false
          routingConfiguration: {
            associatedRouteTable: { id: defaultRtId }
            propagatedRouteTables: {
              ids: [ { id: defaultRtId } ]
              labels: [ 'default' ]
            }
          }
        }
      }
    ]
  }
}

// Secured hub: Azure Firewall inside the hub, NO routing intent. Traffic only
// reaches it where a defaultRouteTable static route points at it (scenario.ps1).
resource fwHub 'Microsoft.Network/azureFirewalls@2023-09-01' = {
  name: 'afw-lab-011-hub'
  location: location
  tags: tags
  dependsOn: [ s2sGw, p2sGw, policyHubRcg ]
  properties: {
    sku: { name: 'AZFW_Hub', tier: firewallTier }
    virtualHub: { id: hub.id }
    firewallPolicy: { id: policyHub.id }
    hubIPAddresses: {
      publicIPs: { count: 1 }
    }
  }
}

resource diagHub 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-lab-011'
  scope: fwHub
  properties: {
    workspaceId: law.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [ { categoryGroup: 'allLogs', enabled: true } ]
  }
}

resource diagSpoke 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-lab-011'
  scope: fwSpoke
  properties: {
    workspaceId: law.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [ { categoryGroup: 'allLogs', enabled: true } ]
  }
}

// -----------------------------------------------------------------------------
// On-prem simulator: VNet + VPN gateway (BGP) + VM
// -----------------------------------------------------------------------------
resource onpremVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: onpremVnetName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ onpremVnetCidr ] }
    subnets: [
      {
        name: 'GatewaySubnet'
        properties: { addressPrefix: onpremGwSubnetCidr }
      }
      {
        name: 'snet-vm'
        properties: { addressPrefix: onpremVmSubnetCidr }
      }
    ]
  }
}

resource onpremGwPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-lab-011-onprem-gw'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  zones: [ '1', '2', '3' ]
  properties: { publicIPAllocationMethod: 'Static' }
}

resource onpremGw 'Microsoft.Network/virtualNetworkGateways@2023-09-01' = {
  name: 'vgw-lab-011-onprem'
  location: location
  tags: tags
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    vpnGatewayGeneration: 'Generation1'
    sku: { name: 'VpnGw1AZ', tier: 'VpnGw1AZ' }
    activeActive: false
    enableBgp: true
    bgpSettings: { asn: onpremAsn }
    ipConfigurations: [
      {
        name: 'default'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: onpremVnet.properties.subnets[0].id }
          publicIPAddress: { id: onpremGwPip.id }
        }
      }
    ]
  }
}

// vWAN side: the on-prem VPN site and the hub VPN connection (Default RT).
resource vpnSite 'Microsoft.Network/vpnSites@2023-09-01' = {
  name: 'site-lab-011-onprem'
  location: location
  tags: tags
  properties: {
    virtualWan: { id: vwan.id }
    deviceProperties: { deviceVendor: 'Azure', deviceModel: 'VpnGw1AZ', linkSpeedInMbps: 10 }
    vpnSiteLinks: [
      {
        name: 'link-onprem'
        properties: {
          ipAddress: onpremGwPip.properties.ipAddress
          linkProperties: { linkProviderName: 'azure', linkSpeedInMbps: 10 }
          bgpProperties: {
            asn: onpremAsn
            bgpPeeringAddress: onpremGw.properties.bgpSettings.bgpPeeringAddress
          }
        }
      }
    ]
  }
}

resource s2sConn 'Microsoft.Network/vpnGateways/vpnConnections@2023-09-01' = {
  parent: s2sGw
  name: 'conn-site-onprem'
  dependsOn: [ fwHub ]
  properties: {
    remoteVpnSite: { id: vpnSite.id }
    routingConfiguration: {
      associatedRouteTable: { id: defaultRtId }
      propagatedRouteTables: {
        ids: [ { id: defaultRtId } ]
        labels: [ 'default' ]
      }
    }
    vpnLinkConnections: [
      {
        name: 'link-onprem'
        properties: {
          vpnSiteLink: { id: '${vpnSite.id}/vpnSiteLinks/link-onprem' }
          enableBgp: true
          sharedKey: s2sSharedKey
          vpnConnectionProtocolType: 'IKEv2'
          connectionBandwidth: 10
        }
      }
    ]
  }
}

// On-prem side: local network gateway pointing at vWAN gateway Instance0.
// Public IP and BGP address are both picked by instance id, so they always
// belong to the same gateway instance regardless of array order.
resource lng 'Microsoft.Network/localNetworkGateways@2023-09-01' = {
  name: 'lng-lab-011-vwan-i0'
  location: location
  tags: tags
  properties: {
    gatewayIpAddress: first(filter(s2sGw.properties.ipConfigurations, c => c.id == 'Instance0'))!.publicIpAddress
    localNetworkAddressSpace: { addressPrefixes: [] }
    bgpSettings: {
      asn: 65515
      bgpPeeringAddress: first(filter(s2sGw.properties.bgpSettings.bgpPeeringAddresses, b => b.ipconfigurationId == 'Instance0'))!.defaultBgpIpAddresses[0]
    }
  }
}

resource onpremConn 'Microsoft.Network/connections@2023-09-01' = {
  name: 'cn-lab-011-onprem-to-vwan'
  location: location
  tags: tags
  properties: {
    connectionType: 'IPsec'
    connectionProtocol: 'IKEv2'
    virtualNetworkGateway1: { id: onpremGw.id, properties: {} }
    localNetworkGateway2: { id: lng.id, properties: {} }
    sharedKey: s2sSharedKey
    enableBgp: true
  }
}

// -----------------------------------------------------------------------------
// Test VMs (no public IPs; driven with az vm run-command)
// -----------------------------------------------------------------------------
var testVms = [
  { name: 'vm-lab-011-app', subnetId: '${appVnet.id}/subnets/snet-app', ip: appVmIp }
  { name: 'vm-lab-011-onprem', subnetId: '${onpremVnet.id}/subnets/snet-vm', ip: onpremVmIp }
]

resource nics 'Microsoft.Network/networkInterfaces@2023-09-01' = [for v in testVms: {
  name: 'nic-${v.name}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: v.ip
          subnet: { id: v.subnetId }
        }
      }
    ]
  }
}]

resource vms 'Microsoft.Compute/virtualMachines@2023-09-01' = [for (v, i) in testVms: {
  name: v.name
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: v.name
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
      networkInterfaces: [ { id: nics[i].id, properties: { deleteOption: 'Delete' } } ]
    }
  }
}]

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------
output hubName string = hub.name
output defaultRouteTableId string = defaultRtId
output hubFirewallId string = fwHub.id
output hubFirewallPrivateIp string = fwHub.properties.hubIPAddresses.privateIPAddress
output spokeFirewallId string = fwSpoke.id
output spokeFirewallPrivateIp string = fwSpoke.properties.ipConfigurations[0].properties.privateIPAddress
output fwConnectionId string = connFw.id
output s2sConnectionId string = s2sConn.id
output p2sGatewayName string = deployP2s ? p2sGw.name : ''
output workspaceCustomerId string = law.properties.customerId
output appVmIp string = appVmIp
output onpremVmIp string = onpremVmIp
output p2sPool string = p2sPoolCidr
