#!/usr/bin/env bash
# Idempotent Entra app registration for Compliant Calendar via `az rest` (Graph).
# Equivalent of main.tf, for when you'd rather not hold Terraform state for a spike.
# Requires: az login as an account with Application.ReadWrite.All + DelegatedPermissionGrant.ReadWrite.All.
# usage: register.sh <test-user-upn>
#   Consent is granted for that one user only (consentType=Principal), not tenant-wide.
set -euo pipefail
TEST_UPN="${1:?usage: register.sh <test-user-upn>}"
NAME="${APP_NAME:-niivo mail}"
BUNDLE_ID="${BUNDLE_ID:-ch.rdbartram.niivooffice}"   # must match scripts/bundle.sh BUNDLE_ID (msauth redirect)
G=https://graph.microsoft.com/v1.0
GRAPH=00000003-0000-0000-c000-000000000000
RMS=00000012-0000-0000-c000-000000000000
MIPSYNC=870c4f2e-85b6-4d43-bdda-6ed9a579b725
GRAPH_SCOPES="User.Read Calendars.ReadWrite.Shared InformationProtectionPolicy.Read Mail.ReadWrite Mail.ReadWrite.Shared Mail.Send Mail.Send.Shared MailboxSettings.ReadWrite offline_access"

sp_id()     { az rest -m GET -u "$G/servicePrincipals?\$filter=appId eq '$1'&\$select=id" --query 'value[0].id' -o tsv; }
scope_id()  { az rest -m GET -u "$G/servicePrincipals?\$filter=appId eq '$1'&\$select=oauth2PermissionScopes" \
                --query "value[0].oauth2PermissionScopes[?value=='$2'].id | [0]" -o tsv; }

graph_access=""
for s in $GRAPH_SCOPES; do graph_access+="{\"id\":\"$(scope_id $GRAPH "$s")\",\"type\":\"Scope\"},"; done
body=$(cat <<JSON
{
  "displayName": "$NAME",
  "signInAudience": "AzureADandPersonalMicrosoftAccount",
  "api": { "requestedAccessTokenVersion": 2 },
  "notes": "Native macOS calendar spike (this repository). Delegated only, no secrets.",
  "isFallbackPublicClient": true,
  "publicClient": { "redirectUris": ["msauth.$BUNDLE_ID://auth", "http://localhost"] },
  "requiredResourceAccess": [
    { "resourceAppId": "$GRAPH",   "resourceAccess": [${graph_access%,}] },
    { "resourceAppId": "$RMS",     "resourceAccess": [{"id":"$(scope_id $RMS user_impersonation)","type":"Scope"}] },
    { "resourceAppId": "$MIPSYNC", "resourceAccess": [{"id":"$(scope_id $MIPSYNC UnifiedPolicy.User.Read)","type":"Scope"}] }
  ]
}
JSON
)

app_obj=$(az rest -m GET -u "$G/applications?\$filter=displayName eq '$NAME'&\$select=id" --query 'value[0].id' -o tsv)
if [[ -z "$app_obj" ]]; then
  app_obj=$(az rest -m POST -u "$G/applications" --headers Content-Type=application/json -b "$body" --query id -o tsv)
  echo "created application $app_obj"
else
  az rest -m PATCH -u "$G/applications/$app_obj" --headers Content-Type=application/json -b "$body" >/dev/null
  echo "updated application $app_obj"
fi
client_id=$(az rest -m GET -u "$G/applications/$app_obj?\$select=appId" --query appId -o tsv)

sp=$(sp_id "$client_id")
if [[ -z "$sp" ]]; then
  sp=$(az rest -m POST -u "$G/servicePrincipals" --headers Content-Type=application/json \
        -b "{\"appId\":\"$client_id\"}" --query id -o tsv)
  echo "created service principal $sp"
fi

user=$(az rest -m GET -u "$G/users/$TEST_UPN?\$select=id" --query id -o tsv)
grant() { # resourceAppId, space-separated scopes
  local res; res=$(sp_id "$1")
  local existing; existing=$(az rest -m GET -u "$G/oauth2PermissionGrants?\$filter=clientId eq '$sp' and resourceId eq '$res' and principalId eq '$user'" --query 'value[0].id' -o tsv)
  if [[ -z "$existing" ]]; then
    az rest -m POST -u "$G/oauth2PermissionGrants" --headers Content-Type=application/json \
      -b "{\"clientId\":\"$sp\",\"consentType\":\"Principal\",\"principalId\":\"$user\",\"resourceId\":\"$res\",\"scope\":\"$2\"}" >/dev/null
    echo "granted [$2] on $1 for test user"
  else
    az rest -m PATCH -u "$G/oauth2PermissionGrants/$existing" --headers Content-Type=application/json -b "{\"scope\":\"$2\"}" >/dev/null
    echo "refreshed grant [$2] on $1"
  fi
}
grant $GRAPH "$GRAPH_SCOPES offline_access openid profile"
grant $RMS "user_impersonation"
grant $MIPSYNC "UnifiedPolicy.User.Read"

tenant=$(az account show --query tenantId -o tsv)
echo "CLIENT_ID=$client_id"
echo "TENANT_ID=$tenant"
