targetScope = 'resourceGroup'

@description('Azure region for this VPN connection.')
param location string

@description('Solution-owned VPN connection name.')
param connectionName string

@description('Resource ID of the Hub VPN Gateway.')
param virtualNetworkGatewayId string

@description('Resource ID of this office Local Network Gateway.')
param localNetworkGatewayId string

@description('PSK retrieved from the existing Key Vault. This is a secure module parameter.')
@secure()
param sharedKey string

@description('Enable BGP for this connection.')
param enableBgp bool

@description('Resource tags.')
param tags object

resource connection 'Microsoft.Network/connections@2024-05-01' = {
  name: connectionName
  location: location
  tags: tags
  properties: {
    connectionType: 'IPsec'
    connectionProtocol: 'IKEv2'
    virtualNetworkGateway1: {
      id: virtualNetworkGatewayId
      properties: {}
    }
    localNetworkGateway2: {
      id: localNetworkGatewayId
      properties: {}
    }
    sharedKey: sharedKey
    enableBgp: enableBgp
    ipsecPolicies: [
      {
        saLifeTimeSeconds: 27000
        saDataSizeKilobytes: 102400000
        ipsecEncryption: 'AES256'
        ipsecIntegrity: 'SHA256'
        ikeEncryption: 'AES256'
        ikeIntegrity: 'SHA256'
        dhGroup: 'DHGroup14'
        pfsGroup: 'PFS14'
      }
    ]
  }
}
