targetScope = 'resourceGroup'

@description('Short prefix used for solution-owned Azure resource names.')
@minLength(3)
@maxLength(20)
param resourcePrefix string

@description('Azure region for regional resources.')
param location string

@description('Tags applied to resources that support tags.')
param tags object

@description('Hub VNet address space. Do not use 192.168.0.0/16 in Azure.')
param hubAddressPrefix string

@description('Prefix reserved for the VPN Gateway. Use at least /27.')
param gatewaySubnetPrefix string

@description('Prefix for the hub shared-services subnet.')
param sharedServicesSubnetPrefix string

@description('Prefix for the hub network-management subnet.')
param networkManagementSubnetPrefix string

@description('VPN Gateway SKU, for example VpnGw1AZ.')
param vpnGatewaySku string = 'VpnGw1AZ'

@description('VPN Gateway generation.')
@allowed([
  'Generation1'
  'Generation2'
])
param vpnGatewayGeneration string = 'Generation2'

@description('Enable BGP on the VPN Gateway and all office connections.')
param enableBgp bool = false

@description('Azure VPN Gateway ASN when BGP is enabled.')
param azureBgpAsn int = 65515

@description('Office definitions. Each office uses an FQDN and its own Key Vault secret.')
@minLength(1)
param offices array

@description('Spoke VNets and their subnets.')
@minLength(1)
param spokes array

@description('Inbound TCP rules allowed from the configured office prefixes. Empty means no custom inbound allow rules.')
param authorizedInboundRules array = []

@description('Name of an existing Key Vault containing one distinct PSK secret per office.')
param keyVaultName string

@description('Resource group containing the existing Key Vault.')
param keyVaultResourceGroupName string = resourceGroup().name

@description('Subscription containing the existing Key Vault.')
param keyVaultSubscriptionId string = subscription().subscriptionId

@description('Create an Azure Firewall resource. It is not attached to routes and does not inspect traffic unless separately configured.')
param enableFirewall bool = false

@description('Prefix reserved for AzureFirewallSubnet when Firewall is enabled. Use at least /26.')
param firewallSubnetPrefix string = ''

@description('Create Azure Bastion. It is disabled by default.')
param enableBastion bool = false

@description('Prefix reserved for AzureBastionSubnet when Bastion is enabled. Use at least /26.')
param bastionSubnetPrefix string = ''

@description('Optional Private DNS zones to create and link to the Hub and all Spokes.')
param privateDnsZones array = []

var hubVnetName = '${resourcePrefix}-hub-vnet'
var gatewayName = '${resourcePrefix}-vpn-gateway'
var gatewayPublicIpName = '${resourcePrefix}-vpn-gateway-pip'
var gatewaySubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', hubVnetName, 'GatewaySubnet')
var firewallSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', hubVnetName, 'AzureFirewallSubnet')
var bastionSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', hubVnetName, 'AzureBastionSubnet')
var officeAddressPrefixGroups = [for office in offices: office.addressPrefixes]
var officeAddressPrefixes = flatten(officeAddressPrefixGroups)
var privateDnsSpokeLinkData = [for linkIndex in range(0, length(privateDnsZones) * length(spokes)): {
  zoneIndex: int(linkIndex / length(spokes))
  spokeIndex: linkIndex % length(spokes)
}]

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
  scope: resourceGroup(keyVaultSubscriptionId, keyVaultResourceGroupName)
}

resource hubVnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: hubVnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        hubAddressPrefix
      ]
    }
    subnets: concat(
      [
        {
          name: 'GatewaySubnet'
          properties: {
            addressPrefix: gatewaySubnetPrefix
          }
        }
        {
          name: 'SharedServicesSubnet'
          properties: {
            addressPrefix: sharedServicesSubnetPrefix
          }
        }
        {
          name: 'NetworkManagementSubnet'
          properties: {
            addressPrefix: networkManagementSubnetPrefix
          }
        }
      ],
      enableFirewall
        ? [
            {
              name: 'AzureFirewallSubnet'
              properties: {
                addressPrefix: firewallSubnetPrefix
              }
            }
          ]
        : [],
      enableBastion
        ? [
            {
              name: 'AzureBastionSubnet'
              properties: {
                addressPrefix: bastionSubnetPrefix
              }
            }
          ]
        : []
    )
  }
}

resource spokeNsgs 'Microsoft.Network/networkSecurityGroups@2024-05-01' = [for (spoke, spokeIndex) in spokes: {
  name: '${resourcePrefix}-${spoke.name}-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [for (rule, ruleIndex) in authorizedInboundRules: {
      name: '${rule.name}-${ruleIndex}'
      properties: {
        description: 'Authorized inbound TCP port from configured office networks.'
        protocol: 'Tcp'
        sourcePortRange: '*'
        destinationPortRange: string(rule.destinationPort)
        sourceAddressPrefixes: officeAddressPrefixes
        destinationAddressPrefix: '*'
        access: 'Allow'
        priority: 100 + ruleIndex
        direction: 'Inbound'
      }
    }]
  }
}]

resource spokeVnets 'Microsoft.Network/virtualNetworks@2024-05-01' = [for (spoke, spokeIndex) in spokes: {
  name: '${resourcePrefix}-${spoke.name}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        spoke.addressPrefix
      ]
    }
    subnets: [for subnet in spoke.subnets: {
      name: subnet.name
      properties: {
        addressPrefix: subnet.addressPrefix
        networkSecurityGroup: {
          id: spokeNsgs[spokeIndex].id
        }
      }
    }]
  }
}]

resource hubToSpokePeerings 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = [for (spoke, spokeIndex) in spokes: {
  parent: hubVnet
  name: '${resourcePrefix}-hub-to-${spoke.name}'
  properties: {
    remoteVirtualNetwork: {
      id: spokeVnets[spokeIndex].id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true
    useRemoteGateways: false
  }
}]

resource spokeToHubPeerings 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = [for (spoke, spokeIndex) in spokes: {
  parent: spokeVnets[spokeIndex]
  name: '${resourcePrefix}-spoke-to-hub'
  properties: {
    remoteVirtualNetwork: {
      id: hubVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: true
  }
}]

resource gatewayPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: gatewayPublicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource vpnGateway 'Microsoft.Network/virtualNetworkGateways@2024-05-01' = {
  name: gatewayName
  location: location
  tags: tags
  dependsOn: [
    hubVnet
  ]
  properties: union(
    {
      ipConfigurations: [
        {
          name: 'gateway-ip-configuration'
          properties: {
            privateIPAllocationMethod: 'Dynamic'
            subnet: {
              id: gatewaySubnetId
            }
            publicIPAddress: {
              id: gatewayPublicIp.id
            }
          }
        }
      ]
      gatewayType: 'Vpn'
      vpnType: 'RouteBased'
      vpnGatewayGeneration: vpnGatewayGeneration
      enableBgp: enableBgp
      activeActive: false
      sku: {
        name: vpnGatewaySku
        tier: vpnGatewaySku
      }
    },
    enableBgp
      ? {
          bgpSettings: {
            asn: azureBgpAsn
          }
        }
      : {}
  )
}

resource officeLocalNetworkGateways 'Microsoft.Network/localNetworkGateways@2024-05-01' = [for office in offices: {
  name: '${resourcePrefix}-${office.name}-lng'
  location: location
  tags: tags
  properties: union(
    {
      fqdn: office.fqdn
      localNetworkAddressSpace: {
        addressPrefixes: office.addressPrefixes
      }
    },
    enableBgp
      ? {
          bgpSettings: {
            asn: office.asn
            bgpPeeringAddress: office.bgpPeerIp
          }
        }
      : {}
  )
}]

module officeConnections 'modules/vpn-connection.bicep' = [for (office, officeIndex) in offices: {
  name: '${resourcePrefix}-connection-${uniqueString(office.name, resourceGroup().id)}'
  params: {
    location: location
    connectionName: '${resourcePrefix}-${office.name}-connection'
    virtualNetworkGatewayId: vpnGateway.id
    localNetworkGatewayId: officeLocalNetworkGateways[officeIndex].id
    sharedKey: keyVault.getSecret(office.pskSecretName)
    enableBgp: enableBgp
    tags: tags
  }
}]

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2024-05-01' = if (enableFirewall) {
  name: '${resourcePrefix}-firewall-policy'
  location: location
  tags: tags
  properties: {
    sku: {
      tier: 'Standard'
    }
    threatIntelMode: 'Alert'
  }
}

resource firewallPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (enableFirewall) {
  name: '${resourcePrefix}-firewall-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource azureFirewall 'Microsoft.Network/azureFirewalls@2024-05-01' = if (enableFirewall) {
  name: '${resourcePrefix}-firewall'
  location: location
  tags: tags
  dependsOn: [
    hubVnet
  ]
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Standard'
    }
    firewallPolicy: {
      id: firewallPolicy!.id
    }
    ipConfigurations: [
      {
        name: 'firewall-ip-configuration'
        properties: {
          subnet: {
            id: firewallSubnetId
          }
          publicIPAddress: {
            id: firewallPublicIp!.id
          }
        }
      }
    ]
  }
}

resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (enableBastion) {
  name: '${resourcePrefix}-bastion-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource azureBastion 'Microsoft.Network/bastionHosts@2024-05-01' = if (enableBastion) {
  name: '${resourcePrefix}-bastion'
  location: location
  tags: tags
  dependsOn: [
    hubVnet
  ]
  sku: {
    name: 'Standard'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'bastion-ip-configuration'
        properties: {
          subnet: {
            id: bastionSubnetId
          }
          publicIPAddress: {
            id: bastionPublicIp!.id
          }
        }
      }
    ]
  }
}

resource privateDnsZoneResources 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zone in privateDnsZones: {
  name: zone
  location: 'global'
  tags: tags
  properties: {}
}]

resource privateDnsHubLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zone, zoneIndex) in privateDnsZones: {
  parent: privateDnsZoneResources[zoneIndex]
  name: '${resourcePrefix}-hub-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: hubVnet.id
    }
  }
}]

resource privateDnsSpokeLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for link in privateDnsSpokeLinkData: {
  parent: privateDnsZoneResources[link.zoneIndex]
  name: '${resourcePrefix}-${spokes[link.spokeIndex].name}-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: spokeVnets[link.spokeIndex].id
    }
  }
}]

output hubVnetId string = hubVnet.id
output vpnGatewayName string = vpnGateway.name
output vpnGatewayPublicIp string = gatewayPublicIp.properties.ipAddress
output spokeVnetIds array = [for (spoke, spokeIndex) in spokes: spokeVnets[spokeIndex].id]
