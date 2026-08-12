# NOTES: honest flags for captain-s3-sync (CAP-569)

The CloudFormation template is built and validates clean
(`aws cloudformation validate-template` + `cfn-lint 1.55.0`, zero warnings). It
is written to a contract that partly depends on Captain BACKEND work that does
NOT exist yet. That backend is the dependency ticket for this to actually run.

## Captain backend dependencies (do not exist yet)

The template phones home to Captain and expects a specific contract. These
receivers must be built before a real customer can launch this stack:

1. **`CaptainCallbackUrl` enroll receiver.** An HTTPS endpoint (default
   placeholder `https://api.runcaptain.com/v1/deploy/aws/s3/enroll`, must be
   confirmed) that accepts the POST body:
   `{deploymentId, templateVersion, action, stackId, region, bucket,
   snsTopicArn, roleArn, externalId, syncId, secret}`.
   It must authenticate the `secret` against the named `syncId`, then perform the
   enrollment and return `2xx` with JSON `{"verified": true, "status": "..."}`.
   Any other response (non-2xx, or `verified` not true) makes the stack roll back.

2. **The verification handshake.** On enroll, Captain must actually:
   - subscribe its endpoint to `snsTopicArn` (the topic policy already allows
     Captain's account to `sns:Subscribe`), and
   - assume `roleArn` with `sts:ExternalId = externalId` and do a probe
     `ListBucket` / `GetObject` to prove the trust and policy work.
   Only if both pass should it return `verified: true`. This is what makes the
   deploy self-verifying; without it, `verified` is meaningless.

3. **Deployment-state object / endpoint.** Captain must expose per-deployment
   state keyed by the `dep_<token>` deployment id (subscription confirmed?
   assume-role probe passed? last handshake result?). The README points customers
   at it for debugging. It does not exist yet.

4. **Delete / teardown handling.** On stack delete the custom resource POSTs
   `{action: "delete", ...}`. Captain should unsubscribe and mark the deployment
   torn down. Teardown is best-effort on the client side (it never blocks a stack
   delete), so the backend should also reconcile orphaned subscriptions.

5. **SNS subscription confirmation.** When Captain subscribes its HTTPS endpoint,
   SNS sends a `SubscriptionConfirmation`. Captain's endpoint must handle that
   message type (confirm the subscription) in addition to `Notification`
   messages. Standard SNS-to-HTTPS plumbing, but it is real work on the receiver.

The existing S3 sync backend already enrolls via an SNS topic ARN
(`captain_subscribe_sync_webhook` takes `sns_topic_arn`), so the subscribe path
has a foundation; the enroll receiver, the handshake, and the deployment-state
object are the new pieces.

## Pre-existing-bucket notification constraint (real limitation)

CloudFormation can set a bucket's `NotificationConfiguration` natively only on a
bucket the stack creates and owns. Customers point Captain at an EXISTING bucket,
and a bucket has exactly ONE notification configuration, so a naive write wipes
any SNS/SQS/Lambda/EventBridge hooks already there.

The template handles this with a `SetBucketNotification` custom resource that does
an additive read-merge-write (appends only our tagged `TopicConfiguration`,
removes only ours on delete). Caveats worth knowing:

- It needs `s3:GetBucketNotification` + `s3:PutBucketNotification` on the bucket.
  If the customer will not grant that through the stack, the README documents a
  manual `aws s3api` step and the template resources can be deleted.
- The merge preserves siblings, but it has been reasoned through, not yet tested
  against a bucket that already carries SNS/SQS/Lambda/EventBridge configs. Test
  the preserve path before GA. (Same open item flagged in the earlier S3 webhook
  build NOTES.)
- Two Captain syncs on the SAME bucket both add a `TopicConfiguration` with
  `Id: CaptainSyncTopic`; S3 requires unique config ids, so multi-sync-per-bucket
  would collide. If that becomes a use case, make the id sync-specific.

## Alternative wiring path (context)

The earlier session built an EventBridge-based variant of this
(`../webhook-build/s3/captain-s3-eventbridge.template.yaml`) that avoids the
single-notification-slot problem entirely (EventBridge is a boolean on the bucket
and routing lives in many non-colliding rules). This CAP-569 template uses the
SNS path the task specified and the existing backend enrolls with. If the
notification-slot collision above bites, the EventBridge variant is the
documented way out.

## Validation status

- `aws cloudformation validate-template --region us-east-1` : PASS
  (reports `CAPABILITY_NAMED_IAM` required, as expected for the named roles).
- `cfn-lint 1.55.0` : PASS, zero warnings (fixed one W3005 redundant-DependsOn).
- NOT deployed. No stack created, no real AWS resources touched. Validation is a
  read-only API call.
