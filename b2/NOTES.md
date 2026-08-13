# Engineering notes: b2/ (captain-b2-sync)

Two paths: a shell script (`setup/captain-b2-sync.sh`) and a Terraform
module (`terraform/`). Enrollment verification is not yet activated on the
Captain backend, so a real provision reaches the phone-home step and fails
there by design, rolling back the key it minted.

## Design choices

- **No cross-account assume-role on B2.** AWS gives Captain a role it
  assumes with an external id and temporary credentials; B2 has no
  equivalent. The nearest safe primitive is a scoped application key:
  read-only, restricted to the one bucket, capabilities
  `listBuckets,listFiles,readFiles,readBucketNotifications`. The master
  key never crosses the wire; only the scoped key does, over TLS in the
  enroll POST. It is a long-lived credential, so `--key-duration` /
  `key_duration_seconds` give it an expiry; Captain must re-enroll with a
  fresh key before expiry, and that rotation loop is backend work.
  Teardown deletes the scoped key by name, so revocation is one command.
- **The event path is account-gated by Backblaze.** B2 Event Notifications
  are enabled per account by support ticket. Where not enabled,
  `b2_set_bucket_notification_rules` fails, and so does the Terraform
  `b2_bucket_notification_rules` resource. The script defaults to
  `--event-path auto`: it tries to set the rule, and on a non-enabled
  account prints a clear warning, marks the event status `blocked`, and
  keeps going, so the scoped key and phone-home still complete.
  `--event-path force` turns a blocked event path into a hard failure.
  Terraform defaults `event_path = "skip"` so `apply` succeeds; flip it to
  `"enabled"` once the account has the feature. Reconcile polling via the
  S3-compatible endpoint is the always-on backstop, so a B2 sync is fully
  functional without events, just not near-real-time; the webhook is a
  latency optimization.
- **Notification rules are merged, not replaced, by the script.**
  `b2_set_bucket_notification_rules` replaces the whole rule set, exactly
  like S3's `PutBucketNotification`, so the script does a read-merge-write:
  append only our named rule, remove only ours on teardown, preserving
  sibling rules by name. Honest caveat: with Event Notifications gated,
  the preserve path has not been exercised against a bucket that already
  carries other rules; verify it before relying on it. The Terraform
  resource owns the full set and does NOT merge; the module comments say
  to use the script (or `terraform import`) when siblings must be
  preserved.
- **Random generators guard against SIGPIPE.** The deployment-id and
  HMAC-secret generators build random strings with
  `tr -dc ... < /dev/urandom | head -c N`; `head` closes the pipe once it
  has its bytes, `tr` exits 141, and under `set -o pipefail -o errexit`
  that would silently abort the whole script before the key is minted or
  the phone-home runs. Both generators capture the pipe's output with a
  trailing `|| true` so the pipeline's exit status never reaches
  `errexit`. Any new generator needs the same guard; lint does not catch
  this class of bug.
- **Secrets travel by env var, not argv.** `--secret` defaults from
  `CAPTAIN_ENROLL_SECRET` (the flag still works and overrides it), and the
  README examples use env vars for every secret, because argv is visible
  to other local users via `ps` and lands in shell history.
- **Exit codes are a contract**: 0 success, 1 usage/preflight, 2 B2 API
  error, 3 Captain verify failed. Transport-level B2 API failures
  (`b2_authorize_account`, `b2_list_buckets`, `b2_create_key`) exit 2 via
  `die_api`; config-shaped problems that merely sit next to an API call (a
  malformed-but-HTTP-200 auth response, a bucket name not found in a
  successful listing) exit 1 on purpose. Callers script against this
  (retry on 2, not on 1); keep new failure paths consistent.
- **What lands in Terraform state.** The scoped read application key and
  the HMAC signing secret land in state in plaintext, so state must live
  on an encrypted backend (see `terraform/versions.tf`). The Captain
  enrollment secret does not: `var.secret` is used only inside the
  `local-exec` provisioner's `environment` block on
  `null_resource.enroll`, never in a resource attribute or `triggers`, so
  it never reaches state. If state is ever exposed, rotate the scoped key
  and regenerate the HMAC secret.

## Captain backend contract

1. **Enroll endpoint** (`--callback-url`, default
   `https://api.runcaptain.com/v1/deploy/b2/enroll`) accepting
   `{deploymentId, templateVersion, action, provider:"backblaze-b2",
   syncId, secret, account{accountId}, bucket{name,id},
   s3Compatible{endpoint,region,keyId,applicationKey},
   events{status,ruleName,webhookUrl,hmacSha256SigningSecret}}`,
   authenticating `secret` against `syncId` and returning `2xx` with
   `{"verified": true, ...}`.
2. **A real verification handshake**: use the scoped `s3Compatible` key
   against the endpoint (region-pinned S3v4) to `ListObjectsV2` and
   `GetObject`-probe the bucket before returning `verified: true`; when
   the event path is enabled, also confirm the webhook rule is present
   (the scoped key carries `readBucketNotifications`).
3. **Events ingest endpoint** (`--events-url`, default
   `https://api.runcaptain.com/v1/deploy/b2/events?sync=<syncId>`), the
   webhook the B2 rule targets. It must verify the
   `X-Bz-Event-Notification-Signature` HMAC using the
   `hmacSha256SigningSecret` sent at enroll, and handle B2's
   test/verification ping fired when a rule is created.
4. **Per-deployment state** keyed by the `dep_<token>` id, for the
   README's debugging pointer.
5. **Delete handling**: teardown POSTs `{action:"delete", ...}`
   best-effort and never blocks the client teardown, so the backend should
   reconcile.

Captain's existing surface (`captain_create_backblaze_sync`,
`captain_index_backblaze`, `captain_reconcile_sync`) already covers the
reconcile side; the enroll receiver, the S3 probe, the events ingest, and
the deployment-state object are the new pieces.

## Testing changes

Static checks, all expected clean: `shellcheck` on
`setup/captain-b2-sync.sh` and `terraform/phone_home.sh` (note it cannot
catch the SIGPIPE/pipefail/errexit interaction; only a live run under the
real shell flags surfaces that), `bash -n` on both system bash and the
shebang target, and `terraform validate` plus `terraform fmt -check`.

For a live test, run a full provision and teardown against a real,
throwaway, timestamp-named bucket:

- authorize and list should pass; id and secret generation should not
  abort silently.
- the scoped key should be minted, then removed by rollback and confirmed
  deleted from the account.
- on a non-enabled account, the notification rule step should warn and
  continue (`blocked`), not fail.
- the phone-home should be reached and fail closed with exit 3 and a
  clear error while the receiver is not activated, then auto-roll-back
  the key it minted.
- re-running teardown should be idempotent ("no matching keys found") and
  tolerate the same enroll failure on its best-effort notice.
- confirm via `b2_list_buckets` / `b2_list_keys` that nothing permanent
  is left behind, and delete the throwaway bucket.

Exit-code regressions are cheap to check without touching real
infrastructure: bogus operator credentials against the real auth endpoint
must exit 2, a stubbed `curl` returning a synthetic failure on
`b2_list_buckets` must exit 2, and a malformed `--sync-id` or unknown
subcommand must exit 1.
