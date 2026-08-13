# Inputs. Captain normally hands you a filled-in terraform.tfvars when it
# generates your setup command, so you only review and `terraform apply`.

variable "sync_id" {
  type        = string
  description = "Captain sync id (sync_<token>) this deployment enrolls."

  validation {
    condition     = can(regex("^sync_[A-Za-z0-9]+$", var.sync_id))
    error_message = "sync_id must be of the form sync_<token> (letters and digits after the prefix)."
  }
}

variable "secret" {
  type        = string
  sensitive   = true
  description = "One-time enrollment secret Captain minted for this sync (>= 16 chars). Sent to Captain over TLS only; never stored anywhere it can be read back."

  validation {
    condition     = length(var.secret) >= 16
    error_message = "secret must be at least 16 characters."
  }
}

variable "bucket_name" {
  type        = string
  description = "EXISTING Backblaze B2 bucket to sync. This module does not create it."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{4,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be a valid B2 bucket name (6-63 chars, lowercase letters/digits/'.'/'-')."
  }
}

variable "callback_url" {
  type        = string
  default     = "https://api.runcaptain.com/v1/deploy/b2/enroll"
  description = "Captain enroll endpoint the phone-home POSTs to. Must be https. PLACEHOLDER default; Captain fills this in per-sync."

  validation {
    condition     = can(regex("^https://", var.callback_url))
    error_message = "callback_url must be an https:// URL (the secret is only ever sent over TLS)."
  }
}

variable "events_url" {
  type        = string
  default     = ""
  description = "Captain ingest webhook the B2 notification rule points at. Must be https. Defaults to the enroll host's /events path tagged with the sync id when left blank."

  validation {
    condition     = var.events_url == "" || can(regex("^https://", var.events_url))
    error_message = "events_url must be blank or an https:// URL."
  }
}

variable "key_duration_seconds" {
  type        = number
  default     = null
  description = "Optional expiry for the scoped read key, in seconds (rotation). Null means a non-expiring key. Must be < 1000 days."

  validation {
    condition     = var.key_duration_seconds == null || (var.key_duration_seconds > 0 && var.key_duration_seconds < 86400000)
    error_message = "key_duration_seconds must be null or a positive integer below 86400000 (1000 days)."
  }
}

variable "event_path" {
  type        = string
  default     = "skip"
  description = "skip: reconcile-only, do not create the notification rule (DEFAULT, because B2 Event Notifications are account-gated by Backblaze; see b2/NOTES.md). enabled: create the rule (use once Backblaze has enabled the feature on your account)."

  validation {
    condition     = contains(["skip", "enabled"], var.event_path)
    error_message = "event_path must be either 'skip' or 'enabled'."
  }
}
