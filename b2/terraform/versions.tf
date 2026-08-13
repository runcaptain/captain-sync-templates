# captain-b2-sync Terraform module (template version 2026-08-12)
#
# IaC equivalent of setup/captain-b2-sync.sh for teams that manage cloud wiring
# with Terraform. It stands up the SAME three things in your own Backblaze
# account: a scoped read-only application key (the reconcile grant), a native B2
# Event Notification rule (the latency path), and a self-verifying phone-home to
# Captain so a clean `apply` means a CONFIRMED sync.
#
# Provider auth: set B2_APPLICATION_KEY_ID and B2_APPLICATION_KEY in the
# environment (an operator key that can create keys + manage notifications).
# These are used only by Terraform during apply; they are never sent to Captain.
#
# STATE CONTAINS SECRETS. This stack's state holds the scoped read application
# key (b2_application_key.captain_read.application_key) and the generated HMAC
# secret (random_password.hmac.result) IN PLAINTEXT. Marking a value
# `sensitive = true` only redacts it from CLI/plan output, it does not encrypt
# state. (The Captain enrollment secret, var.secret, is NOT in this list: it is
# passed only through the local-exec `environment` block on null_resource.enroll
# and never lands in a resource attribute or in `triggers`, so it does not get
# written to state. See variables.tf's description of `secret`.) You MUST point
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
# enrollment secret does not need rotation on a state leak since it was never
# written there; treat it as compromised only if it leaked some other way.

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
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "b2" {
  # application_key_id / application_key come from B2_APPLICATION_KEY_ID and
  # B2_APPLICATION_KEY. Leaving them unset here keeps operator secrets out of
  # the config and the state file.
}
