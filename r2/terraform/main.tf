# =============================================================================
# Captain R2 sync stack (Terraform / OpenTofu)
# -----------------------------------------------------------------------------
# The IaC equivalent of the Wrangler path. Stands up, inside the CUSTOMER'S
# Cloudflare account:
#
#   1. EVENT WIRING       a Queue + a dead-letter Queue, an R2 event-notification
#                         rule (bucket object changes -> Queue), and the consumer
#                         Worker that drains the Queue and POSTs events to Captain.
#   2. READ GRANT         a scoped, read-only R2 API token (Captain's reconcile
#                         backstop reads objects with it via the S3 API), PLUS the
#                         same Worker's keyless read-proxy routes as the no-key
#                         alternative.
#   3. ENROLLMENT         an apply-time call to Captain's real webhook API
#                         (POST {captain_api_base}/v2/syncs/{sync_id}/webhooks,
#                         data.http.subscribe). Captain mints the per-sync
#                         subscribe_url the Worker forwards events to; a non-2xx
#                         or a missing subscribe_url FAILS THE APPLY.
#
# Reconcile/polling is the always-on backstop; the Queue path is the latency win.
#
# PREREQ: build the Worker bundle first so Terraform has something to upload:
#   cd ../worker && npm install && npm run build   # writes ../worker/dist/index.js
# =============================================================================

provider "cloudflare" {
  # Falls back to the CLOUDFLARE_API_TOKEN env var when the variable is null.
  api_token = var.cloudflare_api_token
}

locals {
  template_version   = "2026-08-13"
  worker_bundle_path = "${path.module}/../worker/dist/index.js"
  deployment_id      = "dep_${random_string.dep.result}"

  # Bucket-scoped R2 resource key (Cloudflare's documented format), NOT the
  # account-wide "com.cloudflare.api.account.<id>" key. This is what actually
  # limits the token to this one bucket instead of every bucket on the account.
  bucket_resource = "com.cloudflare.edge.r2.bucket.${var.account_id}_${var.jurisdiction}_${var.bucket_name}"

  # Public URL for the Worker's keyless read proxy, only if the account's
  # workers.dev subdomain was supplied. Empty string means no public read-proxy
  # URL (Captain reads via the scoped token instead).
  worker_url = var.workers_subdomain != "" ? "https://${var.worker_name}.${var.workers_subdomain}.workers.dev" : ""

  # R2 event-notification actions. Creates/overwrites -> upsert; deletes -> delete.
  event_actions = ["PutObject", "CopyObject", "CompleteMultipartUpload", "DeleteObject", "LifecycleDeletion"]
}

# Stripe-style deployment id (dep_<token>). Stored in state, stable across
# applies. A local reference id for support and audit trails. No bare UUIDs.
resource "random_string" "dep" {
  length  = 24
  special = false
  upper   = true
  lower   = true
  numeric = true
}

# Pin the read-token creation time in state so expires_on does not drift on every
# apply (which a raw timestamp() would cause).
resource "time_static" "read_token_created" {}

# =============================================================================
# 0. ENROLLMENT: subscribe this sync's webhook with Captain
# -----------------------------------------------------------------------------
# POST {captain_api_base}/v2/syncs/{sync_id}/webhooks, Bearer Captain API key,
# empty JSON body (R2 needs no sns_topic_arn; that field is for AWS S3 syncs).
# Captain answers 2xx with the subscribe_url it minted, plus secret_set and
# instructions. That subscribe_url IS the Worker's CAPTAIN_INGEST_URL: there is
# no default anywhere because the URL is minted per sync by this call. The
# postcondition fails the apply unless the response carries a subscribe_url.
# =============================================================================

data "http" "subscribe" {
  url    = "${var.captain_api_base}/v2/syncs/${var.sync_id}/webhooks"
  method = "POST"

  request_headers = {
    "authorization" = "Bearer ${var.captain_api_key}"
    "content-type"  = "application/json"
    "user-agent"    = "captain-r2-terraform/${local.template_version}"
  }

  request_body = jsonencode({})

  retry {
    attempts     = 3
    min_delay_ms = 2000
    max_delay_ms = 10000
  }

  lifecycle {
    postcondition {
      condition     = self.status_code >= 200 && self.status_code < 300 && try(jsondecode(self.response_body).subscribe_url, "") != ""
      error_message = "Captain did not confirm the webhook subscription. HTTP ${self.status_code}. Body: ${substr(self.response_body, 0, 400)}. Check sync_id and captain_api_key, then re-apply."
    }
  }
}

locals {
  # The per-sync ingest URL Captain minted. Baked into the Worker below.
  captain_ingest_url = try(jsondecode(data.http.subscribe.response_body).subscribe_url, "")
}

# =============================================================================
# 1. EVENT WIRING: queues + Worker + notification
# =============================================================================

resource "cloudflare_queue" "main" {
  account_id = var.account_id
  queue_name = var.queue_name
}

resource "cloudflare_queue" "dlq" {
  account_id = var.account_id
  queue_name = "${var.queue_name}-dlq"
}

# The consumer Worker (bundle built by wrangler). Bindings mirror wrangler.jsonc.
resource "cloudflare_workers_script" "consumer" {
  account_id         = var.account_id
  script_name        = var.worker_name
  main_module        = "index.js"
  content_file       = local.worker_bundle_path
  content_sha256     = fileexists(local.worker_bundle_path) ? filesha256(local.worker_bundle_path) : null
  content_type       = "application/javascript+module"
  compatibility_date = var.compatibility_date

  observability = {
    enabled            = true
    head_sampling_rate = 1
  }

  bindings = [
    { type = "r2_bucket", name = "R2", bucket_name = var.bucket_name },
    { type = "plain_text", name = "TEMPLATE_VERSION", text = local.template_version },
    { type = "plain_text", name = "SYNC_ID", text = var.sync_id },
    { type = "plain_text", name = "BUCKET_NAME", text = var.bucket_name },
    { type = "plain_text", name = "ACCOUNT_ID", text = var.account_id },
    { type = "plain_text", name = "CAPTAIN_INGEST_URL", text = local.captain_ingest_url },
    { type = "plain_text", name = "DEBUG", text = var.debug ? "true" : "false" },
    { type = "secret_text", name = "CAPTAIN_SECRET", text = var.captain_secret },
  ]
}

# Enable the workers.dev subdomain so the read proxy + health check are reachable.
resource "cloudflare_workers_script_subdomain" "consumer" {
  account_id       = var.account_id
  script_name      = cloudflare_workers_script.consumer.script_name
  enabled          = true
  previews_enabled = false
}

# Bind the Worker as the consumer of the events queue, with a dead-letter queue so
# a persistently failing Captain ingest parks messages instead of looping.
resource "cloudflare_queue_consumer" "worker" {
  account_id        = var.account_id
  queue_id          = cloudflare_queue.main.queue_id
  type              = "worker"
  script_name       = cloudflare_workers_script.consumer.script_name
  dead_letter_queue = cloudflare_queue.dlq.queue_name

  settings = {
    batch_size       = 100
    max_retries      = 5
    max_wait_time_ms = 5000
  }
}

# Point the bucket's object-change events at the queue. depends_on the consumer so
# there is always a drain attached before events start flowing.
resource "cloudflare_r2_bucket_event_notification" "main" {
  account_id   = var.account_id
  bucket_name  = var.bucket_name
  queue_id     = cloudflare_queue.main.queue_id
  jurisdiction = var.jurisdiction

  rules = [
    {
      actions     = local.event_actions
      description = "captain-${var.sync_id}"
      prefix      = var.prefix != "" ? var.prefix : null
    }
  ]

  depends_on = [cloudflare_queue_consumer.worker]
}

# =============================================================================
# 2. CROSS-ACCOUNT READ GRANT: scoped, read-only R2 API token
# -----------------------------------------------------------------------------
# HONEST NOTE: R2 has no cross-account assume-role. The least-privilege
# equivalent is a read-only token scoped to THIS ONE BUCKET, not the account.
# It is a long-lived credential (unlike the AWS assume-role path), so we
# (a) scope it to R2 read on this bucket only, (b) give it an expiry you
# re-apply to rotate, and (c) also expose the Worker read proxy as the fully
# keyless alternative. Captain's R2 sync reads via the S3 API using:
# access_key_id = token id, secret_access_key = SHA-256 of the token value
# (Cloudflare's documented S3 credential derivation).
#
# SCOPING: the account-level "Workers R2 Storage Read" permission group grants
# read on every bucket in the account, no matter what goes in `resources`.
# Bucket-level scoping requires the BUCKET-scoped permission group ("Workers
# R2 Storage Bucket Item Read") paired with the bucket resource key
# (com.cloudflare.edge.r2.bucket.<account>_<jurisdiction>_<bucket>, built in
# locals.bucket_resource above). We fetch the full permission-group list and
# filter client-side by exact name instead of passing `name`/`scope` to the
# data source, matching Cloudflare's own worked example and avoiding
# URL-encoding pitfalls in that filter.
#
# STATE WARNING: this token's id/value and the SHA-256 derived from it live in
# Terraform state IN PLAINTEXT (see versions.tf / README "State and secrets"
# for the encrypted-backend requirement and rotation guidance).
# =============================================================================

data "cloudflare_api_token_permission_groups_list" "all" {}

locals {
  r2_bucket_read_permission_id = one([
    for g in data.cloudflare_api_token_permission_groups_list.all.result :
    g.id if g.name == "Workers R2 Storage Bucket Item Read"
  ])
}

resource "cloudflare_api_token" "read" {
  name       = "captain-r2-read-${var.sync_id}"
  expires_on = var.read_token_ttl_days > 0 ? timeadd(time_static.read_token_created.rfc3339, "${var.read_token_ttl_days * 24}h") : null

  policies = [
    {
      effect            = "allow"
      permission_groups = [{ id = local.r2_bucket_read_permission_id }]
      resources = {
        (local.bucket_resource) = "*"
      }
    }
  ]
}

# =============================================================================
# 3. AFTER THE APPLY
# -----------------------------------------------------------------------------
# Enrollment already happened in data.http.subscribe above (a 2xx with a minted
# subscribe_url is confirmed enrollment). The scoped read credentials do NOT
# travel to Captain automatically: feed them into your Captain R2 sync yourself
# (`tofu output -raw read_access_key_id` / `read_secret_access_key`, see the
# README). There is no unsubscribe call on destroy either: Captain detects the
# dead event source once the queue and Worker are gone, and scheduled reconcile
# continues as the backstop.
# =============================================================================
