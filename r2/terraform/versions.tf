# Terraform / OpenTofu version and provider pins for the Captain R2 sync stack.
# Validated with `tofu validate` (OpenTofu 1.12) against cloudflare provider 5.x.
#
# STATE CONTAINS SECRETS. This stack's state holds the Captain enrollment
# secret (var.captain_secret, written into the Worker's CAPTAIN_SECRET) and
# the derived R2 read credentials (cloudflare_api_token.read's id and the
# SHA-256 secret computed from its value) IN PLAINTEXT. Terraform state is
# not encrypted at rest by default. You MUST point this stack at an encrypted
# remote backend before running it against anything real, for example:
#
#   terraform {
#     backend "s3" {
#       bucket  = "your-tfstate-bucket"
#       key     = "captain-r2-sync/terraform.tfstate"
#       region  = "us-east-1"
#       encrypt = true              # SSE on the bucket, or use a KMS key
#     }
#   }
#
# or Terraform Cloud / OpenTofu Cloud (state is encrypted at rest by default),
# or any backend that guarantees encryption at rest plus access control. Local
# state (the default when no `backend` block is set) is UNENCRYPTED on disk
# and MUST NOT be used beyond a throwaway local test.
#
# ROTATION: to rotate the leaked-or-expiring credentials in state, re-apply
# (the read token has expires_on = read_token_ttl_days and Cloudflare issues a
# new token value on each create; to force rotation early, `tofu taint
# cloudflare_api_token.read` then apply). Rotating captain_secret means
# changing the input variable and re-applying, which rewrites the Worker
# secret too. Either rotation still leaves the OLD value in older state
# versions/history unless your backend's state history is also purged or the
# backend does not retain history (reason enough, on its own, to use a
# backend with access control instead of a shared file).
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}
