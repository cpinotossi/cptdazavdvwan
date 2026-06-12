using './main.bicep'

param location      = readEnvironmentVariable('LOCATION', 'swedencentral')
param prefix        = readEnvironmentVariable('PREFIX', 'cptdazavdvwan')
param adminUsername = readEnvironmentVariable('ADMIN_USERNAME', 'chpinoto')

// VM is not reachable from the public internet (no public IP, access via Bastion only).
// Password kept in cleartext here by deliberate decision (matches the primary stack).
param adminPassword = 'demo!pass123'

// End-user access via the same Entra security group used by the primary stack (grp-avd-users).
// The shortpath.yml workflow resolves the group object ID and passes it via AVD_USER_GROUP_OBJECT_ID.
param avdUserGroupObjectId = readEnvironmentVariable('AVD_USER_GROUP_OBJECT_ID', '')
