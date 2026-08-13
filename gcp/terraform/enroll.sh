#!/usr/bin/env bash
# =============================================================================
# Captain GCS phone-home. POSTs enrollment facts to Captain and makes the deploy
# SELF-VERIFYING: on create it exits non-zero unless Captain returns a verified
# response, which fails `terraform apply` (or the gcloud setup.sh) with a clear
# reason. On delete it is best-effort and never blocks a teardown.
#
# Invoked two ways:
#   - Terraform:  local-exec interpreter runs this file, argv[1] = create|delete,
#                 all facts come from the environment (see main.tf).
#   - gcloud:     setup.sh / teardown.sh source-exec it the same way.
#
# Reads (env): CAPTAIN_ENROLL_URL ACTION DEPLOYMENT_ID TEMPLATE_VERSION SYNC_ID
#   EXTERNAL_ID PROJECT_ID BUCKET_NAME PUBSUB_TOPIC PUBSUB_SUBSCRIPTION
#   PUSH_SERVICE_ACCOUNT READER_SERVICE_ACCOUNT INGEST_URL OIDC_AUDIENCE
#   ENROLLMENT_SECRET
# Optional (env): CAPTAIN_ENROLL_RETRIES (default 4), CAPTAIN_DEBUG (default 1).
# =============================================================================
set -euo pipefail

# ---- logging -----------------------------------------------------------------
DEBUG="${CAPTAIN_DEBUG:-1}"
log()   { printf '[captain-enroll %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
debug() { [ "$DEBUG" = "1" ] && log "DEBUG $*" || true; }
die()   { log "ERROR $*"; exit 1; }

ACTION="${ACTION:-${1:-create}}"

# ---- preflight ---------------------------------------------------------------
command -v curl >/dev/null 2>&1 || die "curl not found on PATH. Install curl and re-run."
command -v jq   >/dev/null 2>&1 || die "jq not found on PATH. Install jq (brew install jq / apt-get install jq) and re-run."

: "${CAPTAIN_ENROLL_URL:?CAPTAIN_ENROLL_URL is required}"
case "$CAPTAIN_ENROLL_URL" in
  https://*) : ;;
  *) die "CAPTAIN_ENROLL_URL must be https:// (refusing to send the enrollment secret over plaintext). Got: $CAPTAIN_ENROLL_URL" ;;
esac

for v in DEPLOYMENT_ID SYNC_ID EXTERNAL_ID PROJECT_ID BUCKET_NAME PUBSUB_TOPIC \
         PUBSUB_SUBSCRIPTION PUSH_SERVICE_ACCOUNT READER_SERVICE_ACCOUNT \
         INGEST_URL ENROLLMENT_SECRET; do
  eval "val=\${$v:-}"
  [ -n "${val}" ] || die "$v is required but empty. Captain should have pre-filled it."
done

TEMPLATE_VERSION="${TEMPLATE_VERSION:-2026-08-12}"
OIDC_AUDIENCE="${OIDC_AUDIENCE:-$INGEST_URL}"
RETRIES="${CAPTAIN_ENROLL_RETRIES:-4}"

# ---- build the JSON payload with jq (safe escaping, secret never logged) -----
payload="$(jq -n \
  --arg deploymentId        "$DEPLOYMENT_ID" \
  --arg templateVersion     "$TEMPLATE_VERSION" \
  --arg action              "$ACTION" \
  --arg provider            "gcp" \
  --arg storage             "gcs" \
  --arg syncId              "$SYNC_ID" \
  --arg externalId          "$EXTERNAL_ID" \
  --arg projectId           "$PROJECT_ID" \
  --arg bucket              "$BUCKET_NAME" \
  --arg pubsubTopic         "$PUBSUB_TOPIC" \
  --arg pubsubSubscription  "$PUBSUB_SUBSCRIPTION" \
  --arg pushServiceAccount  "$PUSH_SERVICE_ACCOUNT" \
  --arg readerServiceAccount "$READER_SERVICE_ACCOUNT" \
  --arg ingestUrl           "$INGEST_URL" \
  --arg oidcAudience        "$OIDC_AUDIENCE" \
  --arg secret              "$ENROLLMENT_SECRET" \
  '{deploymentId:$deploymentId, templateVersion:$templateVersion, action:$action,
    provider:$provider, storage:$storage, syncId:$syncId, externalId:$externalId,
    projectId:$projectId, bucket:$bucket, pubsubTopic:$pubsubTopic,
    pubsubSubscription:$pubsubSubscription, pushServiceAccount:$pushServiceAccount,
    readerServiceAccount:$readerServiceAccount, ingestUrl:$ingestUrl,
    oidcAudience:$oidcAudience, secret:$secret}')"

# A copy of the payload with the secret redacted, for logs only.
redacted="$(printf '%s' "$payload" | jq '.secret = "***redacted***"')"
log "action=$ACTION deploymentId=$DEPLOYMENT_ID syncId=$SYNC_ID endpoint=$CAPTAIN_ENROLL_URL"
debug "payload=$(printf '%s' "$redacted" | tr -d '\n')"

# ---- POST with retry on transient network / 5xx errors -----------------------
attempt=0
body=""
code=""
while : ; do
  attempt=$((attempt + 1))
  resp="$(curl -sS -m 45 -w $'\n%{http_code}' \
      -X POST "$CAPTAIN_ENROLL_URL" \
      -H 'content-type: application/json' \
      -H "user-agent: captain-gcs-enroll/${TEMPLATE_VERSION}" \
      --data-binary "$payload" 2>/tmp/captain_enroll_curl_err || true)"
  code="$(printf '%s' "$resp" | tail -n1)"
  body="$(printf '%s' "$resp" | sed '$d')"

  if [ -z "$code" ] || [ "$code" = "000" ]; then
    err="$(cat /tmp/captain_enroll_curl_err 2>/dev/null || true)"
    log "network error reaching Captain (attempt $attempt/$RETRIES): ${err:-no response}"
  else
    debug "http $code (attempt $attempt/$RETRIES) body=$(printf '%s' "$body" | tr -d '\n' | cut -c1-400)"
    # Retry only on 5xx; 4xx is a real client error and should fail fast.
    case "$code" in
      5??) log "Captain returned $code (attempt $attempt/$RETRIES), will retry" ;;
      *)   break ;;
    esac
  fi

  if [ "$attempt" -ge "$RETRIES" ]; then break; fi
  sleep $((attempt * 3))
done

# ---- delete: best-effort, never block teardown -------------------------------
if [ "$ACTION" = "delete" ]; then
  if [ "${code:-}" = "" ] || [ "${code:-}" = "000" ]; then
    log "teardown notice could not reach Captain; tolerated (Captain reconciles orphaned subscriptions)."
  else
    log "teardown notice sent (http $code); tolerated regardless of response."
  fi
  exit 0
fi

# ---- create: require a verified response or fail the deploy ------------------
if [ -z "${code:-}" ] || [ "${code:-}" = "000" ]; then
  die "Could not reach Captain enroll endpoint after $RETRIES attempts: $(cat /tmp/captain_enroll_curl_err 2>/dev/null). Check egress/DNS and that $CAPTAIN_ENROLL_URL is correct."
fi

if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
  reason="$(printf '%s' "$body" | jq -r '.error // .message // empty' 2>/dev/null || true)"
  die "Captain rejected enrollment (http $code)${reason:+: $reason}. Full body: $(printf '%s' "$body" | tr -d '\n' | cut -c1-500)"
fi

verified="$(printf '%s' "$body" | jq -r '.verified // false' 2>/dev/null || echo false)"
if [ "$verified" != "true" ]; then
  reason="$(printf '%s' "$body" | jq -r '.status // .error // .message // empty' 2>/dev/null || true)"
  die "Captain reached but did NOT verify the deployment (verified=$verified)${reason:+, status=$reason}. This usually means the reader binding has not propagated yet (retry apply in ~60s) or the OIDC audience does not match Captain's verifier. Body: $(printf '%s' "$body" | tr -d '\n' | cut -c1-500)"
fi

status="$(printf '%s' "$body" | jq -r '.status // "verified"' 2>/dev/null || echo verified)"
log "SUCCESS Captain verified deployment $DEPLOYMENT_ID (status=$status). Read access and event delivery both confirmed."
exit 0
