using './main.bicep'

param prefix   = readEnvironmentVariable('PREFIX', 'cptdazavdvwan')
param location = readEnvironmentVariable('LOCATION', 'swedencentral')

// How long the CPU pressure is applied once the experiment runs.
param experimentDuration = 'PT10M'

// Target CPU utilization percentage (1-99).
param cpuPressureLevel = 95
