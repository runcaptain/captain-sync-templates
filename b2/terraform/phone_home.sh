#!/usr/bin/env bash
#
# phone_home.sh  (template version 2026-08-12)
#
# Called by the Terraform null_resource.enroll provisioner. Reads the enrollment
# facts from CAPTAIN_* environment variables, POSTs them to Captain, and:
#   - on "create": exits non-zero unless Captain returns {"verified": true},
#     which fails `terraform apply` so a clean apply is a CONFIRMED sync.
#   - on "delete": best-effort teardown notice, never fails the destroy.
#
# Secrets are never echoed: the logged payload is redacted with jq.
set -o errexit
set -o nounset
set -o pipefail

ACTION="${CAPTAIN_ACTION:-${1:-create}}"
URL="${CAPTAIN_CALLBACK_URL:?CAPTAIN_CALLBACK_URL is required}"
TEMPLATE_VERSION="${CAPTAIN_TEMPLATE_VERSION:-2026-08-12}"

_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log()  { printf '%s [INFO]  %s\n'  "$(_ts)" "$*" >&2; }
err()  { printf '%s [ERROR] %s\n'  "$(_ts)" "$*" >&2; }

command -v curl >/dev/null 2>&1 || { err "curl is required."; exit 1; }
command -v jq   >/dev/null 2>&1 || { err "jq is required.";   exit 1; }

payload="$(jq -nc \
  --arg dep   "${CAPTAIN_DEPLOYMENT_ID:-}" \
  --arg ver   "$TEMPLATE_VERSION" \
  --arg act   "$ACTION" \
  --arg sync  "${CAPTAIN_SYNC_ID:-}" \
  --arg sec   "${CAPTAIN_SECRET:-}" \
  --arg acct  "${CAPTAIN_ACCOUNT_ID:-}" \
  --arg bkt   "${CAPTAIN_BUCKET_NAME:-}" \
  --arg bid   "${CAPTAIN_BUCKET_ID:-}" \
  --arg s3url "${CAPTAIN_S3_ENDPOINT:-}" \
  --arg s3reg "${CAPTAIN_S3_REGION:-}" \
  --arg kid   "${CAPTAIN_READ_KEY_ID:-}" \
  --arg akey  "${CAPTAIN_READ_APP_KEY:-}" \
  --arg evurl "${CAPTAIN_EVENTS_URL:-}" \
  --arg est   "${CAPTAIN_EVENT_STATUS:-skipped}" \
  --arg rname "${CAPTAIN_RULE_NAME:-}" \
  --arg hmac  "${CAPTAIN_HMAC_SECRET:-}" \
  '{
     deploymentId: $dep, templateVersion: $ver, action: $act, provider: "backblaze-b2",
     source: "terraform",
     syncId: $sync, secret: $sec,
     account: { accountId: $acct },
     bucket:  { name: $bkt, id: $bid },
     s3Compatible: { endpoint: $s3url, region: $s3reg, keyId: $kid, applicationKey: $akey },
     events: { status: $est, ruleName: $rname, webhookUrl: $evurl, hmacSha256SigningSecret: $hmac }
   }')"

redacted="$(printf '%s' "$payload" | jq -c '
  .secret = "***" | .s3Compatible.applicationKey = "***" | .events.hmacSha256SigningSecret = "***"')"
log "Phoning home to Captain (${ACTION}): ${redacted}"

tmp="$(mktemp)"
code="$(curl --silent --show-error --max-time 45 -X POST \
  -H "Content-Type: application/json" \
  -H "User-Agent: captain-b2-terraform/${TEMPLATE_VERSION}" \
  -H "Authorization: captain-secret ${CAPTAIN_SECRET:-}" \
  --data "$payload" -o "$tmp" -w '%{http_code}' "$URL" || echo "000")"
body="$(cat "$tmp")"; rm -f "$tmp"

if [ "$ACTION" = "delete" ]; then
  [ "$code" = "200" ] || err "Teardown notice returned HTTP ${code} (tolerated)."
  exit 0
fi

verified="$(printf '%s' "$body" | jq -r '.verified // false' 2>/dev/null || echo false)"
if [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 300 ] 2>/dev/null && [ "$verified" = "true" ]; then
  status="$(printf '%s' "$body" | jq -r '.status // "verified"' 2>/dev/null || echo verified)"
  log "Captain CONFIRMED enrollment (status: ${status}). Deployment ${CAPTAIN_DEPLOYMENT_ID:-}."
  exit 0
fi

err "Captain did NOT confirm enrollment (HTTP ${code}, verified=${verified})."
err "Response: $(printf '%s' "$body" | head -c 400)"
err "Likely causes: wrong secret/sync id, the scoped key cannot read the bucket over ${CAPTAIN_S3_ENDPOINT:-?}, or Captain's enroll endpoint is unreachable."
err "The key/rule remain in Terraform state. Fix the cause and re-apply, or 'terraform destroy' to tear down."
exit 1
