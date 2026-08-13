# Engineering notes: gcp/ (Captain GCS sync)

Two paths: Terraform (`terraform/`) and a shell script (`gcloud/setup.sh`
plus `gcloud/teardown.sh`). Enrollment verification is not yet activated on
the Captain backend, so a real end-to-end run reaches the phone-home step
and fails there by design; everything up to that step is exercisable today.

## Design choices

- **Cross-account read is Captain's own service account, not a customer
  key.** The GCP analog of the S3 assume-role. The customer only IAM-binds
  `captain_reader_service_account` (objectViewer, one bucket); Captain
  authenticates as itself from its own project, so no key material ever
  leaves the customer account. The confused-deputy guard that ExternalId
  provides on AWS is carried by `external_id` on the push endpoint and in
  the enroll payload; Captain must bind it to the sync.
- **Push auth is OIDC, not a shared secret in the URL.** Pub/Sub mints a
  Google-signed token as a dedicated push service account in the customer
  project; Captain verifies it. The one-time `enrollment_secret` is only
  for the enroll handshake, never for per-event auth.
- **Additive notification.** GCS buckets allow multiple notification
  configs, so there is no S3-style single-slot clobber problem. Teardown
  removes only ours.
- **Deterministic push SA id.** The push service account id is derived from
  the sync id (`cap-push-<sha256(sync_id)[:16]>`, under GCP's 30-char
  limit), so re-runs of `setup.sh` reuse the same SA instead of orphaning a
  fresh one each time, and `teardown.sh` can derive the same id when
  `--push-sa` is omitted.
- **`external_id` and `sync_id` are charset-validated and URL-encoded.**
  Both are validated against RFC 3986 unreserved characters
  (`^[A-Za-z0-9._~-]+$`) and percent-encoded when building
  `push_endpoint`. Either measure alone prevents URL injection; both are in
  place.
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
- **Teardown's delete notice is authenticated or skipped.** `teardown.sh`
  takes `--secret`; when supplied, the delete notice authenticates the same
  way the Terraform destroy path does. When omitted, the script skips the
  notice entirely (logged) rather than send a placeholder secret.
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

## Captain backend contract

The phone-home expects:

1. **Enroll receiver** (placeholder
   `https://api.runcaptain.com/v1/deploy/gcp/gcs/enroll`) accepting
   `{deploymentId, templateVersion, action, provider, storage, syncId,
   externalId, projectId, bucket, pubsubTopic, pubsubSubscription,
   pushServiceAccount, readerServiceAccount, ingestUrl, oidcAudience,
   secret}`. It must authenticate `secret` against `syncId` and return
   `2xx` with `{"verified": true, ...}`; anything else fails the run.
2. **A real verification handshake**: list/get on the bucket as
   `readerServiceAccount` to prove the objectViewer grant propagated, and
   allowlist `pushServiceAccount` as an accepted OIDC subject on
   `ingestUrl` for `oidcAudience`.
3. **An ingest endpoint** that verifies the Google-signed OIDC bearer token
   (audience, issuer accounts.google.com, subject equals the enrolled push
   SA), maps the delivery to a sync via the `sync_id`/`external_id` query
   params, and returns 2xx quickly so Pub/Sub does not redeliver.
4. **Per-deployment state** keyed by the `dep_<token>` id, for the README's
   debugging pointer.
5. **Delete handling**: teardown POSTs `{action: "delete", ...}`
   best-effort, so the backend should reconcile orphaned
   subscriptions and bindings.

## Testing changes

Static checks, all expected clean: `bash -n` and `shellcheck` on
`gcloud/setup.sh`, `gcloud/teardown.sh`, and `terraform/enroll.sh`;
`terraform fmt -check -diff` and `terraform validate` in `gcp/terraform`.
Note that none of these catch the SIGPIPE class of bug or exit-code
ordering mistakes; those need the scripts actually run.

Without a GCP project you can still exercise the real scripts' control
flow by putting a mock `gcloud` first on `PATH` that answers only the
subcommands the script calls and fails loudly on anything unrecognized,
plus a local mock enroll endpoint for the phone-home
(`terraform/enroll.sh` should exit 0 on `verified:true`, exit 1 with a
readable reason on `verified:false` or a 4xx, and exit 0 on the delete
action so teardown is never blocked). Check exit codes, not just the final
log line.

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
