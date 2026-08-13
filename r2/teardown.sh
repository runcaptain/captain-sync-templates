#!/usr/bin/env bash
# =============================================================================
# Captain R2 sync: teardown (Wrangler path)
# -----------------------------------------------------------------------------
# Undoes what deploy.sh created, in an order safe to interrupt and re-run:
#   1. R2 event notification rule   (stop new events first)
#   2. CAPTAIN_SECRET                (explicit, belt-and-suspenders; also
#                                      goes away with the Worker in step 4)
#   3. Queue consumer binding        (detach the Worker from the queue)
#   4. The consumer Worker itself
#   5. The events queue + dead-letter queue
#
# The R2 bucket itself is NEVER touched: this stack does not create it, so
# teardown does not delete it either.
#
# Every step tolerates "already gone" (not-found errors are swallowed) so a
# partial or repeated teardown is safe.
#
# Usage: same identifying env vars as deploy.sh.
#   export CLOUDFLARE_ACCOUNT_ID=<your account id>   # `wrangler whoami`
#   export BUCKET_NAME=<the bucket you deployed against>
#   # optional, only if you overrode them at deploy time:
#   export WORKER_NAME=captain-r2-sync  QUEUE_NAME=captain-r2-sync
#   ./teardown.sh
# =============================================================================
set -euo pipefail

log()  { printf '\033[1;34m[captain]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[captain][warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[captain][error]\033[0m %s\n' "$*" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$HERE/worker"

WORKER_NAME="${WORKER_NAME:-captain-r2-sync}"
QUEUE_NAME="${QUEUE_NAME:-captain-r2-sync}"
DLQ_NAME="${QUEUE_NAME}-dlq"

command -v npx  >/dev/null || die "npx is not installed (comes with npm). Install Node 18+ and retry."
: "${BUCKET_NAME:?Set BUCKET_NAME (the bucket you deployed against).}"

log "Checking wrangler auth..."
npx --yes wrangler whoami >/dev/null 2>&1 || die "wrangler is not authenticated. Run \`wrangler login\` or set CLOUDFLARE_API_TOKEN."

# Reuse the per-sync config deploy.sh generated, so we target the exact same
# Worker/queue names it deployed. Regenerate it if it is gone (e.g. a fresh
# checkout) using the same substitutions deploy.sh uses.
GEN="$WORKER_DIR/wrangler.generated.jsonc"
if [[ -f "$GEN" ]]; then
  log "Reusing $GEN from the original deploy."
else
  : "${CLOUDFLARE_ACCOUNT_ID:?Set CLOUDFLARE_ACCOUNT_ID (see \`wrangler whoami\`); no wrangler.generated.jsonc was found to reuse.}"
  log "No wrangler.generated.jsonc found; regenerating one for $WORKER_NAME / $QUEUE_NAME."
  sed \
    -e "s|replace-with-your-bucket|$BUCKET_NAME|g" \
    -e "s|sync_replaceme|${SYNC_ID:-sync_unknown}|g" \
    -e "s|\"captain-r2-sync\"|\"$WORKER_NAME\"|" \
    -e "s|captain-r2-sync-dlq|$DLQ_NAME|g" \
    -e "s|\"queue\": \"captain-r2-sync\"|\"queue\": \"$QUEUE_NAME\"|g" \
    -e "s|\"ACCOUNT_ID\": \"\"|\"ACCOUNT_ID\": \"$CLOUDFLARE_ACCOUNT_ID\"|" \
    "$WORKER_DIR/wrangler.jsonc" > "$GEN"
fi

WR() { ( cd "$WORKER_DIR" && npx --yes wrangler "$@" -c "$GEN" ); }

# Runs a wrangler subcommand and treats it as fatal ONLY when wrangler's REAL
# exit code is non-zero AND the output does not match an expected
# idempotent-ok pattern (here: an "already gone" phrasing for a delete). The
# exit code is read straight off the command substitution, no pipe involved,
# so a genuine failure (auth expiry, permission denial, rate limit, network
# blip) can never be masked by a downstream grep. The grep below is purely
# cosmetic, to hide the noisy "already gone" line from what gets echoed; it
# is never the source of truth for success or failure.
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
# 1. R2 EVENT NOTIFICATION: stop new events before touching the queue/Worker.
# =============================================================================
log "Deleting R2 event notification rule on $BUCKET_NAME -> $QUEUE_NAME (ok if already gone)..."
run_step "Deleting R2 event notification rule on $BUCKET_NAME" "not found|does not exist|no.*rule" \
  WR r2 bucket notification delete "$BUCKET_NAME" --queue "$QUEUE_NAME"

# =============================================================================
# 2. SECRET: delete explicitly for a clean record of intent.
# =============================================================================
log "Deleting CAPTAIN_SECRET from $WORKER_NAME (ok if already gone)..."
run_step "Deleting CAPTAIN_SECRET from $WORKER_NAME" "not found|does not exist" \
  WR secret delete CAPTAIN_SECRET --name "$WORKER_NAME"

# =============================================================================
# 3 + 4. QUEUE CONSUMER + WORKER: detach, then delete the script.
# =============================================================================
log "Removing $WORKER_NAME as a consumer of $QUEUE_NAME (ok if already gone)..."
run_step "Removing $WORKER_NAME as a consumer of $QUEUE_NAME" "not found|does not exist|no worker consumer.*exists" \
  WR queues consumer remove "$QUEUE_NAME" "$WORKER_NAME"

log "Deleting Worker $WORKER_NAME (ok if already gone)..."
run_step "Deleting Worker $WORKER_NAME" "not found|does not exist" \
  WR delete "$WORKER_NAME" --force

# =============================================================================
# 5. QUEUES: main + dead-letter, last (a queue with a live consumer or
#    in-flight messages can refuse to delete out of order).
# =============================================================================
log "Deleting queue $QUEUE_NAME (ok if already gone)..."
run_step "Deleting queue $QUEUE_NAME" "not found|does not exist" \
  WR queues delete "$QUEUE_NAME"
log "Deleting dead-letter queue $DLQ_NAME (ok if already gone)..."
run_step "Deleting dead-letter queue $DLQ_NAME" "not found|does not exist" \
  WR queues delete "$DLQ_NAME"

log "Done. Torn down: event notification, secret, queue consumer, Worker $WORKER_NAME, queues $QUEUE_NAME + $DLQ_NAME."
echo "  - R2 bucket $BUCKET_NAME was NOT touched (this stack never created it)."
echo "  - If this sync should also stop reconciling in Captain, delete it there too (captain_delete_sync / dashboard)."
