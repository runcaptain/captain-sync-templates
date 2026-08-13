# Engineering notes: gcp/ (Captain GCS sync)

Two paths: Terraform (`terraform/`) and a shell script (`gcloud/setup.sh`
plus `gcloud/teardown.sh`). Both end with a webhook-registration call to the
real Captain API (`POST /v2/syncs/{sync_id}/webhooks`); everything is
exercisable end to end with a sync id, an API key, and the minted
`subscribe_url` from Captain.

## Design choices

- **Cross-account read is Captain's own service account, not a customer
  key.** The GCP analog of the S3 assume-role. The customer only IAM-binds
  `captain_reader_service_account` (objectViewer, one bucket); Captain
  authenticates as itself from its own project, so no key material ever
  leaves the customer account.
- **Push auth is OIDC, not a shared secret in the URL.** Pub/Sub mints a
  Google-signed token as a dedicated push service account in the customer
  project. The Captain API key is only for the one registration call,
  never for per-event auth.
- **The push endpoint is the minted `subscribe_url`, verbatim.** Captain's
  webhook-registration endpoint mints a per-sync ingest URL; the template
  appends nothing to it (no query params), because the URL already
  identifies the sync. `--ingest-url` / `captain_ingest_url` therefore has
  NO default and is required: there is no shared ingest URL to fall back
  to. enroll.sh re-registers on every run and warns when the returned
  `subscribe_url` differs from the configured one.
- **API key stays out of logs and history.** `setup.sh` prefers the
  `CAPTAIN_API_KEY` env var over `--api-key`; Terraform marks
  `captain_api_key` sensitive and the tfvars example points at
  `TF_VAR_captain_api_key`. enroll.sh sends the key only in the
  Authorization header and never prints it (its debug logging prints the
  response body, which contains no secret). curl reads that header from a
  file in a private mktemp dir (`-H @file`, curl >= 7.55) rather than from
  argv, so the key is also invisible to `ps`, and the curl stderr capture
  lives in the same per-run dir instead of a fixed /tmp path two
  concurrent runs would share.
- **No teardown phone-home.** Captain documents no unsubscribe endpoint, so
  teardown does not invent one: `teardown.sh` and `terraform destroy` only
  remove the cloud-side resources. Captain detects the dead event source
  and the reconcile backstop keeps the sync consistent. (An earlier build
  round invented its own enroll/teardown endpoints; do not reintroduce any
  endpoint that is not in the contract section below, in code or docs.)
- **Additive notification.** GCS buckets allow multiple notification
  configs, so there is no S3-style single-slot clobber problem. Teardown
  removes only ours.
- **Deterministic push SA id.** The push service account id is derived from
  the sync id (`cap-push-<sha256(sync_id)[:16]>`, under GCP's 30-char
  limit), so re-runs of `setup.sh` reuse the same SA instead of orphaning a
  fresh one each time, and `teardown.sh` can derive the same id when
  `--push-sa` is omitted.
- **`sync_id` is charset-validated.** Both paths validate
  `^sync_[A-Za-z0-9]+$` before it is interpolated into the API path
  (`/v2/syncs/{sync_id}/webhooks`), so it cannot inject path segments.
- **Notification matching is exact, not substring.** Both scripts find our
  notification by parsing `gcloud storage buckets notifications list
  --format=json` with `jq` and matching `endswith("/topics/<TOPIC>")` on
  the nested `topic` field. A substring grep of the text output
  false-matches when an existing notification's topic name is a prefix of
  the new one, which silently skips creating the new sync's notification.
- **Notification-list errors are never swallowed.** A real failure of the
  list call (permission denied, wrong bucket, transient API error) makes
  `teardown.sh` record a failure and exit 1, and makes `setup.sh` die
  immediately rather than proceed to create a possibly duplicate
  notification. A not-found-style response is still tolerated via the
  shared `already_gone()` classifier, which lowercases output before
  matching because gRPC-style errors (`NOT_FOUND`) and GCS JSON API errors
  (`HTTPError 404: Not Found`) differ in casing.
- **Failure beats dry-run in exit ordering.** `teardown.sh` checks
  `TEARDOWN_HAD_FAILURE` before the `--dry-run` branch, so a dry run that
  hits a genuine failure exits 1 with a message saying so; the "nothing
  was deleted" success banner and exit 0 only happen when no step failed.
  The list calls run during a dry run too (listing what exists is how the
  script decides what a real run would delete), so real failures can and
  do happen under `--dry-run`.
- **Random-id generation guards against SIGPIPE.** `rand()` wraps its
  `tr -dc ... < /dev/urandom | head -c N` pipeline so a benign SIGPIPE
  cannot abort the script: `head -c` closes the pipe once it has enough
  bytes, `tr` exits 141, and under `set -euo pipefail` that would otherwise
  kill the whole script on every invocation. Any new random generator in
  these scripts needs the same guard.
- **Fresh-project race.** The Pub/Sub service agent must exist before the
  token-creator binding. `setup.sh` force-creates it (`gcloud beta services
  identity create`); on a brand-new project a Terraform user may need one
  re-apply if the agent was not yet materialized. Documented in the README.
- **`.terraform.lock.hcl` is committed**, matching the sibling modules; it
  pins provider versions and is not a secret or local state.

## Captain API contract (real, verified against the production MCP client)

The only Captain call these templates make:

1. **Webhook registration**:
   `POST {CAPTAIN_API_BASE}/v2/syncs/{sync_id}/webhooks` with
   `Authorization: Bearer {CAPTAIN_API_KEY}`. `CAPTAIN_API_BASE` defaults
   to `https://api.captain.dev` and stays overridable
   (`--api-base` / `captain_api_base`) for staging.
2. **Body**: `{}` for GCS. Only S3-family syncs send
   `{"sns_topic_arn": "..."}` (the API answers 422 without it there); GCS
   has no required body fields.
3. **Success**: any 2xx JSON response carrying `subscribe_url` (the
   per-sync ingest URL Captain minted), plus `secret_set` (bool) and
   `instructions` (array of strings). 2xx + `subscribe_url` IS a
   successful enrollment; enroll.sh requires both and logs the rest.
4. **Failure**: non-2xx fails the run (only 5xx and network errors are
   retried). 401/403 means the API key, 404 means the sync id.
5. **No unsubscribe endpoint.** Teardown makes no API call; reconcile is
   the backstop for orphaned wiring.

`deployment_id` (`dep_<token>`) is purely local: a Stripe-style correlation
id stamped on the run's logs and outputs. Captain does not key any state by
it.

## Testing changes

Static checks, all expected clean: `bash -n` and `shellcheck` on
`gcloud/setup.sh`, `gcloud/teardown.sh`, and `terraform/enroll.sh`;
`terraform fmt -check -diff` and `terraform validate` in `gcp/terraform`.
Note that none of these catch the SIGPIPE class of bug or exit-code
ordering mistakes; those need the scripts actually run.

Without a GCP project you can still exercise the real scripts' control
flow by putting a mock `gcloud` first on `PATH` that answers only the
subcommands the script calls and fails loudly on anything unrecognized,
plus a local mock of `POST /v2/syncs/{sync_id}/webhooks` for the
registration call (`terraform/enroll.sh` should exit 0 on a 2xx body with
a `subscribe_url`, exit 1 with a readable reason on a 4xx or a 2xx body
missing `subscribe_url`, and print the mismatch WARNING when `INGEST_URL`
differs from the returned `subscribe_url`). Check exit codes, not just the
final log line.

For a live test, use a throwaway project and bucket with a principal
holding the roles listed in the README, and verify at least:

- `setup.sh --dry-run` completes start to finish and mutates nothing.
- Two consecutive `setup.sh` runs reuse the same push SA.
- A new sync's notification is created (not skipped) on a bucket that
  already has an unrelated notification whose topic name prefix-collides
  with the new one.
- `teardown.sh` actually removes the bucket notification, and
  `teardown.sh --dry-run` against a bucket the caller lacks
  `storage.buckets.get` on exits 1.
- Confirm cleanup with `gcloud storage buckets notifications list`,
  `gcloud pubsub subscriptions/topics list`, and `gcloud iam
  service-accounts list`, not just the script's own "removed" message.

Tear down everything the test created before finishing.
