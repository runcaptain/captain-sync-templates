locals {
  template_version = "2026-08-13"

  # Stripe-style deployment id: dep_<token>. No bare UUIDs.
  deployment_id = "dep_${random_string.dep.result}"

  # Region lives inside the S3 endpoint: s3.<region>.backblazeb2.com
  s3_endpoint = data.b2_account_info.this.s3_api_url
  s3_region   = try(regex("^https://s3\\.([a-z0-9-]+)\\.backblazeb2\\.com", local.s3_endpoint)[0], "unknown")

  # The B2 rule targets the per-sync subscribe URL Captain mints at enrollment.
  subscribe_url = data.external.captain_webhook.result.subscribe_url

  # B2-safe resource name fragments (letters/digits/'-' only, lowercased rule).
  key_name  = "captain-b2-read-${replace(var.sync_id, "_", "-")}"
  rule_name = lower("captain-sync-${replace(var.sync_id, "_", "-")}")
}

# =========================================================================
# ENROLLMENT: mint the per-sync subscribe URL from Captain's API
#
# POST {api_base}/v2/syncs/<sync_id>/webhooks with a Bearer API key and an
# empty JSON body (B2 is not an SNS-backed source, so no sns_topic_arn).
# Captain answering 2xx with a subscribe_url IS the enrollment; anything else
# fails the plan/apply with a clear reason. The call is idempotent per sync
# (Captain returns the sync's subscribe URL), so re-running plan/apply is safe.
#
# The API key comes ONLY from the CAPTAIN_API_KEY environment variable, so it
# never lands in the plan or in state. See enroll_webhook.sh.
# =========================================================================
data "external" "captain_webhook" {
  program = ["/usr/bin/env", "bash", "${path.module}/enroll_webhook.sh"]

  query = {
    sync_id          = var.sync_id
    api_base         = var.api_base
    template_version = local.template_version
  }
}

# Discover the account's S3 endpoint + region (works in any B2 region).
data "b2_account_info" "this" {}

# Resolve the bucket name to its bucket id.
data "b2_bucket" "target" {
  bucket_name = var.bucket_name
}

# dep_<token> stable across applies (stored in state).
resource "random_string" "dep" {
  length  = 24
  special = false
}

# 32-char signing secret for the webhook HMAC (B2 requires exactly 32 chars).
resource "random_password" "hmac" {
  length  = 32
  special = false
  upper   = false
}

# =========================================================================
# READ GRANT: scoped, read-only application key (the reconcile grant)
#
# Restricted to the ONE bucket, read-only. Backblaze has no cross-account
# assume-role, so this key IS the grant Captain uses against the S3-compatible
# endpoint. Set key_duration_seconds to have it auto-expire (rotation).
# =========================================================================
resource "b2_application_key" "captain_read" {
  key_name     = local.key_name
  capabilities = ["listBuckets", "listFiles", "readFiles", "readBucketNotifications"]
  bucket_ids   = [data.b2_bucket.target.bucket_id]

  valid_duration_in_seconds = var.key_duration_seconds
}

# =========================================================================
# EVENT WIRING: native B2 Event Notification rule (the latency path)
#
# Created only when event_path = "enabled". Default is "skip" because Event
# Notifications are account-gated by Backblaze; applying this resource on a
# non-enabled account FAILS. Flip to "enabled" once Backblaze turns the feature
# on for your account. See b2/NOTES.md.
#
# NOTE ON SIBLING RULES: this resource manages the FULL rule set for the bucket.
# If the bucket already carries other notification rules you want to keep, import
# them into this resource or use the setup script (setup/captain-b2-sync.sh),
# which does an additive read-merge-write and preserves siblings.
# =========================================================================
resource "b2_bucket_notification_rules" "captain" {
  count     = var.event_path == "enabled" ? 1 : 0
  bucket_id = data.b2_bucket.target.bucket_id

  notification_rules {
    name               = local.rule_name
    is_enabled         = true
    event_types        = ["b2:ObjectCreated:*", "b2:ObjectDeleted:*"]
    object_name_prefix = ""

    target_configuration {
      target_type                = "webhook"
      url                        = local.subscribe_url
      hmac_sha256_signing_secret = random_password.hmac.result
    }
  }
}

# No teardown call to Captain on destroy: there is no unsubscribe endpoint.
# `terraform destroy` removes the B2-side resources; Captain detects the dead
# event source on its own and the scheduled reconcile backstop keeps the sync
# consistent until you pause or delete it in Captain.
