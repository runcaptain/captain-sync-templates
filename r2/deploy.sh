#!/usr/bin/env bash
# =============================================================================
# Captain R2 sync: one-command deploy (Wrangler path)
# -----------------------------------------------------------------------------
# Cloudflare has no "Launch Stack" button, so this script IS the one-click
# equivalent. It:
#   1. Preflights your tools and inputs (fails early with a clear message).
#   2. Subscribes this sync's webhook with Captain
#      (POST {CAPTAIN_API_BASE}/v2/syncs/{SYNC_ID}/webhooks). Captain mints the
#      per-sync subscribe_url the Worker will forward events to. A 2xx with a
#      subscribe_url IS confirmed enrollment; anything else FAILS LOUDLY before
#      any Cloudflare resource is created.
#   3. Creates the events queue + dead-letter queue.
#   4. Deploys the consumer Worker (queue drain + keyless read proxy), wired to
#      the minted subscribe_url.
#   5. Sets the shared secret.
#   6. Wires R2 event notifications on your bucket -> the queue.
#   7. Self-tests the event path end to end.
#
# Reconcile/polling is the always-on backstop; the queue path is the latency win.
#
# Usage:
#   export CLOUDFLARE_ACCOUNT_ID=<your account id>   # `wrangler whoami`
#   export SYNC_ID=sync_xxx                          # your Captain sync id
#   export BUCKET_NAME=<your-r2-bucket>
#   export CAPTAIN_API_KEY=<your Captain API key>    # authenticates the webhook subscribe
#   export CAPTAIN_SECRET=<16+ char shared secret>   # you choose it; guards the Worker read proxy
#   # optional overrides:
#   export CAPTAIN_API_BASE=https://api.captain.dev  # override for staging only
#   export CAPTAIN_INGEST_URL=...  # reuse an already-minted subscribe_url (skips the subscribe call)
#   export WORKER_NAME=captain-r2-sync  QUEUE_NAME=captain-r2-sync
#   export PREFIX=docs/            # only watch keys under this prefix
#   export DEBUG=true             # verbose Worker logs
#   ./deploy.sh
# =============================================================================
set -euo pipefail

log()  { printf '\033[1;34m[captain]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[captain][warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[captain][error]\033[0m %s\n' "$*" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$HERE/worker"

# --- defaults ---
WORKER_NAME="${WORKER_NAME:-captain-r2-sync}"
QUEUE_NAME="${QUEUE_NAME:-captain-r2-sync}"
DLQ_NAME="${QUEUE_NAME}-dlq"
CAPTAIN_API_BASE="${CAPTAIN_API_BASE:-https://api.captain.dev}"
# CAPTAIN_INGEST_URL has NO default on purpose: it is the per-sync subscribe_url
# Captain mints in step 2 below. Setting it up front only makes sense to reuse a
# subscribe_url from an earlier run.
CAPTAIN_INGEST_URL="${CAPTAIN_INGEST_URL:-}"
PREFIX="${PREFIX:-}"
DEBUG="${DEBUG:-false}"

# =============================================================================
# 1. PREFLIGHT
# =============================================================================
log "Preflight checks..."
command -v node >/dev/null    || die "node is not installed. Install Node 18+ and retry."
command -v npx  >/dev/null    || die "npx is not installed (comes with npm). Install Node 18+ and retry."
command -v jq   >/dev/null    || die "jq is not installed. brew install jq (or apt-get install jq)."
command -v curl >/dev/null    || die "curl is not installed."

: "${CLOUDFLARE_ACCOUNT_ID:?Set CLOUDFLARE_ACCOUNT_ID (see \`wrangler whoami\`).}"
: "${SYNC_ID:?Set SYNC_ID (sync_... from Captain).}"
: "${BUCKET_NAME:?Set BUCKET_NAME (your existing R2 bucket).}"
: "${CAPTAIN_API_KEY:?Set CAPTAIN_API_KEY (your Captain API key; authenticates the webhook subscribe).}"
: "${CAPTAIN_SECRET:?Set CAPTAIN_SECRET (16+ char shared secret YOU choose; it guards the Worker read proxy).}"

[[ "$SYNC_ID" =~ ^sync_[A-Za-z0-9]+$ ]] || die "SYNC_ID must look like sync_<token>, got: $SYNC_ID"
[[ "${#CAPTAIN_SECRET}" -ge 16 ]]        || die "CAPTAIN_SECRET must be at least 16 characters."
[[ "$BUCKET_NAME" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || die "BUCKET_NAME is not a valid R2 bucket name: $BUCKET_NAME"

log "Checking wrangler auth..."
npx --yes wrangler whoami >/dev/null 2>&1 || die "wrangler is not authenticated. Run \`wrangler login\` or set CLOUDFLARE_API_TOKEN."

log "Installing Worker dependencies..."
( cd "$WORKER_DIR" && npm install --no-audit --no-fund >/dev/null 2>&1 ) || die "npm install failed in $WORKER_DIR"

# =============================================================================
# 2. ENROLL: subscribe this sync's webhook with Captain
# -----------------------------------------------------------------------------
# POST {CAPTAIN_API_BASE}/v2/syncs/{SYNC_ID}/webhooks with a Bearer API key and
# an empty JSON body. Captain answers 2xx with the per-sync subscribe_url it
# minted; that URL becomes CAPTAIN_INGEST_URL, the target the Worker forwards
# events to. A 2xx with a subscribe_url IS successful enrollment. Runs BEFORE
# any Cloudflare resource is touched so a bad sync id or API key fails early.
# =============================================================================
if [[ -n "$CAPTAIN_INGEST_URL" ]]; then
  log "CAPTAIN_INGEST_URL provided; reusing the already-minted subscribe_url and skipping the subscribe call."
else
  SUBSCRIBE_ENDPOINT="$CAPTAIN_API_BASE/v2/syncs/$SYNC_ID/webhooks"
  log "Subscribing sync $SYNC_ID with Captain: POST $SUBSCRIBE_ENDPOINT ..."
  SUB_STATUS="000"
  SUB_BODY=""
  for attempt in 1 2 3; do
    RESP="$(curl -sS -w '\n%{http_code}' -X POST "$SUBSCRIBE_ENDPOINT" \
              -H "Authorization: Bearer $CAPTAIN_API_KEY" \
              -H "content-type: application/json" \
              -d '{}' 2>/dev/null || true)"
    SUB_STATUS="$(printf '%s\n' "$RESP" | tail -n1)"
    SUB_BODY="$(printf '%s\n' "$RESP" | sed '$d')"
    if [[ "$SUB_STATUS" == "000" || "$SUB_STATUS" =~ ^5 ]] && [[ "$attempt" -lt 3 ]]; then
      warn "Subscribe attempt $attempt/3 got HTTP $SUB_STATUS; retrying in 2s..."
      sleep 2
      continue
    fi
    break
  done

  if [[ "$SUB_STATUS" == "000" ]]; then
    die "Could not reach Captain at $SUBSCRIBE_ENDPOINT (connection failed). Check CAPTAIN_API_BASE and your network, then re-run."
  fi
  if [[ ! "$SUB_STATUS" =~ ^2 ]]; then
    echo "$SUB_BODY" | jq . 2>/dev/null || echo "$SUB_BODY"
    die "Captain returned HTTP $SUB_STATUS for the webhook subscribe (body printed above). Check SYNC_ID and CAPTAIN_API_KEY, then re-run. Nothing was created yet."
  fi

  CAPTAIN_INGEST_URL="$(printf '%s' "$SUB_BODY" | jq -r '.subscribe_url // empty' 2>/dev/null || true)"
  if [[ -z "$CAPTAIN_INGEST_URL" ]]; then
    echo "$SUB_BODY" | jq . 2>/dev/null || echo "$SUB_BODY"
    die "Captain returned HTTP $SUB_STATUS but no subscribe_url in the body (printed above). Cannot wire the Worker without it."
  fi

  log "Enrolled. Captain minted subscribe_url: $CAPTAIN_INGEST_URL"
  SECRET_SET="$(printf '%s' "$SUB_BODY" | jq -r '.secret_set // false' 2>/dev/null || echo false)"
  if [[ "$SECRET_SET" != "true" ]]; then
    warn "Captain reports secret_set=false for this sync's webhook. Events still flow; set the webhook secret on your Captain sync if you want signed deliveries."
  fi
  # Captain may include next-step instructions in the response; show them.
  printf '%s' "$SUB_BODY" | jq -r '.instructions[]? | "  - \(.)"' 2>/dev/null || true
fi

# =============================================================================
# 3. GENERATE a per-sync wrangler config from the committed template
# =============================================================================
GEN="$WORKER_DIR/wrangler.generated.jsonc"
log "Generating $GEN for sync $SYNC_ID ..."
sed \
  -e "s|replace-with-your-bucket|$BUCKET_NAME|g" \
  -e "s|sync_replaceme|$SYNC_ID|g" \
  -e "s|\"captain-r2-sync\"|\"$WORKER_NAME\"|" \
  -e "s|captain-r2-sync-dlq|$DLQ_NAME|g" \
  -e "s|\"queue\": \"captain-r2-sync\"|\"queue\": \"$QUEUE_NAME\"|g" \
  -e "s|\"ACCOUNT_ID\": \"\"|\"ACCOUNT_ID\": \"$CLOUDFLARE_ACCOUNT_ID\"|" \
  -e "s|\"CAPTAIN_INGEST_URL\": \"\"|\"CAPTAIN_INGEST_URL\": \"$CAPTAIN_INGEST_URL\"|" \
  -e "s|\"DEBUG\": \"false\"|\"DEBUG\": \"$DEBUG\"|" \
  "$WORKER_DIR/wrangler.jsonc" > "$GEN"

WR() { ( cd "$WORKER_DIR" && npx --yes wrangler "$@" -c "$GEN" ); }

# Runs a wrangler subcommand and treats it as fatal ONLY when wrangler's REAL
# exit code is non-zero AND the output does not match an expected
# idempotent-ok pattern (e.g. "already exists" on a create). The exit code
# is read straight off the command substitution, no pipe involved, so a
# genuine failure (auth expiry, permission denial, rate limit, invalid
# name, network blip) can never be masked by a downstream grep. The grep
# below is purely cosmetic, to hide the noisy idempotent line from what
# gets echoed; it is never the source of truth for success or failure.
run_step() {
  local desc="$1" ok_pattern="$2"
  shift 2
  local out status
  # Must be `if out="$(...)"; then ... else ... fi`, not a bare `out="$(...)"`
  # followed by `status=$?`. Under `set -e`, a bare assignment's command
  # substitution is NOT exempt from errexit: a non-zero exit there kills the
  # whole script immediately, before `status=$?` or the ok_pattern check ever
  # run. Command substitution used as the condition of an `if` IS exempt.
  # Verified directly against a `false`-returning repro under set -euo
  # pipefail before relying on it here.
  if out="$("$@" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  if [[ $status -ne 0 ]] && ! grep -qiE "$ok_pattern" <<<"$out"; then
    [[ -n "$out" ]] && echo "$out"
    die "$desc failed (wrangler exited $status)."
  fi
  if [[ -n "$out" ]]; then
    grep -viE "$ok_pattern" <<<"$out" || true
  fi
  return 0
}

# =============================================================================
# 4. QUEUES (idempotent)
# =============================================================================
log "Creating queue $QUEUE_NAME (ok if it already exists)..."
run_step "Creating queue $QUEUE_NAME" "already exists|already taken" WR queues create "$QUEUE_NAME"
log "Creating dead-letter queue $DLQ_NAME (ok if it already exists)..."
run_step "Creating dead-letter queue $DLQ_NAME" "already exists|already taken" WR queues create "$DLQ_NAME"

# =============================================================================
# 5. DEPLOY the Worker + set the secret
# =============================================================================
log "Deploying Worker $WORKER_NAME ..."
DEPLOY_OUT="$(WR deploy 2>&1)" || { echo "$DEPLOY_OUT"; die "wrangler deploy failed."; }
echo "$DEPLOY_OUT"
WORKER_URL="$(printf '%s\n' "$DEPLOY_OUT" | grep -oE 'https://[a-zA-Z0-9._-]+\.workers\.dev' | head -1 || true)"
[[ -n "$WORKER_URL" ]] || warn "Could not parse the workers.dev URL from deploy output; enable it in the dashboard if the health check below fails."

log "Setting CAPTAIN_SECRET..."
printf '%s' "$CAPTAIN_SECRET" | WR secret put CAPTAIN_SECRET >/dev/null 2>&1 || die "Failed to set CAPTAIN_SECRET."

# =============================================================================
# 6. R2 EVENT NOTIFICATIONS -> queue
# =============================================================================
log "Wiring R2 event notifications on $BUCKET_NAME -> $QUEUE_NAME ..."
NOTIF_ARGS=(r2 bucket notification create "$BUCKET_NAME" --queue "$QUEUE_NAME" --event-types object-create object-delete)
[[ -n "$PREFIX" ]] && NOTIF_ARGS+=(--prefix "$PREFIX")
# Cloudflare's real error text for "a notification rule already covers this
# bucket+queue" is a rule-conflict/overlap message (code 11020), not the
# words "already exists" -- confirmed live. Match that, not a guess.
run_step "Wiring R2 event notifications on $BUCKET_NAME" "already exists|already taken|rule conflict|invalid overlap" WR "${NOTIF_ARGS[@]}"
log "Step 7 below self-tests real event delivery in your account; scheduled reconcile is the backstop either way."

# =============================================================================
# 7. VERIFY the read proxy + self-test the event path
# =============================================================================
if [[ -n "$WORKER_URL" ]]; then
  # A Worker secret update is not instantly global: `wrangler secret put` in
  # step 5 can leave some edge PoPs still serving the old (or no) secret for a
  # few seconds. Poll an authorized route with the new secret, bounded to
  # ~15s, so Captain's first read-proxy call does not hit propagation lag.
  log "Waiting for CAPTAIN_SECRET to be live at the edge (up to 15s)..."
  SECRET_LIVE=false
  DEADLINE=$((SECONDS + 15))
  while (( SECONDS < DEADLINE )); do
    PROBE_CODE="$(curl -sS -o /dev/null -w '%{http_code}' "$WORKER_URL/__captain/objects?limit=1" \
                    -H "Authorization: Bearer $CAPTAIN_SECRET" 2>/dev/null || echo 000)"
    if [[ "$PROBE_CODE" != "401" && "$PROBE_CODE" != "000" ]]; then
      SECRET_LIVE=true
      break
    fi
    sleep 1
  done
  if [[ "$SECRET_LIVE" == "true" ]]; then
    log "CAPTAIN_SECRET confirmed live; the read proxy answers with it."
  else
    warn "CAPTAIN_SECRET still not reading back as live after 15s; usually just propagation lag. Re-probe with: curl $WORKER_URL/__captain/objects?limit=1 -H 'Authorization: Bearer \$CAPTAIN_SECRET'"
  fi

  log "Self-testing the R2 -> Queue -> Worker event path (writes + deletes a canary)..."
  ST="$(curl -sS -X POST "$WORKER_URL/__captain/selftest" -H "Authorization: Bearer $CAPTAIN_SECRET" 2>/dev/null || true)"
  echo "$ST" | jq . 2>/dev/null || echo "$ST"
  log "Watch: run \`cd worker && npx wrangler tail -c wrangler.generated.jsonc\` and look for a queue batch with the canary key within ~30s."
else
  warn "No workers.dev URL was parsed from the deploy output. Enable the workers.dev subdomain in the dashboard so Captain can reach the read proxy, then re-run ./deploy.sh (idempotent)."
fi

log "Done. Sync $SYNC_ID is enrolled; the Worker forwards events to Captain's minted subscribe_url."
echo "  - Open your Captain dashboard for sync $SYNC_ID; a reconcile of $BUCKET_NAME runs now."
echo "  - Future object changes sync near-real-time via the queue."
echo "  - Debug logs: cd worker && npx wrangler tail -c wrangler.generated.jsonc"
echo "  - To tear this down later: ./teardown.sh (same env vars as this script)."
