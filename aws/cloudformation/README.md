# Captain S3 sync (AWS CloudFormation)

One click stands up everything Captain needs to keep an S3 bucket synced in your
own AWS account: an SNS topic fed by the bucket's change events, a read-only
cross-account role Captain assumes (no long-lived keys), and a self-verifying
custom resource that phones home so a green stack actually means a working sync.

## Launch Stack

[![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/create/review?templateURL=https://captain-deploy-templates.s3.amazonaws.com/templates/2026-08-12/captain-s3-sync.yaml&stackName=captain-s3-sync)

The link, expanded:

```
https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/create/review
  ?templateURL=https://captain-deploy-templates.s3.amazonaws.com/templates/2026-08-12/captain-s3-sync.yaml
  &stackName=captain-s3-sync
```

`templateURL` uses a DATE-based version path (`.../templates/2026-08-12/...`).
This is a PLACEHOLDER host: publish the template to a public HTTPS location and
put that dated URL here. Captain normally generates this whole link per sync and
pre-fills the parameters (`CaptainCallbackUrl`, `CaptainAccountId`, `ExternalId`,
`BucketName`, `SyncId`, `Secret`) so the customer only reviews and clicks Create.

## Region

Launch the stack in the SAME region as your bucket. The quick-create link pins
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
   `CaptainCallbackUrl`: `stackId`, `region`, `bucket`, `snsTopicArn`, `roleArn`,
   `externalId`, `syncId`, `secret`, and a generated `deploymentId` (`dep_<token>`).
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

## Debugging a failed deploy

- CloudFormation console, your stack, the Events tab. The failed resource
  (`EnrollWithCaptain` or `SetBucketNotification`) carries a status reason with
  the actual error, for example `Captain callback returned HTTP 403: unknown
  sync` or `Could not reach Captain callback: <urlopen timeout>`.
- The phone-home result is in that same Reason string, and in the enroll Lambda's
  CloudWatch logs (log group `/aws/lambda/captain-s3-enroll-<syncId>`). The
  notification-setter logs to `/aws/lambda/captain-s3-setnotif-<syncId>`.
- Captain's side: look up the deployment-state object by the `DeploymentId`
  output (`dep_<token>`). Captain exposes it so you can see whether the topic
  subscription and the assume-role probe passed, and the last handshake result.
  (This deployment-state endpoint is Captain backend work; see `../../NOTES.md`.)
- Common causes: wrong `CaptainAccountId` (assume-role trust fails), an external
  id that does not match the sync, launching in a different region than the
  bucket, or the bucket already having a conflicting notification config.

## Pre-existing bucket: the notification constraint

CloudFormation can set a bucket's notification config natively only on a bucket
the stack itself creates and owns. Your bucket already exists, and a bucket has
exactly ONE notification configuration, so a naive write would wipe any existing
SNS/SQS/Lambda/EventBridge hooks. This template therefore sets the notification
with a custom resource that does an additive read-merge-write: it appends our
topic config (tagged with the sync id) and, on delete, removes only ours.

If you would rather not grant notification-management permission through the
stack, delete the `SetBucketNotification*` resources from the template and run
this once yourself after the stack is up (it preserves existing hooks):

```bash
# Point the bucket at the topic without clobbering existing notifications.
BUCKET=<your-bucket>; REGION=us-east-1
TOPIC=$(aws cloudformation describe-stacks --stack-name captain-s3-sync \
  --region "$REGION" --query "Stacks[0].Outputs[?OutputKey=='SnsTopicArn'].OutputValue" \
  --output text)
CUR=$(aws s3api get-bucket-notification-configuration --bucket "$BUCKET" --region "$REGION")
echo "$CUR" | jq --arg t "$TOPIC" '
  .TopicConfigurations = ((.TopicConfigurations // []) + [{
    Id: "CaptainSyncTopic", TopicArn: $t,
    Events: ["s3:ObjectCreated:*","s3:ObjectRemoved:*"]
  }])' > /tmp/notif.json
aws s3api put-bucket-notification-configuration --bucket "$BUCKET" --region "$REGION" \
  --notification-configuration file:///tmp/notif.json
```

## Outputs

- `SnsTopicArn`: topic the bucket publishes to and Captain subscribes to.
- `ReadRoleArn`: the cross-account read role Captain assumes.
- `ExternalId`: echoed back for your records.
- `DeploymentId`: the `dep_<token>` id; use it to look up deployment state.
- `WhatToDoNext`: one-line next step.
