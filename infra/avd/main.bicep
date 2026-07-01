// avd/main.bicep - cptdazavdvwan
// AVD WORKLOAD (spoke) layer: the AVD spoke VNet + subnets, its egress (NAT
// Gateway) and management (Bastion), the UDR that tests Service-Tag routing,
// the AVD control plane (host pool / app group / workspace), the session-host
// VM and end-user RBAC.
//
// Depends on the PLATFORM stack (infra/platform): the spoke connects to the
// vWAN hub created there, referenced read-only via `existing`. Deploy platform
// FIRST. Single resource group, deployed incrementally.

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

@description('Entra object ID of the security GROUP that gets AVD access, Reader on the resource group, and sign-in rights on the session host. Add/remove users via group membership without redeploying. Leave empty to skip these role assignments.')
param avdUserGroupObjectId string = ''

// ---- Built-in role definition IDs ----
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var desktopVirtualizationUserRoleId = '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'
var virtualMachineUserLoginRoleId = 'fb879df8-f326-4884-b1cf-06f3ad86be52'
var assignAvdGroup = !empty(avdUserGroupObjectId)

// ---- Address Spaces ----
var avdSpokeAddr = '10.1.0.0/16'
var avdHostSubnet = '10.1.1.0/24'
var avdPeSubnet = '10.1.2.0/24'
var avdBastionSubnet = '10.1.10.0/26'

// ============ Platform hub (from infra/platform) ============
// Read-only reference to the vWAN hub created by the platform stack. The spoke
// connection below attaches to it. Platform must be deployed first.
resource vhub 'Microsoft.Network/virtualHubs@2023-09-01' existing = {
  name: 'vhub-${prefix}'
}

// ============ NAT Gateway for AVD RDP bypass ============
// NAT Gateway is subnet-scoped and must live in the spoke VNet (it is NOT
// supported in the vWAN hub). It provides a stable egress IP for traffic that
// the UDR below sends straight to the Internet (WindowsVirtualDesktop), while
// everything else still egresses via the firewall in the hub.
// https://learn.microsoft.com/azure/nat-gateway/tutorial-hub-spoke-nat-firewall
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
      {
        // Private Endpoint subnet (used by the infra/fslogix stack for the
        // Azure Files private endpoint). Owned here so an avd deploy re-run does
        // not stomp a subnet added out-of-band by the fslogix stack.
        name: 'snet-pe'
        properties: {
          addressPrefix: avdPeSubnet
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
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
    customRdpProperty: 'drivestoredirect:s:;usbdevicestoredirect:s:;redirectclipboard:i:1;redirectprinters:i:0;audiomode:i:0;videoplaybackmode:i:1;devicestoredirect:s:*;redirectcomports:i:1;redirectsmartcards:i:1;enablecredsspsupport:i:1;redirectwebauthn:i:1;use multimon:i:1;enablerdsaadauth:i:1;keyboardhook:i:2;'
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

// ============ End-user RBAC ============
// Least-privilege access for the AVD user group (members added/removed via group membership):
//  - Desktop Virtualization User on the application group  -> may use the published desktop
//  - Virtual Machine User Login on the session host        -> may sign in to the Entra-joined VM
//  - Reader on the resource group                          -> may view the resources
resource avdUserAppGroup 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignAvdGroup) {
  name: guid(appGroup.id, avdUserGroupObjectId, desktopVirtualizationUserRoleId)
  scope: appGroup
  properties: {
    principalId: avdUserGroupObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', desktopVirtualizationUserRoleId)
    principalType: 'Group'
  }
}

resource avdUserVmLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignAvdGroup) {
  name: guid(vmAvd.id, avdUserGroupObjectId, virtualMachineUserLoginRoleId)
  scope: vmAvd
  properties: {
    principalId: avdUserGroupObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', virtualMachineUserLoginRoleId)
    principalType: 'Group'
  }
}

resource avdUserReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignAvdGroup) {
  name: guid(resourceGroup().id, avdUserGroupObjectId, readerRoleId)
  scope: resourceGroup()
  properties: {
    principalId: avdUserGroupObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalType: 'Group'
  }
}

// ============ Outputs ============
output natGatewayPublicIp string = natgwPip.properties.ipAddress
output bastionName string = bastion.name
output hostPoolName string = hostPool.name
output avdVmName string = vmAvd.name
output routeTableName string = rtAvd.name
output routeTableId string = rtAvd.id
