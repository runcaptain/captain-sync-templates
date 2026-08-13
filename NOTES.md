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

The template handles this with a `SetBucketNotification` custom resource (CFN) /
`functions/setnotif.py` (Terraform) that does an additive read-merge-write
(appends only our tagged `TopicConfiguration`, removes only ours on delete).
Caveats worth knowing:

- It needs `s3:GetBucketNotification` + `s3:PutBucketNotification` on the bucket.
  If the customer will not grant that through the stack, the README documents a
  manual `aws s3api` step and the template resources can be deleted.
- CONFIRMED (adversarial testing, live-reproduced against a real bucket on both
  the CFN and Terraform paths): the merge is NOT unconditionally additive. S3
  itself rejects `PutBucketNotificationConfiguration` with `InvalidArgument:
  Configurations overlap` whenever our new config's event type
  (`ObjectCreated`/`ObjectRemoved`) overlaps an EXISTING hook's event type on an
  overlapping prefix. A whole-bucket sync (the default, empty prefix) overlaps
  ANY existing `ObjectCreated`/`ObjectRemoved` hook. This fails SAFE (it's an
  atomic PUT, so a rejected write never touches the existing config) but the
  deploy itself fails for a common bucket state: any bucket that already has
  create/remove notifications wired up. Fixed: both the CFN inline Lambda and
  `functions/setnotif.py` now read the existing config and check for this
  overlap BEFORE attempting the write, and fail fast naming the conflicting
  config's id, event type, and prefix, instead of letting S3's opaque
  `InvalidArgument` surface. The documented manual jq fallback does the same
  check. A customer who hits this should pick a non-overlapping prefix; that
  is the only documented way out today (see "Alternative wiring path" below).
- Each Captain sync's `TopicConfiguration` uses a per-sync `Id`
  (`captain-<syncId>`), so multiple Captain syncs on the SAME bucket do not
  collide with EACH OTHER (S3 requires unique config ids within a bucket). They
  can still hit the overlap rule above against each other (or against a
  third-party hook) if their event types and prefixes overlap; same fail-fast
  behavior applies.

## Alternative wiring path (does not exist yet, corrected this round)

Earlier drafts of this document and every runtime error/README in `aws/`
pointed customers who hit the overlap above at an EventBridge-based variant,
`../webhook-build/s3/captain-s3-eventbridge.template.yaml`. That file does not
exist anywhere in this repo or in `git log --all`. It was a dead link baked
into live CloudFormation/Terraform failure text, so a customer whose bucket
already had a conflicting `ObjectCreated`/`ObjectRemoved` hook (a normal state
for a bucket already wired into something else) hit this as their first-run
failure with no real remedy. Fixed this round: every reference to the
EventBridge variant (the CFN template, `functions/setnotif.py`, and all four
READMEs) has been stripped back to the one remedy that actually exists today:
set a non-overlapping `ObjectPrefix` / `object_prefix` for the sync.

An EventBridge-based wiring variant (bucket-level boolean, no single
notification slot to collide over) is still worth building as a real fix for
customers who cannot use a prefix, but it needs to be built and committed
before anything points to it again.

## Terraform: cached-failure trap on retry (history: fixed, then regressed, now fixed again honestly)

CONFIRMED (adversarial testing, reproduced): `aws_lambda_invocation.setnotif`
and `.enroll` only re-invoke their Lambda when their `input` changes. A failed
apply (which is GUARANTEED today, since `enroll` 404s until CAP-586 exists)
wrote the failing `result` to state as "applied," and every subsequent
`terraform plan`/`apply` re-checked that CACHED result and failed the same
postcondition again WITHOUT ever calling the Lambda a second time -- the only
way out was `terraform apply -replace=aws_lambda_invocation.enroll` (or
`.setnotif`), which is not something a customer would think to do off a plain
apply failure.

**First fix (regressed, reverted):** both resources were given
`triggers = { redeploy_at = timestamp() }` to force a re-invoke on every
apply. This was wrong: `triggers` is a force-REPLACE argument on
`aws_lambda_invocation`, so ANY change to it, and `timestamp()` is always
different, destroys and recreates the resource on EVERY apply, not just
retries. MEDIUM regression, live-confirmed via CloudWatch: two back-to-back
applies with zero input changes still produced two real invocations of each
Lambda. For `setnotif` that meant the real S3 bucket notification config was
removed and re-added on every unrelated apply (a real window with no hook).
For `enroll` it meant the documented ONE-TIME enrollment `secret` got
re-POSTed to Captain on every unrelated apply; once CAP-586 enforces
one-time-use server-side, an ordinary `terraform apply` on an
already-verified, working sync would break it.

**Current fix:** the `triggers` block is removed entirely from both
resources (`aws/terraform/main.tf`). Re-invocation now happens only when
`input` genuinely changes (a real bucket/topic/prefix/secret change), which
is correct and non-destructive. The honest trade-off this brings back: a
failed apply's result is cached in state, and a later `terraform apply` with
IDENTICAL input will NOT retry on its own. Both postcondition error messages
now say so explicitly and name the exact command to run:
`terraform apply -replace=aws_lambda_invocation.setnotif` (or `.enroll`).
This is documented prominently in `aws/terraform/README.md` under
"Retrying a failed apply." We chose this over a "smart" retry-on-failure-only
trigger because there is no clean way to read "did the last apply's
postcondition fail" from inside the same Terraform config without either an
external data source or a customer-driven input bump, both of which reduce to
the same manual action as `-replace` while adding complexity. A loud,
explicit manual-retry message beats churning live customer infrastructure on
every apply.

Live-verified this round (throwaway bucket, real Lambdas, real SNS topic,
torn down after): two back-to-back `terraform apply` runs with no input
changes produced exactly ONE invocation each of `setnotif` and `enroll`
(confirmed via CloudWatch log stream/event counts) and an unchanged
`aws s3api get-bucket-notification-configuration` result across both applies.
Then, with a mock Captain endpoint flipped to return 404 with NO Terraform
input change, a plain `terraform apply` stayed a no-op (as expected, this is
the documented trade-off), `terraform apply -replace=aws_lambda_invocation.enroll`
forced a real retry that failed loudly with the exact retry command in the
error text, and after flipping the mock back to a verified response, the same
`-replace` command succeeded, with `setnotif` never touched across any of it.

## SyncId / sync_id had no length bound (fixed this round, live-reproduced)

CONFIRMED (adversarial fuzzing, live-reproduced against a real account):
`ExternalId` (CFN `MaxLength: 1224`) and `ObjectPrefix` (`MaxLength: 1024`)
both had explicit length bounds; `SyncId` (CFN `AllowedPattern:
"^sync_[A-Za-z0-9]+$"`, no `MaxLength`) did not, in both the CloudFormation
template and `terraform/variables.tf`. But `SyncId` is baked verbatim into
IAM role names and Lambda function names, both hard-capped by AWS at 64
characters. Deploying with a 65-char `SyncId` failed as expected on
`CreateRole`, but CloudFormation's automatic rollback then tried to
`DeleteRole` the SAME over-length name and hit the identical AWS validation
error, landing the stack in `ROLLBACK_FAILED`. A follow-up `delete-stack`
then produced `DELETE_FAILED` for the same reason. The only way out was
`aws cloudformation delete-stack --retain-resources EnrollFunctionRole`, a
flag that was nowhere in this repo's docs. This directly contradicted the
template's own design pledge ("validates its inputs up front with
human-readable error messages," "never hangs") -- a value that passed the
template's own `AllowedPattern` produced a permanently stuck stack.

**Fix:** `MaxLength: 44` added to `SyncId` in the CloudFormation template
(`Parameters.SyncId`) and an equivalent `length(var.sync_id) <= 44` check
added to `sync_id` in `terraform/variables.tf`, matching the discipline
already applied to `ExternalId` and `ObjectPrefix`. 44 is not a round number
picked for looks: the longest resource name built from `SyncId` is the
`setnotif` IAM role/Lambda name, `captain-s3-setnotif-<SyncId>` (a 20-char
literal prefix), and IAM role names and Lambda function names are both
capped at 64 chars by AWS, so 44 is the exact longest `SyncId` that still
fits (20 + 44 = 64). The `enroll` (18-char prefix, 46 available) and `read`
(16-char prefix, 48 available) names have more headroom, so the `setnotif`
name is the binding constraint.

Live-verified this round: redeployed the same 65-char `SyncId` stack that
previously produced `ROLLBACK_FAILED` / `DELETE_FAILED`. With the `MaxLength`
in place, CloudFormation now rejects the value at parameter-validation time,
before any resource is created (`Parameter validation failed: ... SyncId ...
44` in `describe-stack-events` / the console error, no stack ever reaches
`CREATE_IN_PROGRESS`). No role, no rollback, no stuck stack. On the Terraform
side, `terraform plan` with the same 65-char `sync_id` now fails the
`variables.tf` validation block before touching AWS at all.

## CloudFormation: rollback log-group race and the retry collision (CONFIRMED live, final design)

CONFIRMED (live-reproduced repeatedly against the internal test account):
`AWS::Logs::LogGroup` deletion in CloudFormation is a single, un-retried API
call. CloudFormation calls `DeleteLogGroup`, reports `DELETE_COMPLETE`, and
moves on. CloudWatch's delivery of a Lambda invocation's own log lines
(including the platform-emitted `END`/`REPORT` line, written AFTER the
handler returns) is asynchronous and can lag by a few seconds. If a line is
still in flight when a ROLLBACK deletes the log group, CloudWatch silently
recreates the group a moment later to hold it. The recreated group is
orphaned (nothing owns it), empty or near-empty, and has NO retention set
(the original group's 30-day retention does not carry over), so it does not
age out on its own.

Two "fixes" were tried and both live-disproven before landing on the final
design:

1. `DeletionPolicy: Retain` + a `LogGroupCleanup` custom-resource chain
   (retained groups deleted late, with retries, by a third Lambda).
   REVERTED, two independent adversarial retests:
   - CRITICAL: the cleanup Lambda's own log group
     (`/aws/lambda/captain-s3-logclean-<SyncId>`) was retained, never
     deleted by anything, and named deterministically on `SyncId` alone.
     Since the enroll endpoint guaranteed-404s until CAP-586 ships, every
     real customer's FIRST Launch Stack click fails and rolls back, and the
     RETRY with the same prefilled link (same `SyncId`) hard-failed
     immediately at CREATE because the retained group already existed.
   - The rescue chain also had an unfixable race: the enroll/setnotif log
     groups land in CloudFormation's first parallel create batch while the
     4-resource cleanup chain takes longer; an early sibling failure cancels
     in-flight creates, so the orphan could happen with no rescuer created.
2. Plain stack-owned log groups at the default `/aws/lambda/<function>`
   names (deterministic on `SyncId` alone). ALSO insufficient, confirmed
   live this round: a natural create-fail-rollback (real 404ing enroll
   endpoint) left BOTH log groups orphaned via the race above
   (CloudFormation events showed both `DELETE_COMPLETE`; both still existed,
   0 bytes), and the IDENTICAL same-`SyncId` retry was then rejected before
   creating anything: `CREATE_FAILED ... Validation failed with 2 error(s)`,
   with `describe-events` listing `EnrollLogGroup` and
   `SetBucketNotificationLogGroup` as the two `VALIDATION_ERROR`s
   (CloudFormation's resource-existence validation sees the orphans).

**Final design.** The log groups stay plain stack-owned resources (normal
create, normal delete with the stack, 30-day retention), but their NAMES
embed a per-stack-instance token: the first segment of the `AWS::StackId`
UUID, unique per Launch Stack attempt:

```
/captain/s3-sync/<syncId>/<attemptToken>/enroll
/captain/s3-sync/<syncId>/<attemptToken>/setnotif
```

Each Lambda points at its group explicitly via `LoggingConfig.LogGroup`
(function and role names stay deterministic on `SyncId`, so the
`MaxLength: 44` invariant is untouched). A retry is a new stack instance,
so it gets fresh log group names and can never collide with an orphan from
a failed attempt.

Invariant to preserve going forward: NO resource whose name is
deterministic on `SyncId` alone may be able to survive a rollback, by
policy OR by the CloudWatch recreate race. IAM roles, Lambda functions, and
the SNS topic are `SyncId`-deterministic but delete cleanly and
synchronously on rollback (verified live: retries recreate them without
complaint); log groups are the one resource class with the async recreate
race, and they now carry the per-attempt token.

**Accepted residue (honest accounting):** when the race fires, a failed
deploy can still leave an orphaned, empty log group under the per-attempt
name. It is cosmetic, collision-proof, has no retention, and is removable
with one line:

```bash
aws logs describe-log-groups --log-group-name-prefix "/captain/s3-sync/<syncId>/" --region <region>
aws logs delete-log-group --log-group-name "/captain/s3-sync/<syncId>/<attemptToken>/enroll" --region <region>
```

The backend (CAP-586 scope) could sweep these on enroll failure if we ever
care; not worth it today.

The Terraform variant has no equivalent problem: its log groups are
ordinary managed resources (no `prevent_destroy`, no `skip_destroy`), and
Terraform does not auto-rollback-delete on a failed apply at all, so there
is no delete race and no retained-name collision on re-apply (verified by
reading `aws/terraform/main.tf`, not assumed).

## Validation status

- `aws cloudformation validate-template --region us-east-1` : PASS
  (reports `CAPABILITY_NAMED_IAM` required, as expected for the named roles),
  re-run this round after reverting the log-group-cleanup chain, still PASS.
- `cfn-lint` : PASS, zero warnings, re-run this round after the revert.
- `terraform fmt -check -diff`, `terraform validate`, `tflint` (`aws/terraform`)
  : all PASS, zero warnings, re-run this round (Terraform is untouched by
  this round's fix; the orphaned-log-group race is CloudFormation-specific,
  since Terraform has no equivalent automatic-rollback-delete behavior on a
  failed apply -- a failed `apply` just leaves what it already created).
- CloudFormation, log-group revert + per-attempt names: DEPLOYED this
  round. Live retest of the exact critical scenario: real stack, throwaway
  bucket, real 404ing enroll endpoint, natural create-fail-rollback, then
  an IDENTICAL retry with the SAME `SyncId`. With plain `/aws/lambda/...`
  names the retry was REJECTED at validation (see the section above); with
  the per-attempt names the retry proceeded past all resource creation and
  failed only at the expected enroll 404. Full teardown and a residue sweep
  (describe-stacks + describe-log-groups) came back clean afterward.
- CloudFormation: DEPLOYED a prior round against real, throwaway,
  uniquely-timestamped buckets in the internal test account, specifically to
  live-verify the two fixes above (not just re-read the template):
  1. `CreateStack` with a 65-char `SyncId` (the exact value that previously
     produced `ROLLBACK_FAILED`/`DELETE_FAILED`) now fails synchronously with
     `ValidationError: Parameter SyncId failed to satisfy constraint` before
     any resource is touched. No stack, no role, nothing to roll back.
  2. `CreateStack` with a boundary 44-char `SyncId` is accepted and the stack
     proceeds to real resource creation (IAM roles, log groups); on a later
     `CREATE_FAILED` the stack reached `ROLLBACK_COMPLETE` cleanly, no
     `ROLLBACK_FAILED`, confirmed no leftover IAM roles/log groups after.
  3. A bucket pre-wired with a sibling `ObjectCreated` notification hook
     (whole-bucket, unrelated `Id`) made a whole-bucket sync deploy fail at
     `SetBucketNotification` as designed, `ROLLBACK_COMPLETE`, and the live
     `ResourceStatusReason` text was read back verbatim: it names the
     conflicting hook and points at "a non-overlapping ObjectPrefix... see
     NOTES.md" with no EventBridge mention. The sibling hook was confirmed
     untouched on the bucket afterward.
  All three stacks, both buckets, and the sibling SNS topic were fully torn
  down after (`delete-stack` + `wait stack-delete-complete`, bucket/topic
  deletes); a final sweep for stacks/buckets/topics/roles matching the test
  naming came back empty, and `git status` shows no residue outside the
  intended file edits.
- Terraform: NOT deployed this round (the `sync_id` fix is a `terraform
  validate`-time check, already exercised above; a live `apply` would need a
  real Captain callback endpoint, which is still CAP-586, unchanged from
  prior rounds). The previous round's live Terraform deploy/retry testing
  (cached-failure trap, `-replace` retry, plain-apply-after-failure) is
  unaffected by this round's changes and still holds.

## Repo-wide internal status (moved out of the root README)

The root README is customer-facing now; the conventions, per-cloud QA status,
and backend work list that used to live there are kept here.

### Conventions

- Template versions and any versioned URL path segment are DATE-based,
  `YYYY-MM-DD` (for example `.../templates/2026-08-12/captain-s3-sync.yaml`).
- Customer-facing object ids are Stripe-style `prefix_token`
  (`dep_...` deployment ids, `sync_...` sync ids). No bare UUIDs in outputs.
- No em dashes anywhere in customer-facing copy.

### Per-cloud verification status

All five providers are built: AWS S3, GCP GCS, Azure Blob, Cloudflare R2, and
Backblaze B2. Each has a template or script, a per-cloud README, and a NOTES.md
documenting what adversarial testing found and fixed. None can complete a real
customer launch yet: every one of them phones home to a Captain enroll receiver
that does not exist. AWS's contract is tracked as CAP-586; each other cloud's
NOTES.md lists its own exact payload shape for the same class of missing
endpoint. Until those receivers exist, a real deploy reaches the phone-home step
and fails there by design (fail-closed).

What has been verified, per cloud:

- **AWS S3** (CAP-569). CloudFormation validates clean
  (`aws cloudformation validate-template`, `cfn-lint`) but has not been deployed
  as a real stack. Terraform validates clean and WAS deployed live this round
  against a real, throwaway bucket with a mock Captain endpoint standing in for
  the receiver, then fully torn down. Both paths correctly detect and fail fast
  on S3's one-notification-slot overlap constraint on a bucket that already has
  a hook.
- **GCP GCS** (CAP-570). Both the Terraform and `gcloud/setup.sh` paths are
  built and statically validated (`terraform validate`, `shellcheck`, `bash -n`).
  Live provisioning is BLOCKED on the build machine by `gcloud` auth (no active
  credential, and separately no IAM permissions on Pub/Sub or Storage), so
  nothing has run against a real GCP project. Verification instead used a mocked
  `gcloud` on `PATH` to drive the real script's control flow, plus a local mock
  enroll endpoint for the phone-home. That approach caught and fixed two real
  bugs: a SIGPIPE crash in the id generator, and a notification-name
  prefix-collision false match.
- **Azure Blob** (CAP-571). Bicep compiles clean to ARM (`az bicep build`,
  `az bicep lint`). Testing found and fixed two bugs that silently killed the
  phone-home, a SIGPIPE token generator and a missing `curl` binary in the
  pinned CLI image, then verified both the success and failure branches live,
  end to end, inside the real pinned container image against a local mock
  server. Not deployed to real Azure: no CLI auth and no live Captain Azure
  endpoint in this environment. Azure also carries a dependency none of the
  others do: a multi-tenant Captain AD app with an admin-consent flow, which
  has to exist before `captainPrincipalId` can even be filled in.
- **Cloudflare R2** (CAP-572). The Worker bundles clean and Terraform validates
  clean. Path A (`deploy.sh`/`teardown.sh`, Wrangler) IS live-tested end to end
  against a real Cloudflare account and R2 bucket, including confirmed event
  delivery through the queue. Driving actual failing `wrangler` calls, rather
  than relying on lint alone, turned up and fixed two real bugs in the
  scripts' error handling. Path B (Terraform, the scoped-token path) validates
  but could not be exercised live here: this environment's OAuth session
  cannot mint an R2 S3 API token; it needs a real `CLOUDFLARE_API_TOKEN`.
- **Backblaze B2** (CAP-568). The setup script and the Terraform module both
  pass their linters, and a full live provision-and-teardown ran against a
  real, throwaway B2 bucket: authorize, list, mint the scoped read key, hit
  Captain's placeholder enroll endpoint (a real 404, since the receiver doesn't
  exist), and roll back cleanly. Event Notifications are separately BLOCKED by
  Backblaze's own per-account gating (enabled only by support ticket); until
  that clears, a B2 sync falls back to reconcile-only polling, and that
  fallback is intentional.

### Backend work required before customer launch

Every provider needs the same class of backend work before a customer can
complete a real launch: a Captain enroll receiver that authenticates the
one-time secret, proves the read grant works, and only then returns
`verified: true`; a deployment-state endpoint for the READMEs' debugging
pointers; and delete/teardown handling. See each cloud's own `NOTES.md` for its
exact payload contract.

### Publish-time TODO (root README button)

The root README's Launch Stack button points at
`https://TEMPLATE-BUCKET-PLACEHOLDER.s3.amazonaws.com/templates/2026-08-13/captain-s3-sync.yaml`.
At publish time, upload the CloudFormation template to the real public bucket
under a dated path and replace the placeholder host in the README.
