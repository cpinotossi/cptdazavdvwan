// identity/members.bicep - DYNAMIC group MEMBERSHIP for cptdazavdvwan.
// Owns ONLY who is a member of the security groups created by main.bicep. Runs in its
// own pipeline (members.yml) so frequent access changes never touch the AVD/Chaos infra.
//
// The groups already exist (created by main.bicep). Declaring them again with the same
// uniqueName performs an idempotent upsert; here we add the members relationship.
//
// 'replace' semantics makes the parameter list the single source of truth: a user
// removed from the .bicepparam file is removed from the group on the next deployment.
// (The Microsoft Graph extension defaults to 'append', which would only ever add.)
//
// Group naming comes from shared.bicep, so names are defined exactly once across the
// creation and membership templates (DRY).

extension microsoftGraphV1

targetScope = 'resourceGroup'

import { avdUserGroup, chaosOperatorGroup } from './shared.bicep'

@description('Naming prefix (matches the main deployment).')
param prefix string = 'cptdazavdvwan'

@description('Entra object IDs of users that may use AVD. Single source of truth; replace semantics removes anyone not listed.')
param avdUserMemberObjectIds string[]

@description('Entra object IDs of users allowed to start/stop the Chaos experiment. Replace semantics removes anyone not listed.')
param chaosOperatorMemberObjectIds string[]

var avd = avdUserGroup(prefix)
var chaos = chaosOperatorGroup(prefix)

resource avdUsers 'Microsoft.Graph/groups@v1.0' = {
  displayName: avd.displayName
  uniqueName: avd.uniqueName
  mailEnabled: false
  mailNickname: avd.mailNickname
  securityEnabled: true
  members: {
    relationshipSemantics: 'replace'
    relationships: avdUserMemberObjectIds
  }
}

resource chaosOperators 'Microsoft.Graph/groups@v1.0' = {
  displayName: chaos.displayName
  uniqueName: chaos.uniqueName
  mailEnabled: false
  mailNickname: chaos.mailNickname
  securityEnabled: true
  members: {
    relationshipSemantics: 'replace'
    relationships: chaosOperatorMemberObjectIds
  }
}
