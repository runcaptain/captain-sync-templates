output "deployment_id" {
  description = "Stripe-style deployment id (dep_<token>). Use it to look up deployment state in Captain."
  value       = local.deployment_id
}

output "read_key_id" {
  description = "The scoped read-only application key id for the reconcile grant. Pair with read_application_key when setting the sync's credentials in Captain."
  value       = b2_application_key.captain_read.application_key_id
}

output "read_application_key" {
  description = "Secret half of the scoped read key, for setting as the sync's Backblaze credentials in Captain (https://docs.captain.dev/guides/sync/set-up). Marked sensitive: view with `terraform output -raw read_application_key`. It also lives in state; see versions.tf."
  value       = b2_application_key.captain_read.application_key
  sensitive   = true
}

output "subscribe_url" {
  description = "Per-sync ingest URL Captain minted at enrollment; the B2 Event Notification rule targets it. Returning this with 2xx is Captain's confirmation of enrollment."
  value       = local.subscribe_url
}

output "s3_endpoint" {
  description = "S3-compatible endpoint for this account, the reconcile backstop target."
  value       = local.s3_endpoint
}

output "region" {
  description = "B2 region derived from the S3 endpoint (for example us-east-005)."
  value       = local.s3_region
}

output "event_path" {
  description = "Whether the native Event Notification rule was created (enabled) or skipped because Backblaze has not enabled the feature on this account (skipped)."
  value       = var.event_path == "enabled" ? "enabled" : "skipped"
}

output "notification_rule_name" {
  description = "Name of the Captain notification rule (present only when event_path = enabled)."
  value       = local.rule_name
}

output "what_to_do_next" {
  description = "One-line next step."
  value = format(
    "Deployment %s is enrolled for sync %s. If the sync does not already use the scoped read key as its credentials, set it in Captain (docs.captain.dev/guides/sync/set-up); future changes to %s %s.",
    local.deployment_id,
    var.sync_id,
    var.bucket_name,
    var.event_path == "enabled" ? "webhook to the subscribe URL in near-real-time" : "sync via the scheduled reconcile backstop (event path skipped; enable B2 Event Notifications to add the latency path)"
  )
}
