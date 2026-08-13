# NOTES: honest flags for captain-b2-sync (CAP-568)

The B2 artifacts are built and pass their linters (`shellcheck` clean on both
scripts, `terraform validate` + `terraform fmt` clean on the module). A full
live provision + teardown has now been run end to end against a real,
throwaway B2 bucket (create bucket, mint scoped key, attempt the notification
rule, phone home, roll back, delete key, delete bucket). See "Fixed: SIGPIPE
abort" and "Validation status" below. Two things are still written to a
contract that depends on work OUTSIDE this repo. Read these before shipping.

## 0. Fixed: the random generators aborted the script silently (SIGPIPE/141)

A prior round of adversarial testing found that `new_deployment_id()` and
`new_hmac_secret()` in `setup/captain-b2-sync.sh` built their random strings as
`tr -dc ... < /dev/urandom | head -c N`. `head` exits once it has read N bytes
and closes its end of the pipe; `tr`, still writing into a pipe nobody is
reading, gets `SIGPIPE` and exits 141. Under `set -o pipefail` the pipeline
itself then reports 141, and under `set -o errexit` that standalone assignment
aborted the whole script silently, before the read key was minted, before the
notification rule was attempted, before the phone-home call. `errexit`
swallows the failure, so no `[ERROR]` line printed either: every provision and
every dry-run just stopped.

Fix: both generators now capture the pipe's output into a local variable with
a trailing `|| true`, so the pipeline's exit status never reaches `errexit`.
The bytes produced are unaffected by the signal; only the pipeline's reported
exit status was wrong. Verified with a 50-iteration stress test of both
generators under `set -o errexit -o nounset -o pipefail` (zero failures) and
with a full live provision against a throwaway bucket, which now proceeds
through key minting, the event-path check, and reaches the phone-home call as
intended (see "Validation status").

A related medium finding from the same round: the enroll secret and the
operator B2 app key were only reachable as CLI flags in the README examples,
visible to other local users via `ps`/`/proc` and left in shell history. The
enroll secret had no env-var fallback (the operator credentials already did).
Fix: `--secret` now defaults from `CAPTAIN_ENROLL_SECRET` (the flag still
works and overrides it); README examples for both provision and teardown use
env vars, not argv, for every secret.

## 1. The EVENT path is BLOCKED (Backblaze account gating)

B2 Event Notifications are a per-account feature that Backblaze enables by
support ticket. On an account where it is not enabled, `b2_set_bucket_notification_rules`
fails, and so does the Terraform `b2_bucket_notification_rules` resource.

How the artifacts handle it:

- `setup/captain-b2-sync.sh` defaults to `--event-path auto`: it TRIES to set
  the rule, and if the account is not enabled it prints a clear WARN, marks the
  event status `blocked`, and keeps going. The scoped read key and the
  self-verifying phone-home still complete, so the RECONCILE backstop is live.
  `--event-path force` turns a blocked event path into a hard failure (use once
  the account is enabled and you want to guarantee the webhook exists).
- `terraform/` defaults `event_path = "skip"` so `apply` succeeds today. Flip it
  to `"enabled"` once Backblaze has enabled the feature on your account.

Reconcile/polling via the S3-compatible endpoint is the always-on backstop and
works on its own; the webhook is only a latency optimization. So a B2 sync is
fully functional today, just not near-real-time until the event path is
unblocked. Track the Backblaze support ticket; when it clears, re-run the setup
script with `--event-path force` (or set `event_path = "enabled"` and re-apply).

## 2. Captain backend receivers (do not exist yet)

Both the script and the module phone home to Captain and require a verified
response. These receivers must exist before a real customer launch:

1. **Enroll endpoint** (`--callback-url`, default
   `https://api.runcaptain.com/v1/deploy/b2/enroll`). Accepts the POST body
   (`deploymentId, templateVersion, action, provider:"backblaze-b2", syncId,
   secret, account{accountId}, bucket{name,id}, s3Compatible{endpoint,region,
   keyId,applicationKey}, events{status,ruleName,webhookUrl,hmacSha256SigningSecret}`),
   authenticates `secret` against `syncId`, and returns `2xx` with
   `{"verified": true, "status": "..."}`. Anything else fails the deploy.

2. **The verification handshake.** On enroll Captain must actually use the
   scoped `s3Compatible` key against the `endpoint` (region-pinned S3v4) to
   `ListObjectsV2` + `GetObject`-probe the bucket, proving the read grant works,
   before returning `verified: true`. Without that, `verified` is meaningless.
   When the event path is `enabled`, Captain should also confirm the webhook
   rule is present (the scoped key carries `readBucketNotifications`).

3. **Events ingest endpoint** (`--events-url`, default
   `https://api.runcaptain.com/v1/deploy/b2/events?sync=<syncId>`). This is the
   webhook the B2 rule targets. It must verify the
   `X-Bz-Event-Notification-Signature` HMAC using the
   `hmacSha256SigningSecret` we send at enroll, and handle B2's test/verification
   ping that fires when a rule is created. Blocked until the event path is
   unblocked (see flag 1), but the receiver is real work.

4. **Deployment-state object.** Keyed by the `dep_<token>` id, so a customer can
   see whether the read probe passed and (later) whether the webhook is firing.
   The README points customers at it for debugging. Does not exist yet.

5. **Delete / teardown handling.** On teardown both artifacts POST
   `{action:"delete", ...}` best-effort. Captain should mark the deployment torn
   down and stop expecting events. Never blocks the client teardown.

The existing Captain MCP surface already has `captain_create_backblaze_sync`,
`captain_index_backblaze`, and `captain_reconcile_sync`, so the RECONCILE side
has a real foundation to test against today. The enroll receiver, the S3-probe
handshake, the events ingest, and the deployment-state object are the new
pieces.

## 3. No cross-account assume-role on B2 (design choice, not a bug)

AWS gives Captain a role it assumes with an external id and temporary creds. B2
has no equivalent. The nearest safe primitive is a scoped application key:
minted read-only, restricted to the one bucket, capabilities
`listBuckets,listFiles,readFiles,readBucketNotifications`. It is a long-lived
credential, so:

- We NEVER hand Captain the master key. Only the scoped key crosses the wire,
  and only over TLS in the enroll POST.
- Use `--key-duration` / `key_duration_seconds` to give the key an expiry and
  rotate. Captain must re-enroll (fresh key) before expiry; that rotation loop
  is a backend follow-up.
- Teardown deletes the scoped key by name, so revocation is one command.

## 4. Additive notification merge is reasoned, not yet tested against siblings

`setup/captain-b2-sync.sh` does a read-merge-write on the bucket's notification
rules (append only our named rule, remove only ours on teardown), because
`b2_set_bucket_notification_rules` replaces the WHOLE set, exactly like S3
`PutBucketNotification`. The merge preserves sibling rules by name, but it has
not been exercised against a bucket that already carries other rules (Event
Notifications being gated, there was no enabled account to test on). Verify the
preserve path before GA. The Terraform `b2_bucket_notification_rules` resource
owns the full set and does NOT merge; the module comments say to use the script
(or `terraform import`) when siblings must be preserved.

## 5. Fixed: B2 API failures were exiting 1 (usage error) instead of 2 (API error)

A final pre-launch QA sweep found `authorize()` and `resolve_bucket()` in
`setup/captain-b2-sync.sh` calling plain `die` (exit 1) on a failed
`b2_authorize_account` or `b2_list_buckets` call, instead of `die_api 2`. That
contradicts the script's own documented contract (`0 success, 1 usage/preflight,
2 B2 API error, 3 Captain verify failed`) and means a caller scripting against
the exit code (retry on 2, don't retry on 1, etc.) could not tell a bad
operator key or an outage apart from a malformed flag.

Fix: both call sites now use `die_api 2`, matching every other B2-API-error
call site already in the file (`b2_create_key`, the three `--event-path force`
fatal branches). The two `die` (exit 1) calls immediately after those same API
calls, for a malformed-but-HTTP-200 auth response and a "bucket not found"
after a successful `b2_list_buckets`, are left as exit 1 on purpose: those are
config/usage problems (bad response shape, wrong bucket name), not transport
failures, even though they sit next to an API call.

## 6. Fixed: STATE CONTAINS SECRETS block in terraform/versions.tf made a false claim about `var.secret`

The same sweep found the warning block claiming `var.secret` (the Captain
enrollment secret) lands in Terraform state IN PLAINTEXT, alongside the scoped
read application key and the HMAC secret, which genuinely do. That's wrong for
this stack: `var.secret` is used only inside the `environment` block of the
`local-exec` provisioner on `null_resource.enroll` (`main.tf`), never assigned
to a resource attribute or put in `triggers`, so it never reaches
`terraform.tfstate`. It directly contradicted `variables.tf`'s own description
of `secret` ("never stored anywhere it can be read back") in the same file set.

Root cause: the block was carried over from `r2/terraform/versions.tf`, where
the equivalent claim about `var.captain_secret` is true because the R2 stack
writes that secret into a `cloudflare_workers_script`'s `secret_text` binding,
a real persisted resource attribute. B2 has no equivalent resource, so the
warning didn't apply and shouldn't have been copied as-is.

Fix: removed `var.secret` from the plaintext-secrets list, added a short note
explaining why it doesn't apply here, and reworded the "if state is ever
exposed" remediation to rotate the scoped key and regenerate the HMAC secret
(the two things that actually need it) rather than also telling operators to
rotate an enrollment secret that was never at risk from a state leak in the
first place.

## Validation status

- `shellcheck 0.11.0` on `setup/captain-b2-sync.sh` and `terraform/phone_home.sh`:
  PASS, zero findings at `--severity=style`. Note: shellcheck does not catch
  the SIGPIPE/pipefail/errexit interaction above; that class of bug needs a
  live run under the real flags to surface, which is why it slipped through
  the prior round despite a clean lint. Guard against regressions with the
  live-run check below, not lint alone.
- `bash -n` syntax check: PASS on both `/bin/bash` (3.2.57, macOS system bash)
  and the script's own `#!/usr/bin/env bash` shebang target.
- `terraform validate` (provider Backblaze/b2 0.13.2) and `terraform fmt -check`:
  PASS.
- Live end-to-end provision + teardown against a real, throwaway B2 bucket
  (`captain-b2-fixtest-<timestamp>`, created and deleted this session):
  - `b2_authorize_account` + `b2_list_buckets`: PASS (region us-east-005, S3
    endpoint `s3.us-east-005.backblazeb2.com`).
  - Deployment id and HMAC secret generation: PASS, no silent 141 abort
    (confirms the SIGPIPE fix in the actual call path, not just in isolation).
  - `b2_create_key` (scoped read-only key): PASS, key minted then removed by
    rollback and confirmed deleted from the account.
  - Event Notification rule: BLOCKED as expected (`[bad_request] API not
    enabled`), account-gated per flag 1. Not fatal; script warned and
    continued.
  - Phone-home to `https://api.runcaptain.com/v1/deploy/b2/enroll`: reached
    (was NOT reached before the fix), got HTTP 404 as expected (CAP-586
    receiver does not exist yet), and the script failed at the RIGHT place
    with a clear `[ERROR]` message and exit code 3, then auto-rolled back the
    key it had minted.
  - Teardown command re-run afterward: idempotent, correctly reported "no
    matching keys found," and tolerated the same 404 on its best-effort
    Captain notice.
  - Bucket, key, and rule all confirmed gone from the account afterward
    (`b2_list_buckets` / `b2_list_keys` both empty). Nothing permanent left
    behind.

### Re-validation after items 5 and 6 (this round)

- `bash -n setup/captain-b2-sync.sh`: PASS.
- `shellcheck -x setup/captain-b2-sync.sh`: PASS, zero findings.
- `terraform fmt -check -diff` and `terraform validate` on `terraform/`
  (provider Backblaze/b2 0.13.2): PASS.
- Live test, `authorize()`'s `die_api 2` path: ran `provision` against the
  real Backblaze auth endpoint (`https://api.backblazeb2.com`) with bogus
  operator credentials. Got a real HTTP 401, script logged
  `b2_authorize_account failed (HTTP 401)` and exited **2**, confirmed via
  `echo $?`. Dies before any mutation, so no B2 resources were created and
  nothing needed tearing down.
- Live test, `resolve_bucket()`'s `die_api 2` path: stubbed `curl` in a
  scratch `PATH` (zero real network calls) to return a synthetic 200 on
  `b2_authorize_account` and a synthetic 403 on `b2_list_buckets`, so the
  path specifically exercised is the one this fix touches. Script logged
  `b2_list_buckets failed (HTTP 403)` and exited **2**, confirmed via
  `echo $?`. Fully stubbed, so again nothing to tear down.
- Usage-error paths still exit 1 after the fix (regression check): a
  malformed `--sync-id` and an unknown subcommand both still exit **1**.
- `terraform/versions.tf` fix is prose + comments only, no `.tf` logic
  changed; `terraform validate`/`fmt` above cover that it's still
  well-formed. Cross-checked the corrected claim against `main.tf` and
  `variables.tf` directly (not just re-reading the comment): `var.secret`
  appears exactly once in the whole `terraform/` directory, inside
  `null_resource.enroll`'s `local-exec` `environment` block, never in a
  resource attribute or in `triggers`.

## Publish-time TODO (moved from README)

The README's launch command downloads the script from
`https://captain-deploy-templates.s3.amazonaws.com/templates/2026-08-12/captain-b2-sync.sh`.
That host is a PLACEHOLDER: publish `setup/captain-b2-sync.sh` to a public
HTTPS location under a DATE-based version path and put that dated URL in the
README. The README now carries a customer-phrased "URL not yet active, clone
the repo instead" note; remove it once the script is published.
