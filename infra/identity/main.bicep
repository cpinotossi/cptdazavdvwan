// identity/main.bicep - Entra security group LIFECYCLE for cptdazavdvwan.
// Creates the security groups that main.bicep and chaos/main.bicep assign roles to,
// using the Microsoft Graph Bicep extension. Deployed alongside the AVD infrastructure
// (deploy.yml). Group object IDs are exposed as outputs and fed into the AVD/Chaos
// deployments via the avdUserGroupObjectId / chaosOperatorGroupObjectId parameters.
//
// This template intentionally does NOT manage membership. Group membership is dynamic
// and owned by members.bicep + its own pipeline (members.yml). Because the Microsoft
// Graph extension defaults to 'append' semantics, omitting the members property here
// never disturbs members managed by the membership pipeline.
//
// Prerequisite: the deploying identity needs the Microsoft Graph application permission
// Group.ReadWrite.All (app-only) or the Groups Administrator Entra role.

extension microsoftGraphV1

targetScope = 'resourceGroup'

import { avdUserGroup, chaosOperatorGroup } from './shared.bicep'

@description('Naming prefix (matches the main deployment).')
param prefix string = 'cptdazavdvwan'

var avd = avdUserGroup(prefix)
var chaos = chaosOperatorGroup(prefix)

// Security group for AVD end users (Desktop Virtualization User + VM User Login + Reader).
resource avdUsers 'Microsoft.Graph/groups@v1.0' = {
  displayName: avd.displayName
  uniqueName: avd.uniqueName
  mailEnabled: false
  mailNickname: avd.mailNickname
  securityEnabled: true
}

// Security group for Chaos operators (Chaos Studio Operator on the experiment).
resource chaosOperators 'Microsoft.Graph/groups@v1.0' = {
  displayName: chaos.displayName
  uniqueName: chaos.uniqueName
  mailEnabled: false
  mailNickname: chaos.mailNickname
  securityEnabled: true
}

@description('Object ID of the AVD user group. Pass to main.bicep as avdUserGroupObjectId.')
output avdUserGroupObjectId string = avdUsers.id

@description('Object ID of the Chaos operator group. Pass to chaos/main.bicep as chaosOperatorGroupObjectId.')
output chaosOperatorGroupObjectId string = chaosOperators.id
