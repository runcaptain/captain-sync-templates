# =============================================================================
# Inputs for the Captain R2 sync stack.
#
# Captain pre-fills sync_id, captain_secret, and the callback URLs when it
# generates your deploy command. You supply the Cloudflare pieces: an API token
# to run Terraform, your account id, and the bucket name.
#
# Naming: Captain object ids are Stripe-style prefix_token (sync_..., dep_...).
# No bare UUIDs. No em dashes anywhere.
# =============================================================================

variable "cloudflare_api_token" {
  description = <<-EOT
    Cloudflare API token Terraform uses to create the queue, Worker, event
    notification, and the scoped read token. Needs, at the account level:
    Workers Scripts:Edit, Queues:Edit, Workers R2 Storage:Edit, and
    API Tokens:Edit (to mint the read-only child token). Leave null to fall back
    to the CLOUDFLARE_API_TOKEN environment variable.
  EOT
  type        = string
  default     = null
  sensitive   = true
}

variable "account_id" {
  description = "Cloudflare account id (32 hex chars) that owns the R2 bucket. Find it in the R2 dashboard URL or via `wrangler whoami`."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.account_id))
    error_message = "account_id must be a 32-character hex Cloudflare account id."
  }
}

variable "bucket_name" {
  description = "The EXISTING R2 bucket to sync. This stack does not create it."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 chars, lowercase letters, numbers and hyphens, starting and ending alphanumeric."
  }
}

variable "sync_id" {
  description = "Captain sync id (sync_<token>) this deployment enrolls. Captain fills this in."
  type        = string

  validation {
    condition     = can(regex("^sync_[A-Za-z0-9]+$", var.sync_id))
    error_message = "sync_id must be a Captain sync id of the form sync_<token>."
  }
}

variable "captain_secret" {
  description = <<-EOT
    One-time enrollment secret minted by Captain for this sync. Doubles as the
    bearer secret between Captain and the Worker. `sensitive = true` keeps it
    out of CLI output, but it is still written to Terraform state IN
    PLAINTEXT (Terraform state is not encrypted by design). Use an encrypted
    remote backend (see versions.tf) before applying this against anything
    real. To rotate, change this value and re-apply.
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.captain_secret) >= 16
    error_message = "captain_secret must be at least 16 characters."
  }
}

variable "captain_ingest_url" {
  description = "Captain endpoint the Worker POSTs object-change events to."
  type        = string
  default     = "https://api.runcaptain.com/v1/deploy/r2/ingest"

  validation {
    condition     = can(regex("^https://", var.captain_ingest_url))
    error_message = "captain_ingest_url must be https."
  }
}

variable "captain_enroll_url" {
  description = "Captain enrollment endpoint the phone-home POSTs to. A non-2xx or verified!=true response fails the apply."
  type        = string
  default     = "https://api.runcaptain.com/v1/deploy/r2/enroll"

  validation {
    condition     = can(regex("^https://", var.captain_enroll_url))
    error_message = "captain_enroll_url must be https."
  }
}

variable "worker_name" {
  description = "Name for the consumer Worker. Kept per-sync so two syncs never collide."
  type        = string
  default     = "captain-r2-sync"
}

variable "queue_name" {
  description = "Name for the events queue. Kept per-sync so two syncs never collide."
  type        = string
  default     = "captain-r2-sync"
}

variable "workers_subdomain" {
  description = <<-EOT
    Your account's workers.dev subdomain (the '<name>' in <name>.workers.dev),
    used to build the Worker's public URL for the keyless read proxy. Find it in
    the Workers dashboard or via `wrangler whoami`. Optional: leave empty to
    enroll with the scoped read token only (no read proxy URL sent to Captain).
  EOT
  type        = string
  default     = ""
}

variable "prefix" {
  description = "Optional key prefix. If set, only object changes under this prefix fire event notifications."
  type        = string
  default     = ""
}

variable "jurisdiction" {
  description = "R2 jurisdiction for the bucket (default, eu, or fedramp)."
  type        = string
  default     = "default"

  validation {
    condition     = contains(["default", "eu", "fedramp"], var.jurisdiction)
    error_message = "jurisdiction must be one of: default, eu, fedramp."
  }
}

variable "compatibility_date" {
  description = "Workers runtime compatibility date. Keep aligned with the Worker's wrangler.jsonc."
  type        = string
  default     = "2026-08-12"
}

variable "read_token_ttl_days" {
  description = <<-EOT
    Lifetime of the scoped, bucket-only read-only R2 token in days, after
    which it expires and must be re-applied. 0 = no expiry (not recommended:
    the token id and its derived S3 secret sit in Terraform state in
    plaintext for as long as it stays valid). Re-apply before expiry to
    rotate; see versions.tf for the encrypted-backend requirement.
  EOT
  type        = number
  default     = 90
}

variable "debug" {
  description = "Set true to make the Worker emit verbose per-message debug logs (visible in `wrangler tail`)."
  type        = bool
  default     = false
}
