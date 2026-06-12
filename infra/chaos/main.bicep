// chaos/main.bicep - Azure Chaos Studio for cptdazavdvwan
// Onboards the AVD session host VM as an agent-based Chaos target and defines a
// CPU-pressure experiment used to put the session host under load on demand.
//
// Prerequisite handled by the chaos GitHub workflow (not by this template):
//   A user-assigned managed identity 'id-chaos-<prefix>' exists and is ASSIGNED
//   to the VM. Agent-based faults require the UAMI on the VM, which cannot be
//   patched onto an existing VM from a separate Bicep stack.

targetScope = 'resourceGroup'

@description('Naming prefix (matches the main deployment).')
param prefix string = 'cptdazavdvwan'

@description('Azure region for the Chaos resources.')
param location string = resourceGroup().location

@description('Name of the user-assigned managed identity the Chaos agent authenticates with.')
param chaosIdentityName string = 'id-chaos-${prefix}'

@description('Entra tenant ID for the agent identity.')
param tenantId string = subscription().tenantId

@description('ISO8601 duration the CPU pressure is applied during the experiment.')
param experimentDuration string = 'PT10M'

@description('Target CPU utilization percentage during the experiment.')
@minValue(1)
@maxValue(99)
param cpuPressureLevel int = 95

@description('Entra object ID of the security GROUP allowed to start/stop the Chaos experiment. Manage members via group membership without redeploying. Leave empty to skip the role assignment.')
param chaosOperatorGroupObjectId string = ''

var vmName = 'vm-avd-${prefix}'
var experimentName = 'exp-cpu-${prefix}'
var cpuFaultUrn = 'urn:csci:microsoft:agent:cpuPressure/1.0'

// Reader is the required role for agent-based faults (needs */read on the target).
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

// Chaos Studio Operator: can run (start/cancel) experiments without managing them.
var chaosOperatorRoleId = '1a40e87e-6645-48e0-b27a-0b115d849a20'

resource vmAvd 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: vmName
}

resource chaosIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: chaosIdentityName
}

// Agent-based Chaos target (extension resource on the VM).
resource agentTarget 'Microsoft.Chaos/targets@2024-01-01' = {
  name: 'Microsoft-Agent'
  scope: vmAvd
  properties: {
    identities: [
      {
        type: 'AzureManagedIdentity'
        clientId: chaosIdentity.properties.clientId
        tenantId: tenantId
      }
    ]
  }
}

resource cpuCapability 'Microsoft.Chaos/targets/capabilities@2024-01-01' = {
  parent: agentTarget
  name: 'CPUPressure-1.0'
}

// Chaos Studio agent (Windows) installed as a VM extension. Authenticates with the
// UAMI and registers against the agent profile created by the target above.
resource chaosAgent 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vmAvd
  name: 'ChaosAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Chaos'
    type: 'ChaosWindowsAgent'
    typeHandlerVersion: '1.1'
    autoUpgradeMinorVersion: true
    settings: {
      profile: agentTarget.properties.agentProfileId
      'auth.msi.clientid': chaosIdentity.properties.clientId
    }
  }
  dependsOn: [
    cpuCapability
  ]
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
            id: agentTarget.id
          }
        ]
      }
    ]
    steps: [
      {
        name: 'cpu-pressure-step'
        branches: [
          {
            name: 'branch-cpu'
            actions: [
              {
                type: 'continuous'
                name: cpuFaultUrn
                selectorId: 'avd-host'
                duration: experimentDuration
                parameters: [
                  {
                    key: 'pressureLevel'
                    value: '${cpuPressureLevel}'
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

// Reader on the VM lets the experiment identity discover and target the agent.
resource readerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  scope: subscription()
  name: readerRoleId
}

resource experimentReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vmAvd.id, experiment.id, readerRole.id)
  scope: vmAvd
  properties: {
    principalId: experiment.identity.principalId
    roleDefinitionId: readerRole.id
    principalType: 'ServicePrincipal'
  }
}

// Chaos Studio Operator lets the user group start and stop this experiment only.
resource experimentOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(chaosOperatorGroupObjectId)) {
  name: guid(experiment.id, chaosOperatorGroupObjectId, chaosOperatorRoleId)
  scope: experiment
  properties: {
    principalId: chaosOperatorGroupObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', chaosOperatorRoleId)
    principalType: 'Group'
  }
}

@description('Name of the Chaos experiment to start from the notebook.')
output experimentName string = experiment.name

@description('Resource ID of the Chaos experiment.')
output experimentId string = experiment.id

@description('Principal ID of the experiment system-assigned identity.')
output experimentPrincipalId string = experiment.identity.principalId
