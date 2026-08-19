#!/usr/bin/env bash
# =============================================================================
# Captain GCS one-click sync (self-verifying), gcloud edition.
#
# Does exactly what the Terraform module does, imperatively, for people who would
# rather run a script than manage Terraform state:
#   1. Pub/Sub topic + let this project's GCS service agent publish to it.
#   2. GCS object-change notification on your EXISTING bucket -> that topic.
#   3. A dedicated push service account + a push subscription that delivers to
#      your sync's Captain ingest URL with a Google-signed OIDC token (no keys).
#   4. roles/storage.objectViewer for Captain's OWN service account on the bucket.
#   5. A final ENROLLMENT call to the Captain API
#      (POST /v2/syncs/<sync-id>/webhooks): it exits non-zero unless Captain
#      answers 2xx with the sync's subscribe_url. A clean run means Captain has
#      this webhook on file, not just that the GCP resources went green.
#
# Every step logs what it is doing and every id it creates. Re-running is safe:
# existing resources are detected and reused (idempotent).
#
# Usage:
#   export CAPTAIN_API_KEY=<your Captain API key>   # preferred over --api-key
#   ./setup.sh \
#     --project my-gcp-project \
#     --bucket my-existing-bucket \
#     --sync-id sync_abc123 \
#     --ingest-url <the subscribe_url Captain minted for this sync> \
#     --reader-sa captain-reader@captain-prod.iam.gserviceaccount.com \
#     [--api-key <key>] \
#     [--api-base https://api.captain.dev] \
#     [--oidc-audience <aud>] \
#     [--event-types OBJECT_FINALIZE,OBJECT_DELETE,OBJECT_METADATA_UPDATE,OBJECT_ARCHIVE] \
#     [--object-prefix ""] \
#     [--dry-run]
#
# --ingest-url is the subscribe_url that POST /v2/syncs/<sync-id>/webhooks
# returns; Captain pre-fills it when it generates this command for your sync.
# There is no default: every sync gets its own minted URL. See
# https://docs.captain.dev/guides/sync/set-up if you do not have yours.
#
# Captain normally generates this exact command for you per-sync with every
# value pre-filled.
# =============================================================================
set -euo pipefail

TEMPLATE_VERSION="2026-08-13"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENROLL_SH="${HERE}/../terraform/enroll.sh" # single source of truth for the enrollment call

# ---- logging -----------------------------------------------------------------
log()   { printf '[captain-setup %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
step()  { printf '\n[captain-setup %s] ==== %s ====\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
die()   { printf '[captain-setup %s] ERROR %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; exit 1; }

# ---- defaults / args ---------------------------------------------------------
PROJECT_ID=""; BUCKET_NAME=""; SYNC_ID=""
CAPTAIN_READER_SA=""
CAPTAIN_INGEST_URL=""                                # required; no default (per-sync minted URL)
CAPTAIN_API_BASE="https://api.captain.dev"           # override only for staging
CAPTAIN_API_KEY="${CAPTAIN_API_KEY:-}"               # env preferred; --api-key accepted
OIDC_AUDIENCE=""
EVENT_TYPES="OBJECT_FINALIZE,OBJECT_DELETE,OBJECT_METADATA_UPDATE,OBJECT_ARCHIVE"
OBJECT_PREFIX=""
DRY_RUN="0"

while [ $# -gt 0 ]; do
  case "$1" in
    --project)        PROJECT_ID="$2"; shift 2 ;;
    --bucket)         BUCKET_NAME="$2"; shift 2 ;;
    --sync-id)        SYNC_ID="$2"; shift 2 ;;
    --reader-sa)      CAPTAIN_READER_SA="$2"; shift 2 ;;
    --ingest-url)     CAPTAIN_INGEST_URL="$2"; shift 2 ;;
    --api-base)       CAPTAIN_API_BASE="$2"; shift 2 ;;
    --api-key)        CAPTAIN_API_KEY="$2"; shift 2 ;;
    --oidc-audience)  OIDC_AUDIENCE="$2"; shift 2 ;;
    --event-types)    EVENT_TYPES="$2"; shift 2 ;;
    --object-prefix)  OBJECT_PREFIX="$2"; shift 2 ;;
    --dry-run)        DRY_RUN="1"; shift ;;
    -h|--help)        grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

run() {
  # Log the command, then run it (or just log it under --dry-run).
  log "+ $*"
  if [ "$DRY_RUN" = "1" ]; then return 0; fi
  "$@"
}

# ---- preflight ---------------------------------------------------------------
step "Preflight checks"
for bin in gcloud jq curl; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin not found on PATH. Install it and re-run."
done
[ -f "$ENROLL_SH" ] || die "enrollment script not found at $ENROLL_SH (run this from the repo so the terraform/ sibling is present)."

: "${PROJECT_ID:?--project is required}"
: "${BUCKET_NAME:?--bucket is required}"
: "${SYNC_ID:?--sync-id is required}"
: "${CAPTAIN_READER_SA:?--reader-sa is required}"
[ -n "$CAPTAIN_INGEST_URL" ] \
  || die "--ingest-url is required. It is the subscribe_url Captain minted for this sync (Captain pre-fills it in your generated command; see https://docs.captain.dev/guides/sync/set-up)."
[ -n "$CAPTAIN_API_KEY" ] \
  || die "no Captain API key. Export CAPTAIN_API_KEY (preferred, keeps it out of shell history) or pass --api-key."

echo "$SYNC_ID" | grep -Eq '^sync_[A-Za-z0-9]+$' || die "--sync-id must look like sync_<token>. Got: $SYNC_ID"
echo "$CAPTAIN_READER_SA" | grep -Eq '\.iam\.gserviceaccount\.com$' || die "--reader-sa must be a Google service account email."
case "$CAPTAIN_INGEST_URL" in https://*) : ;; *) die "--ingest-url must be https://" ;; esac
case "$CAPTAIN_API_BASE" in https://*) : ;; *) die "--api-base must be https:// (refusing to send the API key over plaintext)" ;; esac

ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1 || true)"
[ -n "$ACTIVE_ACCOUNT" ] || die "no active gcloud credential. Run: gcloud auth login"
log "active gcloud account: $ACTIVE_ACCOUNT"

gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1 || die "cannot see project '$PROJECT_ID' (wrong id, or your account lacks access)."
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
log "project '$PROJECT_ID' number=$PROJECT_NUMBER"

# ---- derive ids --------------------------------------------------------------
# The { ... } || true wrapper matters under this script's own "set -euo
# pipefail": head -c exits after it has read enough bytes and closes its end
# of the pipe, so tr gets SIGPIPE on its next write and the pipeline's exit
# status becomes 141 (the rightmost non-zero status in the pipe under
# pipefail, even though head itself exited 0). Without the wrapper that 141
# trips "set -e" and kills the whole script on every single invocation,
# including --dry-run, before it reaches "Enabling required APIs". The
# wrapper catches that specific benign SIGPIPE without hiding a real failure:
# if /dev/urandom or tr itself is missing, "$1" is empty or short and
# downstream id validation (or gcloud) will still fail loudly.
rand() { { LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c "$1"; } || true; }

# sha256_hex: portable sha256 (Cloud Shell/Linux has sha256sum; macOS has shasum).
sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-64
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -c1-64
  else
    die "need sha256sum or shasum on PATH to derive the push service account id."
  fi
}

# push_sa_id_for_sync: deterministic push-SA id from sync_id alone, so setup.sh
# is genuinely idempotent (a re-run reuses the SA instead of creating a new one
# and orphaning the old one) and teardown.sh can find the same SA without being
# told its id. gcloud service-account ids must be 6-30 chars, lowercase
# letters/digits/hyphens, starting with a letter; sha256 hex is already in that
# alphabet. KEEP THIS IN SYNC with the identical function in teardown.sh.
push_sa_id_for_sync() { printf 'cap-push-%s' "$(sha256_hex "$1" | cut -c1-16)"; }

TOPIC="captain-gcs-sync-${SYNC_ID}"
SUB="captain-gcs-push-${SYNC_ID}"
# GCP label VALUES must be lowercase; sync_id may contain uppercase
# (^sync_[A-Za-z0-9]+$), which would make `--labels=captain-sync-id=<sync_id>`
# invalid and fail topic/subscription creation. Lowercase it for the label only;
# the exact sync id still lives in the resource names and custom-attributes.
SYNC_ID_LABEL="$(printf '%s' "$SYNC_ID" | tr '[:upper:]' '[:lower:]')"
PUSH_SA_ID="$(push_sa_id_for_sync "$SYNC_ID")"
PUSH_SA_EMAIL="${PUSH_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
DEPLOYMENT_ID="dep_$(rand 24)"
TOPIC_FQN="projects/${PROJECT_ID}/topics/${TOPIC}"
SUB_FQN="projects/${PROJECT_ID}/subscriptions/${SUB}"
GCS_AGENT="$(gcloud storage service-agent --project="$PROJECT_ID" 2>/dev/null || true)"
[ -n "$GCS_AGENT" ] || die "could not resolve the GCS service agent for $PROJECT_ID (is the storage API enabled?)."
PUBSUB_AGENT="service-${PROJECT_NUMBER}@gcp-sa-pubsub.iam.gserviceaccount.com"
# The push endpoint is the minted subscribe_url exactly as Captain returned it.
# Nothing is appended: the URL already identifies the sync.
PUSH_ENDPOINT="$CAPTAIN_INGEST_URL"
EFFECTIVE_AUDIENCE="${OIDC_AUDIENCE:-$CAPTAIN_INGEST_URL}"

log "deploymentId=$DEPLOYMENT_ID topic=$TOPIC sub=$SUB pushSA=$PUSH_SA_EMAIL"
log "gcsAgent=$GCS_AGENT pubsubAgent=$PUBSUB_AGENT readerSA=$CAPTAIN_READER_SA"

# ---- 0. enable APIs + materialize the Pub/Sub service agent ------------------
step "Enabling required APIs (pubsub, storage)"
run gcloud services enable pubsub.googleapis.com storage.googleapis.com --project="$PROJECT_ID"
# Force-create the Pub/Sub service agent so the token-creator binding below works
# even on a brand new project (best-effort; ignored if it already exists).
run gcloud beta services identity create --service=pubsub.googleapis.com --project="$PROJECT_ID" || true

# ---- 1. topic + publisher grant ----------------------------------------------
step "Pub/Sub topic"
if gcloud pubsub topics describe "$TOPIC" --project="$PROJECT_ID" >/dev/null 2>&1; then
  log "topic $TOPIC already exists, reusing"
else
  run gcloud pubsub topics create "$TOPIC" --project="$PROJECT_ID" \
    --labels="captain-sync-id=${SYNC_ID_LABEL},captain-managed-by=gcloud"
fi
step "Let the GCS service agent publish to the topic"
run gcloud pubsub topics add-iam-policy-binding "$TOPIC" --project="$PROJECT_ID" \
  --member="serviceAccount:${GCS_AGENT}" --role="roles/pubsub.publisher" --quiet

# ---- 2. bucket notification (additive; does not clobber existing ones) --------
step "GCS notification on gs://${BUCKET_NAME}"
# Parse structured JSON and match the topic field with endswith, not a
# grep -F substring scan of the default YAML/text listing. grep -F "$TOPIC"
# would false-positive whenever an existing notification's topic name has
# $TOPIC as a PREFIX (e.g. an existing notification for
# captain-gcs-sync-sync_abcxyz false-matches a new sync's
# captain-gcs-sync-sync_abc), which would skip creating the new notification
# entirely while the script still reports success. Same jq + endswith
# pattern already used in teardown.sh, kept in sync with it.
#
# The list call is captured, not 2>/dev/null'd away: if it fails for a real
# reason (permission denied, wrong bucket, a transient API error) that must
# not be read as "no existing notification, go ahead and create one" -- it
# could double up a notification the lookup just failed to see, or paper
# over a permissions problem the enrollment call would otherwise catch far
# later.
NOTIF_LIST_OUT="$(gcloud storage buckets notifications list "gs://${BUCKET_NAME}" --format=json 2>&1)" \
  && NOTIF_LIST_STATUS=0 || NOTIF_LIST_STATUS=$?
[ "$NOTIF_LIST_STATUS" -eq 0 ] \
  || die "could not list notifications on gs://${BUCKET_NAME}: $NOTIF_LIST_OUT"
EXISTING_NOTIF="$(printf '%s' "$NOTIF_LIST_OUT" | jq -r --arg topic "/topics/${TOPIC}" '
      [.[]? | select((.["Notification Configuration"].topic // "") | endswith($topic))
             | .["Notification Configuration"].id][0] // empty
    ' 2>/dev/null || true)"
if [ -n "$EXISTING_NOTIF" ]; then
  log "a notification to $TOPIC already exists on the bucket, reusing"
else
  NOTIF_ARGS=(gcloud storage buckets notifications create "gs://${BUCKET_NAME}"
    --topic="$TOPIC_FQN" --payload-format=json
    --event-types="$EVENT_TYPES"
    --custom-attributes="captain_sync_id=${SYNC_ID},captain_managed=gcloud")
  [ -n "$OBJECT_PREFIX" ] && NOTIF_ARGS+=(--object-prefix="$OBJECT_PREFIX")
  run "${NOTIF_ARGS[@]}"
fi

# ---- 3. push identity + token-creator + push subscription --------------------
step "Push service account (OIDC identity)"
if gcloud iam service-accounts describe "$PUSH_SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
  log "push SA $PUSH_SA_EMAIL already exists, reusing"
else
  run gcloud iam service-accounts create "$PUSH_SA_ID" --project="$PROJECT_ID" \
    --display-name="Captain GCS push identity for ${SYNC_ID}" \
    --description="Pub/Sub signs OIDC tokens as this SA on push to Captain. No other permissions."
fi
step "Let the Pub/Sub service agent mint OIDC tokens as the push SA"
run gcloud iam service-accounts add-iam-policy-binding "$PUSH_SA_EMAIL" --project="$PROJECT_ID" \
  --member="serviceAccount:${PUBSUB_AGENT}" --role="roles/iam.serviceAccountTokenCreator" --quiet

step "Push subscription -> Captain ingest (OIDC)"
if gcloud pubsub subscriptions describe "$SUB" --project="$PROJECT_ID" >/dev/null 2>&1; then
  log "subscription $SUB already exists; updating push config"
  run gcloud pubsub subscriptions modify-push-config "$SUB" --project="$PROJECT_ID" \
    --push-endpoint="$PUSH_ENDPOINT" \
    --push-auth-service-account="$PUSH_SA_EMAIL" \
    --push-auth-token-audience="$EFFECTIVE_AUDIENCE"
else
  run gcloud pubsub subscriptions create "$SUB" --project="$PROJECT_ID" \
    --topic="$TOPIC" \
    --push-endpoint="$PUSH_ENDPOINT" \
    --push-auth-service-account="$PUSH_SA_EMAIL" \
    --push-auth-token-audience="$EFFECTIVE_AUDIENCE" \
    --ack-deadline=60 \
    --message-retention-duration=7d \
    --expiration-period=never \
    --min-retry-delay=10s --max-retry-delay=600s \
    --labels="captain-sync-id=${SYNC_ID_LABEL},captain-managed-by=gcloud"
fi

# ---- 4. cross-account read grant (no long-lived keys) ------------------------
step "Grant Captain's reader SA objectViewer on the bucket"
run gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
  --member="serviceAccount:${CAPTAIN_READER_SA}" --role="roles/storage.objectViewer"

# ---- 5. enroll the webhook with the Captain API -------------------------------
step "Register the webhook with Captain (POST /v2/syncs/${SYNC_ID}/webhooks)"
if [ "$DRY_RUN" = "1" ]; then
  log "dry-run: skipping enrollment. Would POST ${CAPTAIN_API_BASE%/}/v2/syncs/${SYNC_ID}/webhooks (Bearer auth, empty JSON body)"
else
  CAPTAIN_API_BASE="$CAPTAIN_API_BASE" \
  SYNC_ID="$SYNC_ID" \
  CAPTAIN_API_KEY="$CAPTAIN_API_KEY" \
  INGEST_URL="$CAPTAIN_INGEST_URL" \
  DEPLOYMENT_ID="$DEPLOYMENT_ID" \
  TEMPLATE_VERSION="$TEMPLATE_VERSION" \
    bash "$ENROLL_SH" \
    || die "webhook registration failed. The GCP plumbing was created but Captain has not confirmed the webhook. See the error above, fix, then re-run this script (it is idempotent)."
fi

# ---- done --------------------------------------------------------------------
step "Done"
if [ "$DRY_RUN" = "1" ]; then
cat >&2 <<EOF

  Dry run only. Nothing was created and the enrollment call was skipped, so
  this sync is NOT registered. Re-run without --dry-run to actually deploy it.

    deploymentId : $DEPLOYMENT_ID
EOF
else
cat >&2 <<EOF

  Captain GCS sync is live and REGISTERED with the Captain API.

    deploymentId : $DEPLOYMENT_ID   (local id, stamped on this run's logs)
    syncId       : $SYNC_ID
    bucket       : gs://$BUCKET_NAME
    topic        : $TOPIC_FQN
    subscription : $SUB_FQN
    push SA      : $PUSH_SA_EMAIL   (the OIDC identity on each push delivery)
    reader SA    : $CAPTAIN_READER_SA  => roles/storage.objectViewer

  Next: open your Captain dashboard for $SYNC_ID. Object changes push
  near-real-time; the reconcile backstop covers anything push misses.

  To tear this down later (--push-sa is optional; teardown.sh re-derives it
  from --sync-id if omitted):
    ./teardown.sh --project $PROJECT_ID --bucket $BUCKET_NAME \\
      --sync-id $SYNC_ID --reader-sa $CAPTAIN_READER_SA
EOF
fi
