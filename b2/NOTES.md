# Engineering notes: b2/ (captain-b2-sync)

Two paths: a shell script (`setup/captain-b2-sync.sh`) and a Terraform
module (`terraform/`). Both enroll against Captain's live API
(`POST {api_base}/v2/syncs/<sync_id>/webhooks`); the only prerequisites a
customer needs are their sync id, a Captain API key, and the subscribe URL
the run mints for them.

## Design choices

- **No cross-account assume-role on B2.** AWS gives Captain a role it
  assumes with an external id and temporary credentials; B2 has no
  equivalent. The nearest safe primitive is a scoped application key:
  read-only, restricted to the one bucket, capabilities
  `listBuckets,listFiles,readFiles,readBucketNotifications`. The master
  key never crosses the wire. The webhook enrollment endpoint does not
  accept credentials, so the scoped key is handed to the customer instead
  of POSTed anywhere: the script prints it ONCE in the stdout success
  summary (stderr logs stay fully redacted), and the Terraform module
  exposes it as the sensitive `read_application_key` output, for the
  customer to set as the sync's credentials in Captain
  (docs.captain.dev/guides/sync/set-up). It is a long-lived credential,
  so `--key-duration` / `key_duration_seconds` give it an expiry;
  re-provision with a fresh key before expiry, since automatic rotation
  is not in place. Teardown deletes the scoped key by name, so
  revocation is one command.
- **Enrollment is the verification.** The provision call to
  `POST {api_base}/v2/syncs/<sync_id>/webhooks` (Bearer API key, empty
  JSON body) either returns 2xx with the minted `subscribe_url`, or the
  run fails. There is no separate confirm step to fake: the subscribe
  URL in the response is the thing the notification rule needs, so a
  green run cannot happen without Captain having answered. The script
  enrolls before touching notification rules and rolls back the scoped
  key on failure; Terraform enrolls via an external data source, so a
  failed enrollment fails the plan before any rule is created.
- **The event path is account-gated by Backblaze.** B2 Event Notifications
  are enabled per account by support ticket. Where not enabled,
  `b2_set_bucket_notification_rules` fails, and so does the Terraform
  `b2_bucket_notification_rules` resource. The script defaults to
  `--event-path auto`: it tries to set the rule, and on a non-enabled
  account prints a clear warning, marks the event status `blocked`, and
  keeps going, so the scoped key and the enrollment still complete.
  `--event-path force` turns a blocked event path into a hard failure.
  Terraform defaults `event_path = "skip"` so `apply` succeeds; flip it to
  `"enabled"` once the account has the feature. Reconcile polling via the
  S3-compatible endpoint is the always-on backstop, so a B2 sync is fully
  functional without events, just not near-real-time; the webhook is a
  latency optimization. Enrollment runs even on the skip path, so the
  subscribe URL is already minted when events get enabled later.
- **Notification rules are merged, not replaced, by the script.**
  `b2_set_bucket_notification_rules` replaces the whole rule set, exactly
  like S3's `PutBucketNotification`, so the script does a read-merge-write:
  append only our named rule, remove only ours on teardown, preserving
  sibling rules by name. Honest caveat: where Event Notifications are
  gated, the preserve path has not been exercised against a bucket that
  already carries other rules; verify it before relying on it. The
  Terraform resource owns the full set and does NOT merge; the module
  comments say to use the script (or `terraform import`) when siblings
  must be preserved.
- **The HMAC signing secret is B2-side.** Each run generates a 32-char
  secret for the notification rule's `hmacSha256SigningSecret`, which B2
  uses to sign event deliveries. It is generated locally, set on the
  rule, and redacted from logs.
- **Random generators guard against SIGPIPE.** The deployment-id and
  HMAC-secret generators build random strings with
  `tr -dc ... < /dev/urandom | head -c N`; `head` closes the pipe once it
  has its bytes, `tr` exits 141, and under `set -o pipefail -o errexit`
  that would silently abort the whole script before the key is minted or
  the enrollment runs. Both generators capture the pipe's output with a
  trailing `|| true` so the pipeline's exit status never reaches
  `errexit`. Any new generator needs the same guard; lint does not catch
  this class of bug.
- **Secrets travel by env var, not argv.** `--api-key` defaults from
  `CAPTAIN_API_KEY` (the flag still works and overrides it), and the
  README examples use env vars for every secret, because argv is visible
  to other local users via `ps` and lands in shell history.
- **Exit codes are a contract**: 0 success, 1 usage/preflight, 2 B2 API
  error, 3 Captain enrollment failed. Transport-level B2 API failures
  (`b2_authorize_account`, `b2_list_buckets`, `b2_create_key`) exit 2 via
  `die_api`; config-shaped problems that merely sit next to an API call (a
  malformed-but-HTTP-200 auth response, a bucket name not found in a
  successful listing) exit 1 on purpose. Callers script against this
  (retry on 2, not on 1); keep new failure paths consistent.
- **What lands in Terraform state.** The scoped read application key and
  the HMAC signing secret land in state in plaintext, so state must live
  on an encrypted backend (see `terraform/versions.tf`). The Captain API
  key does not: it travels only through the `CAPTAIN_API_KEY` environment
  variable into `enroll_webhook.sh`, never through a variable, a
  data-source query, or a resource attribute, so it never reaches state.
  If state is ever exposed, rotate the scoped key and regenerate the HMAC
  secret.

## Captain API contract (as wired)

1. **Webhook enrollment**: `POST {api_base}/v2/syncs/<sync_id>/webhooks`
   with `Authorization: Bearer <CAPTAIN_API_KEY>`. Body is `{}` for B2:
   `sns_topic_arn` is required only for S3-family syncs backed by SNS
   (the API returns 422 without it there); B2 delivers webhooks directly.
   `api_base` defaults to `https://api.captain.dev` and is overridable
   (`--api-base` / `CAPTAIN_API_BASE` / `var.api_base`) for staging.
2. **Response** (2xx JSON): `subscribe_url` (the per-sync ingest URL the
   B2 notification rule targets), `secret_set` (bool), `instructions`
   (array of strings). A 2xx with a `subscribe_url` IS the successful
   enrollment; there is no separate verify call.
3. **No unsubscribe endpoint.** Teardown removes the B2-side resources
   only. Captain detects the dead event source, and the scheduled
   reconcile backstop keeps the sync consistent until the customer pauses
   or deletes the sync in Captain.

Captain's existing surface (`captain_create_backblaze_sync`,
`captain_index_backblaze`, `captain_reconcile_sync`,
`captain_subscribe_sync_webhook`) covers sync creation, backfill,
reconcile, and this same webhook enrollment over MCP; the templates here
only wire the customer's B2 side to it.

## Testing changes

Static checks, all expected clean: `shellcheck` on
`setup/captain-b2-sync.sh` and `terraform/enroll_webhook.sh` (note it
cannot catch the SIGPIPE/pipefail/errexit interaction; only a live run
under the real shell flags surfaces that), `bash -n` on both system bash
and the shebang target, and `terraform validate` plus
`terraform fmt -check`.

For a live test, run a full provision and teardown against a real,
throwaway, timestamp-named bucket with a real staging sync:

- authorize and list should pass; id and secret generation should not
  abort silently.
- the scoped key should be minted, and its id plus secret half should
  appear in the stdout summary only, never in the stderr logs.
- the enrollment should return 2xx with a `subscribe_url`, and the
  notification rule (where events are enabled) should target exactly
  that URL.
- on a non-enabled account, the notification rule step should warn and
  continue (`blocked`), not fail.
- a bogus or revoked API key must exit 3 with a clear error and
  auto-roll-back the key the run minted.
- re-running teardown should be idempotent ("no matching keys found").
- confirm via `b2_list_buckets` / `b2_list_keys` that nothing permanent
  is left behind, and delete the throwaway bucket.

Exit-code regressions are cheap to check without touching real
infrastructure: bogus operator credentials against the real auth endpoint
must exit 2, a stubbed `curl` returning a synthetic failure on
`b2_list_buckets` must exit 2, and a malformed `--sync-id` or unknown
subcommand must exit 1.
