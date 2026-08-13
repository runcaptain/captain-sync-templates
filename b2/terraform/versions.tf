# captain-b2-sync Terraform module (template version 2026-08-13)
#
# IaC equivalent of setup/captain-b2-sync.sh for teams that manage cloud wiring
# with Terraform. It stands up the SAME three things in your own Backblaze
# account: enrollment of the sync's event webhook with Captain's API (which
# mints the per-sync subscribe URL), a native B2 Event Notification rule
# targeting that URL (the latency path), and a scoped read-only application
# key (the reconcile grant). A clean `apply` means an ENROLLED sync.
#
# Provider auth: set B2_APPLICATION_KEY_ID and B2_APPLICATION_KEY in the
# environment (an operator key that can create keys + manage notifications).
# These are used only by Terraform during apply; they are never sent to Captain.
# Captain auth: set CAPTAIN_API_KEY in the environment; enroll_webhook.sh sends
# it as an Authorization: Bearer header and it never enters the plan or state.
#
# STATE CONTAINS SECRETS. This stack's state holds the scoped read application
# key (b2_application_key.captain_read.application_key) and the generated HMAC
# secret (random_password.hmac.result) IN PLAINTEXT. Marking a value
# `sensitive = true` only redacts it from CLI/plan output, it does not encrypt
# state. (The Captain API key is NOT in this list: it travels only through the
# CAPTAIN_API_KEY environment variable into enroll_webhook.sh and never lands
# in a resource attribute, a data-source query, or state.) You MUST point
# this stack at an encrypted remote backend before running it against anything
# real, for example:
#
#   terraform {
#     backend "s3" {
#       bucket  = "your-tfstate-bucket"
#       key     = "captain-b2-sync/terraform.tfstate"
#       region  = "us-east-1"
#       encrypt = true              # SSE on the bucket, or use a KMS key
#     }
#   }
#
# or Terraform Cloud / OpenTofu Cloud (state is encrypted at rest by default),
# or any backend that guarantees encryption at rest plus access control. Local
# state (the default when no `backend` block is set) is UNENCRYPTED on disk
# and MUST NOT be used beyond a throwaway local test. If state is ever exposed,
# rotate the scoped key (b2_delete_key on the old key id) and regenerate the
# HMAC signing secret (taint random_password.hmac and re-apply). The Captain
# API key does not need rotation on a state leak since it was never written
# there; treat it as compromised only if it leaked some other way.

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    b2 = {
      source  = "Backblaze/b2"
      version = "~> 0.13"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}

provider "b2" {
  # application_key_id / application_key come from B2_APPLICATION_KEY_ID and
  # B2_APPLICATION_KEY. Leaving them unset here keeps operator secrets out of
  # the config and the state file.
}
