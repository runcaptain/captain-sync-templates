# Captain GCS one-click sync (self-verifying) - provider + version pins.
#
# Template version (date-based, YYYY-MM-DD). Bump this when the template shape
# changes and re-host it under a matching dated path, e.g.
#   .../templates/2026-08-12/gcp/terraform
# Customer-facing object ids here are Stripe-style prefix_token (dep_..., sync_...),
# never bare UUIDs.

terraform {
  required_version = ">= 1.4.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0.0, < 7.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
  }
}

# The phone-home (terraform_data + local-exec) shells out to enroll.sh, which
# needs curl and jq on PATH. No extra provider is required for it.
