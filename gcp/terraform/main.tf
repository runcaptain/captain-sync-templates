# =============================================================================
# Captain GCS one-click sync (self-verifying), Terraform edition.
#
# MECHANISM: GCS object-change notifications -> Pub/Sub topic -> Pub/Sub PUSH
# subscription that delivers to the sync's minted Captain ingest URL
# (captain_ingest_url, the subscribe_url from POST /v2/syncs/<sync_id>/webhooks)
# authenticated with a Google-signed OIDC token (no long-lived keys). A
# read-only cross-account grant lets Captain LIST/GET objects as its OWN
# service account for the reconcile backstop. A final webhook-registration
# call to the Captain API closes the loop.
#
# -----------------------------------------------------------------------------
# DEBUGGABLE-DEPLOY DESIGN (read this before editing)
#
# The failure mode of "terraform apply and hope": every resource turns green,
# but if the sync id is wrong, the API key is dead, or the push endpoint is
# not the URL Captain actually minted, the sync silently never works and
# there is no feedback loop.
#
# This template closes the loop with a WEBHOOK REGISTRATION
# (terraform_data.enroll):
#
#   1. Terraform creates the topic, lets GCS publish to it, attaches the bucket
#      notification, creates the push subscription with an OIDC token, and grants
#      Captain's reader service account objectViewer on the bucket.
#   2. terraform_data.enroll runs LAST and calls the real Captain API:
#      POST {captain_api_base}/v2/syncs/{sync_id}/webhooks with
#      "Authorization: Bearer {captain_api_key}" and an empty JSON body (GCS
#      syncs need no body fields). A 2xx response with a subscribe_url is a
#      successful enrollment; enroll.sh also warns if that subscribe_url
#      differs from the captain_ingest_url the subscription was pointed at.
#   3. enroll.sh exits non-zero on anything else, which FAILS the apply with a
#      human-readable error in the Terraform output. The customer sees the
#      failure now, not three days later when documents are stale.
#
# So a clean apply means the resources exist AND Captain has the webhook on
# file for this sync. On destroy no API call is made: no unsubscribe endpoint
# is documented, and none is needed. Captain detects the dead event source
# and the reconcile backstop keeps the sync consistent.
# =============================================================================

locals {
  # Stripe-style deployment id (dep_<token>); no bare UUIDs in customer output.
  deployment_id    = "dep_${random_string.dep_token.result}"
  template_version = "2026-08-13"

  # Effective OIDC audience: default to the ingest URL when not overridden.
  oidc_audience = var.oidc_audience != "" ? var.oidc_audience : var.captain_ingest_url

  common_labels = merge(var.labels, {
    "captain-sync-id"    = var.sync_id
    "captain-managed-by" = "terraform"
  })
}

# A random alphanumeric token for the deployment id and a short one for names
# that have tight length limits (service account ids are 6-30 chars).
resource "random_string" "dep_token" {
  length  = 24
  upper   = false
  special = false
}

resource "random_string" "name_suffix" {
  length  = 8
  upper   = false
  special = false
}

# -----------------------------------------------------------------------------
# 0. PROJECT FACTS + OPTIONAL API ENABLEMENT
# -----------------------------------------------------------------------------

data "google_project" "this" {
  project_id = var.project_id
}

# The GCS service agent for THIS project. GCS publishes notifications to Pub/Sub
# as this identity, so it needs pubsub.publisher on our topic (granted below).
data "google_storage_project_service_account" "gcs" {
  project = var.project_id
}

resource "google_project_service" "pubsub" {
  count                      = var.manage_apis ? 1 : 0
  project                    = var.project_id
  service                    = "pubsub.googleapis.com"
  disable_on_destroy         = false
  disable_dependent_services = false
}

resource "google_project_service" "storage" {
  count                      = var.manage_apis ? 1 : 0
  project                    = var.project_id
  service                    = "storage.googleapis.com"
  disable_on_destroy         = false
  disable_dependent_services = false
}

# =============================================================================
# 1. EVENT WIRING: Pub/Sub topic <- GCS notification
# =============================================================================

resource "google_pubsub_topic" "captain_sync" {
  project = var.project_id
  name    = "captain-gcs-sync-${var.sync_id}"
  labels  = local.common_labels

  message_retention_duration = var.message_retention_duration

  depends_on = [google_project_service.pubsub]
}

# Let THIS project's GCS service agent publish to the topic. Without this the
# google_storage_notification below fails with a permission error, so it is a
# hard dependency of the notification.
resource "google_pubsub_topic_iam_member" "gcs_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.captain_sync.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

# Attach the notification to the EXISTING bucket. GCS notifications are additive:
# a bucket can carry several, so this does NOT clobber notifications the customer
# already has (unlike the single-slot S3 constraint). Terraform removes only this
# one on destroy.
resource "google_storage_notification" "captain" {
  bucket         = var.bucket_name
  topic          = google_pubsub_topic.captain_sync.id
  payload_format = "JSON_API_V1"
  event_types    = var.event_types

  # Empty prefix means "whole bucket"; only set the filter when a prefix is given.
  object_name_prefix = var.object_name_prefix != "" ? var.object_name_prefix : null

  custom_attributes = {
    captain_sync_id = var.sync_id
    captain_managed = "terraform"
  }

  depends_on = [google_pubsub_topic_iam_member.gcs_publisher]
}

# =============================================================================
# 2. PUSH DELIVERY: subscription -> Captain ingest, authed with an OIDC token
# =============================================================================

# Dedicated push identity in the CUSTOMER project. Pub/Sub mints a Google-signed
# OIDC token as this service account on every push; Captain verifies the token
# instead of trusting an unauthenticated URL. This SA has no other permissions.
resource "google_service_account" "push" {
  project      = var.project_id
  account_id   = "cap-push-${random_string.name_suffix.result}"
  display_name = "Captain GCS push identity for ${var.sync_id}"
  description  = "Pub/Sub uses this to sign OIDC tokens on push to Captain (sync ${var.sync_id}). No other permissions."
}

# Pub/Sub's own service agent must be allowed to mint OIDC tokens AS the push SA.
resource "google_service_account_iam_member" "pubsub_token_creator" {
  service_account_id = google_service_account.push.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_subscription" "captain_push" {
  project = var.project_id
  name    = "captain-gcs-push-${var.sync_id}"
  topic   = google_pubsub_topic.captain_sync.id
  labels  = local.common_labels

  ack_deadline_seconds       = var.ack_deadline_seconds
  message_retention_duration = var.message_retention_duration

  # Never let the subscription expire from inactivity; the sync is long-lived.
  expiration_policy {
    ttl = ""
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  push_config {
    # The minted subscribe_url exactly as Captain returned it. Nothing is
    # appended: the URL already identifies the sync.
    push_endpoint = var.captain_ingest_url

    oidc_token {
      service_account_email = google_service_account.push.email
      audience              = local.oidc_audience
    }

    attributes = {
      "x-goog-version" = "v1"
    }
  }

  # The subscription references the push SA's OIDC identity; make sure Pub/Sub
  # can actually mint the token before the subscription starts pushing.
  depends_on = [google_service_account_iam_member.pubsub_token_creator]
}

# =============================================================================
# 3. CROSS-ACCOUNT READ GRANT (no long-lived keys)
# =============================================================================

# Grant Captain's OWN service account read on exactly this one bucket. Captain
# authenticates as this identity from its own project, so nothing but an IAM
# binding lives in the customer account. This is the reconcile backstop's read
# path.
resource "google_storage_bucket_iam_member" "captain_reader" {
  bucket = var.bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${var.captain_reader_service_account}"
}

# =============================================================================
# 4. WEBHOOK REGISTRATION (the real Captain API)
# =============================================================================

# terraform_data carries the registration facts as its input so a change to any
# of them (sync id, API base, ingest URL, API key) re-runs the registration on
# the next apply. It depends on every resource above, so the call runs LAST,
# after the plumbing it registers actually exists.
#
# There is deliberately NO destroy-time provisioner: Captain documents no
# unsubscribe endpoint. `terraform destroy` just removes the cloud-side
# resources; Captain detects the dead event source and the reconcile backstop
# keeps the sync consistent.
resource "terraform_data" "enroll" {
  input = {
    api_base         = var.captain_api_base
    sync_id          = var.sync_id
    ingest_url       = var.captain_ingest_url
    deployment_id    = local.deployment_id
    template_version = local.template_version
    # Sensitive; passed to the script via env only, never rendered in outputs.
    api_key = var.captain_api_key
  }

  # CREATE / UPDATE: register the webhook, require 2xx + subscribe_url, or
  # fail the apply.
  provisioner "local-exec" {
    when        = create
    interpreter = ["/usr/bin/env", "bash", "${path.module}/enroll.sh"]
    command     = "enroll"
    environment = {
      CAPTAIN_API_BASE = self.input.api_base
      SYNC_ID          = self.input.sync_id
      CAPTAIN_API_KEY  = self.input.api_key
      INGEST_URL       = self.input.ingest_url
      DEPLOYMENT_ID    = self.input.deployment_id
      TEMPLATE_VERSION = self.input.template_version
    }
  }

  depends_on = [
    google_storage_notification.captain,
    google_pubsub_subscription.captain_push,
    google_storage_bucket_iam_member.captain_reader,
  ]
}
