// main.bicep - cptdazavdvwan / shortpath
// Dedicated RDP Shortpath session host, isolated from the primary AVD stack.
//
// Design decisions:
//  - Shortpath type: PUBLIC NETWORKS (STUN/TURN). UDP/TCP are enabled in Windows
//    by default, so NO in-guest configuration (Group Policy / Intune / Machine
//    Configuration) is required. The only network dependency is the Azure
//    Firewall network rule 'rdp-shortpath-relay' (UDP 3478 -> 51.5.0.0/16),
//    which already covers the whole AVD spoke (10.1.0.0/16) in infra/platform/main.bicep.
//    A managed-networks listener (UDP 3390) would require an in-guest policy;
//    that path is intentionally NOT used here.
//  - Own host pool / app group / workspace for clean isolation from hp-<prefix>.
//  - Reuses the existing AVD spoke VNet/subnet (firewall, NAT GW, routing intent).

targetScope = 'resourceGroup'

@description('Azure region for networking and VMs.')
param location string = resourceGroup().location

@description('Azure region for AVD control plane (not all regions support AVD).')
param avdLocation string = 'northeurope'

@description('Naming prefix (must match the primary stack so existing network resources resolve).')
param prefix string = 'cptdazavdvwan'

@description('Admin username for the session host.')
param adminUsername string = 'yourUsername'

@secure()
@description('Admin password for the session host.')
param adminPassword string

@description('Base time for AVD token expiration.')
param baseTime string = utcNow()

@description('Entra object ID of the security GROUP that gets AVD access and sign-in rights on this Shortpath session host. Leave empty to skip these role assignments.')
param avdUserGroupObjectId string = ''

// ---- Built-in role definition IDs ----
var desktopVirtualizationUserRoleId = '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'
var virtualMachineUserLoginRoleId = 'fb879df8-f326-4884-b1cf-06f3ad86be52'
var assignAvdGroup = !empty(avdUserGroupObjectId)

// ---- Existing AVD spoke (created by infra/avd/main.bicep) ----
resource vnetAvd 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: 'vnet-avd-${prefix}'
}

// ============ Dedicated Shortpath Host Pool ============
resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2023-09-05' = {
  name: 'hp-shortpath-${prefix}'
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
  name: 'dag-shortpath-${prefix}'
  location: avdLocation
  properties: {
    hostPoolArmPath: hostPool.id
    applicationGroupType: 'Desktop'
  }
}

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2023-09-05' = {
  name: 'ws-shortpath-${prefix}'
  location: avdLocation
  properties: {
    applicationGroupReferences: [ appGroup.id ]
  }
}

// ============ Dedicated Shortpath Session Host VM ============
resource nicShortpath 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-shortpath-${prefix}'
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

resource vmShortpath 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-shortpath-${prefix}'
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
      computerName: 'vmsp01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: { provisionVMAgent: true }
    }
    networkProfile: { networkInterfaces: [ { id: nicShortpath.id } ] }
    licenseType: 'Windows_Client'
  }
  identity: {
    type: 'SystemAssigned'
  }
}

// ============ Entra ID Join Extension ============
resource aadLogin 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vmShortpath
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
// Mirrors the primary stack so the same AVD group can use this Shortpath host.
// Reader on the resource group is already granted by infra/avd/main.bicep (same RG).
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
  name: guid(vmShortpath.id, avdUserGroupObjectId, virtualMachineUserLoginRoleId)
  scope: vmShortpath
  properties: {
    principalId: avdUserGroupObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', virtualMachineUserLoginRoleId)
    principalType: 'Group'
  }
}

// ============ Outputs ============
output hostPoolName string = hostPool.name
output appGroupName string = appGroup.name
output workspaceName string = workspace.name
output vmName string = vmShortpath.name
