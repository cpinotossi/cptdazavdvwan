using './main.bicep'

param location      = readEnvironmentVariable('LOCATION', 'swedencentral')
param prefix        = readEnvironmentVariable('PREFIX', 'cptdazavdvwan')
param adminUsername = readEnvironmentVariable('ADMIN_USERNAME', 'chpinoto')

// VMs are not reachable from the public internet (no public IP, access via Bastion only).
// Password kept in cleartext here by deliberate decision.
param adminPassword = 'demo!pass123'
