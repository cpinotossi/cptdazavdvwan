using './main.bicep'

param location      = readEnvironmentVariable('LOCATION', 'swedencentral')
param prefix        = readEnvironmentVariable('PREFIX', 'cptdazavdvwan')
param adminUsername = readEnvironmentVariable('ADMIN_USERNAME', 'chpinoto')
param vmSize        = readEnvironmentVariable('AVD_VM_SIZE', 'Standard_D2s_v5')
param computerName  = readEnvironmentVariable('SHORTPATH_COMPUTER_NAME', 'vmsp01')

param adminPassword = readEnvironmentVariable('VM_ADMIN_PASSWORD')

// End-user access via the same Entra security group used by the primary stack (grp-avd-users).
// Reuse the primary stack's configured group without requiring Microsoft Graph access.
param avdUserGroupObjectId = readEnvironmentVariable('AVD_USER_GROUP_OBJECT_ID', '')
