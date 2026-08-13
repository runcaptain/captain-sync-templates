output "deployment_id" {
  description = "Stripe-style deployment id (dep_<token>). Share it with Captain support to identify this deploy attempt."
  value       = local.deployment_id
}

output "subscribe_url" {
  description = "Per-sync ingest URL Captain minted when it accepted the webhook registration."
  value       = try(jsondecode(aws_lambda_invocation.enroll.result).subscribeUrl, null)
}

output "sns_topic_arn" {
  description = "SNS topic the bucket publishes change events to; Captain subscribes here."
  value       = aws_sns_topic.captain.arn
}

output "read_role_arn" {
  description = "Cross-account read-only role Captain assumes (with the external id)."
  value       = aws_iam_role.read.arn
}

output "external_id" {
  description = "External id Captain must present when assuming the read role."
  value       = var.external_id
}

output "sync_scope" {
  description = "What Captain can read: whole bucket, or the prefix if one was set."
  value       = var.object_prefix != "" ? "s3://${var.bucket_name}/${var.object_prefix}* (prefix-scoped)" : "s3://${var.bucket_name}/* (whole bucket)"
}

output "template_version" {
  description = "Date-based version of this deploy artifact."
  value       = local.template_version
}

output "debug_logs_here" {
  description = "CloudWatch log groups to read if a deploy fails."
  value       = "${aws_cloudwatch_log_group.enroll.name} and ${aws_cloudwatch_log_group.setnotif.name}"
}

output "captain_verify_result" {
  description = "The webhook-registration result the Captain API returned during enrollment."
  value       = try(jsondecode(aws_lambda_invocation.enroll.result), aws_lambda_invocation.enroll.result)
}

output "what_to_do_next" {
  description = "One-line next step."
  value       = "Deployment ${local.deployment_id} is enrolled: Captain subscribed to your topic. Open your Captain dashboard for sync ${var.sync_id}; object changes in ${var.bucket_name} now sync near-real-time, with reconcile as the backstop. Guide: https://docs.captain.dev/guides/sync/set-up"
}
