using './main.bicep'

param prefix   = readEnvironmentVariable('PREFIX', 'cptdazavdvwan')
param location = readEnvironmentVariable('LOCATION', 'swedencentral')

// How long the CPU pressure is applied once the experiment runs.
param experimentDuration = 'PT10M'

// Target CPU utilization percentage (1-99).
param cpuPressureLevel = 95

// Entra security group (e.g. grp-avd-chaos) allowed to start/stop the Chaos experiment.
// Set CHAOS_OPERATOR_GROUP_OBJECT_ID to the group's object ID; add operators as members.
param chaosOperatorGroupObjectId = readEnvironmentVariable('CHAOS_OPERATOR_GROUP_OBJECT_ID', '')
