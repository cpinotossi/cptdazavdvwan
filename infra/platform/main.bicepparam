using './main.bicep'

param location = readEnvironmentVariable('LOCATION', 'swedencentral')
param prefix   = readEnvironmentVariable('PREFIX', 'cptdazavdvwan')
