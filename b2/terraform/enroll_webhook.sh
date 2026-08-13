#!/usr/bin/env bash
#
# enroll_webhook.sh  (template version 2026-08-13)
#
# External data source for the Terraform module: enrolls this sync's event
# webhook with Captain's API and returns the minted subscribe URL, which the
# B2 Event Notification rule targets.
#
#   POST {api_base}/v2/syncs/<sync_id>/webhooks
#   Authorization: Bearer $CAPTAIN_API_KEY   (env only, on purpose: it never
#                                             enters the query, the plan, or
#                                             Terraform state)
#   Body: {}  (B2 is not an SNS-backed source, so no sns_topic_arn)
#
# Captain answering 2xx with a subscribe_url IS the successful enrollment.
# Anything else fails the plan/apply with a clear reason on stderr.
#
# Terraform external-program protocol: query JSON on stdin, a flat JSON map of
# strings on stdout. The API key is never echoed anywhere.
set -o errexit
set -o nounset
set -o pipefail

_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
err() { printf '%s [ERROR] %s\n' "$(_ts)" "$*" >&2; }

command -v curl >/dev/null 2>&1 || { err "curl is required."; exit 1; }
command -v jq   >/dev/null 2>&1 || { err "jq is required.";   exit 1; }

query="$(cat)"
sync_id="$(printf '%s' "$query" | jq -r '.sync_id // empty')"
api_base="$(printf '%s' "$query" | jq -r '.api_base // empty')"
template_version="$(printf '%s' "$query" | jq -r '.template_version // "2026-08-13"')"

[ -n "$sync_id" ]  || { err "query is missing sync_id."; exit 1; }
[ -n "$api_base" ] || { err "query is missing api_base."; exit 1; }
[ -n "${CAPTAIN_API_KEY:-}" ] \
  || { err "CAPTAIN_API_KEY is not set. Export your Captain API key; it travels by env var so it stays out of Terraform state."; exit 1; }

url="${api_base%/}/v2/syncs/${sync_id}/webhooks"

tmp="$(mktemp)"
code="$(curl --silent --show-error --max-time 45 -X POST \
  -H "Content-Type: application/json" \
  -H "User-Agent: captain-b2-terraform/${template_version}" \
  -H "Authorization: Bearer ${CAPTAIN_API_KEY}" \
  --data '{}' -o "$tmp" -w '%{http_code}' "$url" || echo "000")"
body="$(cat "$tmp")"; rm -f "$tmp"

subscribe_url=""
if [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 300 ] 2>/dev/null; then
  subscribe_url="$(printf '%s' "$body" | jq -r '.subscribe_url // empty' 2>/dev/null || true)"
fi

if [ -z "$subscribe_url" ]; then
  err "Captain enrollment failed: POST ${url} returned HTTP ${code}."
  err "Response: $(printf '%s' "$body" | head -c 400)"
  err "Likely causes: wrong sync_id, an invalid or revoked Captain API key, or ${api_base} unreachable from this machine."
  exit 1
fi

# Flat string map for Terraform. instructions is flattened to one string.
printf '%s' "$body" | jq -c '{
  subscribe_url: .subscribe_url,
  secret_set:   ((.secret_set // false) | tostring),
  instructions: ((.instructions // []) | join(" | "))
}'
