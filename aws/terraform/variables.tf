# All inputs mirror the CloudFormation template's parameters one-for-one, with
# the same validation and the same "Captain fills this in" convention. Captain
# normally generates a terraform.tfvars for you; see terraform.tfvars.example.

variable "aws_region" {
  type        = string
  description = <<-EOT
    Region to deploy into. MUST be the same region as your bucket: S3-to-SNS
    event notifications are same-region. The cross-account read role is global,
    so region = bucket region is the only thing that must line up.
  EOT

  validation {
    # The `var == null ? true :` guard keeps `terraform validate` clean: an unset
    # required variable is unknown, and can(regex(...)) would otherwise collapse
    # that unknown to a false. Real values are still enforced at plan/apply.
    condition     = var.aws_region == null ? true : can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must look like a region id, e.g. us-east-1."
  }
}

variable "captain_api_base" {
  type        = string
  description = <<-EOT
    Base URL of the Captain API. The enroll Lambda POSTs to
    {captain_api_base}/v2/syncs/{sync_id}/webhooks on create/update. Leave the
    production default unless Captain support points you at a staging
    environment. Must be https:// (the Lambda refuses to send the API key over
    plaintext).
  EOT
  default     = "https://api.captain.dev"

  validation {
    condition     = startswith(var.captain_api_base, "https://")
    error_message = "captain_api_base must be an https:// URL."
  }
}

variable "captain_account_id" {
  type        = string
  description = <<-EOT
    Captain's AWS account id. The cross-account read role trusts this principal
    (scoped further by external_id). Captain fills this in.
  EOT

  validation {
    condition     = var.captain_account_id == null ? true : can(regex("^[0-9]{12}$", var.captain_account_id))
    error_message = "captain_account_id must be a 12-digit AWS account id."
  }
}

variable "external_id" {
  type        = string
  description = <<-EOT
    Per-sync external id. Captain must present it when assuming the read role,
    which blocks the confused-deputy problem. Captain fills this in.
  EOT

  validation {
    # Length is checked separately, not inside the regex: Go's RE2 engine caps
    # bounded repetition at 1000, so a `{8,1224}` bound would fail to compile and
    # can() would swallow it into a spurious false. The char-set regex is unbounded.
    condition     = var.external_id == null ? true : (length(var.external_id) >= 8 && length(var.external_id) <= 1224 && can(regex("^[A-Za-z0-9+=,.@:/_-]+$", var.external_id)))
    error_message = "external_id must be 8-1224 chars from the STS external-id set (letters, digits, +=,.@:/_-)."
  }
}

variable "bucket_name" {
  type        = string
  description = "The EXISTING S3 bucket to sync. This module does not create it."

  validation {
    condition     = var.bucket_name == null ? true : can(regex("^[a-z0-9.\\-]{3,63}$", var.bucket_name))
    error_message = "bucket_name must be a valid S3 bucket name (3-63 chars, lowercase)."
  }
}

variable "object_prefix" {
  type        = string
  description = <<-EOT
    Optional. Restrict the sync to keys under this prefix, e.g. "docs/". When
    set, both the S3 event filter AND the read role are scoped to it, so Captain
    can neither see nor fetch objects outside the prefix. Empty = whole bucket.
  EOT
  default     = ""

  validation {
    condition     = length(var.object_prefix) <= 1024 && !can(regex("[\n\r]", var.object_prefix))
    error_message = "object_prefix must be a single-line key prefix of at most 1024 chars."
  }
}

variable "kms_key_arn" {
  type        = string
  description = <<-EOT
    Optional but REQUIRED if your bucket uses SSE-KMS with a customer-managed
    key. Without kms:Decrypt on that key, Captain's GetObject calls fail with
    AccessDenied even though the role has s3:GetObject. Set this to the bucket's
    KMS key ARN and the read role gets kms:Decrypt scoped to exactly that key.
    Leave empty for SSE-S3 (AES256) or unencrypted buckets.
  EOT
  default     = ""

  validation {
    condition     = var.kms_key_arn == "" || can(regex("^arn:[a-z-]+:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.kms_key_arn))
    error_message = "kms_key_arn must be empty or a full KMS key ARN (arn:aws:kms:REGION:ACCOUNT:key/KEY-ID)."
  }
}

variable "sync_id" {
  type        = string
  description = "The Captain sync id (sync_<token>) this deployment enrolls. Captain fills this in."

  validation {
    # 44-char cap: sync_id is baked verbatim into IAM role and Lambda function
    # names, which AWS caps at 64 chars. 44 is the longest value that still
    # fits under the longest of those names (captain-s3-setnotif-<sync_id>,
    # a 20-char prefix). Without this bound, a too-long sync_id fails
    # CreateRole, and CloudFormation-style automatic rollback would then hit
    # the identical AWS validation error trying to delete the same
    # over-length name -- but Terraform applies this bound up front via
    # `terraform plan`, before any resource is created, so that failure mode
    # cannot happen here.
    condition     = var.sync_id == null ? true : (length(var.sync_id) <= 44 && can(regex("^sync_[A-Za-z0-9]+$", var.sync_id)))
    error_message = "sync_id must be a Captain sync id of the form sync_<token>, 44 chars or fewer."
  }
}

variable "captain_api_key" {
  type        = string
  sensitive   = true
  description = <<-EOT
    Your Captain API key. Sent as an "Authorization: Bearer" header to the
    Captain API so the webhook registration runs against your account.
    Marked sensitive; never printed in plan/apply output and redacted in logs.
  EOT

  validation {
    condition     = var.captain_api_key == null ? true : length(var.captain_api_key) >= 8
    error_message = "captain_api_key must be at least 8 characters."
  }
}

variable "debug_logging" {
  type        = string
  description = <<-EOT
    Verbose CloudWatch logging for the deploy Lambdas ("true"/"false"). Leave
    "true" while standing the sync up; every step prints a structured,
    secret-redacted line. Set "false" to quiet the logs afterwards.
  EOT
  default     = "true"

  validation {
    condition     = contains(["true", "false"], var.debug_logging)
    error_message = "debug_logging must be \"true\" or \"false\"."
  }
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch retention (days) for the deploy Lambda log groups."
  default     = 30
}
