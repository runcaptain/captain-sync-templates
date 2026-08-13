output "deployment_id" {
  description = "Stripe-style deployment id (dep_<token>). Use it to look up deployment state and debug on Captain's side."
  value       = local.deployment_id
}

output "pubsub_topic" {
  description = "The Pub/Sub topic GCS publishes object-change events to."
  value       = google_pubsub_topic.captain_sync.id
}

output "pubsub_subscription" {
  description = "The push subscription that delivers events to Captain's ingest endpoint with an OIDC token."
  value       = google_pubsub_subscription.captain_push.id
}

output "push_service_account" {
  description = "The service account Pub/Sub signs OIDC tokens as. Captain allowlists this email; a push whose token subject is not this SA is rejected."
  value       = google_service_account.push.email
}

output "captain_reader_binding" {
  description = "The Captain service account granted roles/storage.objectViewer on your bucket (no long-lived keys; Captain authenticates as itself)."
  value       = "${var.captain_reader_service_account} => roles/storage.objectViewer on ${var.bucket_name}"
}

output "storage_notification_id" {
  description = "The GCS notification config id attached to the bucket (additive; other notifications on the bucket are untouched)."
  value       = google_storage_notification.captain.notification_id
}

output "oidc_audience" {
  description = "The audience claim Captain validates on each push OIDC token."
  value       = local.oidc_audience
}

output "what_to_do_next" {
  description = "One-line next step."
  value       = "Deployment ${local.deployment_id} is enrolled and verified. Open your Captain dashboard for sync ${var.sync_id}; a targeted reconcile of gs://${var.bucket_name} runs automatically and future object changes push near-real-time."
}
