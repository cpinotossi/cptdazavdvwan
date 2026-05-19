using './main.bicep'

param location      = readEnvironmentVariable('LOCATION', 'swedencentral')
param prefix        = readEnvironmentVariable('PREFIX', 'cptdazavdvwan')
param adminUsername = readEnvironmentVariable('ADMIN_USERNAME', 'chpinoto')

// Secret from Key Vault
var subId  = readEnvironmentVariable('AZURE_SUBSCRIPTION_ID', '')
var kvRg   = readEnvironmentVariable('KV_RG', 'yourKVResourceGroup')
var kvName = readEnvironmentVariable('KV_NAME', 'yourKVName')

param adminPassword = az.getSecret(subId, kvRg, kvName, 'vm-admin-password')
