using './main.bicep'

param location      = readEnvironmentVariable('LOCATION', 'swedencentral')
param prefix        = readEnvironmentVariable('PREFIX', 'cptdazavdvwan')
param adminUsername = readEnvironmentVariable('ADMIN_USERNAME', 'chpinoto')
param vmSize        = readEnvironmentVariable('AVD_VM_SIZE', 'Standard_D2s_v5')
param computerName  = readEnvironmentVariable('AVD_COMPUTER_NAME', 'vmavd01')

param adminPassword = readEnvironmentVariable('VM_ADMIN_PASSWORD')

// End-user access via an Entra security group (e.g. grp-avd-users).
// Set AVD_USER_GROUP_OBJECT_ID to the group's object ID; add jesse as a member of that group.
param avdUserGroupObjectId = readEnvironmentVariable('AVD_USER_GROUP_OBJECT_ID', '')
