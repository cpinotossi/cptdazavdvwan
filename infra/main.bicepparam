using './main.bicep'

param location      = readEnvironmentVariable('LOCATION', 'swedencentral')
param prefix        = readEnvironmentVariable('PREFIX', 'cptdazavdvwan')
param adminUsername = readEnvironmentVariable('ADMIN_USERNAME', 'chpinoto')

// VMs are not reachable from the public internet (no public IP, access via Bastion only).
// Password kept in cleartext here by deliberate decision.
param adminPassword = 'demo!pass123'

// End-user access via an Entra security group (e.g. grp-avd-users).
// Set AVD_USER_GROUP_OBJECT_ID to the group's object ID; add jesse as a member of that group.
param avdUserGroupObjectId = readEnvironmentVariable('AVD_USER_GROUP_OBJECT_ID', '')
