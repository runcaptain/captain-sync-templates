# NOTES: internal context for the aws/ templates (CAP-569)

Internal, not customer-facing. Content relocated here from the aws/ READMEs
during the customer-docs rewrite, plus pointers into the root
[`../NOTES.md`](../NOTES.md), which holds the full CAP-569 engineering history
(overlap-rule live confirmation, SyncId MaxLength rollback wedge, log-group
race testing, Terraform re-invoke adversarial testing).

## Status and backend dependency (CAP-586)

The templates validate clean (`cfn-lint`, `aws cloudformation
validate-template`, `terraform validate`, `terraform fmt`, `tflint`) and the
Terraform plans clean against a real account. The self-verify phone-home POSTs
to a Captain backend receiver that is separate work (CAP-586); until it exists
the enroll POST 404s, so a real end-to-end `apply`/stack-create fails at the
final verify step by design. Everything up to that step is exercisable today.
The exact backend contract is in [`../NOTES.md`](../NOTES.md). The customer
READMEs phrase this as "enrollment verification is not yet activated".

The deployment-state lookup by `DeploymentId` (`dep_<token>`) is also CAP-586
scope: the customer README now tells customers to share the id with Captain
support rather than promising a self-serve endpoint.

## Publishing the CloudFormation template

The Launch Stack button in `cloudformation/README.md` points at
`https://captain-deploy-templates.s3.amazonaws.com/templates/<date>/captain-s3-sync.yaml`,
which is a placeholder host: nothing is published there yet. At publish time,
upload `cloudformation/captain-s3-sync.yaml` to the real public template
bucket under a dated path and update the button URL (and the root README's
button) to match. Until then the customer README tells customers to clone the
repo and upload the template file directly.

## Conventions

- Template/version URL paths are DATE-based, `YYYY-MM-DD`
  (`.../templates/2026-08-13/...`).
- Customer-facing ids are Stripe-style `prefix_token` (`dep_...`, `sync_...`).
  No bare UUIDs.

## CloudFormation log groups: rejected designs

The customer README keeps the caveat (a delete or rollback can leave an empty
recreated log group behind) and its cleanup commands; the design history lives
here. Two designs were tried and rejected, both live-disproven:

- `DeletionPolicy: Retain` plus a cleanup custom resource. Reverted: it
  guaranteed a retained, never-deleted log group whose name was derived from
  the sync id alone, which hard-failed the customer's RETRY of the same
  Launch Stack link with an "already exists" error. Strictly worse than the
  occasional empty log group it was meant to remove.
- Plain log groups at the default `/aws/lambda/<function>` names (derived
  from the sync id alone). Also reverted: when the rollback race fires, the
  orphan it leaves has exactly the name the retry needs, and CloudFormation
  rejects the retry at resource validation. The per-attempt token in the name
  is what makes retries collision-proof.

Full reproduction detail is in the root NOTES.md section "CloudFormation:
rollback log-group race and the retry collision".

## Terraform retry: why no auto re-invoke

An earlier version of the Terraform module forced a re-invoke of the two
`aws_lambda_invocation` resources on every apply via a `timestamp()`-based
trigger. That is a force-REPLACE argument on this resource type: it destroyed
and recreated both invocations on EVERY apply, not just retries. For
`setnotif` that meant the real bucket notification config was removed and
re-added on every unrelated apply; for `enroll` it meant the one-time
enrollment secret got re-sent to Captain on every unrelated apply. The trigger
was removed; retries are now explicit via
`terraform apply -replace=aws_lambda_invocation.<setnotif|enroll>`, which the
customer README documents. Adversarial-testing detail is in the root NOTES.md.
