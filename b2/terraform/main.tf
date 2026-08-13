locals {
  template_version = "2026-08-12"

  # Stripe-style deployment id: dep_<token>. No bare UUIDs.
  deployment_id = "dep_${random_string.dep.result}"

  # Region lives inside the S3 endpoint: s3.<region>.backblazeb2.com
  s3_endpoint = data.b2_account_info.this.s3_api_url
  s3_region   = try(regex("^https://s3\\.([a-z0-9-]+)\\.backblazeb2\\.com", local.s3_endpoint)[0], "unknown")

  # Default the events webhook to the enroll host's /events path, sync-tagged.
  events_url = var.events_url != "" ? var.events_url : "https://api.runcaptain.com/v1/deploy/b2/events?sync=${var.sync_id}"

  # B2-safe resource name fragments (letters/digits/'-' only, lowercased rule).
  key_name  = "captain-b2-read-${replace(var.sync_id, "_", "-")}"
  rule_name = lower("captain-sync-${replace(var.sync_id, "_", "-")}")
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
      url                        = local.events_url
      hmac_sha256_signing_secret = random_password.hmac.result
    }
  }
}

# =========================================================================
# SELF-VERIFYING PHONE-HOME
#
# Runs after the key (and rule, if any) exist. phone_home.sh POSTs the
# enrollment facts to Captain and exits non-zero unless Captain returns
# {"verified": true}. A non-zero exit fails `terraform apply`, so a clean apply
# means Captain confirmed it can read the bucket end to end.
#
# Rollback difference vs the setup script: on a failed verify Terraform leaves
# the key/rule in state (it does not auto-destroy them). Re-run apply after
# fixing the cause, or `terraform destroy` to tear the deployment down. The
# setup script rolls back automatically; that is the one behavioral gap.
# =========================================================================
resource "null_resource" "enroll" {
  depends_on = [
    b2_application_key.captain_read,
    b2_bucket_notification_rules.captain,
  ]

  triggers = {
    deployment_id    = local.deployment_id
    sync_id          = var.sync_id
    bucket_id        = data.b2_bucket.target.bucket_id
    read_key_id      = b2_application_key.captain_read.application_key_id
    event_status     = var.event_path == "enabled" ? "enabled" : "skipped"
    template_version = local.template_version
    callback_url     = var.callback_url
  }

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "${path.module}/phone_home.sh"]
    command     = "create"

    environment = {
      CAPTAIN_CALLBACK_URL     = var.callback_url
      CAPTAIN_ACTION           = "create"
      CAPTAIN_DEPLOYMENT_ID    = local.deployment_id
      CAPTAIN_TEMPLATE_VERSION = local.template_version
      CAPTAIN_SYNC_ID          = var.sync_id
      CAPTAIN_SECRET           = var.secret
      CAPTAIN_ACCOUNT_ID       = data.b2_account_info.this.account_id
      CAPTAIN_BUCKET_NAME      = var.bucket_name
      CAPTAIN_BUCKET_ID        = data.b2_bucket.target.bucket_id
      CAPTAIN_S3_ENDPOINT      = local.s3_endpoint
      CAPTAIN_S3_REGION        = local.s3_region
      CAPTAIN_READ_KEY_ID      = b2_application_key.captain_read.application_key_id
      CAPTAIN_READ_APP_KEY     = b2_application_key.captain_read.application_key
      CAPTAIN_EVENTS_URL       = local.events_url
      CAPTAIN_EVENT_STATUS     = var.event_path == "enabled" ? "enabled" : "skipped"
      CAPTAIN_RULE_NAME        = local.rule_name
      CAPTAIN_HMAC_SECRET      = random_password.hmac.result
    }
  }

  # Best-effort teardown notice. Destroy provisioners can reference only self,
  # so it uses self.triggers (no secret); Captain identifies by dep + sync id.
  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["/usr/bin/env", "bash", "${path.module}/phone_home.sh"]
    command     = "delete"

    environment = {
      CAPTAIN_CALLBACK_URL     = self.triggers.callback_url
      CAPTAIN_ACTION           = "delete"
      CAPTAIN_DEPLOYMENT_ID    = self.triggers.deployment_id
      CAPTAIN_TEMPLATE_VERSION = self.triggers.template_version
      CAPTAIN_SYNC_ID          = self.triggers.sync_id
      CAPTAIN_BUCKET_ID        = self.triggers.bucket_id
      CAPTAIN_READ_KEY_ID      = self.triggers.read_key_id
      CAPTAIN_EVENT_STATUS     = "removed"
    }
  }
}
