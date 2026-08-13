#!/usr/bin/env bash
# =============================================================================
# Reverse setup.sh: remove the notification, subscription, topic, push SA, and
# the reader binding, then send Captain a best-effort teardown notice. Safe to
# run more than once (missing resources are skipped, not errors).
#
# Usage:
#   ./teardown.sh --project P --bucket B --sync-id sync_x \
#     --secret <the enrollment secret Captain minted for this sync> \
#     --reader-sa captain-reader@captain-prod.iam.gserviceaccount.com \
#     [--push-sa cap-push-xxx@P.iam.gserviceaccount.com] \
#     [--deployment-id dep_...] [--external-id ...] \
#     [--enroll-url https://api.runcaptain.com/v1/deploy/gcp/gcs/enroll] [--dry-run]
#
# --push-sa is optional: setup.sh derives the push SA id deterministically
# from --sync-id, so teardown.sh derives the same id when --push-sa is
# omitted rather than requiring the caller to remember it.
# =============================================================================
set -euo pipefail

TEMPLATE_VERSION="2026-08-12"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENROLL_SH="${HERE}/../terraform/enroll.sh"

log()  { printf '[captain-teardown %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
step() { printf '\n[captain-teardown %s] ==== %s ====\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
die()  { printf '[captain-teardown %s] ERROR %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; exit 1; }

# sha256_hex / push_sa_id_for_sync: KEPT IN SYNC with the identical functions
# in setup.sh so teardown.sh can find the push SA setup.sh created even when
# the caller does not pass --push-sa.
sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-64
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -c1-64
  else
    die "need sha256sum or shasum on PATH to derive the push service account id."
  fi
}
push_sa_id_for_sync() { printf 'cap-push-%s' "$(sha256_hex "$1" | cut -c1-16)"; }

PROJECT_ID=""; BUCKET_NAME=""; SYNC_ID=""; PUSH_SA_EMAIL=""; CAPTAIN_READER_SA=""
DEPLOYMENT_ID=""; EXTERNAL_ID="teardown-noop"; ENROLLMENT_SECRET=""; DRY_RUN="0"
CAPTAIN_ENROLL_URL="https://api.runcaptain.com/v1/deploy/gcp/gcs/enroll"
CAPTAIN_INGEST_URL="https://api.runcaptain.com/v1/deploy/gcp/gcs/ingest"

while [ $# -gt 0 ]; do
  case "$1" in
    --project)       PROJECT_ID="$2"; shift 2 ;;
    --bucket)        BUCKET_NAME="$2"; shift 2 ;;
    --sync-id)       SYNC_ID="$2"; shift 2 ;;
    --push-sa)       PUSH_SA_EMAIL="$2"; shift 2 ;;
    --reader-sa)     CAPTAIN_READER_SA="$2"; shift 2 ;;
    --deployment-id) DEPLOYMENT_ID="$2"; shift 2 ;;
    --external-id)   EXTERNAL_ID="$2"; shift 2 ;;
    --secret)        ENROLLMENT_SECRET="$2"; shift 2 ;;
    --enroll-url)    CAPTAIN_ENROLL_URL="$2"; shift 2 ;;
    --dry-run)       DRY_RUN="1"; shift ;;
    -h|--help)       grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

for bin in gcloud jq; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin not found on PATH. Install it and re-run."
done

: "${PROJECT_ID:?--project is required}"
: "${BUCKET_NAME:?--bucket is required}"
: "${SYNC_ID:?--sync-id is required}"
[ -z "$ENROLLMENT_SECRET" ] || [ "${#ENROLLMENT_SECRET}" -ge 16 ] \
  || die "--secret must be at least 16 characters (it is the same enrollment secret setup.sh used)."

# Derive the push SA id the same way setup.sh does, unless the caller already
# knows a different one. Keeps teardown effective even when --push-sa is
# omitted, instead of silently orphaning the SA setup.sh created.
[ -n "$PUSH_SA_EMAIL" ] || PUSH_SA_EMAIL="$(push_sa_id_for_sync "$SYNC_ID")@${PROJECT_ID}.iam.gserviceaccount.com"

TOPIC="captain-gcs-sync-${SYNC_ID}"
SUB="captain-gcs-push-${SYNC_ID}"
TOPIC_FQN="projects/${PROJECT_ID}/topics/${TOPIC}"
SUB_FQN="projects/${PROJECT_ID}/subscriptions/${SUB}"

TEARDOWN_HAD_FAILURE=0
# already_gone: case-insensitive match on the handful of phrases GCP uses for
# "the thing you tried to delete isn't there." Case-insensitive because the
# GCS JSON API (storage buckets notifications delete) reports failures in a
# different style ("HTTPError 404: Not Found") than the gRPC-status-style
# errors Pub/Sub and IAM give ("NOT_FOUND: ..."), and a plain-case substring
# match was missing the former.
already_gone() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    *not_found*|*"not found"*|*"does not exist"*|*"no such"*) return 0 ;;
    *) return 1 ;;
  esac
}
run() {
  log "+ $*"
  [ "$DRY_RUN" = "1" ] && return 0
  out="$("$@" 2>&1)" && return 0
  status=$?
  if already_gone "$out"; then
    log "  (already gone, ok) $out"
  else
    log "  FAILED (exit $status): $out"
    TEARDOWN_HAD_FAILURE=1
  fi
}

step "Bucket notification"
# Parse structured JSON, not the default YAML: in the default YAML the topic
# and id fields land on separate lines (nested under "Notification
# Configuration"), so a single grep+sed line-oriented extraction silently
# fails to find the id even when the topic line matches. jq walks the actual
# object instead of assuming an inline "topic ... id" layout.
#
# The list call itself is captured (not 2>/dev/null'd away) so a real failure
# here -- permission denied, wrong bucket, a transient API error -- is
# reported and counted as a teardown failure instead of silently defaulting
# NOTIF_ID to empty and logging "no notification, skipping" as if the lookup
# had succeeded and simply found nothing.
NOTIF_LIST_OUT="$(gcloud storage buckets notifications list "gs://${BUCKET_NAME}" --format=json 2>&1)" \
  && NOTIF_LIST_STATUS=0 || NOTIF_LIST_STATUS=$?
NOTIF_ID=""
if [ "$NOTIF_LIST_STATUS" -ne 0 ]; then
  if already_gone "$NOTIF_LIST_OUT"; then
    log "  (bucket already gone, ok) $NOTIF_LIST_OUT"
  else
    log "  FAILED (exit $NOTIF_LIST_STATUS) listing notifications on gs://${BUCKET_NAME}: $NOTIF_LIST_OUT"
    TEARDOWN_HAD_FAILURE=1
  fi
else
  NOTIF_ID="$(printf '%s' "$NOTIF_LIST_OUT" | jq -r --arg topic "/topics/${TOPIC}" '
      [.[]? | select((.["Notification Configuration"].topic // "") | endswith($topic))
             | .["Notification Configuration"].id][0] // empty
    ' 2>/dev/null || true)"
fi
if [ -n "$NOTIF_ID" ]; then
  run gcloud storage buckets notifications delete "gs://${BUCKET_NAME}/notificationConfigs/${NOTIF_ID}" --quiet
else
  log "no Captain notification for $TOPIC on the bucket; skipping"
fi

step "Push subscription"
run gcloud pubsub subscriptions delete "$SUB" --project="$PROJECT_ID" --quiet

step "Pub/Sub topic"
run gcloud pubsub topics delete "$TOPIC" --project="$PROJECT_ID" --quiet

step "Push service account"
run gcloud iam service-accounts delete "$PUSH_SA_EMAIL" --project="$PROJECT_ID" --quiet

step "Reader binding"
if [ -n "$CAPTAIN_READER_SA" ]; then
  run gcloud storage buckets remove-iam-policy-binding "gs://${BUCKET_NAME}" \
    --member="serviceAccount:${CAPTAIN_READER_SA}" --role="roles/storage.objectViewer"
else
  log "no --reader-sa given; skipping binding removal"
fi

step "Best-effort teardown notice to Captain"
# Authenticated the same way the Terraform destroy path is: the real
# enrollment secret, not a placeholder. enroll.sh treats create and delete
# identically here (it only relaxes the RESPONSE requirements for delete), so
# a fake secret would either be silently accepted by a lenient backend (a
# spoofable teardown notice) or rejected outright -- neither is the contract
# Terraform's destroy path uses. Skip the notice rather than send either.
if [ "$DRY_RUN" = "1" ]; then
  log "dry-run: skipping teardown notice"
elif [ -z "$ENROLLMENT_SECRET" ]; then
  log "no --secret given; skipping teardown notice rather than send it unauthenticated (Captain reconciles orphans)."
elif [ -f "$ENROLL_SH" ] && [ -n "$DEPLOYMENT_ID" ]; then
  CAPTAIN_ENROLL_URL="$CAPTAIN_ENROLL_URL" ACTION="delete" \
  DEPLOYMENT_ID="$DEPLOYMENT_ID" TEMPLATE_VERSION="$TEMPLATE_VERSION" \
  SYNC_ID="$SYNC_ID" EXTERNAL_ID="$EXTERNAL_ID" PROJECT_ID="$PROJECT_ID" \
  BUCKET_NAME="$BUCKET_NAME" PUBSUB_TOPIC="$TOPIC_FQN" PUBSUB_SUBSCRIPTION="$SUB_FQN" \
  PUSH_SERVICE_ACCOUNT="${PUSH_SA_EMAIL:-none}" READER_SERVICE_ACCOUNT="${CAPTAIN_READER_SA:-none}" \
  INGEST_URL="$CAPTAIN_INGEST_URL" OIDC_AUDIENCE="$CAPTAIN_INGEST_URL" \
  ENROLLMENT_SECRET="$ENROLLMENT_SECRET" \
    bash "$ENROLL_SH" delete || log "teardown notice failed; tolerated (Captain reconciles orphans)."
else
  log "no --deployment-id or enroll.sh missing; skipping notice (Captain reconciles orphans)."
fi

# Check TEARDOWN_HAD_FAILURE before the --dry-run early return: a dry run
# still makes real read calls (e.g. the notification list above), and a
# genuine failure there (permission denied, wrong bucket, transient API
# error) must still surface as a non-zero exit even though --dry-run deleted
# nothing. Checking DRY_RUN first would let that failure get swallowed by
# the "nothing was deleted, exit 0" path, which is exactly the "dry-run
# reports success when it should not" bug this template has hit before.
if [ "$TEARDOWN_HAD_FAILURE" = "1" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    step "Dry run found errors. Nothing was deleted, but see FAILED lines above -- a real run would likely hit the same failures."
  else
    step "Done with errors. Some resources for ${SYNC_ID} may still exist, see FAILED lines above."
  fi
  exit 1
fi
if [ "$DRY_RUN" = "1" ]; then
  step "Dry run only. Nothing was deleted and no teardown notice was sent."
  exit 0
fi
step "Done. Captain GCS sync resources for ${SYNC_ID} removed."
