# Engineering notes: captain-sync-templates

Contributor-facing notes for the whole repo, plus the deep design detail for
the AWS S3 templates (which live in `aws/`). Each cloud directory has its own
NOTES.md covering that provider's design decisions and testing guidance.

## Repo-wide conventions

- Template versions and versioned URL path segments are date-based,
  `YYYY-MM-DD` (for example `.../templates/2026-08-13/captain-s3-sync.yaml`).
- Customer-facing object ids are Stripe-style `prefix_token` (`dep_...`
  deployment ids, `sync_...` sync ids). No bare UUIDs in outputs.
- No em dashes anywhere in customer-facing copy.

## The self-verifying deploy contract

Every template phones home to a Captain enroll receiver at the end of a
deploy and requires a `2xx` response with `{"verified": true}` before it
reports success. The receiver is expected to prove the grant actually works
(subscribe to the topic, assume the role, probe-read the bucket) before
returning `verified: true`; anything else fails the deploy, and on
CloudFormation rolls the stack back. Enrollment verification is not yet
activated on the Captain backend, so a live end-to-end deploy currently
reaches the phone-home step and fails there by design (fail-closed).
Everything up to that step is exercisable today.

For AWS S3 the enroll POST body is `{deploymentId, templateVersion, action,
stackId, partition, region, bucket, objectPrefix, kmsKeyArn, snsTopicArn,
roleArn, externalId, syncId, secret}` (`objectPrefix` and `kmsKeyArn` are
empty strings when unset).
The receiver must authenticate `secret` against `syncId`, subscribe its
endpoint to `snsTopicArn` (the topic policy allows Captain's account to
`sns:Subscribe`, and the receiver must handle SNS's
`SubscriptionConfirmation` message), and assume `roleArn` with
`sts:ExternalId = externalId` for a probe `ListBucket`/`GetObject`. On stack
delete the custom resource POSTs `{action: "delete", ...}` best-effort; it
never blocks a stack delete, so the backend should reconcile orphaned
subscriptions. Each other cloud's NOTES.md lists its own payload shape for
the same class of receiver.

## S3 bucket notifications: additive merge with a pre-write overlap check

CloudFormation can set a bucket's `NotificationConfiguration` natively only
on a bucket the stack creates and owns. Customers point Captain at an
existing bucket, and a bucket has exactly one notification configuration, so
a naive write would wipe any SNS/SQS/Lambda/EventBridge hooks already there.

The templates therefore use a `SetBucketNotification` custom resource (CFN)
and `functions/setnotif.py` (Terraform) that do an additive read-merge-write:
append only our tagged `TopicConfiguration`, remove only ours on delete.
Caveats:

- The merge is not unconditionally additive. S3 rejects
  `PutBucketNotificationConfiguration` with `InvalidArgument: Configurations
  overlap` whenever the new config's event type (`ObjectCreated` or
  `ObjectRemoved`) overlaps an existing hook's event type on an overlapping
  prefix. A whole-bucket sync (the default, empty prefix) overlaps any
  existing `ObjectCreated`/`ObjectRemoved` hook. The write is an atomic PUT,
  so a rejected write never touches the existing config, but the deploy
  fails for a common bucket state. Both the CFN inline Lambda and
  `setnotif.py` check for this overlap before attempting the write and fail
  fast naming the conflicting config's id, event type, and prefix, instead
  of surfacing S3's opaque `InvalidArgument`. The documented manual jq
  fallback does the same check.
- The remedy for a customer who hits the overlap is a non-overlapping
  `ObjectPrefix` / `object_prefix`. That is the only documented way out. An
  EventBridge-based wiring variant (a bucket-level boolean, no single
  notification slot to collide over) would be a real fix for customers who
  cannot use a prefix, but it does not exist yet, and nothing in the repo
  should point at it until it does.
- The merge needs `s3:GetBucketNotification` and `s3:PutBucketNotification`
  on the bucket. If a customer will not grant that through the stack, the
  README documents a manual `aws s3api` step and the template resources can
  be deleted.
- Each sync's `TopicConfiguration` uses a per-sync id (`captain-<syncId>`),
  so multiple Captain syncs on the same bucket do not collide on config id.
  They can still hit the overlap rule against each other or a third-party
  hook; the same fail-fast behavior applies.

## Terraform: explicit -replace retries, no auto re-invoke

`aws_lambda_invocation.setnotif` and `.enroll` re-invoke their Lambda only
when their `input` changes. A failed apply caches the failing result in
state, so a later `terraform apply` with identical input does not retry on
its own; the postcondition error messages say so explicitly and name the
exact command: `terraform apply -replace=aws_lambda_invocation.setnotif`
(or `.enroll`). This is also documented in `aws/terraform/README.md` under
"Retrying a failed apply."

This is deliberate. The obvious alternative, a `timestamp()`-based
`triggers` value, is a force-replace argument on `aws_lambda_invocation`:
it destroys and recreates the invocation on every apply, not just retries.
For `setnotif` that removes and re-adds the live bucket notification config
on every unrelated apply (a real window with no hook); for `enroll` it
re-sends the one-time enrollment secret on every unrelated apply, which
breaks a working sync once the backend enforces one-time use. There is no
clean way to detect "the last apply's postcondition failed" from inside the
same config without reducing to the same manual action while adding
complexity, so a loud, explicit manual-retry message wins.

## SyncId length bound

`SyncId` carries `MaxLength: 44` in the CloudFormation template and a
`length(var.sync_id) <= 44` validation in `terraform/variables.tf`. The
value is baked verbatim into IAM role names and Lambda function names, both
hard-capped by AWS at 64 characters; the longest derived name is
`captain-s3-setnotif-<SyncId>` (a 20-char literal prefix), so 44 is the
exact longest value that still fits. Without the bound, an over-length value
fails on `CreateRole` and CloudFormation's rollback then tries to
`DeleteRole` the same over-length name, hits the identical validation
error, and wedges the stack in `ROLLBACK_FAILED`. Preserve this bound if
you add any resource whose name embeds `SyncId`.

## CloudFormation log groups: per-attempt names and a tolerated race

CloudFormation deletes a log group with a single, un-retried
`DeleteLogGroup` call, while CloudWatch delivers a Lambda's log lines
(including the platform `END`/`REPORT` line, written after the handler
returns) asynchronously, sometimes seconds late. If a line is still in
flight when a rollback deletes the group, CloudWatch silently recreates the
group to hold it: orphaned, empty or near-empty, and with no retention set.

The log groups are plain stack-owned resources, but their names embed a
per-stack-instance token (the first segment of the `AWS::StackId` UUID):

```
/captain/s3-sync/<syncId>/<attemptToken>/enroll
/captain/s3-sync/<syncId>/<attemptToken>/setnotif
```

Each Lambda points at its group via `LoggingConfig.LogGroup`; function and
role names stay deterministic on `SyncId`, so the length bound above is
untouched. A retry is a new stack instance and gets fresh log group names,
so it can never collide with an orphan from a failed attempt.

Two simpler designs do not work. `DeletionPolicy: Retain` plus a cleanup
custom resource guarantees a retained group named on `SyncId` alone, which
hard-fails the retry with an "already exists" error. Plain groups at the
default `/aws/lambda/<function>` names leave a race orphan with exactly the
name the retry needs, and CloudFormation rejects the retry at resource
validation. The invariant to preserve: no resource whose name is
deterministic on `SyncId` alone may survive a rollback, by policy or by the
CloudWatch recreate race. IAM roles, Lambda functions, and the SNS topic
are `SyncId`-deterministic but delete synchronously and cleanly on
rollback; log groups are the one class with the async recreate race.

Tolerated residue: when the race fires, a failed deploy can leave an
orphaned, empty log group under the per-attempt name. It is cosmetic,
collision-proof, and removable with:

```bash
aws logs describe-log-groups --log-group-name-prefix "/captain/s3-sync/<syncId>/" --region <region>
aws logs delete-log-group --log-group-name "/captain/s3-sync/<syncId>/<attemptToken>/enroll" --region <region>
```

The Terraform variant has no equivalent problem: its log groups are
ordinary managed resources and Terraform does not auto-rollback-delete on a
failed apply, so there is no delete race and no name collision on re-apply.

## The five providers at a glance

All five are built: AWS S3, GCP GCS, Azure Blob, Cloudflare R2, and
Backblaze B2, each with a template or script, a customer README, and a
NOTES.md. All share the fail-closed enroll contract above; none can
complete a real customer launch until the Captain enroll receivers are
activated. Provider-specific constraints worth knowing before you touch
one:

- **AWS S3**: the single-notification-slot overlap rule above.
- **GCP GCS**: buckets allow multiple notification configs, so there is no
  single-slot problem; the read grant is an IAM binding for Captain's own
  service account, no key material leaves the customer project.
- **Azure Blob**: additionally depends on a multi-tenant Captain AD app
  with an admin-consent flow before `captainPrincipalId` can be filled in.
- **Cloudflare R2**: two read strategies (keyless Worker proxy, or a
  bucket-scoped S3 token); R2 has no assume-role equivalent.
- **Backblaze B2**: Event Notifications are gated per account by Backblaze
  support ticket; until enabled, a B2 sync intentionally falls back to
  reconcile-only polling.

## Testing changes to the AWS templates

Static checks, all expected clean:

- `aws cloudformation validate-template` (reports `CAPABILITY_NAMED_IAM`
  required, which is expected for the named roles) and `cfn-lint` on the
  CloudFormation template.
- `terraform fmt -check -diff`, `terraform validate`, and `tflint` in
  `aws/terraform`.

For a live test, use a throwaway, uniquely named bucket and stack in an
account you own, with a mock enroll endpoint standing in for the Captain
receiver (the real one is not activated yet, so a real endpoint 404s).
Worthwhile scenarios: a deploy against a bucket that already has an
`ObjectCreated` hook (must fail fast at `SetBucketNotification` naming the
conflicting hook, and must leave the sibling hook untouched); a
create-fail-rollback followed by a retry with the same `SyncId` (must not
collide); and for Terraform, two back-to-back applies with no input change
(must produce exactly one invocation of each Lambda, verifiable in
CloudWatch) plus a failed apply retried via `-replace`. Tear everything
down afterward (`delete-stack` plus `wait stack-delete-complete`, bucket
and topic deletes) and sweep for leftover stacks, buckets, topics, roles,
and log groups before calling the test done.
