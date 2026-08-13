# Captain S3 sync (Terraform)

The Terraform equivalent of [`../cloudformation/captain-s3-sync.yaml`](../cloudformation/captain-s3-sync.yaml).
Same three things, same self-verifying design, all inside your own AWS account:

1. An SNS topic fed by the bucket's `ObjectCreated`/`ObjectRemoved` events,
   attached with an additive read-merge-write so existing, non-overlapping
   bucket hooks are preserved. S3 itself refuses a write that would overlap an
   existing `ObjectCreated`/`ObjectRemoved` hook on an overlapping prefix, so
   `setnotif` checks for that overlap first and fails the apply with a clear,
   actionable error instead of getting rejected mid-write. See "Existing
   notification hooks" below.
2. A read-only cross-account IAM role Captain assumes with the external id (no
   long-lived keys), scoped to this bucket and, optionally, to a prefix / KMS key.
3. A self-verifying phone-home. `terraform apply` succeeds only if Captain
   confirms, end to end, that it can both receive events AND read objects.

One thing to know today: Captain's enrollment verification for this template
is not yet activated, so an apply currently completes the setup steps in your
account and then reports unverified at the final step. Contact Captain for
activation status for your sync.

There is no "Launch Stack" button for Terraform. The one-command equivalent:

```bash
cp terraform.tfvars.example terraform.tfvars   # Captain usually generates this for you
# edit terraform.tfvars: set bucket_name/aws_region and confirm the Captain-filled values
terraform init
terraform apply
```

A successful `apply` is the equivalent of a `CREATE_COMPLETE` stack: Captain has
verified the wiring. If Captain cannot confirm, the `aws_lambda_invocation.enroll`
postcondition fails the apply with Captain's reason, the same way a bad handshake
rolls back the CloudFormation stack.

## Inputs

Captain normally generates a `terraform.tfvars` for you, pre-filled per sync. See
[`terraform.tfvars.example`](./terraform.tfvars.example). The variables mirror the
CloudFormation parameters.

| Variable | Who sets it | What it is |
| --- | --- | --- |
| `aws_region` | You | Region to deploy into. MUST equal the bucket's region. |
| `bucket_name` | You | The EXISTING bucket to sync. Not created here. |
| `object_prefix` | You (optional) | Restrict the sync to a key prefix, e.g. `docs/`. Empty = whole bucket. |
| `kms_key_arn` | You (optional) | REQUIRED if the bucket is SSE-KMS with a customer-managed key. |
| `captain_callback_url` | Captain | The https enroll endpoint. |
| `captain_account_id` | Captain | Captain's AWS account id; the read role trusts it. |
| `sync_id` | Captain | The Captain sync id (`sync_<token>`). |
| `external_id` | Captain | Per-sync external id (confused-deputy guard). |
| `secret` | Captain | One-time enrollment secret (marked `sensitive`). |
| `debug_logging` | You (optional) | `"true"`/`"false"` verbose deploy logs. Defaults `"true"`. |
| `log_retention_days` | You (optional) | CloudWatch retention for the two deploy log groups. Defaults `30`. |

`kms_key_arn` matters: on an SSE-KMS bucket, `s3:GetObject` without `kms:Decrypt`
on the key fails with `AccessDenied`. Set it and the read role gets `kms:Decrypt`
scoped to exactly that key. When you set `object_prefix`, both the S3 event
filter and the read role are confined to it: Captain cannot see or fetch keys
outside the prefix.

One note on state: the one-time enrollment `secret` is marked `sensitive`, which
hides it from CLI output but does not encrypt it. It lands in Terraform state in
plaintext (it is part of the enroll Lambda's invocation input). Use a state
backend with encryption and access control, the same as you would for any stack
that handles a credential.

## Why a Lambda for the bucket notification instead of `aws_s3_bucket_notification`

Terraform's `aws_s3_bucket_notification` resource is AUTHORITATIVE: it owns the
bucket's single notification configuration and would silently wipe any existing
SNS/SQS/Lambda/EventBridge hooks. This module deploys a small helper Lambda
(`functions/setnotif.py`) invoked with `lifecycle_scope = "CRUD"` so it runs on
create, update, AND destroy. It does an additive read-merge-write: it appends only
our topic config (`Id = captain-<syncId>`, unique per sync) and removes only ours
on destroy. That matches the CloudFormation custom resource exactly.

The phone-home is a second helper Lambda (`functions/enroll.py`), also
`lifecycle_scope = "CRUD"`, so `terraform destroy` sends Captain a teardown notice.
Both Lambda sources are plain files you can read and edit; Terraform zips them with
the `archive_file` data source at plan time.

## Existing notification hooks (S3's one-slot constraint)

A bucket has exactly ONE notification configuration, and S3 rejects
`PutBucketNotificationConfiguration` with `InvalidArgument: Configurations
overlap` whenever the config being written shares an event type
(`ObjectCreated`/`ObjectRemoved`) with an EXISTING hook on an overlapping
prefix. A whole-bucket sync (the default, empty `object_prefix`) overlaps ANY
existing `ObjectCreated`/`ObjectRemoved` hook.

`functions/setnotif.py` reads the bucket's existing configuration before
writing and checks for this overlap itself. If it finds one,
`aws_lambda_invocation.setnotif`'s postcondition fails the apply, naming the
conflicting hook's id, event type, and prefix. The existing config is never
touched, since the write is never attempted; the deploy simply does not
succeed for that bucket state. Your option today: pick a non-overlapping
`object_prefix` for this sync.

## IAM the applying principal needs

Same surface as the CloudFormation launcher: create/delete IAM roles and inline
policies (`iam:CreateRole`, `iam:PutRolePolicy`, `iam:AttachRolePolicy`,
`iam:PassRole`, `iam:TagRole`, and the matching deletes), SNS topic + policy,
Lambda create/invoke/delete, CloudWatch Logs group create/retention/delete, and
`s3:GetBucketNotification` + `s3:PutBucketNotification` on the bucket. An admin or
power-user role covers it. No credentials leave the account.

## Debugging a failed apply

- The failing resource is usually `aws_lambda_invocation.enroll` or
  `aws_lambda_invocation.setnotif`. Terraform prints the Lambda's returned JSON in
  the postcondition error, for example
  `Captain did not verify enrollment. Lambda returned: {"verified": false, "error": "..."}`.
- The full step-by-step is in CloudWatch (30-day retention by default), under the
  `CAPTAIN-ENROLL` and `CAPTAIN-SETNOTIF` prefixes:
  - enroll: `/aws/lambda/captain-s3-enroll-<syncId>`
  - notification: `/aws/lambda/captain-s3-setnotif-<syncId>`
  Every step is logged (preflight, phone-home request, Captain's response, the
  merge that preserves existing hooks). The one-time `secret` is NEVER logged; it
  is redacted to its length.
- Inspect what Captain returned without digging through logs:
  `terraform output captain_verify_result`.
- Common causes: wrong `captain_account_id` (assume-role trust fails), an external
  id that does not match the sync, `aws_region` not equal to the bucket's region,
  an SSE-KMS bucket without `kms_key_arn`, or the bucket already having an
  `ObjectCreated`/`ObjectRemoved` notification hook on an overlapping prefix.
  That last one fails at `aws_lambda_invocation.setnotif` with a postcondition
  error naming the conflicting hook's id, event, and prefix. See "Existing
  notification hooks" above for what to do about it.

## Retrying a failed apply

`aws_lambda_invocation.setnotif` and `aws_lambda_invocation.enroll` only
re-invoke their Lambda when their `input` actually changes (a real
bucket/topic/prefix/secret change). If an apply fails a postcondition, that
failing result is cached in Terraform state, and a plain `terraform apply`
right after, with nothing else changed, is a no-op: it will NOT call the
Lambda again and will keep showing the same cached failure.

This is deliberate. Re-invoking on every apply would mean removing and
re-adding your real bucket notification config, and re-sending the one-time
enrollment `secret` to Captain, on every unrelated apply. We would rather ask
you to retry explicitly than silently touch working infrastructure.

To retry once you have fixed the underlying cause (a resolved overlap, a
corrected `external_id`, verification activated for your sync, and so on),
force a real retry of just the failing resource:

```
terraform apply -replace=aws_lambda_invocation.setnotif
```

or

```
terraform apply -replace=aws_lambda_invocation.enroll
```

Each postcondition error message names the exact command to run. Both
Lambdas are idempotent, so re-invoking one with unchanged input is safe; it
just re-runs the same additive merge / phone-home and re-verifies.

## Outputs

- `deployment_id`: the `dep_<token>` id; use it to look up deployment state.
- `sns_topic_arn`, `read_role_arn`, `external_id`: the wiring Captain uses.
- `sync_scope`: whole bucket, or the prefix if you set one.
- `template_version`: date-based version of this deploy artifact.
- `debug_logs_here`: the two CloudWatch log groups to read on failure.
- `captain_verify_result`: the parsed handshake result Captain returned.
- `what_to_do_next`: one-line next step.

## Tearing it down

```bash
terraform destroy
```

Destroy invokes both helper Lambdas one last time: `setnotif` removes only our
`captain-<syncId>` notification config (leaving your other hooks), and `enroll`
POSTs Captain a teardown notice. Neither blocks the destroy if Captain is
unreachable. Your bucket and objects are never touched.

One caveat, the same one the CloudFormation path documents: those destroy-time
invocations write their final log lines seconds before their own log groups are
deleted, and when the Lambda platform delivers logs after the delete, CloudWatch
silently recreates the group. So a destroy can leave one or both of
`/aws/lambda/captain-s3-setnotif-<syncId>` and
`/aws/lambda/captain-s3-enroll-<syncId>` behind, empty and with no retention
set. Unlike the CloudFormation path, these names are stable per sync id, so if
you later re-apply the SAME sync, the apply fails creating the log group
because it already exists. Either way the cleanup is one line per group:

```bash
aws logs delete-log-group --log-group-name "/aws/lambda/captain-s3-setnotif-<syncId>" --region <region>
aws logs delete-log-group --log-group-name "/aws/lambda/captain-s3-enroll-<syncId>" --region <region>
```
