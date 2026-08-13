# Engineering notes: aws/ templates

Design notes for contributors. The full S3 design detail (notification
overlap rule, SyncId length bound, log-group naming, Terraform retry
design, backend contract) lives in the root [`../NOTES.md`](../NOTES.md);
this file covers what you need when working inside `aws/`.

## Status and backend dependency

Both paths validate clean (`cfn-lint`, `aws cloudformation
validate-template`, `terraform validate`, `terraform fmt`, `tflint`).
Enrollment verification is not yet activated on the Captain backend, so a
real end-to-end stack create or `apply` fails at the final verify step by
design; everything up to that step is exercisable today. Deployment-state
lookup by `DeploymentId` (`dep_<token>`) is also backend work; the customer
README tells customers to share the id with Captain support rather than
promising a self-serve endpoint.

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
bucket notification and re-send the one-time enrollment secret on every
unrelated apply.

## Testing changes

Run the static checks above; all must pass clean. For a live test, use a
throwaway uniquely named bucket and stack with a mock enroll endpoint, and
tear everything down afterward. The scenarios worth exercising, and the
teardown discipline, are listed at the end of the root NOTES.md.
