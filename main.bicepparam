using './main.bicep'

param location      = readEnvironmentVariable('LOCATION', 'swedencentral')
param prefix        = readEnvironmentVariable('PREFIX', 'cptdazavdvwan')
param adminUsername = readEnvironmentVariable('ADMIN_USERNAME', 'chpinoto')

// Secret from Key Vault
var subId  = readEnvironmentVariable('AZURE_SUBSCRIPTION_ID', 'ff0bb075-6c44-44ee-bb64-d46ce828c62f')
var kvRg   = readEnvironmentVariable('KV_RG', 'rg-cptdazavdvwan')
var kvName = readEnvironmentVariable('KV_NAME', 'cptdazavdvwan')

param adminPassword = az.getSecret(subId, kvRg, kvName, 'vm-admin-password')
