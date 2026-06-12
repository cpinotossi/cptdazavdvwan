// shared.bicep - single source of truth for the Entra security group identities.
// Imported by both the group-creation template (main.bicep) and the membership
// template (members.bicep) so group naming is defined exactly once (DRY).

@export()
@description('Descriptor for an Entra security group used by this solution.')
type groupDescriptor = {
  displayName: string
  uniqueName: string
  mailNickname: string
}

@export()
@description('AVD end-user group (Desktop Virtualization User + VM User Login + Reader).')
func avdUserGroup(prefix string) groupDescriptor => {
  displayName: 'grp-avd-users'
  uniqueName: 'grp-avd-users-${prefix}'
  mailNickname: 'grp-avd-users-${prefix}'
}

@export()
@description('Chaos operator group (Chaos Studio Operator on the experiment).')
func chaosOperatorGroup(prefix string) groupDescriptor => {
  displayName: 'grp-avd-chaos'
  uniqueName: 'grp-avd-chaos-${prefix}'
  mailNickname: 'grp-avd-chaos-${prefix}'
}
