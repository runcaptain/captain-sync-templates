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

variable "captain_api_key" {
  type        = string
  sensitive   = true
  description = "Your Captain API key. Sent as 'Authorization: Bearer <key>' on the webhook-registration call (POST /v2/syncs/<sync_id>/webhooks) and nowhere else. Sensitive; never printed to outputs. Prefer TF_VAR_captain_api_key over writing it into terraform.tfvars."

  validation {
    condition     = length(var.captain_api_key) > 0
    error_message = "captain_api_key must be set. Mint one in your Captain dashboard; see https://docs.captain.dev/guides/sync/set-up."
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
  description = "The per-sync ingest URL the push subscription delivers to: the subscribe_url that POST /v2/syncs/<sync_id>/webhooks returns. Captain pre-fills it when it generates your tfvars; there is NO default because every sync gets its own minted URL. See https://docs.captain.dev/guides/sync/set-up. Must be https."

  validation {
    condition     = can(regex("^https://", var.captain_ingest_url))
    error_message = "captain_ingest_url must be an https:// URL. It is the subscribe_url Captain minted for this sync; Pub/Sub push with OIDC refuses plaintext, and so does Captain."
  }
}

variable "captain_api_base" {
  type        = string
  description = "Base URL of the Captain API the webhook-registration call goes to. Leave the default (https://api.captain.dev) unless Captain gave you a staging base. Must be https."
  default     = "https://api.captain.dev"

  validation {
    condition     = can(regex("^https://", var.captain_api_base))
    error_message = "captain_api_base must be an https:// URL (the registration call refuses to send the API key over plaintext)."
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
