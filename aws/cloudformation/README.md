# Captain S3 sync (AWS CloudFormation)

One click stands up everything Captain needs to keep an S3 bucket synced in your
own AWS account: an SNS topic fed by the bucket's change events, a read-only
cross-account role Captain assumes (no long-lived keys), and a self-verifying
custom resource that phones home so a green stack actually means a working sync.

Prefer Terraform? The same deploy, built the same self-verifying way, is in
[`../terraform`](../terraform).

One thing to know today: Captain's enrollment verification for this template is
not yet activated, so a deploy currently completes the setup steps in your
account and then reports unverified at the final step. Contact Captain for
activation status for your sync.

## Launch Stack

[![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/create/review?templateURL=https://captain-templates.s3.amazonaws.com/templates/2026-08-13/captain-s3-sync.yaml&stackName=captain-s3-sync)

The link, expanded:

```
https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/create/review
  ?templateURL=https://captain-templates.s3.amazonaws.com/templates/2026-08-13/captain-s3-sync.yaml
  &stackName=captain-s3-sync
```

Prefer the CLI, or want to review the template before launching? Clone this
repo and launch [`captain-s3-sync.yaml`](./captain-s3-sync.yaml) directly: in
the CloudFormation console choose Create stack, then "Upload a template
file", or deploy from the CLI with
`aws cloudformation deploy --template-file captain-s3-sync.yaml
--stack-name captain-s3-sync --capabilities CAPABILITY_NAMED_IAM
--parameter-overrides BucketName=<bucket> CaptainAccountId=<id>
SyncId=<sync_id> ExternalId=<id> Secret=<secret>` (every parameter without
a default must be passed; use the values Captain gave you).

Captain normally generates the whole launch link per sync and pre-fills the
parameters, so you only review and click Create.

## Parameters

Captain pre-fills the enrollment parameters; you confirm them and set the bucket.

| Parameter | Who fills it | What it is |
| --- | --- | --- |
| `CaptainCallbackUrl` | Captain | The https enroll endpoint the phone-home POSTs to. |
| `CaptainAccountId` | Captain | Captain's AWS account id; the read role trusts it. |
| `SyncId` | Captain | The Captain sync id (`sync_<token>`) this deploy enrolls. |
| `ExternalId` | Captain | Per-sync external id, the confused-deputy guard. |
| `Secret` | Captain | One-time enrollment secret (write-only, `NoEcho`). |
| `BucketName` | You | The EXISTING bucket to sync. The stack does not create it. |
| `ObjectPrefix` | You (optional) | Restrict the sync to a key prefix, e.g. `docs/`. Empty = whole bucket. |
| `KmsKeyArn` | You (optional) | REQUIRED if the bucket is SSE-KMS with a customer-managed key (see below). |
| `DebugLogging` | You (optional) | `true`/`false` verbose deploy logs. Defaults `true`. |

### SSE-KMS buckets need `KmsKeyArn`

If your bucket encrypts objects with a customer-managed KMS key, `s3:GetObject`
alone is not enough: Captain also needs `kms:Decrypt` on that key or every fetch
fails with `AccessDenied`. Set `KmsKeyArn` to the bucket's key ARN and the read
role gets `kms:Decrypt` + `kms:DescribeKey` scoped to exactly that one key. Leave
it empty for SSE-S3 (AES256) or unencrypted buckets.

### `ObjectPrefix` scopes both sides

When you set a prefix, both the S3 event filter AND the read role are confined to
it. Captain cannot see or fetch keys outside the prefix, and only changes under
the prefix are delivered.

## Region

Launch the stack in the SAME region as your bucket. The launch link pins
`region=us-east-1`; change that query segment (and the console region picker) to
match your bucket. S3 to SNS event notifications are same-region, and the read
role is global, so the one thing that must line up is region = bucket region.

## IAM the launching user needs

The person clicking Launch Stack needs permission to create the stack and the
named resources in it. At minimum:

- `cloudformation:CreateStack`, `DescribeStacks`, `DescribeStackEvents`,
  `DeleteStack` (to launch, watch, and roll back).
- Acknowledge `CAPABILITY_NAMED_IAM` at review time (the stack creates named IAM
  roles). The console shows the checkbox; `aws cloudformation deploy` needs
  `--capabilities CAPABILITY_NAMED_IAM`.
- IAM to create the roles: `iam:CreateRole`, `iam:DeleteRole`, `iam:PutRolePolicy`,
  `iam:DeleteRolePolicy`, `iam:AttachRolePolicy`, `iam:DetachRolePolicy`,
  `iam:PassRole`, `iam:TagRole`.
- SNS: `sns:CreateTopic`, `sns:DeleteTopic`, `sns:SetTopicAttributes`,
  `sns:GetTopicAttributes`, `sns:Tag*`.
- Lambda (for the two custom resources): `lambda:CreateFunction`,
  `lambda:DeleteFunction`, `lambda:InvokeFunction`, `lambda:GetFunction`.
- CloudWatch Logs: `logs:CreateLogGroup`, `logs:DeleteLogGroup`,
  `logs:PutRetentionPolicy`. The stack creates a log group per Lambda (30-day
  retention) and deletes them with the stack in the normal delete path (see
  "Log group cleanup" below for one narrow rollback-timing caveat).
- S3 notification management on the target bucket: `s3:GetBucketNotification`
  and `s3:PutBucketNotification` on `arn:aws:s3:::<bucket>`. (The custom resource
  role also holds these, but the deploying principal needs them if you run the
  manual notification step below instead.)

An admin or power-user role covers all of this. No credentials leave the account:
Captain only ever assumes the read role, and only with the external id.

## How the deploy verifies itself

Ordinary "launch and hope" templates give you a green stack even when the wiring
is wrong, and the sync just silently never works. This template closes the loop.

1. CloudFormation creates the SNS topic, its access policy, and the read role.
2. A custom resource points the bucket's notifications at the topic (see the
   pre-existing-bucket note below for why this is a custom resource).
3. The `EnrollWithCaptain` custom resource POSTs the enrollment facts to
   `CaptainCallbackUrl`: `stackId`, `region`, `bucket`, `objectPrefix`,
   `kmsKeyArn`, `snsTopicArn`, `roleArn`, `externalId`, `syncId`, `secret`, and a
   generated `deploymentId` (`dep_<token>`).
4. Captain subscribes its endpoint to the topic, assumes the read role with the
   external id (proving the trust and policy really work), runs a verification
   handshake, and returns `2xx` with `{"verified": true}` only if all of that
   succeeded.
5. The custom resource sends `SUCCESS` to CloudFormation only on a verified
   response. Any non-2xx, timeout, or unverified reply becomes `FAILED` with a
   human-readable reason, which rolls the stack back.

So a `CREATE_COMPLETE` stack means Captain has confirmed, end to end, that it can
both receive change events and read your objects. On stack delete the resource
POSTs a teardown notice (best-effort, never blocks the delete).

## Log group cleanup on delete

Each Lambda gets its own CloudWatch log group (30-day retention), named

```
/captain/s3-sync/<syncId>/<attemptToken>/enroll
/captain/s3-sync/<syncId>/<attemptToken>/setnotif
```

where `<attemptToken>` is the first segment of this stack instance's id
(unique per Launch Stack attempt; the `DebugLogsHere` output prints both
full names on a successful deploy). The stack owns both log groups: they are
created with the stack and deleted with the stack in the normal delete path.

One honest caveat: when CloudFormation deletes a log group while the Lambda
platform is still delivering that invocation's final log lines (this happens
on rollbacks, and also on a normal stack delete, since the delete-time
handlers write logs seconds before their own group is removed), CloudWatch
can silently recreate the group a moment later. So a delete, clean or rolled
back, can leave an empty log group behind with no retention set. Because
every attempt uses a fresh `<attemptToken>`, that residue can never collide
with a retry of the same deploy or any other stack operation; it is purely
cosmetic. Remove it with one line per group:

```bash
aws logs describe-log-groups --log-group-name-prefix "/captain/s3-sync/<syncId>/" --region <region>
aws logs delete-log-group --log-group-name "/captain/s3-sync/<syncId>/<attemptToken>/enroll" --region <region>
```

## Debugging a failed deploy

- CloudFormation console, your stack, the Events tab. The failed resource
  (`EnrollWithCaptain` or `SetBucketNotification`) carries a status reason with
  the actual error, for example `Captain callback returned HTTP 403: unknown
  sync`, `Preflight failed: CaptainCallbackUrl must be https://`, or
  `Could not reach Captain callback: <urlopen timeout>`.
- The full step-by-step is in the Lambda CloudWatch logs (30-day retention),
  under the `CAPTAIN-ENROLL` and `CAPTAIN-SETNOTIF` prefixes:
  - enroll: `/captain/s3-sync/<syncId>/<attemptToken>/enroll`
  - notification: `/captain/s3-sync/<syncId>/<attemptToken>/setnotif`
  Find them with `aws logs describe-log-groups --log-group-name-prefix
  "/captain/s3-sync/<syncId>/"` (the `<attemptToken>` is unique per launch
  attempt; on a successful deploy the `DebugLogsHere` output prints both full
  names). These log every step (preflight, phone-home request, Captain's
  response, the merge that preserves your existing hooks). The one-time
  `Secret` is NEVER logged; it is redacted to its length. Set
  `DebugLogging=false` to quiet them after the sync is up.
- Captain's side: the `DeploymentId` output (`dep_<token>`) identifies this
  deploy attempt to Captain. Share it with Captain support to check what
  Captain saw: whether the topic subscription and the assume-role probe
  passed, and the last handshake result.
- Common causes: wrong `CaptainAccountId` (assume-role trust fails), an external
  id that does not match the sync, launching in a different region than the
  bucket, an SSE-KMS bucket without `KmsKeyArn` (reads fail `AccessDenied`), or
  the bucket already having an `ObjectCreated`/`ObjectRemoved` notification hook
  on an overlapping prefix. That last one fails at `SetBucketNotification` with
  a Reason naming the conflicting hook's id, event, and prefix. See
  "Pre-existing bucket: the notification constraint" below for what to do about
  it.

## Pre-existing bucket: the notification constraint

CloudFormation can set a bucket's notification config natively only on a bucket
the stack itself creates and owns. Your bucket already exists, and a bucket has
exactly ONE notification configuration, so a naive write would wipe any existing
SNS/SQS/Lambda/EventBridge hooks. This template therefore sets the notification
with a custom resource that does an additive read-merge-write: it appends our
topic config (its `Id` is `captain-<syncId>`, so two Captain syncs on one bucket
do NOT collide) and, on delete, removes only ours.

That merge only works when it does not collide with what is already there. S3
enforces a stricter rule than "one config per bucket": it also rejects
`PutBucketNotificationConfiguration` with `InvalidArgument: Configurations
overlap` whenever the new config shares an event type (`ObjectCreated` or
`ObjectRemoved`) with an EXISTING hook on an overlapping prefix. Whole-bucket
sync (the default, empty `ObjectPrefix`) overlaps ANY existing
`ObjectCreated`/`ObjectRemoved` hook. So "additive" means "adds our hook
alongside anything it does not conflict with," not "always succeeds no matter
what is already on the bucket."

The custom resource reads the existing config first and checks for that
overlap before writing. If it finds one, the stack fails fast at the
`SetBucketNotification` resource with a `Reason` naming the conflicting
config's id, event type, and prefix, and the existing config is left
untouched (the write is never attempted, so nothing is clobbered either way).
Your option at that point: pick a non-overlapping `ObjectPrefix` for this
sync.

If you would rather not grant notification-management permission through the
stack, delete the `SetBucketNotification*` resources from the template (and
remove `SetBucketNotification` from `EnrollWithCaptain`'s `DependsOn` list,
which otherwise dangles) and run
this once yourself after the stack is up. It does the SAME additive
read-merge-write AND the same overlap check as the custom resource, refusing
to write (rather than getting rejected by S3, or worse, clobbering something)
when one is found:

```bash
# Point the bucket at the topic without clobbering existing notifications.
BUCKET=<your-bucket>; REGION=us-east-1; SYNC_ID=<your-sync-id>
PREFIX=""   # match whatever ObjectPrefix you set for this sync

TOPIC=$(aws cloudformation describe-stacks --stack-name captain-s3-sync \
  --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='SnsTopicArn'].OutputValue" \
  --output text)
CONFIG_ID="captain-$SYNC_ID"
CUR=$(aws s3api get-bucket-notification-configuration --bucket "$BUCKET" --region "$REGION")
# A bucket with NO existing notification config returns an EMPTY response body
# (not even "{}"), which would otherwise make every jq call below a silent
# no-op.
[ -z "$CUR" ] && CUR="{}"

# Fail fast if an existing hook already handles ObjectCreated/ObjectRemoved on
# an overlapping prefix: the put-bucket-notification-configuration call below
# would otherwise be rejected by S3 with InvalidArgument "Configurations
# overlap" (a whole-bucket sync, empty PREFIX, overlaps ANY existing
# ObjectCreated/ObjectRemoved hook).
CONFLICT=$(echo "$CUR" | jq -r --arg id "$CONFIG_ID" --arg prefix "$PREFIX" '
  [ (.TopicConfigurations // [])[], (.QueueConfigurations // [])[], (.LambdaFunctionConfigurations // [])[] ]
  | map(select(.Id != $id))
  | map({
      id: .Id,
      events: (.Events // []),
      prefix: ([(.Filter.Key.FilterRules // [])[] | select(.Name == "prefix" or .Name == "Prefix") | .Value] | first // "")
    })
  | map(select(
      (.events | any(startswith("s3:ObjectCreated") or startswith("s3:ObjectRemoved")))
      and (.prefix as $ep | ($prefix == $ep) or ($ep | startswith($prefix)) or ($prefix | startswith($ep)))
    ))
  | first // empty
  | "\(.id)\t\(.events | join(","))\t\(.prefix)"
')
if [ -n "$CONFLICT" ]; then
  IFS=$'\t' read -r CONFLICT_ID CONFLICT_EVENTS CONFLICT_PREFIX <<< "$CONFLICT"
  echo "REFUSING to write: existing notification config '$CONFLICT_ID' already" >&2
  echo "handles $CONFLICT_EVENTS on prefix '$CONFLICT_PREFIX', which overlaps" >&2
  echo "the prefix '$PREFIX' this sync would write. S3 does not allow two" >&2
  echo "notification configs with overlapping event types on overlapping" >&2
  echo "prefixes. Pick a non-overlapping ObjectPrefix for this sync." >&2
  exit 1
fi

echo "$CUR" | jq --arg t "$TOPIC" --arg id "$CONFIG_ID" --arg prefix "$PREFIX" '
  .TopicConfigurations = (([ .TopicConfigurations[]? | select(.Id != $id) ]) + [
    ({ Id: $id, TopicArn: $t, Events: ["s3:ObjectCreated:*","s3:ObjectRemoved:*"] }
     + (if $prefix != "" then { Filter: { Key: { FilterRules: [{ Name: "prefix", Value: $prefix }] } } } else {} end))
  ])' > /tmp/notif.json
aws s3api put-bucket-notification-configuration --bucket "$BUCKET" --region "$REGION" \
  --notification-configuration file:///tmp/notif.json
```

## Removing the sync

Delete the stack (console, or `aws cloudformation delete-stack --stack-name
captain-s3-sync --region <region>`). The delete removes only the Captain
notification config from your bucket (other hooks are left alone), POSTs
Captain a best-effort teardown notice, and tears down the topic, roles, and
Lambdas. Your bucket and objects are never touched. See "Log group cleanup on
delete" above for the one cosmetic thing a delete can leave behind.

## Outputs

- `DeploymentId`: the `dep_<token>` id; use it to look up deployment state.
- `SnsTopicArn`: topic the bucket publishes to and Captain subscribes to.
- `ReadRoleArn`: the cross-account read role Captain assumes.
- `ExternalId`: echoed back for your records.
- `SyncScope`: whole bucket, or the prefix if you set one.
- `TemplateVersion`: date-based version of this template.
- `DebugLogsHere`: the two CloudWatch log groups to read if a deploy fails.
- `WhatToDoNext`: one-line next step.
