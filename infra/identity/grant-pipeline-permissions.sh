#!/usr/bin/env bash
# One-time bootstrap: grant the GitHub Actions service principal the permissions
# the AVD/Chaos/membership pipelines need.
#
# WHO RUNS THIS: a tenant admin (Privileged Role Administrator / Global Admin for
# the Graph app-role consent, plus Owner or User Access Administrator on the
# subscription for the Azure RBAC grant). The pipeline CANNOT grant itself these
# rights (chicken-and-egg), so this is run once, out-of-band.
#
# WHY:
#   - Graph 'Group.ReadWrite.All' (application) -> create/lookup Entra groups
#     (deploy.yml identity step, members.yml, chaos.yml group lookup).
#   - Graph 'Device.ReadWrite.All' (application) -> delete stale Entra device
#     registrations (vmavd01/vmsp01) in the teardown.yml cleanup step so the
#     next restore's AADLoginForWindows join does not hit 0x801c0083.
#   - Azure RBAC 'User Access Administrator' -> Microsoft.Authorization/
#     roleAssignments/write for the RBAC role assignments in main.bicep /
#     chaos/main.bicep. (Skip if the SP is already Owner.)
#
# Usage:
#   APP_ID=<AZURE_CLIENT_ID value> SUBSCRIPTION_ID=<sub> PREFIX=cptdazavdvwan \
#     ./infra/identity/grant-pipeline-permissions.sh
set -euo pipefail

APP_ID="${APP_ID:?Set APP_ID to the pipeline app (the value behind GitHub secret AZURE_CLIENT_ID)}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:?Set SUBSCRIPTION_ID}"
PREFIX="${PREFIX:-cptdazavdvwan}"
RG="rg-${PREFIX}"

GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"          # Microsoft Graph
GROUP_RW_ALL_ROLE_ID="62a82d76-70ea-41e2-9197-370581804d09"  # Group.ReadWrite.All (application)
DEVICE_RW_ALL_ROLE_ID="1138cb37-bd11-4084-a2b7-9f71582aeddb" # Device.ReadWrite.All (application)

echo "=== Resolve service principal object IDs ==="
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
GRAPH_SP_OBJECT_ID=$(az ad sp show --id "$GRAPH_APP_ID" --query id -o tsv)
echo "Pipeline SP : $SP_OBJECT_ID"
echo "Graph SP    : $GRAPH_SP_OBJECT_ID"

echo "=== Grant Microsoft Graph Group.ReadWrite.All (application) + admin consent ==="
EXISTING=$(az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_OBJECT_ID}/appRoleAssignments" \
  --query "value[?appRoleId=='${GROUP_RW_ALL_ROLE_ID}'] | [0].id" -o tsv 2>/dev/null || true)

if [ -n "$EXISTING" ]; then
  echo "Already granted (assignment ${EXISTING}); skipping."
else
  az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_OBJECT_ID}/appRoleAssignments" \
    --headers "Content-Type=application/json" \
    --body "{\"principalId\":\"${SP_OBJECT_ID}\",\"resourceId\":\"${GRAPH_SP_OBJECT_ID}\",\"appRoleId\":\"${GROUP_RW_ALL_ROLE_ID}\"}"
  echo "Granted Group.ReadWrite.All."
fi

echo "=== Grant Microsoft Graph Device.ReadWrite.All (application) + admin consent ==="
EXISTING_DEVICE=$(az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_OBJECT_ID}/appRoleAssignments" \
  --query "value[?appRoleId=='${DEVICE_RW_ALL_ROLE_ID}'] | [0].id" -o tsv 2>/dev/null || true)

if [ -n "$EXISTING_DEVICE" ]; then
  echo "Already granted (assignment ${EXISTING_DEVICE}); skipping."
else
  az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_OBJECT_ID}/appRoleAssignments" \
    --headers "Content-Type=application/json" \
    --body "{\"principalId\":\"${SP_OBJECT_ID}\",\"resourceId\":\"${GRAPH_SP_OBJECT_ID}\",\"appRoleId\":\"${DEVICE_RW_ALL_ROLE_ID}\"}"
  echo "Granted Device.ReadWrite.All."
fi

echo "=== Grant Azure RBAC 'User Access Administrator' on ${RG} ==="
echo "(Skip this block if the SP is already Owner on the subscription/RG.)"
az role assignment create \
  --assignee "$APP_ID" \
  --role "User Access Administrator" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}" \
  --only-show-errors || echo "::note:: role assignment may already exist."

echo "=== Done. Allow a minute for Graph consent to propagate before the first run. ==="
