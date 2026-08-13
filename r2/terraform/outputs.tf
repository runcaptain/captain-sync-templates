# Outputs are written to tell the tester exactly what happened and what to do next.

output "deployment_id" {
  description = "Stripe-style deployment id (dep_<token>) local to this stack; a stable reference for support and audit trails."
  value       = local.deployment_id
}

output "queue_name" {
  description = "Queue that R2 object-change events flow through to the Worker."
  value       = cloudflare_queue.main.queue_name
}

output "dead_letter_queue_name" {
  description = "Dead-letter queue where events park after repeated Captain ingest failures."
  value       = cloudflare_queue.dlq.queue_name
}

output "worker_name" {
  description = "Consumer Worker name."
  value       = cloudflare_workers_script.consumer.script_name
}

output "worker_url" {
  description = "Public URL for the Worker health check and keyless read proxy (empty if workers_subdomain was not set)."
  value       = local.worker_url
}

output "read_access_key_id" {
  description = "R2 S3 API access key id (the scoped, bucket-only read token id). Feed to Captain's R2 sync as access_key_id. `sensitive = true` hides it from plan/apply output, but it is still stored in Terraform state in plaintext; see versions.tf for the required encrypted backend."
  value       = cloudflare_api_token.read.id
  sensitive   = true
}

output "read_secret_access_key" {
  description = "R2 S3 API secret access key (SHA-256 of the token value). Feed to Captain's R2 sync as secret_access_key. Same plaintext-in-state caveat as read_access_key_id."
  value       = sha256(cloudflare_api_token.read.value)
  sensitive   = true
}

output "read_token_expires_on" {
  description = "When the scoped read token expires. Re-apply before this to rotate. 'never' if read_token_ttl_days = 0."
  value       = var.read_token_ttl_days > 0 ? timeadd(time_static.read_token_created.rfc3339, "${var.read_token_ttl_days * 24}h") : "never"
}

output "captain_subscribe_url" {
  description = "The per-sync ingest URL Captain minted via POST {captain_api_base}/v2/syncs/{sync_id}/webhooks. The Worker forwards object-change events here. If the apply reached this output, the subscription is confirmed (the postcondition gates it)."
  value       = local.captain_ingest_url
}

output "captain_webhook_secret_set" {
  description = "Whether Captain reports a webhook secret is set on this sync (secret_set from the subscribe response)."
  value       = try(jsondecode(data.http.subscribe.response_body).secret_set, false)
}

output "captain_instructions" {
  description = "Any next-step instructions Captain returned with the subscription."
  value       = try(jsondecode(data.http.subscribe.response_body).instructions, [])
}

output "what_to_do_next" {
  description = "One-line next step."
  value       = "Deployment ${local.deployment_id} is enrolled for sync ${var.sync_id}: Captain minted the subscribe_url and the Worker forwards events to it. Feed read_access_key_id / read_secret_access_key into your Captain R2 sync, then Captain reconciles ${var.bucket_name} and future object changes sync near-real-time. If the Queue path looks silent, POST /__captain/selftest on the Worker and watch `wrangler tail`."
}
