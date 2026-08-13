// =============================================================================
// Captain Azure Blob one-click sync (self-verifying).
//
// Stands up everything Captain needs to keep an Azure Blob container synced
// near-real-time, entirely inside the CUSTOMER'S Azure subscription:
//
//   1. EVENT WIRING: an Event Grid system topic on the storage account plus an
//      event subscription whose destination is Captain's HTTPS ingest webhook.
//      Blob -> Event Grid -> direct HTTPS webhook. Event Grid runs its 30-second
//      validation handshake against Captain's endpoint at subscription-create
//      time, so the subscription simply will NOT create unless Captain proves it
//      owns that endpoint. That is the first half of self-verification, and it
//      is native (no code).
//
//   2. CROSS-TENANT READ GRANT (no long-lived keys): a Storage Blob Data Reader
//      role assignment for Captain's service principal (the one that lives in
//      the customer's tenant after admin consent). Captain reads with a token
//      minted for its own identity. No SAS, no account key ever leaves the
//      account.
//
//   3. SELF-VERIFYING PHONE-HOME: a deployment script (the ARM equivalent of a
//      CloudFormation custom resource) that POSTs the enrollment facts to
//      Captain and FAILS the deployment unless Captain returns verified:true.
//      Captain verifies BOTH halves before it answers: the event subscription
//      is live (handshake passed) AND it can actually read the blobs (it mints a
//      token for its SP and does a probe list/read against the account). Only
//      then does the deployment go green.
//
// So a successful deployment ("CREATE_COMPLETE" equivalent) means Captain has
// confirmed, end to end, that it can both receive change events and read your
// objects. A misconfigured deploy fails visibly with a human-readable reason in
// the deployment-script logs, it does not silently green-light a dead sync.
//
// DESIGN NOTES
// - Reconcile / polling on Captain's side is the always-on backstop; the Event
//   Grid webhook is the latency optimization. If a webhook is ever missed,
//   reconcile still catches the change.
// - Customer-facing ids are Stripe-style prefix_token (dep_...). No bare UUIDs.
// - Template version is date-based (YYYY-MM-DD); bump it and re-host under a
//   matching dated path when the template shape changes.
// - ARM parameters cannot express regex constraints, so format rules live in the
//   @description text and the deployment-script preflight emits human-readable
//   errors. Captain pre-fills every Captain-owned parameter when it generates
//   your Deploy to Azure link, so malformed input is unlikely in practice.
// =============================================================================

targetScope = 'resourceGroup'

metadata captainTemplateVersion = '2026-08-12'

// ---------------------------------------------------------------------------
// Parameters. Everything tagged "Captain fills this in" is pre-filled by
// Captain per-sync when it generates your Deploy to Azure link.
// ---------------------------------------------------------------------------

@description('Template version (date-based YYYY-MM-DD). Sent to Captain on enroll so it knows which contract this deployment speaks. Do not change by hand.')
param templateVersion string = '2026-08-12'

@description('Azure region. MUST equal the region of the storage account you are syncing (an Event Grid storage system topic has to live in the same region as its account). Defaults to this resource group\'s region. Captain fills this in.')
param location string = resourceGroup().location

@description('Existing storage account to sync. Must already exist in THIS resource group. 3-24 chars, lowercase letters and numbers only. This template does not create it.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Optional: restrict the sync to a single blob container by name. Leave EMPTY to sync every container in the account. When set, Event Grid only notifies Captain about blobs under this container. 3-63 chars, lowercase.')
@maxLength(63)
param containerName string = ''

@description('Captain Event Grid ingest webhook (HTTPS). Event Grid delivers BlobCreated / BlobDeleted events here and runs its 30-second validation handshake against it at create time. Captain pre-fills this with a per-sync routing token. Must be https. Captain fills this in.')
param captainEventWebhookUrl string

@description('Captain enrollment endpoint (HTTPS) the phone-home deployment script POSTs the enrollment facts to. Captain verifies event delivery + read access and returns verified:true. Must be https. Captain fills this in.')
param captainEnrollUrl string = 'https://api.runcaptain.com/v1/deploy/azure/blob/enroll'

@description('Object id (GUID) of Captain\'s service principal AS IT EXISTS IN YOUR TENANT after you grant admin consent to the Captain enterprise application. The read role is assigned to this principal. Captain fills this in once consent is complete. This is a keyless, cross-tenant grant: Captain reads with a token for its own identity, never a key or SAS from your account.')
param captainPrincipalId string

@description('Captain\'s home Azure AD tenant id (GUID). Sent to Captain on enroll for its records; not used to grant access. Captain fills this in.')
param captainTenantId string = ''

@description('Captain sync id this deployment enrolls, form sync_<token>. Captain fills this in.')
param syncId string

@description('One-time enrollment secret minted by Captain for this sync. POSTed to the enroll endpoint so Captain can bind this deployment to your sync. Write-only (secure); never surfaced in outputs or logs. Captain fills this in.')
@secure()
param secret string

// ---------------------------------------------------------------------------
// Fixed values and derived names.
// ---------------------------------------------------------------------------

// Storage Blob Data Reader. Read + list on blob data, nothing else. This is the
// entire cross-tenant grant Captain gets.
var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

// Event Grid and role-assignment resource names cannot contain underscores, so
// derive a hyphenated slug from the sync id (sync_abc123 -> sync-abc123).
var syncSlug = replace(syncId, '_', '-')

var systemTopicName = 'captain-blob-${syncSlug}'
var eventSubscriptionName = 'captain-sub-${syncSlug}'
var enrollScriptName = 'captain-enroll-${syncSlug}'

// Event Grid Storage subjects look like:
//   /blobServices/default/containers/<container>/blobs/<path>
// so a container filter is a subjectBeginsWith prefix. Empty container = no
// filter = whole account.
var subjectPrefix = empty(containerName) ? '' : '/blobServices/default/containers/${containerName}/'

// ---------------------------------------------------------------------------
// Existing storage account. Referencing it by name makes the deployment FAIL
// early (before any Captain call) if the account name is wrong or not in this
// resource group. That is a free preflight check.
// ---------------------------------------------------------------------------
resource storage 'Microsoft.Storage/storageAccounts@2022-09-01' existing = {
  name: storageAccountName
}

// ===========================================================================
// 1. EVENT WIRING: Event Grid system topic + webhook event subscription
// ===========================================================================

resource systemTopic 'Microsoft.EventGrid/systemTopics@2022-06-15' = {
  name: systemTopicName
  // A storage system topic must live in the same region as the storage account,
  // which is why the location parameter must match the account's region.
  location: location
  properties: {
    source: storage.id
    topicType: 'Microsoft.Storage.StorageAccounts'
  }
  tags: {
    'captain:sync-id': syncId
    'captain:managed-by': 'bicep'
  }
}

// The webhook event subscription. When ARM creates this, Event Grid POSTs a
// Microsoft.EventGrid.SubscriptionValidationEvent to captainEventWebhookUrl and
// waits up to 30 seconds for Captain to echo back the validationCode. If Captain
// does not (wrong URL, endpoint down, endpoint not built), THIS RESOURCE FAILS
// and the whole deployment fails with a clear Event Grid error. That is the
// event-delivery half of verification, enforced natively.
resource eventSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2022-06-15' = {
  parent: systemTopic
  name: eventSubscriptionName
  properties: {
    destination: {
      endpointType: 'WebHook'
      properties: {
        // The webhook URL carries a per-sync routing token but is not the
        // enrollment secret; it is echoed in outputs for the customer's records,
        // so it is intentionally a plain (non-secure) parameter.
        #disable-next-line use-secure-value-for-secure-inputs
        endpointUrl: captainEventWebhookUrl
        // One event per POST keeps Captain's ingest handler simple; raise later
        // if throughput needs it.
        maxEventsPerBatch: 1
        preferredBatchSizeInKilobytes: 64
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.Storage.BlobCreated'
        'Microsoft.Storage.BlobDeleted'
      ]
      subjectBeginsWith: subjectPrefix
      enableAdvancedFilteringOnArrays: true
    }
    eventDeliverySchema: 'EventGridSchema'
    retryPolicy: {
      // Event Grid retries a missed delivery for a full day. Reconcile is still
      // the backstop if it exhausts retries.
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
}

// ===========================================================================
// 2. CROSS-TENANT READ GRANT (no long-lived keys)
// ===========================================================================

// Storage Blob Data Reader for Captain's service principal, scoped to exactly
// this one storage account. principalType is pinned to ServicePrincipal so the
// assignment does not fail while Azure AD replicates a just-consented principal.
resource readGrant 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, captainPrincipalId, storageBlobDataReaderRoleId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReaderRoleId)
    principalId: captainPrincipalId
    principalType: 'ServicePrincipal'
    description: 'Read-only blob access for Captain sync ${syncId}.'
  }
}

// ===========================================================================
// 3. SELF-VERIFYING PHONE-HOME (deployment script)
// ===========================================================================

// The ARM analog of a CloudFormation custom resource. Runs a container during
// deployment, POSTs the enrollment facts to Captain, and controls whether the
// deployment succeeds. It depends on the event subscription and the role grant,
// so by the time it runs, both are in place and Captain's read probe has a real
// role assignment to exercise.
//
// It needs no Azure credentials of its own (it only makes an outbound HTTPS call
// to Captain), so no managed identity is attached. The secret is passed as a
// secureValue and is never echoed.
resource enroll 'Microsoft.Resources/deploymentScripts@2020-10-01' = {
  name: enrollScriptName
  location: location
  kind: 'AzureCLI'
  // eventSubscription.name and readGrant.id are referenced in environmentVariables
  // below, so Bicep already orders this script after both. No explicit dependsOn
  // is needed (and adding one trips the no-unnecessary-dependson linter).
  properties: {
    azCliVersion: '2.60.0'
    retentionInterval: 'PT1H'
    timeout: 'PT30M'
    cleanupPreference: 'OnSuccess'
    environmentVariables: [
      { name: 'CAPTAIN_ENROLL_URL', value: captainEnrollUrl }
      { name: 'TEMPLATE_VERSION', value: templateVersion }
      { name: 'SYNC_ID', value: syncId }
      { name: 'SECRET', secureValue: secret }
      { name: 'SUBSCRIPTION_ID', value: subscription().subscriptionId }
      { name: 'TENANT_ID', value: tenant().tenantId }
      { name: 'CAPTAIN_TENANT_ID', value: captainTenantId }
      { name: 'RESOURCE_GROUP', value: resourceGroup().name }
      { name: 'STORAGE_ACCOUNT_ID', value: storage.id }
      { name: 'STORAGE_ACCOUNT_NAME', value: storageAccountName }
      { name: 'CONTAINER_NAME', value: containerName }
      { name: 'SYSTEM_TOPIC', value: systemTopic.name }
      { name: 'EVENT_SUBSCRIPTION', value: eventSubscription.name }
      { name: 'EVENT_WEBHOOK_URL', value: captainEventWebhookUrl }
      { name: 'PRINCIPAL_ID', value: captainPrincipalId }
      { name: 'ROLE_ASSIGNMENT_ID', value: readGrant.id }
      { name: 'LOCATION', value: location }
    ]
    scriptContent: '''
set -euo pipefail

echo "=================================================================="
echo " Captain Azure Blob enroll (self-verifying phone-home)"
echo "=================================================================="
echo "template_version : ${TEMPLATE_VERSION}"
echo "sync_id          : ${SYNC_ID}"
echo "subscription     : ${SUBSCRIPTION_ID}"
echo "resource_group   : ${RESOURCE_GROUP}"
echo "storage_account  : ${STORAGE_ACCOUNT_NAME}"
echo "container_filter : ${CONTAINER_NAME:-<all containers>}"
echo "system_topic     : ${SYSTEM_TOPIC}"
echo "event_sub        : ${EVENT_SUBSCRIPTION}"
echo "event_webhook    : ${EVENT_WEBHOOK_URL}"
echo "captain_principal: ${PRINCIPAL_ID}"
echo "role_assignment  : ${ROLE_ASSIGNMENT_ID}"
echo "enroll_url       : ${CAPTAIN_ENROLL_URL}"
echo "------------------------------------------------------------------"

# -- Preflight: never send the enrollment secret over plaintext -------------
case "${CAPTAIN_ENROLL_URL}" in
  https://*) echo "preflight: enroll URL is https, ok" ;;
  *) echo "PREFLIGHT FAILED: CAPTAIN_ENROLL_URL must be https:// (refusing to POST the enrollment secret in the clear). Got: ${CAPTAIN_ENROLL_URL}"; exit 1 ;;
esac
case "${EVENT_WEBHOOK_URL}" in
  https://*) echo "preflight: event webhook is https, ok" ;;
  *) echo "PREFLIGHT WARNING: EVENT_WEBHOOK_URL is not https (${EVENT_WEBHOOK_URL}). Event Grid requires https for the validation handshake; the event subscription step should already have failed if so." ;;
esac

# -- Stripe-style deployment id, no bare UUID --------------------------------
# python3 secrets.token_hex(12) writes exactly 24 hex chars and exits 0 on its
# own; no pipe into head, so there is nothing here for pipefail to trip over.
# python3 is already a hard dependency of this script (used below to build the
# JSON payload), so this adds no new tool. (A prior version piped /dev/urandom
# through tr into head -c 24: head closes the pipe once it has its 24 bytes,
# the upstream cat/tr get SIGPIPE, and set -euo pipefail aborted the whole
# script before it ever reached the phone-home POST below. openssl was
# considered as the replacement but is NOT present in the pinned
# mcr.microsoft.com/azure-cli:2.60.0 image (Alpine base, no openssl binary),
# so it was rejected in favor of python3. Audited: this is the only
# urandom/head pipeline in this script.)
TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
export DEP_ID="dep_${TOKEN}"
echo "deployment_id    : ${DEP_ID}"

# -- Build the payload with python3 (keeps the secret out of the arg list) ---
PAYLOAD=$(python3 - <<'PY'
import json, os
print(json.dumps({
    "deploymentId":        os.environ["DEP_ID"],
    "templateVersion":     os.environ.get("TEMPLATE_VERSION", ""),
    "action":              "create",
    "cloud":               "azure",
    "provider":            "blob",
    "subscriptionId":      os.environ.get("SUBSCRIPTION_ID", ""),
    "tenantId":            os.environ.get("TENANT_ID", ""),
    "captainTenantId":     os.environ.get("CAPTAIN_TENANT_ID", ""),
    "resourceGroup":       os.environ.get("RESOURCE_GROUP", ""),
    "storageAccountId":    os.environ.get("STORAGE_ACCOUNT_ID", ""),
    "storageAccountName":  os.environ.get("STORAGE_ACCOUNT_NAME", ""),
    "containerName":       os.environ.get("CONTAINER_NAME", ""),
    "systemTopic":         os.environ.get("SYSTEM_TOPIC", ""),
    "eventSubscription":   os.environ.get("EVENT_SUBSCRIPTION", ""),
    "eventWebhookUrl":     os.environ.get("EVENT_WEBHOOK_URL", ""),
    "captainPrincipalId":  os.environ.get("PRINCIPAL_ID", ""),
    "roleAssignmentId":    os.environ.get("ROLE_ASSIGNMENT_ID", ""),
    "location":            os.environ.get("LOCATION", ""),
    "syncId":              os.environ.get("SYNC_ID", ""),
    "secret":              os.environ.get("SECRET", ""),
}))
PY
)

echo "phone-home: POST ${CAPTAIN_ENROLL_URL} (payload omits secret from this log)"

# POST with python3's stdlib rather than curl. curl is NOT present in the
# pinned mcr.microsoft.com/azure-cli:2.60.0 image (it is Alpine-based and only
# ships wget), so a curl call here would fail "command not found" on every
# real run, get swallowed by a `|| echo "000"` fallback, and permanently
# masquerade as "Captain did not verify" even when Captain is healthy. That
# is the same class of bug as the token generator: the phone-home, the entire
# point of this artifact, silently never reaches Captain. python3 is already
# a hard dependency of this script (used above and below to build/parse
# JSON), so this adds no new tool.
HTTP_CODE=$(PAYLOAD="${PAYLOAD}" python3 - <<'PY'
import os
import urllib.error
import urllib.request

url = os.environ["CAPTAIN_ENROLL_URL"]
payload = os.environ["PAYLOAD"].encode("utf-8")
headers = {
    "content-type": "application/json",
    "user-agent": "captain-azure-enroll/" + os.environ.get("TEMPLATE_VERSION", ""),
}
req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
try:
    with urllib.request.urlopen(req, timeout=45) as resp:
        body, code = resp.read(), resp.getcode()
except urllib.error.HTTPError as e:
    body, code = e.read(), e.code
except Exception:
    body, code = b"", 0

with open("/tmp/captain_resp.json", "wb") as f:
    f.write(body)
print(code)
PY
)

echo "captain_http_status : ${HTTP_CODE}"
echo "captain_response    : $(head -c 800 /tmp/captain_resp.json 2>/dev/null || true)"
echo "------------------------------------------------------------------"

# -- Parse verified + status from Captain's response -------------------------
# `verified` is the ONLY success signal. `status` is display-only text and
# must never gate success on its own: a response like {"verified": true,
# "status": ""} is a real, plausible in-progress/edge shape from Captain, and
# `d.get('status', 'verified')` would wrongly return "" for it (the key IS
# present, just empty, so the dict default never kicks in). That used to make
# CAPTAIN_STATUS empty even though Captain said verified:true, which failed
# the deployment and printed a misleading "verified : false" right next to
# the raw response proving otherwise. Fixed by parsing verified and status as
# two independent fields: status falls back to 'verified' whenever it is
# either absent OR falsy/empty, but only verified decides success.
#
# `status` can ALSO come back as any other JSON type: a number, null, a bool,
# a list, or a nested object. Nothing in Captain's contract promises it is
# always a string. The naive `('1'|'0') + '|' + status` concat throws
# TypeError for any non-string, truthy status (a number, `true`, a non-empty
# list/object) because Python never implicitly stringifies on `+`. That
# TypeError used to be swallowed whole by a blanket `except Exception:
# print('0|')`, so a live Captain returning e.g. {"verified": true, "status":
# 200} silently came out as verified:false with zero indication why: same
# bytes on the wire as a genuine failure. Live-reproduced (see NOTES.md) and
# fixed by coercing `status` to a string for every JSON type BEFORE the
# concat, and by explicitly checking the top-level shape is an object at all
# rather than relying on the exception handler to catch it.
CAPTAIN_PARSED="$(python3 - <<'PY'
import json

def coerce_status(value):
    # Defensive coercion: status is documented as text, but nothing stops
    # Captain (or a proxy/WAF in front of it) from sending a number, null, a
    # bool, a list, or a nested object. Every JSON type becomes a readable
    # string here instead of crashing the '+' concat below.
    if value is None:
        return ''
    if isinstance(value, str):
        return value
    try:
        return json.dumps(value)
    except Exception:
        return str(value)

try:
    d = json.load(open('/tmp/captain_resp.json'))
except Exception:
    print('0|<unparseable response body>')
else:
    if not isinstance(d, dict):
        print('0|<unexpected response shape: top-level JSON is ' + type(d).__name__ + ', not an object>')
    else:
        verified = d.get('verified') is True
        raw_status = coerce_status(d.get('status'))
        status = (raw_status or 'verified') if verified else (raw_status or '')
        print(('1' if verified else '0') + '|' + status)
PY
)"
export CAPTAIN_VERIFIED="${CAPTAIN_PARSED%%|*}"
export CAPTAIN_STATUS="${CAPTAIN_PARSED#*|}"

if [ "${HTTP_CODE}" -ge 200 ] && [ "${HTTP_CODE}" -lt 300 ] && [ "${CAPTAIN_VERIFIED}" = "1" ]; then
  echo "SUCCESS: Captain verified enrollment (event delivery handshake + read-access probe both passed)."
  python3 - <<'PY'
import json, os
json.dump({
    "deploymentId": os.environ["DEP_ID"],
    "captainStatus": os.environ.get("CAPTAIN_STATUS", "verified"),
    "syncId": os.environ.get("SYNC_ID", ""),
}, open(os.environ["AZ_SCRIPTS_OUTPUT_PATH"], "w"))
PY
  echo "deployment_id=${DEP_ID}"
  echo "=================================================================="
else
  echo "=================================================================="
  echo " ENROLLMENT NOT CONFIRMED BY CAPTAIN. Deployment is failing on"
  echo " purpose so you see this now, not three days later on a dead sync."
  echo "------------------------------------------------------------------"
  echo " http_status : ${HTTP_CODE}"
  echo " verified    : $( [ "${CAPTAIN_VERIFIED}" = "1" ] && echo true || echo false )"
  echo " status      : ${CAPTAIN_STATUS:-<none>}"
  echo " response    : $(head -c 800 /tmp/captain_resp.json 2>/dev/null || true)"
  echo "------------------------------------------------------------------"
  echo " Common causes:"
  echo "  - captainPrincipalId is wrong or admin consent for the Captain app"
  echo "    was never granted -> Captain's read probe cannot get a token."
  echo "  - role assignment has not propagated yet (Azure AD can take a few"
  echo "    minutes) -> Captain retries the probe; re-run if it timed out."
  echo "  - enroll URL or secret does not match this sync -> HTTP 401/403/404."
  echo "  - Event Grid RP not registered / webhook handshake failed earlier."
  echo " See azure/README.md 'Debugging a failed deploy' for the full list."
  echo "=================================================================="
  exit 1
fi
'''
  }
}

// ---------------------------------------------------------------------------
// Outputs: tell the user exactly what happened and what to do next.
// ---------------------------------------------------------------------------

@description('Stripe-style deployment id (dep_<token>) generated during the phone-home. Use it to look up deployment state and debug in Captain.')
output deploymentId string = enroll.properties.outputs.deploymentId

@description('Captain-reported enrollment status for this deployment.')
output captainStatus string = enroll.properties.outputs.captainStatus

@description('Resource id of the cross-tenant read role assignment Captain uses.')
output readRoleAssignmentId string = readGrant.id

@description('Event Grid system topic created on the storage account.')
output systemTopicName string = systemTopic.name

@description('Event Grid webhook event subscription that delivers change events to Captain.')
output eventSubscriptionName string = eventSubscription.name

@description('One-line next step.')
output whatToDoNext string = 'Deployment ${enroll.properties.outputs.deploymentId} is enrolled and verified. Open your Captain dashboard for sync ${syncId}: a targeted reconcile of ${storageAccountName} runs automatically and future blob changes sync near-real-time.'
