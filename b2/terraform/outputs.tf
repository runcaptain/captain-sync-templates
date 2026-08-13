output "deployment_id" {
  description = "Stripe-style deployment id (dep_<token>). Use it to look up deployment state in Captain."
  value       = local.deployment_id
}

output "read_key_id" {
  description = "The scoped read-only application key id Captain uses over the S3-compatible endpoint. The secret half is never output."
  value       = b2_application_key.captain_read.application_key_id
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
    "Deployment %s is enrolled and verified for sync %s. Open your Captain dashboard; a targeted reconcile of %s runs now, and future changes %s.",
    local.deployment_id,
    var.sync_id,
    var.bucket_name,
    var.event_path == "enabled" ? "webhook in near-real-time" : "sync via the reconcile backstop (event path skipped; enable B2 Event Notifications to add the latency path)"
  )
}
