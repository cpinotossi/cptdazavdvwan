using './main.bicep'

param prefix   = readEnvironmentVariable('PREFIX', 'cptdazavdvwan')
param location = readEnvironmentVariable('LOCATION', 'swedencentral')

// How long the AVD session host stays down once the experiment runs.
param experimentDuration = 'PT10M'

// false = graceful guest OS shutdown, true = hard power-off.
param abruptShutdown = false
