// main.bicep - cptdazavdvwan
// Minimal vWAN + AVD to test UDR on AVD spoke with Routing Intent enabled.
// Single resource group. Sweden Central.

targetScope = 'resourceGroup'

@description('Azure region.')
param location string = resourceGroup().location

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
        name: 'allow-avd-egress'
        priority: 1000
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'avd-service-traffic'
            sourceAddresses: [ avdSpokeAddr ]
            protocols: [ { protocolType: 'Https', port: 443 } ]
            targetFqdns: [
              '*.wvd.microsoft.com'
              #disable-next-line no-hardcoded-env-urls
              '*.login.microsoftonline.com'
              #disable-next-line no-hardcoded-env-urls
              'login.microsoftonline.com'
              '*.microsoftonline.com'
              '*.microsoft.com'
              '*.azure.com'
              #disable-next-line no-hardcoded-env-urls
              'management.azure.com'
              #disable-next-line no-hardcoded-env-urls
              'gcs.prod.monitoring.core.windows.net'
              #disable-next-line no-hardcoded-env-urls
              '*.prod.warm.ingest.monitor.core.windows.net'
              'catalogartifact.azureedge.net'
              '*.delivery.mp.microsoft.com'
              '*.windowsupdate.com'
              '*.digicert.com'
              '*.azure-dns.com'
              '*.azure-dns.net'
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
            destinationPorts: [ '80' ]
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

// ============ AVD Spoke VNet + UDR (THE TEST) ============
resource rtAvd 'Microsoft.Network/routeTables@2023-09-01' = {
  name: 'rt-avd-${prefix}'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        // Test: more-specific route that should coexist with Routing Intent.
        // Routing Intent injects 10.0.0.0/8 -> FW. This UDR tests if
        // 10.99.0.0/16 -> None wins (more specific).
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
  location: location
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
  location: location
  properties: {
    hostPoolArmPath: hostPool.id
    applicationGroupType: 'Desktop'
  }
}

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2023-09-05' = {
  name: 'ws-${prefix}'
  location: location
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
}

// DSC extension to register as AVD session host
resource extAvdDsc 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vmAvd
  name: 'Microsoft.PowerShell.DSC'
  location: location
  properties: {
    publisher: 'Microsoft.Powershell'
    type: 'DSC'
    typeHandlerVersion: '2.73'
    autoUpgradeMinorVersion: true
    settings: {
      modulesUrl: 'https://wvdportalstorageblob.blob.${environment().suffixes.storage}/galleryartifacts/Configuration_1.0.02797.442.zip'
      configurationFunction: 'Configuration.ps1\\AddSessionHost'
      properties: {
        hostPoolName: hostPool.name
        registrationInfoRegistrationToken: hostPool.properties.registrationInfo.token
        aadJoin: false
      }
    }
  }
  dependsOn: [ cxAvd ]
}

// ============ Outputs ============
output firewallPrivateIp string = fw.properties.hubIPAddresses.privateIPAddress
output bastionName string = bastion.name
output hostPoolName string = hostPool.name
output avdVmName string = vmAvd.name
output routeTableName string = rtAvd.name
output routeTableId string = rtAvd.id
