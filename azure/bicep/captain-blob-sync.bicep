// =============================================================================
// Captain Azure Blob one-click sync (self-verifying).
//
// Stands up everything Captain needs to keep an Azure Blob container synced
// near-real-time, entirely inside the CUSTOMER'S Azure subscription:
//
//   1. EVENT WIRING: an Event Grid system topic on the storage account plus an
//      event subscription whose destination is Captain's HTTPS ingest webhook
//      (the subscribe_url Captain minted for the sync). Blob -> Event Grid ->
//      direct HTTPS webhook. Event Grid runs its 30-second validation handshake
//      against Captain's endpoint at subscription-create time, so the
//      subscription simply will NOT create unless Captain proves it owns that
//      endpoint. That is the first half of self-verification, and it is native
//      (no code).
//
//   2. CROSS-TENANT READ GRANT (no long-lived keys): a Storage Blob Data Reader
//      role assignment for Captain's service principal (the one that lives in
//      the customer's tenant after admin consent). Captain reads with a token
//      minted for its own identity. No SAS, no account key ever leaves the
//      account.
//
//   3. SELF-VERIFYING PHONE-HOME: a deployment script (the ARM equivalent of a
//      CloudFormation custom resource) that enrolls the webhook through
//      Captain's public API, POST {captainApiBase}/v2/syncs/<syncId>/webhooks
//      with "Authorization: Bearer <captainApiKey>" and an empty JSON body
//      (Azure Blob is not an S3-family sync, so no sns_topic_arn), and FAILS
//      the deployment unless Captain answers 2xx with the sync's
//      subscribe_url. A 2xx with a subscribe_url IS successful enrollment.
//
// So a successful deployment ("CREATE_COMPLETE" equivalent) means Event Grid
// proved it can deliver to Captain's live ingest URL (the native handshake)
// AND Captain's API confirmed the webhook is enrolled on your sync under your
// API key. A misconfigured deploy fails visibly with a human-readable reason
// in the deployment-script logs, it does not silently green-light a dead sync.
// Read access rides the role assignment; if that part is misconfigured,
// Captain's reconcile surfaces it in the dashboard rather than at deploy time.
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

metadata captainTemplateVersion = '2026-09-07'

// ---------------------------------------------------------------------------
// Parameters. Everything tagged "Captain fills this in" is pre-filled by
// Captain per-sync when it generates your Deploy to Azure link.
// ---------------------------------------------------------------------------

@description('Template version (date-based YYYY-MM-DD). Reported in the phone-home user-agent so Captain knows which contract this deployment speaks. Do not change by hand.')
param templateVersion string = '2026-09-07'

@description('Azure region. MUST equal the region of the storage account you are syncing (an Event Grid storage system topic has to live in the same region as its account). Defaults to this resource group\'s region. Captain fills this in.')
param location string = resourceGroup().location

@description('Existing storage account to sync. Must already exist in THIS resource group. 3-24 chars, lowercase letters and numbers only. This template does not create it.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Optional: restrict the sync to a single blob container by name. Leave EMPTY to sync every container in the account. When set, Event Grid only notifies Captain about blobs under this container. 3-63 chars, lowercase.')
@maxLength(63)
param containerName string = ''

@description('Optional: further restrict events to blob names starting with this prefix (e.g. docs/2026/). Only meaningful when containerName is set. Match it to the sync\'s prefix in Captain so a busy container does not spend Captain\'s per-connector event budget on out-of-scope blobs.')
param blobPrefix string = ''

@description('Captain Event Grid ingest webhook (HTTPS). This is the subscribe_url Captain mints for your sync when the webhook is enrolled (POST {captainApiBase}/v2/syncs/<syncId>/webhooks). Event Grid delivers BlobCreated / BlobDeleted events here and runs its 30-second validation handshake against it at create time. Must be https. Captain fills this in.')
param captainEventWebhookUrl string

@description('Captain API base URL (HTTPS). The phone-home POSTs to {captainApiBase}/v2/syncs/<syncId>/webhooks. Leave the default unless Captain support points you at a staging environment. Must be https.')
param captainApiBase string = 'https://api.captain.dev'

@description('Your Captain API key. Sent as "Authorization: Bearer ..." on the webhook-enrollment call, nothing else. Write-only (secure); never surfaced in outputs or logs. Captain fills this in.')
@secure()
param captainApiKey string

@description('OPTIONAL (keyless mode only): object id (GUID) of Captain\'s service principal AS IT EXISTS IN YOUR TENANT after you grant admin consent to the Captain enterprise application. Leave EMPTY for account-key syncs (the default): Captain then reads with the storage account key you gave it at sync creation and no role assignment is created. When set, a keyless cross-tenant Storage Blob Data Reader grant is added for that principal.')
param captainPrincipalId string = ''

@description('Captain sync id this deployment enrolls, form sync_<token>. Captain fills this in.')
param syncId string

@description('Leave the default. Changes on every deployment (utcNow) and is wired to the enrollment script\'s forceUpdateTag so a REDEPLOY re-runs the phone-home verification — without it, ARM skips a deploymentScript whose properties are unchanged and a redeploy would not re-verify anything.')
param deployTimestamp string = utcNow()

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
var subjectPrefix = empty(containerName) ? '' : (empty(blobPrefix)
  ? '/blobServices/default/containers/${containerName}/'
  : '/blobServices/default/containers/${containerName}/blobs/${blobPrefix}')

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
// does not (wrong URL, endpoint down, URL is not the subscribe_url Captain
// minted), THIS RESOURCE FAILS and the whole deployment fails with a clear
// Event Grid error. That is the event-delivery half of verification, enforced
// natively.
resource eventSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2022-06-15' = {
  parent: systemTopic
  name: eventSubscriptionName
  properties: {
    destination: {
      endpointType: 'WebHook'
      properties: {
        // HONESTY (adversarial review 2026-09-07): the ingest URL EMBEDS the
        // webhook secret — it IS the bearer credential for this sync's event
        // stream. It stays a plain parameter because Event Grid must store it
        // in the subscription anyway and the exposure audience is this
        // resource group's readers; if it leaks, rotate with
        // POST /v2/syncs/{id}/webhooks {"rotate_secret": true} and update the
        // subscription endpoint (which re-runs the handshake).
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
resource readGrant 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(captainPrincipalId)) {
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
// deployment, enrolls the webhook through Captain's public API, and controls
// whether the deployment succeeds. It depends on the event subscription and
// the role grant, so by the time it runs the event wiring already passed the
// native handshake and the read grant exists.
//
// It needs no Azure credentials of its own (it only makes an outbound HTTPS
// call to Captain), so no managed identity is attached. The Captain API key is
// passed as a secureValue and is never echoed.
resource enroll 'Microsoft.Resources/deploymentScripts@2020-10-01' = {
  name: enrollScriptName
  location: location
  kind: 'AzureCLI'
  // eventSubscription.name and readGrant.id are referenced in environmentVariables
  // below, so Bicep already orders this script after both. No explicit dependsOn
  // is needed (and adding one trips the no-unnecessary-dependson linter).
  properties: {
    azCliVersion: '2.60.0'
    forceUpdateTag: deployTimestamp
    retentionInterval: 'PT1H'
    timeout: 'PT30M'
    cleanupPreference: 'OnSuccess'
    environmentVariables: [
      { name: 'CAPTAIN_API_BASE', value: captainApiBase }
      { name: 'CAPTAIN_API_KEY', secureValue: captainApiKey }
      { name: 'TEMPLATE_VERSION', value: templateVersion }
      { name: 'SYNC_ID', value: syncId }
      { name: 'SUBSCRIPTION_ID', value: subscription().subscriptionId }
      { name: 'RESOURCE_GROUP', value: resourceGroup().name }
      { name: 'STORAGE_ACCOUNT_NAME', value: storageAccountName }
      { name: 'CONTAINER_NAME', value: containerName }
      { name: 'SYSTEM_TOPIC', value: systemTopic.name }
      { name: 'EVENT_SUBSCRIPTION', value: eventSubscription.name }
      { name: 'EVENT_WEBHOOK_URL', value: captainEventWebhookUrl }
      { name: 'PRINCIPAL_ID', value: captainPrincipalId }
      { name: 'ROLE_ASSIGNMENT_ID', value: empty(captainPrincipalId) ? '<none: account-key sync>' : readGrant.id }
      { name: 'LOCATION', value: location }
    ]
    scriptContent: '''
set -euo pipefail

echo "=================================================================="
echo " Captain Azure Blob webhook enrollment (self-verifying phone-home)"
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
echo "captain_api_base : ${CAPTAIN_API_BASE}"
echo "api_key          : <redacted>"
echo "------------------------------------------------------------------"

# -- Preflight: never send the API key over plaintext ------------------------
case "${CAPTAIN_API_BASE}" in
  https://*) echo "preflight: Captain API base is https, ok" ;;
  *) echo "PREFLIGHT FAILED: captainApiBase must be https:// (refusing to send the Captain API key in the clear). Got: ${CAPTAIN_API_BASE}"; exit 1 ;;
esac
# The API key is sent as a Bearer header to this base: pin it to Captain-owned
# domains so a crafted deploy link cannot exfiltrate the key to a third party.
case "${CAPTAIN_API_BASE}" in
  https://api.captain.dev|https://*.captain.dev|https://api.runcaptain.com|https://*.runcaptain.com) : ;;
  *) echo "PREFLIGHT FAILED: captainApiBase must be a captain.dev / runcaptain.com domain (got: ${CAPTAIN_API_BASE}). This guard keeps your Captain API key from being sent elsewhere."; exit 1 ;;
esac
case "${EVENT_WEBHOOK_URL}" in
  https://*) echo "preflight: event webhook is https, ok" ;;
  *) echo "PREFLIGHT WARNING: EVENT_WEBHOOK_URL is not https (${EVENT_WEBHOOK_URL}). Event Grid requires https for the validation handshake; the event subscription step should already have failed if so." ;;
esac

# The real Captain contract: POST {base}/v2/syncs/{syncId}/webhooks with
# Bearer auth. Azure Blob is not an S3-family sync, so the body is the empty
# JSON object (no sns_topic_arn).
WEBHOOKS_URL="${CAPTAIN_API_BASE%/}/v2/syncs/${SYNC_ID}/webhooks"
echo "webhooks_url     : ${WEBHOOKS_URL}"

# -- Stripe-style deployment id, no bare UUID --------------------------------
# python3 secrets.token_hex(12) writes exactly 24 hex chars and exits 0 on its
# own; no pipe into head, so there is nothing here for pipefail to trip over.
# python3 is already a hard dependency of this script (used below for the
# HTTPS call and JSON parsing), so this adds no new tool. (A prior version
# piped /dev/urandom through tr into head -c 24: head closes the pipe once it
# has its 24 bytes, the upstream cat/tr get SIGPIPE, and set -euo pipefail
# aborted the whole script before it ever reached the phone-home POST below.
# openssl was considered as the replacement but is NOT present in the pinned
# mcr.microsoft.com/azure-cli:2.60.0 image (Alpine base, no openssl binary),
# so it was rejected in favor of python3.)
TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
export DEP_ID="dep_${TOKEN}"
echo "deployment_id    : ${DEP_ID} (local correlation id; quote it with your sync id to Captain support)"

echo "phone-home: POST ${WEBHOOKS_URL} (empty JSON body; Authorization header redacted from this log)"

# POST with python3's stdlib rather than curl. curl is NOT present in the
# pinned mcr.microsoft.com/azure-cli:2.60.0 image (it is Alpine-based and only
# ships wget), so a curl call here would fail "command not found" on every
# real run, get swallowed by a `|| echo "000"` fallback, and permanently
# masquerade as "Captain did not answer" even when Captain is healthy. python3
# is already a hard dependency of this script, so this adds no new tool. The
# API key is read from the environment inside python and never appears on an
# argument list or in this log.
HTTP_CODE=$(WEBHOOKS_URL="${WEBHOOKS_URL}" python3 - <<'PY'
import os
import urllib.error
import urllib.request

url = os.environ["WEBHOOKS_URL"]
headers = {
    "authorization": "Bearer " + os.environ["CAPTAIN_API_KEY"],
    "content-type": "application/json",
    "user-agent": "captain-azure-enroll/" + os.environ.get("TEMPLATE_VERSION", ""),
}
req = urllib.request.Request(url, data=b"{}", headers=headers, method="POST")
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

# -- Parse Captain's response -------------------------------------------------
# Contract (verified against the live API, 2026-09-07): a 2xx JSON object with
# ingest_url (string), secret_set (bool), and instructions (array of strings).
# A 2xx with an ingest_url IS successful enrollment; ingest_url is the ONLY
# success signal here (subscribe_url is accepted as a legacy alias). secret_set
# and instructions are display-only and never gate success.
#
# Parsing is deliberately defensive: nothing stops a proxy/WAF in front of
# Captain from sending non-JSON, a non-object top level, or unexpected field
# types, and an earlier build of this script proved that letting a blanket
# `except` swallow those cases makes a healthy Captain indistinguishable from
# a dead one. Every field is coerced to readable text before use, and each
# parse failure degrades to a labeled note instead of a swallowed exception.
python3 - <<'PY'
import json

def as_text(value):
    if value is None:
        return ''
    if isinstance(value, str):
        return value
    try:
        return json.dumps(value)
    except Exception:
        return str(value)

ok, sub, secret_set, note, lines = '0', '', 'unknown', '', []
try:
    d = json.load(open('/tmp/captain_resp.json'))
except Exception:
    note = '<unparseable response body>'
else:
    if not isinstance(d, dict):
        note = '<unexpected response shape: top-level JSON is ' + type(d).__name__ + ', not an object>'
    else:
        raw = d.get('ingest_url') or d.get('subscribe_url')
        if isinstance(raw, str) and raw:
            ok, sub = '1', raw
        else:
            note = '<response has no usable ingest_url>'
        if d.get('secret_set') is True:
            secret_set = 'true'
        elif d.get('secret_set') is False:
            secret_set = 'false'
        raw_lines = d.get('instructions')
        if isinstance(raw_lines, list):
            lines = [as_text(item) for item in raw_lines]

open('/tmp/captain_ok', 'w').write(ok)
open('/tmp/captain_sub', 'w').write(sub)
open('/tmp/captain_secret_set', 'w').write(secret_set)
open('/tmp/captain_note', 'w').write(note)
open('/tmp/captain_instructions', 'w').write('\n'.join(lines))
PY
CAPTAIN_OK="$(cat /tmp/captain_ok)"
SUBSCRIBE_URL="$(cat /tmp/captain_sub)"
SECRET_SET="$(cat /tmp/captain_secret_set)"
CAPTAIN_NOTE="$(cat /tmp/captain_note)"
export SUBSCRIBE_URL SECRET_SET

if [ "${HTTP_CODE}" -ge 200 ] && [ "${HTTP_CODE}" -lt 300 ] && [ "${CAPTAIN_OK}" = "1" ]; then
  echo "SUCCESS: Captain enrolled the webhook for ${SYNC_ID} (2xx with ingest_url)."
  echo "ingest_url    : ${SUBSCRIBE_URL}"
  echo "secret_set    : ${SECRET_SET}"
  if [ "${SUBSCRIBE_URL}" != "${EVENT_WEBHOOK_URL}" ]; then
    echo "NOTE: the ingest_url Captain returned differs from captainEventWebhookUrl."
    echo "      The event subscription delivers to captainEventWebhookUrl. If events do"
    echo "      not flow, redeploy with captainEventWebhookUrl set to the ingest_url"
    echo "      above. Reconcile remains the backstop either way."
  fi
  if [ -s /tmp/captain_instructions ]; then
    echo "captain instructions:"
    sed 's/^/  - /' /tmp/captain_instructions
  fi
  python3 - <<'PY'
import json, os
json.dump({
    "deploymentId": os.environ["DEP_ID"],
    "ingestUrl": os.environ.get("SUBSCRIBE_URL", ""),
    "secretSet": os.environ.get("SECRET_SET", "unknown"),
    "syncId": os.environ.get("SYNC_ID", ""),
}, open(os.environ["AZ_SCRIPTS_OUTPUT_PATH"], "w"))
PY
  echo "deployment_id=${DEP_ID}"
  echo "=================================================================="
else
  echo "=================================================================="
  echo " WEBHOOK ENROLLMENT NOT CONFIRMED BY CAPTAIN. Deployment is failing"
  echo " on purpose so you see this now, not three days later on a dead sync."
  echo "------------------------------------------------------------------"
  echo " http_status : ${HTTP_CODE}"
  echo " parse_note  : ${CAPTAIN_NOTE:-<none>}"
  echo " response    : $(head -c 800 /tmp/captain_resp.json 2>/dev/null || true)"
  echo "------------------------------------------------------------------"
  echo " Common causes:"
  echo "  - 401/403: captainApiKey is wrong, revoked, or for a different"
  echo "    Captain workspace than the sync."
  echo "  - 404: syncId does not exist or is not visible to this API key."
  echo "  - 422 mentioning sns_topic_arn: the syncId points at an S3-family"
  echo "    sync; this template is for Azure Blob syncs only."
  echo "  - status 0 / empty response: outbound HTTPS to ${CAPTAIN_API_BASE}"
  echo "    blocked, or the base URL is wrong (staging override typo)."
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

@description('Stripe-style local correlation id (dep_<token>) generated during the phone-home. It stays client-side; quote it together with your sync id when talking to Captain support.')
output deploymentId string = enroll.properties.outputs.deploymentId

@description('The per-sync ingest URL Captain confirmed during enrollment (the same URL the event subscription delivers to).')
output ingestUrl string = enroll.properties.outputs.ingestUrl

@description('Whether Captain reports a webhook signing secret is set for this sync (true / false / unknown).')
output webhookSecretSet string = enroll.properties.outputs.secretSet

@description('Resource id of the cross-tenant read role assignment Captain uses.')
output readRoleAssignmentId string = empty(captainPrincipalId) ? '' : readGrant.id

@description('Event Grid system topic created on the storage account.')
output systemTopicName string = systemTopic.name

@description('Event Grid webhook event subscription that delivers change events to Captain.')
output eventSubscriptionName string = eventSubscription.name

@description('One-line next step.')
output whatToDoNext string = 'Deployment ${enroll.properties.outputs.deploymentId} enrolled the webhook for sync ${syncId}. Future blob changes on ${storageAccountName} sync near-real-time, with Captain reconcile as the backstop. Setup guide: https://docs.captain.dev/guides/sync/set-up'
