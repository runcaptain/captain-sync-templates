# Engineering notes: aws/ templates

Design notes for contributors. The full S3 design detail (notification
overlap rule, SyncId length bound, log-group naming, Terraform retry
design, backend contract) lives in the root [`../NOTES.md`](../NOTES.md);
this file covers what you need when working inside `aws/`.

## Status and backend contract

Both paths validate clean (`cfn-lint`, `aws cloudformation
validate-template`, `terraform validate`, `terraform fmt`, `tflint`).

The enroll step calls the real, live Captain API:
`POST {api_base}/v2/syncs/{sync_id}/webhooks` with
`Authorization: Bearer {api_key}` and body
`{"sns_topic_arn": "..."}` (required for S3-family syncs; the API returns
422 without it). Success is a 2xx JSON response carrying `subscribe_url`
(the per-sync ingest URL Captain minted), `secret_set`, and `instructions`;
a 2xx with a `subscribe_url` IS successful enrollment, because the API
subscribing to the topic is the enrollment. The canonical `api_base` is
`https://api.captain.dev`, overridable per deploy for staging.

The remaining customer-facing caveat is only that the customer needs a real
sync id and API key from Captain before deploying; the minted
`subscribe_url` comes back at enroll time. There is no unsubscribe endpoint,
so teardown makes NO Captain call: removing the topic is enough, Captain
detects the dead event source, and reconcile remains the backstop. Do not
invent a teardown POST. Deployment-state lookup by `DeploymentId`
(`dep_<token>`) is still backend work; the customer README tells customers
to share the id with Captain support rather than promising a self-serve
endpoint.

## CloudFormation log groups

Log group names embed a per-stack-attempt token so a retry of a failed
Launch Stack never collides with a group orphaned by the
rollback-vs-CloudWatch delivery race. Two simpler designs fail:
`DeletionPolicy: Retain` plus a cleanup resource guarantees a retained
group named on the sync id alone, which hard-fails the retry with "already
exists"; plain groups at the default `/aws/lambda/<function>` names leave a
race orphan with exactly the name the retry needs, and CloudFormation
rejects the retry at resource validation. The customer README keeps the
caveat (a delete or rollback can leave an empty recreated log group behind)
and its cleanup commands; that residue is tolerated as cosmetic and
collision-proof. See the root NOTES.md for the full mechanics.

## Terraform retry: why no auto re-invoke

The two `aws_lambda_invocation` resources re-invoke only when their `input`
changes, so a failed apply's cached result means an identical re-apply will
not retry on its own. Retries are explicit:
`terraform apply -replace=aws_lambda_invocation.<setnotif|enroll>`, named
in the postcondition error messages and documented in the customer README.
A `timestamp()`-based trigger is not an option: on this resource type
`triggers` forces replacement, which would remove and re-add the live
bucket notification and re-register the webhook with Captain on every
unrelated apply.

## Testing changes

Run the static checks above; all must pass clean. For a live test, use a
throwaway uniquely named bucket and stack with a mock Captain API base
(the `CaptainApiBase` / `captain_api_base` override exists for exactly
this), and tear everything down afterward. The scenarios worth exercising, and the
teardown discipline, are listed at the end of the root NOTES.md.
