output "deployment_id" {
  description = "Stripe-style deployment id (dep_<token>). Use it to look up deployment state in Captain."
  value       = local.deployment_id
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
  description = "The verification result Captain returned during the phone-home handshake."
  value       = try(jsondecode(aws_lambda_invocation.enroll.result), aws_lambda_invocation.enroll.result)
}

output "what_to_do_next" {
  description = "One-line next step."
  value       = "Deployment ${local.deployment_id} is enrolled and verified. Open your Captain dashboard for sync ${var.sync_id}; a targeted reconcile of ${var.bucket_name} runs automatically and future object changes sync near-real-time."
}
