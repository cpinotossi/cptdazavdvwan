// chaos/main.bicep - Azure Chaos Studio for cptdazavdvwan
// Onboards the AVD session host VM as a service-direct Chaos target and defines a
// VM shutdown experiment used to negatively influence the session host on demand.

targetScope = 'resourceGroup'

@description('Naming prefix (matches the main deployment).')
param prefix string = 'cptdazavdvwan'

@description('Azure region for the Chaos resources.')
param location string = resourceGroup().location

@description('ISO8601 duration the session host stays shut down during the experiment.')
param experimentDuration string = 'PT10M'

@description('Abruptly power off the VM (true) or gracefully shut down the guest OS (false).')
param abruptShutdown bool = false

var vmName = 'vm-avd-${prefix}'
var experimentName = 'exp-shutdown-${prefix}'
var shutdownCapabilityUrn = 'urn:csci:microsoft:virtualMachine:shutdown/1.0'

// Virtual Machine Contributor - lets the experiment identity stop/start the VM.
var vmContributorRoleId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'

resource vmAvd 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: vmName
}

// Service-direct Chaos target (extension resource on the VM).
resource chaosTarget 'Microsoft.Chaos/targets@2024-01-01' = {
  name: 'Microsoft-VirtualMachine'
  scope: vmAvd
  properties: {}
}

resource shutdownCapability 'Microsoft.Chaos/targets/capabilities@2024-01-01' = {
  parent: chaosTarget
  name: 'Shutdown-1.0'
}

resource experiment 'Microsoft.Chaos/experiments@2024-01-01' = {
  name: experimentName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    selectors: [
      {
        type: 'List'
        id: 'avd-host'
        targets: [
          {
            type: 'ChaosTarget'
            id: chaosTarget.id
          }
        ]
      }
    ]
    steps: [
      {
        name: 'shutdown-session-host'
        branches: [
          {
            name: 'branch-shutdown'
            actions: [
              {
                type: 'continuous'
                name: shutdownCapabilityUrn
                selectorId: 'avd-host'
                duration: experimentDuration
                parameters: [
                  {
                    key: 'abruptShutdown'
                    value: '${abruptShutdown}'
                  }
                ]
              }
            ]
          }
        ]
      }
    ]
  }
}

// Grant the experiment identity permission to power the VM off/on.
resource vmContributor 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  scope: subscription()
  name: vmContributorRoleId
}

resource experimentRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vmAvd.id, experiment.id, vmContributor.id)
  scope: vmAvd
  properties: {
    principalId: experiment.identity.principalId
    roleDefinitionId: vmContributor.id
    principalType: 'ServicePrincipal'
  }
}

@description('Name of the Chaos experiment to start from the notebook.')
output experimentName string = experiment.name

@description('Resource ID of the Chaos experiment.')
output experimentId string = experiment.id

@description('Principal ID of the experiment system-assigned identity.')
output experimentPrincipalId string = experiment.identity.principalId
