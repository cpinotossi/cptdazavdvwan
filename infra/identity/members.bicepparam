using './members.bicep'

param prefix = readEnvironmentVariable('PREFIX', 'cptdazavdvwan')

// Dynamic membership — this list is the single source of truth.
// Add or remove an object ID and re-run the "Deploy Group Membership" action.
// Users not listed here are removed from the group ('replace' semantics).
param avdUserMemberObjectIds = [
  '555b5152-15b5-4f02-bd27-fa17fe0d123e' // jesse
  '7a4c09e1-dfff-4536-a2c1-f9545e8bdc50' // ga1
]

param chaosOperatorMemberObjectIds = [
  '555b5152-15b5-4f02-bd27-fa17fe0d123e' // jesse
]
