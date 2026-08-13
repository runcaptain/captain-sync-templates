# Captain deploy: AWS S3

Wire an existing S3 bucket to Captain's near-real-time sync, entirely inside
your own AWS account. Two equivalent deploy artifacts; pick the one that fits
your tooling:

| | CloudFormation | Terraform |
| --- | --- | --- |
| Path | [`cloudformation/`](./cloudformation) | [`terraform/`](./terraform) |
| Launch | One-click Launch Stack button | `terraform init && terraform apply` |
| Confirmed deploy | `CREATE_COMPLETE` means verified | successful `apply` means verified |

Both stand up the same three things:

1. **Event wiring**: an SNS topic fed by the bucket's
   `ObjectCreated`/`ObjectRemoved` events, attached to the bucket with an
   additive read-merge-write so existing, non-overlapping notification hooks
   are preserved.
2. **A read-only cross-account IAM role** Captain assumes with a per-sync
   external id (no long-lived keys), scoped to just this bucket, and further
   to a key prefix or a KMS key when you set those.
3. **A self-verifying enrollment**: the deploy registers the topic with the
   Captain API (`POST /v2/syncs/{sync_id}/webhooks`, authenticated with your
   Captain API key). Captain subscribes to the topic and returns the per-sync
   `subscribe_url` it minted; the deploy only reports success on that 2xx. A
   misconfigured deploy fails visibly at deploy time instead of silently never
   syncing.

What you need before deploying: your Captain sync id (`sync_<token>`) and a
Captain API key. Captain normally pre-fills both when it generates your deploy
artifacts. The full walkthrough is at
https://docs.captain.dev/guides/sync/set-up.

Reconcile/polling is Captain's always-on backstop; this event wiring is the
latency optimization on top of it. A missed event never means a missed object.

## Which one

Use CloudFormation for the one-click console experience, or if your org
standardizes on CFN/StackSets. Use Terraform if your infrastructure already
lives in Terraform and you want this sync in the same state and review flow.

They are functionally identical, down to the notification merge, the per-sync
notification config id (so two Captain syncs on one bucket do not collide),
the optional prefix/KMS scoping, and the redacted debug logging.

## If your bucket already has change notifications

A bucket has exactly one notification configuration, and S3 rejects any write
that shares an event type (`ObjectCreated`/`ObjectRemoved`) with an existing
hook on an overlapping prefix. A whole-bucket sync (the default, empty prefix)
overlaps ANY existing hook on those event types. This is an S3 rule, not
something the template can merge around.

Both deploy paths read the bucket's existing configuration before writing and
check for this overlap themselves. If one is found, the deploy fails fast,
naming the conflicting hook's id, event type, and prefix in the error, and
your existing config is left exactly as it was: the write is never attempted,
so nothing is clobbered either way.

The way out today: set `ObjectPrefix` (CloudFormation) or `object_prefix`
(Terraform) to a prefix that does not overlap the existing hook's prefix.
