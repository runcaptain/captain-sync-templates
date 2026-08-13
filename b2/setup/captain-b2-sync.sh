#!/usr/bin/env bash
#
# captain-b2-sync.sh  (template version 2026-08-12)
#
# One command stands up everything Captain needs to keep a Backblaze B2 bucket
# synced, entirely inside YOUR OWN Backblaze account:
#
#   1. EVENT WIRING       a native B2 Event Notification rule that webhooks
#                         object create/delete straight to Captain's ingest
#                         endpoint (the latency optimization).
#   2. READ GRANT         a SCOPED, read-only application key restricted to the
#                         one bucket, handed to Captain so it can list and fetch
#                         objects over the S3-compatible endpoint (the always-on
#                         reconcile/polling backstop). We NEVER hand Captain your
#                         master key.
#   3. SELF-VERIFY        a phone-home to Captain that makes Captain actually
#                         prove it can read the bucket (and, when Event
#                         Notifications are enabled on your account, that the
#                         webhook is wired) BEFORE this script reports success.
#                         If Captain cannot confirm, the script rolls back the
#                         key and the rule it created and exits non-zero. A
#                         green run means a CONFIRMED sync, not a hopeful one.
#
# Backblaze has no CloudFormation/console one-click and no cross-account
# assume-role. The scoped application key IS the cross-account grant; it is
# minted read-only, single-bucket, and can be given an expiry for rotation.
#
# HONEST FLAG: B2 Event Notifications are account-gated by Backblaze (you open a
# support ticket to have the feature enabled). If your account is not enabled,
# the EVENT path is BLOCKED and this script says so plainly and keeps going: the
# reconcile backstop via the S3-compatible endpoint still works on its own. See
# b2/NOTES.md.
#
# Conventions: template/URL versions are date-based YYYY-MM-DD; customer-facing
# ids are Stripe-style prefix_token (dep_<token>). No bare UUIDs.
#
# ---------------------------------------------------------------------------
set -o errexit
set -o nounset
set -o pipefail

TEMPLATE_VERSION="2026-08-12"
SCRIPT_NAME="captain-b2-sync"
USER_AGENT="captain-b2-setup/${TEMPLATE_VERSION}"

# Backblaze fixed entrypoint. Everything else (apiUrl, s3ApiUrl, region) is
# discovered from b2_authorize_account so this works in any B2 region.
B2_AUTH_URL="https://api.backblazeb2.com/b2api/v3/b2_authorize_account"

# ---------------------------------------------------------------------------
# Defaults. Captain normally pre-fills --callback-url and --events-url when it
# generates your setup command, so a customer only pastes and runs.
# ---------------------------------------------------------------------------
DEFAULT_CALLBACK_URL="https://api.runcaptain.com/v1/deploy/b2/enroll"
DEFAULT_EVENTS_URL="https://api.runcaptain.com/v1/deploy/b2/events"

# ---------------------------------------------------------------------------
# Logging. Everything goes to stderr so stdout stays clean for machine-readable
# output (the final JSON summary). Secrets are NEVER logged: payloads are
# redacted with jq before they are printed.
# ---------------------------------------------------------------------------
DEBUG="${CAPTAIN_DEBUG:-0}"

_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log()   { printf '%s [%s] %s\n'  "$(_ts)" "INFO"  "$*" >&2; }
warn()  { printf '%s [%s] %s\n'  "$(_ts)" "WARN"  "$*" >&2; }
err()   { printf '%s [%s] %s\n'  "$(_ts)" "ERROR" "$*" >&2; }
debug() { [ "$DEBUG" = "1" ] && printf '%s [%s] %s\n' "$(_ts)" "DEBUG" "$*" >&2 || true; }
die()   { err "$*"; err "Setup did NOT complete. See the message above; re-run with --debug for the full trace."; exit 1; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<EOF
${SCRIPT_NAME} (template ${TEMPLATE_VERSION})

Wire a Backblaze B2 bucket to Captain: native event-notification webhook +
scoped read-only application key + self-verifying phone-home.

USAGE
  ${SCRIPT_NAME}.sh provision [options]     stand up + verify (default command)
  ${SCRIPT_NAME}.sh teardown  [options]     remove the key + rule this created
  ${SCRIPT_NAME}.sh --help

REQUIRED (provision)
  --sync-id       sync_<token>   Captain sync id this deployment enrolls.
  --secret        <string>       One-time enrollment secret Captain minted for
                                 this sync (>= 16 chars). Write-only; never logged.
                                 PREFER the env var below: an argv flag is
                                 visible to other local users via ps/proc and
                                 lands in shell history.
                                 (or set env CAPTAIN_ENROLL_SECRET)
  --bucket        <name>         EXISTING B2 bucket to sync. Not created here.

OPERATOR CREDENTIALS (used ONLY during setup, never sent to Captain)
  --b2-key-id     <keyId>        A B2 key that can create keys + manage
  --b2-app-key    <appKey>       notifications on this bucket. Prefer a bucket-
                                 scoped admin key over the master key.
                                 PREFER the env vars below over these flags for
                                 the same reason as --secret above.
  (or set env B2_APPLICATION_KEY_ID / B2_APPLICATION_KEY)

OPTIONAL
  --callback-url  <https url>    Captain enroll endpoint.
                                 default: ${DEFAULT_CALLBACK_URL}
  --events-url    <https url>    Captain ingest webhook the B2 rule points at.
                                 default: ${DEFAULT_EVENTS_URL}?sync=<sync-id>
  --key-duration  <seconds>      Expire the scoped read key after N seconds
                                 (rotation). Omit for a non-expiring key.
  --event-path    auto|force|skip
                                 auto (default): try to set the notification
                                   rule; if Event Notifications are not enabled
                                   on the account, warn and continue.
                                 force: treat a blocked event path as fatal.
                                 skip:  reconcile-only, do not touch rules.
  --deployment-id dep_<token>    Reuse an id (teardown, or re-run). Otherwise
                                 a fresh dep_<token> is generated.
  --no-rollback                  On a failed verify, leave the key + rule in
                                 place for inspection (default rolls them back).
  --dry-run                      Preflight + auth + resolve, then stop. Creates
                                 nothing, sends nothing.
  --debug                        Verbose trace (or env CAPTAIN_DEBUG=1).
  --help

EXIT CODES
  0 success (verified)   1 usage/preflight   2 B2 API error
  3 Captain verify failed (rolled back unless --no-rollback)
EOF
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# Stripe-style deployment id: dep_ + 24 url-safe chars. No bare UUIDs.
#
# NOTE: `tr ... | head -c N` is a SIGPIPE trap under `set -o pipefail`. head
# closes its end of the pipe once it has read N bytes; tr, still writing,
# gets SIGPIPE and exits 141. pipefail then reports the pipeline as failed
# even though we got exactly the bytes we wanted, and under `set -o errexit`
# that standalone assignment would abort the whole script. Capture into a
# variable with a trailing `|| true` so the pipeline's exit status never
# reaches errexit; the output itself is unaffected by the signal.
new_deployment_id() {
  local token
  token="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)" || true
  printf 'dep_%s' "$token"
}

# 32-char hex secret for the webhook HMAC (B2 requires exactly 32 chars).
# Same SIGPIPE/pipefail/errexit trap as new_deployment_id() above; same fix.
new_hmac_secret() {
  local secret
  secret="$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 32)" || true
  printf '%s' "$secret"
}

# Sanitize an id into a B2-safe resource name fragment: [A-Za-z0-9-] only.
sanitize_name() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9-' '-'
}

# curl wrapper: fail loudly, capture body + HTTP code. Prints "BODY\n<code>".
# Never traces credentials.
http_call() {
  # args: METHOD URL [--auth-basic KID:AKEY | --auth-token TOKEN] [--json BODY]
  local method="$1" url="$2"; shift 2
  local auth_kind="" auth_val="" body="" tmp code
  while [ $# -gt 0 ]; do
    case "$1" in
      --auth-basic) auth_kind="basic"; auth_val="$2"; shift 2 ;;
      --auth-token) auth_kind="token"; auth_val="$2"; shift 2 ;;
      --json)       body="$2"; shift 2 ;;
      *) die "http_call: unknown arg $1" ;;
    esac
  done
  tmp="$(mktemp)"
  local -a args
  args=(--silent --show-error --max-time 45 -X "$method"
        -H "User-Agent: ${USER_AGENT}" -o "$tmp" -w '%{http_code}')
  if [ "$auth_kind" = "basic" ]; then
    args+=(-u "$auth_val")
  elif [ "$auth_kind" = "token" ]; then
    args+=(-H "Authorization: ${auth_val}")
  fi
  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/json" --data "$body")
  fi
  debug "HTTP ${method} ${url}"
  code="$(curl "${args[@]}" "$url" || echo "000")"
  HTTP_BODY="$(cat "$tmp")"
  HTTP_CODE="$code"
  rm -f "$tmp"
  debug "HTTP <- ${code} ($(printf '%s' "$HTTP_BODY" | wc -c | tr -d ' ') bytes)"
}

# Pull a human message out of a B2 error body if present.
b2_err() {
  printf '%s' "$1" | jq -r '"[" + (.code // "?") + "] " + (.message // "" ) + " (status " + (.status|tostring) + ")"' 2>/dev/null \
    || printf '%s' "$1"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  log "Preflight: checking tools and parameters."
  command -v curl >/dev/null 2>&1 || die "curl is required but not found on PATH."
  command -v jq   >/dev/null 2>&1 || die "jq is required but not found on PATH. Install: https://jqlang.github.io/jq/"

  [ -n "$SYNC_ID" ]  || { usage; die "--sync-id is required."; }
  [ -n "$BUCKET" ]   || { usage; die "--bucket is required."; }
  case "$COMMAND" in
    provision)
      [ -n "$SECRET" ] || { usage; die "--secret is required for provision."; }
      ;;
  esac

  printf '%s' "$SYNC_ID" | grep -Eq '^sync_[A-Za-z0-9]+$' \
    || die "--sync-id '${SYNC_ID}' is not of the form sync_<token>."
  printf '%s' "$BUCKET" | grep -Eq '^[a-z0-9][a-z0-9.-]{4,61}[a-z0-9]$' \
    || die "--bucket '${BUCKET}' is not a valid B2 bucket name (6-63 chars, lowercase letters/digits/'.'/'-')."
  if [ "$COMMAND" = "provision" ] && [ "${#SECRET}" -lt 16 ]; then
    die "--secret must be at least 16 characters (Captain mints this for the sync)."
  fi
  printf '%s' "$CALLBACK_URL" | grep -Eq '^https://' \
    || die "--callback-url must be an https:// URL (the secret is only ever sent over TLS). Got: ${CALLBACK_URL}"
  printf '%s' "$EVENTS_URL" | grep -Eq '^https://' \
    || die "--events-url must be an https:// URL. Got: ${EVENTS_URL}"

  [ -n "$B2_KEY_ID" ]  || die "Operator B2 key id missing. Pass --b2-key-id or set B2_APPLICATION_KEY_ID."
  [ -n "$B2_APP_KEY" ] || die "Operator B2 app key missing. Pass --b2-app-key or set B2_APPLICATION_KEY."

  case "$EVENT_PATH" in auto|force|skip) ;; *) die "--event-path must be auto|force|skip (got '${EVENT_PATH}')." ;; esac
  if [ -n "$KEY_DURATION" ]; then
    printf '%s' "$KEY_DURATION" | grep -Eq '^[1-9][0-9]*$' || die "--key-duration must be a positive integer (seconds)."
  fi
  log "Preflight OK."
}

# ---------------------------------------------------------------------------
# Authorize + discover (region, apiUrl, s3 endpoint, capabilities)
# ---------------------------------------------------------------------------
authorize() {
  log "Authorizing with Backblaze (operator key ${B2_KEY_ID})."
  http_call GET "$B2_AUTH_URL" --auth-basic "${B2_KEY_ID}:${B2_APP_KEY}"
  [ "$HTTP_CODE" = "200" ] || { err "$(b2_err "$HTTP_BODY")"; die_api 2 "b2_authorize_account failed (HTTP ${HTTP_CODE}). Check the operator key id/secret."; }

  API_URL="$(printf '%s' "$HTTP_BODY" | jq -r '.apiInfo.storageApi.apiUrl // empty')"
  S3_URL="$(printf '%s' "$HTTP_BODY" | jq -r '.apiInfo.storageApi.s3ApiUrl // empty')"
  ACCOUNT_ID="$(printf '%s' "$HTTP_BODY" | jq -r '.accountId // empty')"
  CAPS="$(printf '%s' "$HTTP_BODY" | jq -r '.apiInfo.storageApi.capabilities | join(",")')"
  [ -n "$API_URL" ] && [ -n "$S3_URL" ] && [ -n "$ACCOUNT_ID" ] \
    || die "b2_authorize_account response missing apiUrl/s3ApiUrl/accountId. Response: $(printf '%s' "$HTTP_BODY" | head -c 300)"

  # Region is embedded in the S3 endpoint: s3.<region>.backblazeb2.com
  S3_REGION="$(printf '%s' "$S3_URL" | sed -n 's#^https://s3\.\([a-z0-9-]*\)\.backblazeb2\.com#\1#p')"
  [ -n "$S3_REGION" ] || S3_REGION="unknown"

  log "Account ${ACCOUNT_ID}, apiUrl ${API_URL}, S3 endpoint ${S3_URL} (region ${S3_REGION})."

  # Warn early if the operator key is missing a capability we will need. We do
  # not hard-fail: the exact operation will report the real error, but naming
  # the gap up front is a much better debugging experience.
  local need
  for need in writeKeys listBuckets; do
    printf ',%s,' "$CAPS" | grep -q ",${need}," \
      || warn "Operator key is missing capability '${need}'. The relevant step will fail; use a key with more scope (or the master key) for setup."
  done
  if [ "$EVENT_PATH" != "skip" ]; then
    printf ',%s,' "$CAPS" | grep -q ',writeBucketNotifications,' \
      || warn "Operator key lacks 'writeBucketNotifications'. If the event path is not skipped it will fail; Event Notifications may also be account-gated (see b2/NOTES.md)."
  fi
}

resolve_bucket() {
  log "Resolving bucket '${BUCKET}'."
  http_call POST "${API_URL}/b2api/v3/b2_list_buckets" \
    --auth-token "$AUTH_TOKEN" \
    --json "$(jq -nc --arg a "$ACCOUNT_ID" --arg b "$BUCKET" '{accountId:$a, bucketName:$b}')"
  [ "$HTTP_CODE" = "200" ] || { err "$(b2_err "$HTTP_BODY")"; die_api 2 "b2_list_buckets failed (HTTP ${HTTP_CODE})."; }
  BUCKET_ID="$(printf '%s' "$HTTP_BODY" | jq -r --arg b "$BUCKET" '.buckets[] | select(.bucketName==$b) | .bucketId' | head -n1)"
  [ -n "$BUCKET_ID" ] \
    || die "Bucket '${BUCKET}' not found in account ${ACCOUNT_ID}. Check the name and that the operator key can see it (needs listBuckets, and if the key is bucket-restricted it must be restricted to THIS bucket)."
  log "Bucket '${BUCKET}' -> bucketId ${BUCKET_ID}."
}

# Cache the auth token from the last authorize() call for reuse.
set_auth_token() {
  AUTH_TOKEN="$(printf '%s' "$1" | jq -r '.authorizationToken')"
}

# ---------------------------------------------------------------------------
# Read grant: mint a SCOPED, read-only application key for Captain
# ---------------------------------------------------------------------------
mint_read_key() {
  local keyname
  keyname="captain-b2-read-$(sanitize_name "$SYNC_ID")"
  log "Minting scoped read-only key '${keyname}' (bucket ${BUCKET_ID}, caps listBuckets,listFiles,readFiles,readBucketNotifications)."
  local payload
  payload="$(jq -nc \
    --arg a "$ACCOUNT_ID" --arg n "$keyname" --arg b "$BUCKET_ID" \
    --argjson dur "${KEY_DURATION:-null}" \
    '{accountId:$a, keyName:$n, bucketId:$b,
      capabilities:["listBuckets","listFiles","readFiles","readBucketNotifications"]}
     + (if $dur == null then {} else {validDurationInSeconds:$dur} end)')"
  http_call POST "${API_URL}/b2api/v3/b2_create_key" --auth-token "$AUTH_TOKEN" --json "$payload"
  [ "$HTTP_CODE" = "200" ] || { err "$(b2_err "$HTTP_BODY")"; die_api 2 "b2_create_key failed (HTTP ${HTTP_CODE}). The operator key needs 'writeKeys'."; }
  READ_KEY_ID="$(printf '%s' "$HTTP_BODY" | jq -r '.applicationKeyId')"
  READ_APP_KEY="$(printf '%s' "$HTTP_BODY" | jq -r '.applicationKey')"
  CREATED_KEY=1
  log "Scoped read key created: ${READ_KEY_ID} (secret captured, not logged)."
}

delete_read_key() {
  [ "${CREATED_KEY:-0}" = "1" ] || return 0
  [ -n "${READ_KEY_ID:-}" ] || return 0
  log "Removing scoped read key ${READ_KEY_ID}."
  http_call POST "${API_URL}/b2api/v3/b2_delete_key" --auth-token "$AUTH_TOKEN" \
    --json "$(jq -nc --arg k "$READ_KEY_ID" '{applicationKeyId:$k}')"
  [ "$HTTP_CODE" = "200" ] || warn "Could not delete key ${READ_KEY_ID} (HTTP ${HTTP_CODE}): $(b2_err "$HTTP_BODY"). Remove it by hand if it lingers."
}

# ---------------------------------------------------------------------------
# Event wiring: ADDITIVE notification-rule set (preserve sibling rules)
#
# b2_set_bucket_notification_rules REPLACES the whole rule set, exactly like S3
# PutBucketNotification. So we read the current rules, drop any prior copy of
# OURS (matched by name), append ours, and write the merged set. Teardown drops
# only ours. This never clobbers rules the customer already has.
# ---------------------------------------------------------------------------
rule_name() { printf 'captain-sync-%s' "$(sanitize_name "$SYNC_ID" | tr '[:upper:]' '[:lower:]')"; }

get_rules() {
  http_call POST "${API_URL}/b2api/v3/b2_get_bucket_notification_rules" \
    --auth-token "$AUTH_TOKEN" --json "$(jq -nc --arg b "$BUCKET_ID" '{bucketId:$b}')"
}

set_notification_rule() {
  local rname; rname="$(rule_name)"
  log "Setting Event Notification rule '${rname}' -> ${EVENTS_URL} (additive; sibling rules preserved)."

  get_rules
  if [ "$HTTP_CODE" != "200" ]; then
    local msg; msg="$(b2_err "$HTTP_BODY")"
    # Account gating shows up here (feature not enabled). Distinguish blocked
    # from a hard failure so the operator knows the reconcile backstop is fine.
    if printf '%s' "$HTTP_BODY" | grep -qiE 'not enabled|not available|feature|unsupported|forbidden'; then
      EVENT_STATUS="blocked"
      warn "Event Notifications appear to be BLOCKED on this account: ${msg}"
      warn "This is expected until Backblaze enables the feature (open a support ticket). The reconcile/polling backstop still keeps the sync current. See b2/NOTES.md."
      [ "$EVENT_PATH" = "force" ] && { die_api 2 "--event-path force set, but Event Notifications are blocked."; }
      return 0
    fi
    EVENT_STATUS="error"
    warn "Could not read existing notification rules (HTTP ${HTTP_CODE}): ${msg}"
    [ "$EVENT_PATH" = "force" ] && { die_api 2 "--event-path force set, but reading rules failed."; }
    return 0
  fi

  local merged
  merged="$(printf '%s' "$HTTP_BODY" | jq -c \
    --arg b "$BUCKET_ID" --arg name "$rname" --arg url "$EVENTS_URL" --arg hmac "$HMAC_SECRET" '
      { bucketId: $b,
        eventNotificationRules:
          ((.eventNotificationRules // [])
            | map(select(.name != $name))                       # drop prior copy of ours
            + [ { name: $name, isEnabled: true, objectNamePrefix: "",
                  eventTypes: ["b2:ObjectCreated:*","b2:ObjectDeleted:*"],
                  targetConfiguration: {
                    targetType: "webhook", url: $url,
                    hmacSha256SigningSecret: $hmac } } ]) }')"

  http_call POST "${API_URL}/b2api/v3/b2_set_bucket_notification_rules" \
    --auth-token "$AUTH_TOKEN" --json "$merged"
  if [ "$HTTP_CODE" = "200" ]; then
    CREATED_RULE=1
    EVENT_STATUS="enabled"
    log "Event Notification rule '${rname}' is set and enabled."
  else
    local msg; msg="$(b2_err "$HTTP_BODY")"
    if printf '%s' "$HTTP_BODY" | grep -qiE 'not enabled|not available|feature|unsupported|forbidden'; then
      EVENT_STATUS="blocked"
      warn "Event Notifications BLOCKED on this account: ${msg} (reconcile backstop still active; see b2/NOTES.md)."
      [ "$EVENT_PATH" = "force" ] && { die_api 2 "--event-path force set, but Event Notifications are blocked."; }
    else
      EVENT_STATUS="error"
      warn "Failed to set notification rule (HTTP ${HTTP_CODE}): ${msg}"
      [ "$EVENT_PATH" = "force" ] && { die_api 2 "--event-path force set, but setting the rule failed."; }
    fi
  fi
}

remove_notification_rule() {
  local rname; rname="$(rule_name)"
  get_rules
  [ "$HTTP_CODE" = "200" ] || { warn "Could not read rules to remove ours (HTTP ${HTTP_CODE}); skipping."; return 0; }
  local remaining
  remaining="$(printf '%s' "$HTTP_BODY" | jq -c --arg name "$rname" --arg b "$BUCKET_ID" \
    '{bucketId:$b, eventNotificationRules: ((.eventNotificationRules // []) | map(select(.name != $name)))}')"
  http_call POST "${API_URL}/b2api/v3/b2_set_bucket_notification_rules" \
    --auth-token "$AUTH_TOKEN" --json "$remaining"
  if [ "$HTTP_CODE" = "200" ]; then
    log "Removed notification rule '${rname}' (sibling rules preserved)."
  else
    warn "Could not remove rule '${rname}' (HTTP ${HTTP_CODE}): $(b2_err "$HTTP_BODY")."
  fi
}

# ---------------------------------------------------------------------------
# Rollback + fatal helpers
# ---------------------------------------------------------------------------
die_api() { local c="$1"; shift; err "$*"; exit "$c"; }

rollback() {
  if [ "$NO_ROLLBACK" = "1" ]; then
    warn "--no-rollback: leaving the scoped key and notification rule in place for inspection."
    warn "Read key id: ${READ_KEY_ID:-none}. Notification rule: $(rule_name). Remove with: ${SCRIPT_NAME}.sh teardown --sync-id ${SYNC_ID} --bucket ${BUCKET}"
    return 0
  fi
  warn "Rolling back what this run created."
  [ "${CREATED_RULE:-0}" = "1" ] && remove_notification_rule || true
  delete_read_key || true
}

# ---------------------------------------------------------------------------
# Self-verifying phone-home to Captain
# ---------------------------------------------------------------------------
phone_home() {
  local action="$1"
  local payload redacted
  payload="$(jq -nc \
    --arg dep   "$DEPLOYMENT_ID" \
    --arg ver   "$TEMPLATE_VERSION" \
    --arg act   "$action" \
    --arg sync  "$SYNC_ID" \
    --arg sec   "$SECRET" \
    --arg acct  "$ACCOUNT_ID" \
    --arg bkt   "$BUCKET" \
    --arg bid   "$BUCKET_ID" \
    --arg s3url "$S3_URL" \
    --arg s3reg "$S3_REGION" \
    --arg kid   "${READ_KEY_ID:-}" \
    --arg akey  "${READ_APP_KEY:-}" \
    --arg evurl "$EVENTS_URL" \
    --arg est   "${EVENT_STATUS:-skipped}" \
    --arg rname "$(rule_name)" \
    --arg hmac  "$HMAC_SECRET" \
    '{
       deploymentId: $dep, templateVersion: $ver, action: $act, provider: "backblaze-b2",
       syncId: $sync, secret: $sec,
       account: { accountId: $acct },
       bucket:  { name: $bkt, id: $bid },
       s3Compatible: { endpoint: $s3url, region: $s3reg, keyId: $kid, applicationKey: $akey },
       events: { status: $est, ruleName: $rname, webhookUrl: $evurl, hmacSha256SigningSecret: $hmac }
     }')"
  # Redacted copy for logs: strip every secret-bearing field.
  redacted="$(printf '%s' "$payload" | jq -c '
    .secret = "***" | .s3Compatible.applicationKey = "***" | .events.hmacSha256SigningSecret = "***"')"
  log "Phoning home to Captain (${action}): ${redacted}"

  http_call POST "$CALLBACK_URL" --auth-token "captain-secret ${SECRET}" --json "$payload"

  if [ "$action" = "delete" ]; then
    # Teardown notice is best-effort; never block teardown on it.
    [ "$HTTP_CODE" = "200" ] || warn "Teardown notice to Captain returned HTTP ${HTTP_CODE} (tolerated)."
    return 0
  fi

  local verified
  verified="$(printf '%s' "$HTTP_BODY" | jq -r '.verified // false' 2>/dev/null || echo false)"
  if [ "$HTTP_CODE" -ge 200 ] 2>/dev/null && [ "$HTTP_CODE" -lt 300 ] 2>/dev/null && [ "$verified" = "true" ]; then
    CAPTAIN_STATUS="$(printf '%s' "$HTTP_BODY" | jq -r '.status // "verified"' 2>/dev/null || echo verified)"
    log "Captain CONFIRMED enrollment (status: ${CAPTAIN_STATUS})."
    return 0
  fi

  err "Captain did NOT confirm enrollment."
  err "  HTTP ${HTTP_CODE}, verified=${verified}"
  err "  Response: $(printf '%s' "$HTTP_BODY" | head -c 400)"
  err "  Likely causes: wrong --secret or --sync-id, the scoped key cannot read the bucket over ${S3_URL}, or Captain's enroll endpoint is unreachable."
  rollback
  die_api 3 "Enrollment failed verification (see above)."
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
do_provision() {
  preflight
  authorize
  set_auth_token "$HTTP_BODY"   # HTTP_BODY still holds the authorize response
  resolve_bucket

  [ -n "$DEPLOYMENT_ID" ] || DEPLOYMENT_ID="$(new_deployment_id)"
  HMAC_SECRET="$(new_hmac_secret)"
  log "Deployment id: ${DEPLOYMENT_ID}"

  if [ "$DRY_RUN" = "1" ]; then
    log "--dry-run: preflight/auth/resolve done. Would mint a scoped read key, set rule '$(rule_name)', and phone home to ${CALLBACK_URL}. Nothing was created."
    printf '{"dryRun":true,"deploymentId":"%s","bucketId":"%s","s3Endpoint":"%s","region":"%s","eventPath":"%s"}\n' \
      "$DEPLOYMENT_ID" "$BUCKET_ID" "$S3_URL" "$S3_REGION" "$EVENT_PATH"
    return 0
  fi

  mint_read_key
  if [ "$EVENT_PATH" = "skip" ]; then
    EVENT_STATUS="skipped"
    log "--event-path skip: reconcile-only, not touching notification rules."
  else
    set_notification_rule
  fi
  phone_home create

  log "SUCCESS. Deployment ${DEPLOYMENT_ID} is enrolled and verified."
  # Machine-readable summary on stdout (secrets excluded).
  jq -nc \
    --arg dep "$DEPLOYMENT_ID" --arg sync "$SYNC_ID" --arg bkt "$BUCKET" \
    --arg bid "$BUCKET_ID" --arg kid "$READ_KEY_ID" --arg s3 "$S3_URL" \
    --arg reg "$S3_REGION" --arg est "${EVENT_STATUS:-skipped}" \
    --arg cap "${CAPTAIN_STATUS:-verified}" \
    '{ status:"verified", deploymentId:$dep, syncId:$sync,
       bucket:$bkt, bucketId:$bid, readKeyId:$kid,
       s3Endpoint:$s3, region:$reg, eventPath:$est, captainStatus:$cap,
       whatToDoNext: ("Enrollment " + $dep + " verified. Open your Captain dashboard for sync " + $sync + "; a targeted reconcile of " + $bkt + " runs now, and future changes " + (if $est=="enabled" then "webhook in near-real-time." else "sync via the reconcile backstop (event path: " + $est + ").")) }'
}

do_teardown() {
  # Teardown does not need --secret for the B2 side; it does for the best-effort
  # Captain notice. Keep going even if the notice cannot be sent.
  preflight
  authorize
  set_auth_token "$HTTP_BODY"
  resolve_bucket

  # Remove our notification rule.
  remove_notification_rule

  # Delete any read keys named for this sync.
  local keyname; keyname="captain-b2-read-$(sanitize_name "$SYNC_ID")"
  log "Looking for scoped read keys named '${keyname}' to delete."
  http_call POST "${API_URL}/b2api/v3/b2_list_keys" --auth-token "$AUTH_TOKEN" \
    --json "$(jq -nc --arg a "$ACCOUNT_ID" '{accountId:$a, maxKeyCount:10000}')"
  if [ "$HTTP_CODE" = "200" ]; then
    local ids id
    ids="$(printf '%s' "$HTTP_BODY" | jq -r --arg n "$keyname" '.keys[]? | select(.keyName==$n) | .applicationKeyId')"
    if [ -z "$ids" ]; then
      log "No matching keys found (already gone)."
    else
      for id in $ids; do
        READ_KEY_ID="$id"; CREATED_KEY=1
        delete_read_key
      done
    fi
  else
    warn "b2_list_keys failed (HTTP ${HTTP_CODE}); delete the '${keyname}' key by hand if it remains."
  fi

  # Best-effort Captain teardown notice.
  [ -n "$DEPLOYMENT_ID" ] || DEPLOYMENT_ID="dep_teardown"
  HMAC_SECRET=""
  READ_KEY_ID=""; READ_APP_KEY=""
  if [ -n "$SECRET" ]; then
    EVENT_STATUS="removed"
    phone_home delete
  else
    warn "No --secret given; skipping the Captain teardown notice (B2 resources were still removed)."
  fi
  log "Teardown complete for sync ${SYNC_ID} on bucket ${BUCKET}."
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
COMMAND="provision"
SYNC_ID=""
SECRET="${CAPTAIN_ENROLL_SECRET:-}"
BUCKET=""
B2_KEY_ID="${B2_APPLICATION_KEY_ID:-}"
B2_APP_KEY="${B2_APPLICATION_KEY:-}"
CALLBACK_URL="$DEFAULT_CALLBACK_URL"
EVENTS_URL=""
KEY_DURATION=""
EVENT_PATH="auto"
DEPLOYMENT_ID=""
NO_ROLLBACK=0
DRY_RUN=0

# State set later
API_URL=""; S3_URL=""; ACCOUNT_ID=""; CAPS=""; S3_REGION=""; AUTH_TOKEN=""
BUCKET_ID=""; READ_KEY_ID=""; READ_APP_KEY=""; HMAC_SECRET=""
EVENT_STATUS=""; CAPTAIN_STATUS=""
CREATED_KEY=0; CREATED_RULE=0
HTTP_BODY=""; HTTP_CODE=""

case "${1:-}" in
  provision|teardown) COMMAND="$1"; shift ;;
  -h|--help) usage; exit 0 ;;
  "") : ;;                 # default provision
  --*) : ;;                # options with default provision command
  *) die "Unknown command '${1}'. Use 'provision', 'teardown', or --help." ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --sync-id)       SYNC_ID="${2:-}"; shift 2 ;;
    --secret)        SECRET="${2:-}"; shift 2 ;;
    --bucket)        BUCKET="${2:-}"; shift 2 ;;
    --b2-key-id)     B2_KEY_ID="${2:-}"; shift 2 ;;
    --b2-app-key)    B2_APP_KEY="${2:-}"; shift 2 ;;
    --callback-url)  CALLBACK_URL="${2:-}"; shift 2 ;;
    --events-url)    EVENTS_URL="${2:-}"; shift 2 ;;
    --key-duration)  KEY_DURATION="${2:-}"; shift 2 ;;
    --event-path)    EVENT_PATH="${2:-}"; shift 2 ;;
    --deployment-id) DEPLOYMENT_ID="${2:-}"; shift 2 ;;
    --no-rollback)   NO_ROLLBACK=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --debug)         DEBUG=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) usage; die "Unknown option '${1}'." ;;
  esac
done

# Default the events URL to the enroll host's /events path tagged with the sync.
if [ -z "$EVENTS_URL" ]; then
  EVENTS_URL="${DEFAULT_EVENTS_URL}?sync=${SYNC_ID}"
fi

log "${SCRIPT_NAME} ${TEMPLATE_VERSION} :: command=${COMMAND} sync=${SYNC_ID:-?} bucket=${BUCKET:-?} event-path=${EVENT_PATH} dry-run=${DRY_RUN}"

case "$COMMAND" in
  provision) do_provision ;;
  teardown)  do_teardown ;;
  *) die "Unhandled command ${COMMAND}." ;;
esac
