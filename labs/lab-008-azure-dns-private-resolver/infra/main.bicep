// labs/lab-008-azure-dns-private-resolver/infra/main.bicep
//
// Deploys:
//   Hub VNet  (10.80.0.0/16) — workload subnet + two resolver subnets
//   Spoke VNet (10.81.0.0/16) — workload subnet + test VM
//   VNet peering: hub <-> spoke
//   DNS Private Resolver (hub)
//     - Inbound endpoint  → snet-dns-inbound  (10.80.2.0/28)
//     - Outbound endpoint → snet-dns-outbound (10.80.3.0/28)
//   Private DNS Zone: internal.lab (linked to hub, auto-registration OFF)
//   Static A record: app.internal.lab → 10.80.1.10
//   DNS Forwarding Ruleset (linked to spoke VNet)
//     - Rule: internal.lab         → inbound endpoint IP
//     - Rule: onprem.example.com   → 10.0.0.1 (simulated external DNS)
//   Test VM (spoke, Standard_B1s, no public IP)
//     - Boot diagnostics enabled  → serial console accessible via Azure Portal
//     - cloud-init pre-installs: bind9-dnsutils (dig/nslookup), iputils-ping

@description('Azure region for all resources')
param location string = 'eastus2'

@description('Admin username for the test VM')
param adminUser string = 'azureuser'

@description('Admin password for the test VM')
@secure()
param adminPassword string

@description('Owner tag value')
param owner string = 'lab'

// ─── Tags ────────────────────────────────────────────────────────────────────
var tags = {
  project: 'azure-labs'
  lab: 'lab-008'
  owner: owner
  environment: 'lab'
  'cost-center': 'learning'
}

// ─── Naming ───────────────────────────────────────────────────────────────────
var hubVnetName          = 'vnet-hub-008'
var spokeVnetName        = 'vnet-spoke-008'
var hubNsgName           = 'nsg-hub-008'
var spokeNsgName         = 'nsg-spoke-008'
var resolverName         = 'dnsresolver-008'
var inboundEpName        = 'ep-inbound-008'
var outboundEpName       = 'ep-outbound-008'
var rulesetName          = 'ruleset-008'
var dnsZoneName          = 'internal.lab'
var zoneVnetLinkName     = 'link-hub-internal-lab'
var vmSpokeName          = 'vm-spoke-008'
var nicSpokeName         = 'nic-vm-spoke-008'

// ─── Address spaces ───────────────────────────────────────────────────────────
var hubVnetCidr          = '10.80.0.0/16'
var hubWorkloadSubnet    = '10.80.1.0/24'
var hubInboundSubnet     = '10.80.2.0/28'   // /28 minimum for resolver endpoints
var hubOutboundSubnet    = '10.80.3.0/28'
var spokeVnetCidr        = '10.81.0.0/16'
var spokeWorkloadSubnet  = '10.81.1.0/24'

// Static DNS A record target (simulated app server)
var appRecordIp          = '10.80.1.10'

var securityPolicyName = 'dnspolicy-lab-008'
var domainListName     = 'domainlist-lab-008-blocked'
var securityRuleName   = 'rule-block-lab-domains'
var policyLinkName     = 'link-policy-spoke'

// ─── Subnet IDs — computed from known names to avoid fragile index references ─
// These are constructed after the VNet is declared using resourceId() so that
// subnet ordering changes in the array never silently break endpoint deployments.
var inboundSubnetId  = resourceId('Microsoft.Network/virtualNetworks/subnets', hubVnetName,   'snet-dns-inbound')
var outboundSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', hubVnetName,   'snet-dns-outbound')
var spokeWorkloadSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', spokeVnetName, 'snet-workload-spoke')

// ─── Cloud-init: pre-install DNS tools for serial-console testing ─────────────
// bind9-dnsutils   → dig, nslookup, nsupdate
// iputils-ping     → ping
// dnsmasq-base     → local resolver inspection
// Encoded as base64 for the customData field (Azure decodes and runs at first boot).
var cloudInitScript = '''
#cloud-config
package_update: true
packages:
  - bind9-dnsutils
  - iputils-ping
  - dnsmasq-base
runcmd:
  - echo "=== DNS lab tools ready ===" > /etc/motd
  - echo "Try: dig app.internal.lab" >> /etc/motd
  - echo "Try: nslookup app.internal.lab" >> /etc/motd
  - echo "Try: resolvectl status" >> /etc/motd
'''

// ─── NSG: Hub (no rules needed for resolver subnets — delegated, NSG not supported) ──
resource hubNsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: hubNsgName
  location: location
  tags: tags
  properties: {
    securityRules: []   // Hub workload subnet — open within VNet
  }
}

// ─── NSG: Spoke ───────────────────────────────────────────────────────────────
resource spokeNsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: spokeNsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
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

// ─── Hub VNet ─────────────────────────────────────────────────────────────────
// NOTE: Resolver endpoint subnets must be delegated and cannot have NSGs.
resource hubVnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: hubVnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ hubVnetCidr ]
    }
    subnets: [
      {
        name: 'snet-workload-hub'
        properties: {
          addressPrefix: hubWorkloadSubnet
          networkSecurityGroup: { id: hubNsg.id }
        }
      }
      {
        name: 'snet-dns-inbound'
        properties: {
          addressPrefix: hubInboundSubnet
          // No NSG — required for resolver inbound endpoint subnets
          delegations: [
            {
              name: 'delegation-dns-resolver'
              properties: {
                serviceName: 'Microsoft.Network/dnsResolvers'
              }
            }
          ]
        }
      }
      {
        name: 'snet-dns-outbound'
        properties: {
          addressPrefix: hubOutboundSubnet
          // No NSG — required for resolver outbound endpoint subnets
          delegations: [
            {
              name: 'delegation-dns-resolver'
              properties: {
                serviceName: 'Microsoft.Network/dnsResolvers'
              }
            }
          ]
        }
      }
    ]
  }
}

// ─── Spoke VNet ───────────────────────────────────────────────────────────────
resource spokeVnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: spokeVnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ spokeVnetCidr ]
    }
    subnets: [
      {
        name: 'snet-workload-spoke'
        properties: {
          addressPrefix: spokeWorkloadSubnet
          networkSecurityGroup: { id: spokeNsg.id }
        }
      }
    ]
  }
}

// ─── VNet Peering: Hub → Spoke ────────────────────────────────────────────────
resource peeringHubToSpoke 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-05-01' = {
  parent: hubVnet
  name: 'peer-hub-to-spoke'
  properties: {
    remoteVirtualNetwork: { id: spokeVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

// ─── VNet Peering: Spoke → Hub ────────────────────────────────────────────────
resource peeringSpokeToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-05-01' = {
  parent: spokeVnet
  name: 'peer-spoke-to-hub'
  properties: {
    remoteVirtualNetwork: { id: hubVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

// ─── DNS Private Resolver ─────────────────────────────────────────────────────
resource resolver 'Microsoft.Network/dnsResolvers@2022-07-01' = {
  name: resolverName
  location: location
  tags: tags
  properties: {
    virtualNetwork: { id: hubVnet.id }
  }
}

// ─── Inbound Endpoint ─────────────────────────────────────────────────────────
resource inboundEndpoint 'Microsoft.Network/dnsResolvers/inboundEndpoints@2022-07-01' = {
  parent: resolver
  name: inboundEpName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        privateIpAllocationMethod: 'Dynamic'
        subnet: {
          id: inboundSubnetId
        }
      }
    ]
  }
}

// ─── Outbound Endpoint ───────────────────────────────────────────────────────
resource outboundEndpoint 'Microsoft.Network/dnsResolvers/outboundEndpoints@2022-07-01' = {
  parent: resolver
  name: outboundEpName
  location: location
  tags: tags
  properties: {
    subnet: {
      id: outboundSubnetId
    }
  }
}

// ─── DNS Forwarding Ruleset ───────────────────────────────────────────────────
resource ruleset 'Microsoft.Network/dnsForwardingRulesets@2022-07-01' = {
  name: rulesetName
  location: location
  tags: tags
  properties: {
    dnsResolverOutboundEndpoints: [
      { id: outboundEndpoint.id }
    ]
  }
}

// ─── Forwarding Rule: internal.lab → inbound endpoint (resolves private zone) ─
resource ruleInternalLab 'Microsoft.Network/dnsForwardingRulesets/forwardingRules@2022-07-01' = {
  parent: ruleset
  name: 'rule-internal-lab'
  properties: {
    domainName: 'internal.lab.'             // trailing dot is required
    targetDnsServers: [
      {
        ipAddress: inboundEndpoint.properties.ipConfigurations[0].privateIpAddress
        port: 53
      }
    ]
    forwardingRuleState: 'Enabled'
  }
}

// ─── Forwarding Rule: onprem.example.com → simulated external DNS ─────────────
// Demonstrates controlled forwarding to an "external" resolver.
// 10.0.0.1 is a placeholder — in a real scenario this would be on-prem DNS.
resource ruleOnprem 'Microsoft.Network/dnsForwardingRulesets/forwardingRules@2022-07-01' = {
  parent: ruleset
  name: 'rule-onprem-example'
  properties: {
    domainName: 'onprem.example.com.'
    targetDnsServers: [
      {
        ipAddress: '10.0.0.1'               // simulated on-prem DNS — replace in real use
        port: 53
      }
    ]
    forwardingRuleState: 'Enabled'
  }
}

// ─── Ruleset VNet Link → Spoke ────────────────────────────────────────────────
// Spoke VMs use this ruleset for forwarding. No link to hub needed
// because hub VMs resolve internal.lab directly via the private zone link.
resource rulesetLinkSpoke 'Microsoft.Network/dnsForwardingRulesets/virtualNetworkLinks@2022-07-01' = {
  parent: ruleset
  name: 'link-ruleset-spoke'
  properties: {
    virtualNetwork: { id: spokeVnet.id }
  }
}

// ─── Private DNS Zone: internal.lab ──────────────────────────────────────────
resource dnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: dnsZoneName
  location: 'global'
  tags: tags
}

// ─── Zone VNet Link → Hub (auto-registration OFF — explicit records only) ────
resource zoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsZone
  name: zoneVnetLinkName
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: hubVnet.id }
  }
}

// ─── Static A Record: app.internal.lab ────────────────────────────────────────
resource appARecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: dnsZone
  name: 'app'
  properties: {
    ttl: 300
    aRecords: [
      { ipv4Address: appRecordIp }
    ]
  }
}

// ─── NIC for Spoke Test VM ────────────────────────────────────────────────────
resource nicSpoke 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: nicSpokeName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: spokeWorkloadSubnetId
          }
        }
      }
    ]
  }
  dependsOn: [
    peeringSpokeToHub
    peeringHubToSpoke
  ]
}

// ─── Spoke Test VM ────────────────────────────────────────────────────────────
// Serial console access:
//   Azure Portal → Virtual machines → vm-spoke-008 → Help → Serial console
//   No NSG rules or public IP needed — serial console is an out-of-band channel.
//   Login with the adminUser/adminPassword supplied at deploy time.
resource vmSpoke 'Microsoft.Compute/virtualMachines@2023-07-01' = {
  name: vmSpokeName
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: 'Standard_B1s' }
    osProfile: {
      computerName: vmSpokeName
      adminUsername: adminUser
      adminPassword: adminPassword
      linuxConfiguration: { disablePasswordAuthentication: false }
      // cloud-init runs at first boot: installs dig/nslookup/ping and sets MOTD
      customData: base64(cloudInitScript)
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
      networkInterfaces: [
        {
          id: nicSpoke.id
          properties: { deleteOption: 'Delete' }
        }
      ]
    }
    // Boot diagnostics — required for Azure Serial Console access.
    // Managed storage (no storageUri) is free and needs no storage account.
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// ─── DNS Security Policy ─────────────────────────────────────────────────────
// Demonstrates DNS query filtering. Regional resource - must match VNet region.
// One VNet can be linked to at most one DNS Security Policy.
resource dnsSecurityPolicy 'Microsoft.Network/dnsResolverPolicies@2023-07-01-preview' = {
  name: securityPolicyName
  location: location
  tags: tags
}

// ─── DNS Domain List ─────────────────────────────────────────────────────────
// Top-level resource (not nested under policy). Contains domains to block.
// Domains use standard DNS format with trailing dot.
resource domainList 'Microsoft.Network/dnsResolverDomainLists@2023-07-01-preview' = {
  name: domainListName
  location: location
  tags: tags
  properties: {
    domains: [
      'blocked.lab.'
      'malware.internal.lab.'
    ]
  }
}

// ─── DNS Security Rule: Block ─────────────────────────────────────────────────
// Blocks queries for domains in the domain list before they reach the forwarding
// ruleset or private DNS zones. Priority 100. SERVFAIL returned to the querier.
resource securityRule 'Microsoft.Network/dnsResolverPolicies/dnsSecurityRules@2023-07-01-preview' = {
  parent: dnsSecurityPolicy
  name: securityRuleName
  location: location
  properties: {
    priority: 100
    action: {
      actionType: 'Block'
      blockResponseCode: 'SERVFAIL'
    }
    dnsSecurityRuleState: 'Enabled'
    dnsResolverDomainLists: [
      { id: domainList.id }
    ]
  }
}

// ─── Policy VNet Link: spoke ──────────────────────────────────────────────────
// Links the security policy to the spoke VNet. DNS queries from spoke VMs
// are evaluated against the policy rules before forwarding ruleset is consulted.
// NOTE: A VNet can be linked to only one DNS Security Policy at a time.
resource policyVnetLink 'Microsoft.Network/dnsResolverPolicies/virtualNetworkLinks@2023-07-01-preview' = {
  parent: dnsSecurityPolicy
  name: policyLinkName
  properties: {
    virtualNetwork: { id: spokeVnet.id }
  }
}

// ─── Outputs ─────────────────────────────────────────────────────────────────
output hubVnetId string = hubVnet.id
output spokeVnetId string = spokeVnet.id
output resolverId string = resolver.id
output resolverName string = resolver.name
output inboundEndpointId string = inboundEndpoint.id
output inboundEndpointIp string = inboundEndpoint.properties.ipConfigurations[0].privateIpAddress
output outboundEndpointId string = outboundEndpoint.id
output rulesetId string = ruleset.id
output dnsZoneId string = dnsZone.id
output vmSpokeId string = vmSpoke.id
output vmSpokeName string = vmSpoke.name
output appRecordFqdn string = 'app.${dnsZoneName}'
// Direct portal link to serial console (requires Azure AD login with VM Contributor+ role)
output vmSpokeSerialConsoleUrl string = 'https://portal.azure.com/#resource${vmSpoke.id}/serialConsole'
output securityPolicyId string = dnsSecurityPolicy.id
output securityPolicyName string = dnsSecurityPolicy.name
output domainListId string = domainList.id
output domainListName string = domainList.name
