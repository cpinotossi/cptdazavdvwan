// main.bicep - cptdazavdvwan / fslogix
// Dedicated multi-session AVD host with FSLogix profile containers on Azure Files,
// reachable ONLY via a private endpoint, isolated from the primary AVD stack.
//
// Design decisions (see infra/fslogix/README.md for the full rationale + pros/cons):
//  - MULTI-SESSION host (Windows 11 Enterprise multi-session image) so two users
//    can sign in to the SAME pooled host at once and exercise profile roaming.
//  - Azure Files share with Microsoft Entra Kerberos (AADKERB) = cloud-only /
//    Entra-ID-only identities, NO Active Directory Domain Services.
//  - PRIVATE ENDPOINT ONLY: storage publicNetworkAccess 'Disabled', networkAcls
//    defaultAction 'Deny'. The share is unreachable from the public internet.
//  - Private DNS zone privatelink.file.core.windows.net is LINKED DIRECTLY to the
//    existing vnet-avd. This project has NO DNS Private Resolver and the spoke uses
//    Azure default DNS (168.63.129.16), so the VNet link is what makes
//    <storage>.file.core.windows.net resolve to the private IP. No custom DNS needed.
//  - PE lives in snet-pe, a dedicated subnet in the SAME vnet-avd as the session
//    host (snet-pe is defined in infra/avd/main.bicep so a deploy.yml re-run keeps it).
//  - Own host pool / app group / workspace for clean isolation from hp-<prefix>.
//  - Entra Kerberos POST-CONFIG (admin consent + app manifest tag) is NOT done here
//    because the storage Entra app is auto-created by the Storage RP only AFTER this
//    deploys; the fslogix.yml workflow handles it (Option B, fully automated).

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

@description('Entra object ID of the security GROUP that gets AVD access, sign-in rights and SMB share access on this FSLogix host. Leave empty to skip these role assignments.')
param avdUserGroupObjectId string = ''

@description('Storage account name for the Azure Files FSLogix share (3-24 lowercase alphanumeric, globally unique).')
@minLength(3)
@maxLength(24)
param storageAccountName string = 'stfsl${prefix}'

@description('Azure Files share name for FSLogix profile containers.')
param fileShareName string = 'profiles'

@description('FSLogix profile share quota in GiB.')
param fileShareQuotaGiB int = 100

@description('Maximum concurrent user sessions on the pooled multi-session host.')
param hostMaxSessionLimit int = 4

// ---- Built-in role definition IDs ----
var desktopVirtualizationUserRoleId = '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'
var virtualMachineUserLoginRoleId = 'fb879df8-f326-4884-b1cf-06f3ad86be52'
var storageFileDataSmbShareContributorRoleId = '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb'
var assignAvdGroup = !empty(avdUserGroupObjectId)

// ---- Existing AVD spoke (created by infra/avd/main.bicep) ----
resource vnetAvd 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: 'vnet-avd-${prefix}'

  resource snetHosts 'subnets@2023-09-01' existing = {
    name: 'snet-avd-hosts'
  }

  resource snetPe 'subnets@2023-09-01' existing = {
    name: 'snet-pe'
  }
}

// ============ Storage Account + Azure Files (Entra Kerberos, private only) ============
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    // Reachable ONLY through the private endpoint.
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      virtualNetworkRules: []
      ipRules: []
    }
    // Cloud-only / Entra-ID-only identities via Microsoft Entra Kerberos.
    // No activeDirectoryProperties: that block is only for hybrid (AD DS) identities.
    azureFilesIdentityBasedAuthentication: {
      directoryServiceOptions: 'AADKERB'
    }
  }
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource profileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileServices
  name: fileShareName
  properties: {
    shareQuota: fileShareQuotaGiB
    enabledProtocols: 'SMB'
  }
}

// ============ Private DNS + Private Endpoint for Azure Files ============
resource fileDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.file.${environment().suffixes.storage}'
  location: 'global'
}

// Link the zone directly to the AVD spoke so default Azure DNS resolves the
// storage FQDN to the private IP (no DNS Private Resolver / custom DNS in this project).
resource fileDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: fileDnsZone
  name: 'link-vnet-avd'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetAvd.id }
  }
}

resource filePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: 'pe-${storageAccountName}-file'
  location: location
  properties: {
    subnet: { id: vnetAvd::snetPe.id }
    privateLinkServiceConnections: [
      {
        name: 'pe-${storageAccountName}-file'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: [ 'file' ]
        }
      }
    ]
  }
}

resource filePeDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: filePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-file'
        properties: {
          privateDnsZoneId: fileDnsZone.id
        }
      }
    ]
  }
}

// ============ Dedicated Multi-Session Host Pool ============
resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2023-09-05' = {
  name: 'hp-fslogix-${prefix}'
  location: avdLocation
  properties: {
    hostPoolType: 'Pooled'
    loadBalancerType: 'BreadthFirst'
    preferredAppGroupType: 'Desktop'
    maxSessionLimit: hostMaxSessionLimit
    validationEnvironment: true
    customRdpProperty: 'enablerdsaadauth:i:1;targetisaadjoined:i:1;'
    registrationInfo: {
      registrationTokenOperation: 'Update'
      expirationTime: dateTimeAdd(baseTime, 'PT24H')
    }
  }
}

resource appGroup 'Microsoft.DesktopVirtualization/applicationGroups@2023-09-05' = {
  name: 'dag-fslogix-${prefix}'
  location: avdLocation
  properties: {
    hostPoolArmPath: hostPool.id
    applicationGroupType: 'Desktop'
  }
}

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2023-09-05' = {
  name: 'ws-fslogix-${prefix}'
  location: avdLocation
  properties: {
    applicationGroupReferences: [ appGroup.id ]
  }
}

// ============ Dedicated Multi-Session FSLogix Host VM ============
resource nicFslogix 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'nic-fslogix-${prefix}'
  location: location
  properties: {
    ipConfigurations: [ {
      name: 'ipcfg'
      properties: {
        privateIPAllocationMethod: 'Dynamic'
        subnet: { id: vnetAvd::snetHosts.id }
      }
    } ]
  }
}

resource vmFslogix 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-fslogix-${prefix}'
  location: location
  properties: {
    hardwareProfile: { vmSize: 'Standard_D2s_v5' }
    storageProfile: {
      // Windows 11 Enterprise MULTI-SESSION + M365 (FSLogix agent preinstalled).
      imageReference: {
        publisher: 'microsoftwindowsdesktop'
        offer: 'office-365'
        sku: 'win11-24h2-avd-m365'
        version: 'latest'
      }
      osDisk: { createOption: 'FromImage', managedDisk: { storageAccountType: 'Premium_LRS' } }
    }
    osProfile: {
      computerName: 'vmfsl01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: { provisionVMAgent: true }
    }
    networkProfile: { networkInterfaces: [ { id: nicFslogix.id } ] }
    licenseType: 'Windows_Client'
  }
  identity: {
    type: 'SystemAssigned'
  }
}

// ============ Entra ID Join Extension ============
resource aadLogin 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vmFslogix
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
// Same AVD group used by the primary stack. Reader on the RG is already granted
// by infra/avd/main.bicep (same RG).
//  - Desktop Virtualization User on the FSLogix app group -> may use the desktop
//  - Virtual Machine User Login on the host               -> may sign in (Entra)
//  - Storage File Data SMB Share Contributor on storage   -> may read/write own FSLogix profile
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
  name: guid(vmFslogix.id, avdUserGroupObjectId, virtualMachineUserLoginRoleId)
  scope: vmFslogix
  properties: {
    principalId: avdUserGroupObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', virtualMachineUserLoginRoleId)
    principalType: 'Group'
  }
}

resource avdUserSmbShare 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignAvdGroup) {
  name: guid(storage.id, avdUserGroupObjectId, storageFileDataSmbShareContributorRoleId)
  scope: storage
  properties: {
    principalId: avdUserGroupObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageFileDataSmbShareContributorRoleId)
    principalType: 'Group'
  }
}

// ============ Outputs ============
output storageAccountName string = storage.name
output fileShareName string = profileShare.name
output profileShareUncPath string = '\\\\${storage.name}.file.${environment().suffixes.storage}\\${fileShareName}'
output storageFileFqdn string = '${storage.name}.file.${environment().suffixes.storage}'
output hostPoolName string = hostPool.name
output appGroupName string = appGroup.name
output workspaceName string = workspace.name
output vmName string = vmFslogix.name
