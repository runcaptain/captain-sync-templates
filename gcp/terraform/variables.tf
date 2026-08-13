# -----------------------------------------------------------------------------
# Inputs. Captain normally pre-fills every "Captain fills this in" value when it
# generates your deploy link / tfvars, so a customer only confirms and applies.
# Each variable carries a validation block that produces a human-readable error
# at plan time instead of a confusing API failure at apply time.
# -----------------------------------------------------------------------------

variable "project_id" {
  type        = string
  description = "Your Google Cloud project id that OWNS the bucket. All resources (topic, subscription, push service account) are created here."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project id (6-30 chars, lowercase letters/digits/hyphens, cannot start with a digit or end with a hyphen)."
  }
}

variable "bucket_name" {
  type        = string
  description = "The EXISTING GCS bucket to sync. This template does not create it; it only attaches a notification and grants Captain read on it."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be a valid GCS bucket name (3-222 chars, lowercase letters/digits/dots/hyphens/underscores). Do not include a gs:// prefix."
  }
}

variable "sync_id" {
  type        = string
  description = "The Captain sync id (sync_<token>) this deployment enrolls. Captain fills this in."

  validation {
    condition     = can(regex("^sync_[A-Za-z0-9]+$", var.sync_id))
    error_message = "sync_id must be a Captain sync id of the form sync_<token> (letters and digits after the sync_ prefix)."
  }
}

variable "enrollment_secret" {
  type        = string
  sensitive   = true
  description = "One-time enrollment secret minted by Captain for this sync. POSTed to the enroll endpoint so Captain can bind this deployment to your sync. Sensitive; never printed to outputs."

  validation {
    condition     = length(var.enrollment_secret) >= 16
    error_message = "enrollment_secret must be at least 16 characters. Captain mints this for you; do not shorten or invent one."
  }
}

variable "external_id" {
  type        = string
  description = "Per-sync external id (confused-deputy guard). Echoed to Captain during enrollment and carried, URL-encoded, on the push endpoint so Captain can bind incoming events to the right sync. Captain fills this in."

  validation {
    condition     = length(var.external_id) >= 8 && length(var.external_id) <= 1224
    error_message = "external_id must be between 8 and 1224 characters."
  }

  validation {
    # Restrict to RFC 3986 unreserved characters. This is belt and suspenders
    # with the urlencode() call on push_endpoint in main.tf: even if a future
    # external_id somehow skipped encoding, it still could not inject a query
    # param or corrupt the push endpoint URL.
    condition     = can(regex("^[A-Za-z0-9._~-]+$", var.external_id))
    error_message = "external_id must contain only letters, digits, and the characters . _ ~ - (URL-safe, no encoding required)."
  }
}

variable "captain_reader_service_account" {
  type        = string
  description = "Captain's OWN Google service account email. This template grants it roles/storage.objectViewer on your bucket. Captain authenticates as this identity from its own project, so NO long-lived keys ever leave your account. Captain fills this in."

  validation {
    condition     = can(regex("^[a-z0-9-]+@[a-z0-9-]+\\.iam\\.gserviceaccount\\.com$", var.captain_reader_service_account))
    error_message = "captain_reader_service_account must be a Google service account email ending in .iam.gserviceaccount.com."
  }
}

variable "captain_ingest_url" {
  type        = string
  description = "Captain's Pub/Sub push ingest endpoint. The push subscription delivers object-change events here, authenticated with a Google-signed OIDC token. PLACEHOLDER default shown; Captain fills this in when it generates your deploy link. Must be https."
  default     = "https://api.runcaptain.com/v1/deploy/gcp/gcs/ingest"

  validation {
    condition     = can(regex("^https://", var.captain_ingest_url))
    error_message = "captain_ingest_url must be an https:// URL. Pub/Sub push with OIDC refuses plaintext, and so does Captain."
  }
}

variable "captain_enroll_url" {
  type        = string
  description = "Captain's enrollment endpoint. The self-verifying phone-home POSTs the deployment facts here on apply/destroy; Captain runs its read + delivery handshake and returns verified:true only if both pass. PLACEHOLDER default shown. Must be https."
  default     = "https://api.runcaptain.com/v1/deploy/gcp/gcs/enroll"

  validation {
    condition     = can(regex("^https://", var.captain_enroll_url))
    error_message = "captain_enroll_url must be an https:// URL (the phone-home refuses to send the secret over plaintext)."
  }
}

variable "oidc_audience" {
  type        = string
  description = "Audience claim Pub/Sub mints into the OIDC token on each push. Captain validates it. Leave empty to use captain_ingest_url as the audience (the common case). Captain fills this in only if its verifier expects a distinct audience."
  default     = ""
}

variable "event_types" {
  type        = list(string)
  description = "GCS object events that trigger a Pub/Sub notification. Defaults cover create, delete, metadata change, and lifecycle archive so reconcile stays accurate. Removing OBJECT_DELETE means deletions only reconcile on the polling backstop."
  default     = ["OBJECT_FINALIZE", "OBJECT_DELETE", "OBJECT_METADATA_UPDATE", "OBJECT_ARCHIVE"]

  validation {
    condition     = length(var.event_types) > 0 && alltrue([for e in var.event_types : contains(["OBJECT_FINALIZE", "OBJECT_DELETE", "OBJECT_METADATA_UPDATE", "OBJECT_ARCHIVE"], e)])
    error_message = "event_types must be a non-empty subset of: OBJECT_FINALIZE, OBJECT_DELETE, OBJECT_METADATA_UPDATE, OBJECT_ARCHIVE."
  }
}

variable "object_name_prefix" {
  type        = string
  description = "Optional object-name prefix filter. When set, only objects under this prefix produce notifications (reconcile still covers the whole grant). Empty means the whole bucket."
  default     = ""
}

variable "manage_apis" {
  type        = bool
  description = "When true, Terraform enables the pubsub and storage APIs on the project (idempotent, never disabled on destroy). Set false if your org enables APIs centrally and the deploying principal lacks serviceusage.services.enable."
  default     = true
}

variable "ack_deadline_seconds" {
  type        = number
  description = "Pub/Sub push ack deadline. Captain must ack within this window or the message redelivers. 60s is a safe default for an ingest endpoint doing quick enqueue-and-ack."
  default     = 60

  validation {
    condition     = var.ack_deadline_seconds >= 10 && var.ack_deadline_seconds <= 600
    error_message = "ack_deadline_seconds must be between 10 and 600."
  }
}

variable "message_retention_duration" {
  type        = string
  description = "How long Pub/Sub retains an unacked message before dropping it (the webhook side is a latency optimization; reconcile is the always-on backstop). Format like 604800s (7 days, the max)."
  default     = "604800s"
}

variable "labels" {
  type        = map(string)
  description = "Extra labels applied to the topic and subscription, merged with Captain's own tagging labels."
  default     = {}
}
