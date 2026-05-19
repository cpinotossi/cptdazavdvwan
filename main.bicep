// main.bicep - cptdazavdvwan
// Minimal vWAN + AVD to test UDR on AVD spoke with Routing Intent enabled.
// Single resource group. Sweden Central.

targetScope = 'resourceGroup'

@description('Azure region for networking and VMs.')
param location string = resourceGroup().location

@description('Azure region for AVD control plane (not all regions support AVD).')
param avdLocation string = 'northeurope'

@description('Naming prefix.')
param prefix string = 'cptdazavdvwan'

@description('Admin username for VMs.')
param adminUsername string = 'yourUsername'

@secure()
@description('Admin password for VMs.')
param adminPassword string

@description('Base time for AVD token expiration.')
param baseTime string = utcNow()

// ---- Address Spaces ----
var hubAddr = '10.0.0.0/16'
var avdSpokeAddr = '10.1.0.0/16'
var avdHostSubnet = '10.1.1.0/24'
var avdBastionSubnet = '10.1.10.0/26'

// ============ Virtual WAN + Hub ============
resource vwan 'Microsoft.Network/virtualWans@2023-09-01' = {
  name: 'vwan-${prefix}'
  location: location
  properties: {
    type: 'Standard'
    allowVnetToVnetTraffic: true
    allowBranchToBranchTraffic: true
  }
}

resource vhub 'Microsoft.Network/virtualHubs@2023-09-01' = {
  name: 'vhub-${prefix}'
  location: location
  properties: {
    addressPrefix: hubAddr
    sku: 'Standard'
    virtualWan: { id: vwan.id }
  }
}

// ============ Azure Firewall Policy ============
resource fwPolicy 'Microsoft.Network/firewallPolicies@2023-09-01' = {
  name: 'afwp-${prefix}'
  location: location
  properties: {
    sku: { tier: 'Standard' }
    threatIntelMode: 'Alert'
    dnsSettings: {
      enableProxy: true
    }
  }
}

resource fwRcg 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-09-01' = {
  parent: fwPolicy
  name: 'rcg-allow'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-avd-egress-https'
        priority: 1000
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'avd-service-traffic-https'
            sourceAddresses: [ avdSpokeAddr ]
            protocols: [ { protocolType: 'Https', port: 443 } ]
            targetFqdns: [
              // AVD Service Traffic (required)
              '*.wvd.microsoft.com'
              #disable-next-line no-hardcoded-env-urls
              '*.service.windows.cloud.microsoft'
              #disable-next-line no-hardcoded-env-urls
              '*.windows.cloud.microsoft'
              #disable-next-line no-hardcoded-env-urls
              '*.windows.static.microsoft'
              // Authentication
              #disable-next-line no-hardcoded-env-urls
              'login.microsoftonline.com'
              #disable-next-line no-hardcoded-env-urls
              '*.login.microsoftonline.com'
              '*.microsoftonline.com'
              #disable-next-line no-hardcoded-env-urls
              'login.windows.net'
              // Azure management + general Microsoft
              '*.microsoft.com'
              '*.azure.com'
              #disable-next-line no-hardcoded-env-urls
              'management.azure.com'
              'aka.ms'
              // Monitoring
              #disable-next-line no-hardcoded-env-urls
              'gcs.prod.monitoring.core.windows.net'
              #disable-next-line no-hardcoded-env-urls
              '*.prod.warm.ingest.monitor.core.windows.net'
              // Azure Marketplace + updates
              'catalogartifact.azureedge.net'
              '*.delivery.mp.microsoft.com'
              '*.windowsupdate.com'
              #disable-next-line no-hardcoded-env-urls
              '*.prod.do.dsp.mp.microsoft.com'
              // Storage / Blob (AVD agent download, SXS stack updates)
              #disable-next-line no-hardcoded-env-urls
              '*.blob.core.windows.net'
              #disable-next-line no-hardcoded-env-urls
              '*.servicebus.windows.net'
              #disable-next-line no-hardcoded-env-urls
              '*.core.windows.net'
              // DNS, certificates, telemetry
              '*.azure-dns.com'
              '*.azure-dns.net'
              '*.digicert.com'
              #disable-next-line no-hardcoded-env-urls
              '*.events.data.microsoft.com'
              // OneDrive, Graph
              '*.sfx.ms'
              #disable-next-line no-hardcoded-env-urls
              'graph.microsoft.com'
              // Entra ID device registration
              'enterpriseregistration.windows.net'
              '*.microsoftazuread-sso.com'
              'pas.windows.net'
            ]
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-avd-egress-http'
        priority: 1010
        action: { type: 'Allow' }
        rules: [
          {
            // Port 80 required for certificates + connectivity checks
            ruleType: 'ApplicationRule'
            name: 'avd-certificates-http'
            sourceAddresses: [ avdSpokeAddr ]
            protocols: [ { protocolType: 'Http', port: 80 } ]
            targetFqdns: [
              #disable-next-line no-hardcoded-env-urls
              'oneocsp.microsoft.com'
              'www.microsoft.com'
              '*.digicert.com'
              #disable-next-line no-hardcoded-env-urls
              '*.aikcertaia.microsoft.com'
              #disable-next-line no-hardcoded-env-urls
              'azcsprodeusaikpublish.blob.core.windows.net'
              #disable-next-line no-hardcoded-env-urls
              '*.microsoftaik.azure.net'
              #disable-next-line no-hardcoded-env-urls
              'ctldl.windowsupdate.com'
              #disable-next-line no-hardcoded-env-urls
              'www.msftconnecttest.com'
              'ocsp.msocsp.com'
            ]
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-avd-network'
        priority: 1100
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'kms'
            ipProtocols: [ 'TCP' ]
            sourceAddresses: [ avdSpokeAddr ]
            destinationAddresses: [ '23.102.135.246', '20.118.99.224', '40.83.235.53' ]
            destinationPorts: [ '1688' ]
          }
          {
            // RDP Shortpath relay - required for relayed RDP connectivity
            ruleType: 'NetworkRule'
            name: 'rdp-shortpath-relay'
            ipProtocols: [ 'UDP' ]
            sourceAddresses: [ avdSpokeAddr ]
            destinationAddresses: [ '51.5.0.0/16' ]
            destinationPorts: [ '3478' ]
          }
          {
            ruleType: 'NetworkRule'
            name: 'dns'
            ipProtocols: [ 'UDP', 'TCP' ]
            sourceAddresses: [ avdSpokeAddr ]
            destinationAddresses: [ '168.63.129.16' ]
            destinationPorts: [ '53' ]
          }
          {
            ruleType: 'NetworkRule'
            name: 'ntp'
            ipProtocols: [ 'UDP' ]
            sourceAddresses: [ avdSpokeAddr ]
            destinationFqdns: [ 'time.windows.com' ]
            destinationPorts: [ '123' ]
          }
          {
            ruleType: 'NetworkRule'
            name: 'metadata-wireserver'
            ipProtocols: [ 'TCP' ]
            sourceAddresses: [ avdSpokeAddr ]
            destinationAddresses: [ '169.254.169.254', '168.63.129.16' ]
            destinationPorts: [ '80', '32526' ]
          }
        ]
      }
    ]
  }
}

// ============ Azure Firewall (Secured Hub) ============
resource fw 'Microsoft.Network/azureFirewalls@2023-09-01' = {
  name: 'afw-${prefix}'
  location: location
  properties: {
    sku: { name: 'AZFW_Hub', tier: 'Standard' }
    hubIPAddresses: { publicIPs: { count: 1 } }
    virtualHub: { id: vhub.id }
    firewallPolicy: { id: fwPolicy.id }
  }
  dependsOn: [ fwRcg ]
}

// ============ Routing Intent ============
resource routingIntent 'Microsoft.Network/virtualHubs/routingIntent@2023-09-01' = {
  parent: vhub
  name: 'ri-${prefix}'
  properties: {
    routingPolicies: [
      { name: 'PrivateTraffic', destinations: [ 'PrivateTraffic' ], nextHop: fw.id }
      { name: 'InternetTraffic', destinations: [ 'Internet' ], nextHop: fw.id }
    ]
  }
}

// ============ NAT Gateway for AVD RDP bypass ============
resource natgwPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-natgw-avd-${prefix}'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource natgw 'Microsoft.Network/natGateways@2023-09-01' = {
  name: 'natgw-avd-${prefix}'
  location: location
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [ { id: natgwPip.id } ]
  }
}

// ============ AVD Spoke VNet + UDR (THE TEST) ============
// Test: Can a UDR with Service Tag 'WindowsVirtualDesktop' + next-hop Internet
// coexist with vWAN Routing Intent (0/0 -> FW)?
// Expected: WVD traffic exits via NAT GW, everything else via FW.
resource rtAvd 'Microsoft.Network/routeTables@2023-09-01' = {
  name: 'rt-avd-${prefix}'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        // THE KEY TEST: Service Tag route for AVD/WVD traffic -> Internet (NAT GW).
        // If Routing Intent allows this, RDP/WVD traffic bypasses the firewall.
        name: 'avd-wvd-direct-internet'
        properties: {
          addressPrefix: 'WindowsVirtualDesktop'
          nextHopType: 'Internet'
        }
      }
      {
        // Secondary test: more-specific private route vs Routing Intent 10.0.0.0/8.
        name: 'test-udr-more-specific'
        properties: {
          addressPrefix: '10.99.0.0/16'
          nextHopType: 'None'
        }
      }
    ]
  }
}

resource nsgAvd 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-avd-${prefix}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-rdp-from-vnet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
    ]
  }
}

resource vnetAvd 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-avd-${prefix}'
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ avdSpokeAddr ] }
    subnets: [
      {
        name: 'snet-avd-hosts'
        properties: {
          addressPrefix: avdHostSubnet
          routeTable: { id: rtAvd.id }
          networkSecurityGroup: { id: nsgAvd.id }
          natGateway: { id: natgw.id }
        }
      }
      { name: 'AzureBastionSubnet', properties: { addressPrefix: avdBastionSubnet } }
    ]
  }
}

resource cxAvd 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-09-01' = {
  parent: vhub
  name: 'cx-avd'
  properties: {
    remoteVirtualNetwork: { id: vnetAvd.id }
    allowHubToRemoteVnetTransit: true
    allowRemoteVnetToUseHubVnetGateways: true
    enableInternetSecurity: true
  }
  dependsOn: [ routingIntent ]
}

// ============ Bastion ============
resource bastionPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-bastion-${prefix}'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource bastion 'Microsoft.Network/bastionHosts@2023-09-01' = {
  name: 'bas-${prefix}'
  location: location
  sku: { name: 'Standard' }
  properties: {
    enableTunneling: true
    ipConfigurations: [ {
      name: 'ipcfg'
      properties: {
        subnet: { id: '${vnetAvd.id}/subnets/AzureBastionSubnet' }
        publicIPAddress: { id: bastionPip.id }
      }
    } ]
  }
}

// ============ AVD Host Pool ============
resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2023-09-05' = {
  name: 'hp-${prefix}'
  location: avdLocation
  properties: {
    hostPoolType: 'Pooled'
    loadBalancerType: 'BreadthFirst'
    preferredAppGroupType: 'Desktop'
    maxSessionLimit: 5
    validationEnvironment: true
    registrationInfo: {
      registrationTokenOperation: 'Update'
      expirationTime: dateTimeAdd(baseTime, 'PT24H')
    }
  }
}

resource appGroup 'Microsoft.DesktopVirtualization/applicationGroups@2023-09-05' = {
  name: 'dag-${prefix}'
  location: avdLocation
  properties: {
    hostPoolArmPath: hostPool.id
    applicationGroupType: 'Desktop'
  }
}

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2023-09-05' = {
  name: 'ws-${prefix}'
  location: avdLocation
  properties: {
    applicationGroupReferences: [ appGroup.id ]
  }
}

// ============ AVD Session Host VM ============
resource nicAvd 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-avd-${prefix}'
  location: location
  properties: {
    ipConfigurations: [ {
      name: 'ipcfg'
      properties: {
        privateIPAllocationMethod: 'Dynamic'
        subnet: { id: '${vnetAvd.id}/subnets/snet-avd-hosts' }
      }
    } ]
  }
}

resource vmAvd 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-avd-${prefix}'
  location: location
  properties: {
    hardwareProfile: { vmSize: 'Standard_D2s_v5' }
    storageProfile: {
      imageReference: {
        publisher: 'microsoftwindowsdesktop'
        offer: 'office-365'
        sku: 'win11-24h2-avd-m365'
        version: 'latest'
      }
      osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'Premium_LRS' } }
    }
    osProfile: {
      computerName: 'vmavd01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: { provisionVMAgent: true }
    }
    networkProfile: { networkInterfaces: [ { id: nicAvd.id } ] }
    licenseType: 'Windows_Client'
  }
  identity: {
    type: 'SystemAssigned'
  }
}

// ============ Entra ID Join Extension ============
resource aadLogin 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vmAvd
  name: 'AADLoginForWindows'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.0'
    autoUpgradeMinorVersion: true
    settings: {
      mdmId: ''
    }
  }
}

// ============ Outputs ============
output firewallPrivateIp string = fw.properties.hubIPAddresses.privateIPAddress
output firewallPublicIp string = fw.properties.hubIPAddresses.publicIPs.addresses[0].address
output natGatewayPublicIp string = natgwPip.properties.ipAddress
output bastionName string = bastion.name
output hostPoolName string = hostPool.name
output avdVmName string = vmAvd.name
output routeTableName string = rtAvd.name
output routeTableId string = rtAvd.id
