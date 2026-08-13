#!/usr/bin/env bash
# =============================================================================
# Captain webhook enrollment. Registers this deployment's event delivery with
# the Captain API:
#
#   POST {CAPTAIN_API_BASE}/v2/syncs/{SYNC_ID}/webhooks
#   Authorization: Bearer {CAPTAIN_API_KEY}
#   Body: {}    (GCS syncs send an empty JSON object; only S3-family syncs
#                send {"sns_topic_arn": ...})
#
# Success is a 2xx JSON response carrying subscribe_url: the per-sync ingest
# URL Captain minted, the same URL the Pub/Sub push subscription delivers to.
# Anything else exits non-zero, which fails `terraform apply` (or setup.sh)
# with a readable reason.
#
# Invoked two ways:
#   - Terraform:  local-exec interpreter runs this file, all facts come from
#                 the environment (see main.tf).
#   - gcloud:     setup.sh execs it the same way.
#
# Reads (env):    CAPTAIN_API_BASE SYNC_ID CAPTAIN_API_KEY
# Optional (env): INGEST_URL (the subscribe_url the push subscription points
#                 at; a warning is logged if Captain returns a different one),
#                 DEPLOYMENT_ID (log correlation only), TEMPLATE_VERSION,
#                 CAPTAIN_ENROLL_RETRIES (default 4), CAPTAIN_DEBUG (default 1).
#
# The API key travels only in the Authorization header, is never logged, and
# never appears on a command line: curl reads the header from a file inside a
# private (0700) mktemp dir, so it is not visible in `ps` either.
# =============================================================================
set -euo pipefail

# ---- logging -----------------------------------------------------------------
DEBUG="${CAPTAIN_DEBUG:-1}"
log()   { printf '[captain-enroll %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
debug() { [ "$DEBUG" = "1" ] && log "DEBUG $*" || true; }
die()   { log "ERROR $*"; exit 1; }

# ---- preflight ---------------------------------------------------------------
command -v curl >/dev/null 2>&1 || die "curl not found on PATH. Install curl and re-run."
command -v jq   >/dev/null 2>&1 || die "jq not found on PATH. Install jq (brew install jq / apt-get install jq) and re-run."

: "${CAPTAIN_API_BASE:?CAPTAIN_API_BASE is required (canonical: https://api.captain.dev)}"
case "$CAPTAIN_API_BASE" in
  https://*) : ;;
  *) die "CAPTAIN_API_BASE must be https:// (refusing to send the API key over plaintext). Got: $CAPTAIN_API_BASE" ;;
esac

: "${SYNC_ID:?SYNC_ID is required (sync_<token>, from your Captain dashboard)}"
echo "$SYNC_ID" | grep -Eq '^sync_[A-Za-z0-9]+$' \
  || die "SYNC_ID must look like sync_<token>. Got: $SYNC_ID"

: "${CAPTAIN_API_KEY:?CAPTAIN_API_KEY is required (mint one in your Captain dashboard)}"

# Private scratch dir (mktemp -d is mode 0700): holds the curl stderr capture
# and the Authorization header file. A fixed /tmp path would let two concurrent
# runs clobber each other's error capture; putting the header in a file keeps
# the API key off curl's argv (and out of `ps`).
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/captain-enroll.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "$WORKDIR"' EXIT
CURL_ERR="$WORKDIR/curl_err"
AUTH_HEADER_FILE="$WORKDIR/auth_header"
printf 'authorization: Bearer %s\n' "$CAPTAIN_API_KEY" > "$AUTH_HEADER_FILE"

ENDPOINT="${CAPTAIN_API_BASE%/}/v2/syncs/${SYNC_ID}/webhooks"
TEMPLATE_VERSION="${TEMPLATE_VERSION:-2026-08-13}"
RETRIES="${CAPTAIN_ENROLL_RETRIES:-4}"

log "sync=$SYNC_ID endpoint=$ENDPOINT${DEPLOYMENT_ID:+ deploymentId=$DEPLOYMENT_ID}"

# ---- POST with retry on transient network / 5xx errors -----------------------
# GCS syncs need no request body fields, so the body is the empty JSON object.
attempt=0
body=""
code=""
while : ; do
  attempt=$((attempt + 1))
  resp="$(curl -sS -m 45 -w $'\n%{http_code}' \
      -X POST "$ENDPOINT" \
      -H @"$AUTH_HEADER_FILE" \
      -H 'content-type: application/json' \
      -H "user-agent: captain-gcs-enroll/${TEMPLATE_VERSION}" \
      --data-binary '{}' 2>"$CURL_ERR" || true)"
  code="$(printf '%s' "$resp" | tail -n1)"
  body="$(printf '%s' "$resp" | sed '$d')"

  if [ -z "$code" ] || [ "$code" = "000" ]; then
    err="$(cat "$CURL_ERR" 2>/dev/null || true)"
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

# ---- require 2xx + subscribe_url or fail the deploy ---------------------------
if [ -z "${code:-}" ] || [ "${code:-}" = "000" ]; then
  die "Could not reach the Captain API after $RETRIES attempts: $(cat "$CURL_ERR" 2>/dev/null || true). Check egress/DNS and that $CAPTAIN_API_BASE is correct."
fi

if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
  reason="$(printf '%s' "$body" | jq -r '.error // .message // .detail // empty' 2>/dev/null || true)"
  hint=""
  case "$code" in
    401|403) hint=" Check CAPTAIN_API_KEY (it must be a live key for the workspace that owns $SYNC_ID)." ;;
    404)     hint=" Check the sync id; $SYNC_ID was not found for this API key." ;;
  esac
  die "Captain rejected the webhook registration (http $code)${reason:+: $reason}.${hint} Full body: $(printf '%s' "$body" | tr -d '\n' | cut -c1-500)"
fi

subscribe_url="$(printf '%s' "$body" | jq -r '.subscribe_url // empty' 2>/dev/null || true)"
[ -n "$subscribe_url" ] \
  || die "Captain returned http $code but no subscribe_url in the response; cannot confirm the enrollment. Body: $(printf '%s' "$body" | tr -d '\n' | cut -c1-500)"

secret_set="$(printf '%s' "$body" | jq -r '.secret_set // false' 2>/dev/null || echo false)"
log "SUCCESS webhook registered for $SYNC_ID (secret_set=$secret_set)."
log "subscribe_url: $subscribe_url"

# Sanity check: the push subscription must deliver to the URL Captain minted.
if [ -n "${INGEST_URL:-}" ] && [ "$INGEST_URL" != "$subscribe_url" ]; then
  log "WARNING the push subscription delivers to $INGEST_URL but Captain returned $subscribe_url. Re-run with the ingest URL set to the returned subscribe_url so events actually arrive."
fi

# Surface any next-step instructions Captain sent back.
instructions="$(printf '%s' "$body" | jq -r '.instructions[]?' 2>/dev/null || true)"
if [ -n "$instructions" ]; then
  while IFS= read -r line; do
    if [ -n "$line" ]; then log "captain: $line"; fi
  done <<< "$instructions"
fi

exit 0
