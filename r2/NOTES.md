# Engineering notes: r2/ (captain-r2-sync)

The Worker typechecks and bundles clean (`wrangler deploy --dry-run`); the
Terraform validates clean (`tofu validate`, `tofu fmt`). Enrollment
verification is not yet activated on the Captain backend, so a real deploy
reaches the phone-home step and fails there by design.

## Design choices

- **One Worker, three roles** (queue consumer, keyless read proxy,
  phone-home). Keeps the deploy to a single artifact and makes the keyless
  read path possible.
- **Two read strategies on purpose.** The keyless proxy (Path A, Wrangler)
  is the cleanest no-long-lived-keys story but requires a new reconcile
  adapter on the Captain side (below). The scoped token (Path B,
  Terraform) works with Captain's R2 sync as it exists today but is a
  long-lived credential, because R2 has no assume-role equivalent. That is
  mitigated by scoping: the token is read-only and bucket-scoped, not
  account-wide, and carries an expiry. The token id and value (and the
  SHA-256-derived S3 secret) live in Terraform state in plaintext, so
  state must be on an encrypted backend (see `terraform/versions.tf`).
- **Minting the Path B token needs a real API token.** Creating an R2 S3
  API token requires `CLOUDFLARE_API_TOKEN` (API Tokens: Edit); a
  wrangler OAuth session cannot mint one. Path A sidesteps this entirely
  since no S3 token is minted at all.
- **Per-sync naming.** The default `captain-r2-sync` Worker and queue
  names collide if two syncs share one account; override
  `WORKER_NAME`/`QUEUE_NAME` (Path A) or `worker_name`/`queue_name`
  (Path B) to run more than one.
- **Dead-letter queue** parks messages after `max_retries` so a broken
  ingest does not loop forever; reconcile covers whatever lands there.
- **Events are a latency optimization, not the source of truth.**
  Scheduled reconcile through the read path remains authoritative;
  `/__captain/selftest` exists so a customer can confirm event delivery in
  their own account before trusting it as more than an optimization.
- **The selftest canary is deleted synchronously.** The selftest writes a
  canary object and deletes it in the same request, right after the write.
  The R2 event notifications for the `PutObject` and `DeleteObject` fire
  the moment each operation happens, so the object never needs to persist.
  Do not reintroduce a deferred cleanup (`ctx.waitUntil` around a timer):
  a bare `setTimeout` inside `waitUntil` is not a reliable way to keep a
  Workers isolate alive, the deferred delete never runs, and since
  `deploy.sh` calls the selftest on every deploy, the customer's real
  bucket accumulates `__captain/healthcheck/*` objects, each one a real
  `PutObject` that Captain's ingest has no reason to filter out.

## Shell scripts: run_step() and idempotency patterns

`deploy.sh` and `teardown.sh` wrap every wrangler call in a shared
`run_step()` helper (identical in both files, keep them byte-identical). A
step is fatal only when wrangler's real exit code is non-zero AND its
output does not match the step's known idempotent-ok text; any `grep -v`
filtering is purely cosmetic. Two hard-won rules for anyone touching it:

- The output capture must be the condition of an `if`
  (`if out="$("$@" 2>&1)"; then status=0; else status=$?; fi`). A bare
  `out=$(cmd)` assignment gets no `errexit` exemption under
  `set -euo pipefail`, so the script dies on the assignment before the
  idempotency check or `die()` ever runs. `shellcheck` and `bash -n`
  cannot catch this; only driving a failing command through the script
  does.
- Never trust a guessed idempotent-error substring without confirming it
  against a real wrangler run. Cloudflare's actual texts differ from the
  obvious guesses: re-creating an existing queue returns "is already
  taken" (not "already exists"), and re-creating an existing notification
  rule returns a rule-conflict message (code 11020) containing neither
  word. The delete-side "not found"/"does not exist" patterns do match
  the real text.

Related trap when testing events: `wrangler r2 object put` writes to
Miniflare's local R2 simulator unless given the flag targeting the real
remote bucket. A local write never fires a real event notification, which
looks identical to "notifications are broken." The selftest writes through
the R2 binding and always hits the real bucket.

## Captain backend contract

1. **Ingest receiver** (`CAPTAIN_INGEST_URL`, default
   `https://api.runcaptain.com/v1/deploy/r2/ingest`). Accepts
   `{source:"r2", syncId, bucket, accountId, templateVersion,
   events:[{op, key, size, eTag, action, eventTime}]}` with
   `Authorization: Bearer <secret>` and `x-captain-sync-id`. It must be
   idempotent per `(syncId, key, eventTime)` because the Worker retries
   whole batches on any non-2xx.
2. **Enroll receiver** (`CAPTAIN_ENROLL_URL`, default
   `https://api.runcaptain.com/v1/deploy/r2/enroll`). Path A sends the
   shared `secret`; Path B also sends `readAccessKeyId` + `readSecretKey`.
   It must actually verify before returning `{"verified": true}`: for
   Path A, call back the Worker read proxy
   (`GET {workerUrl}/__captain/objects` with the bearer secret) and
   confirm it can list; for Path B, use the scoped key against the R2 S3
   API and confirm the same.
3. **A reconcile adapter for the keyless proxy.** Path B's key plugs into
   Captain's existing R2 sync as-is; Path A's proxy is a new read mode
   (list/fetch over HTTPS from `{workerUrl}/__captain/*` with the bearer
   secret instead of the S3 API).
4. **Teardown handling.** `teardown.sh` (Path A) and `tofu destroy`
   (Path B) remove the client-side resources, but neither currently tells
   Captain the sync went away; the backend should reconcile orphaned
   enrollments until a delete handshake exists.

## Testing changes

- Worker: `npm install && npm run build` in `worker/`, then
  `wrangler deploy --dry-run` and the typecheck; both must be clean.
- Terraform: `tofu fmt` and `tofu validate`, but only after the Worker
  build exists: `main.tf`'s `content_sha256` reads
  `worker/dist/index.js` off disk, so validate fails with
  "content_sha256 must be specified" on a fresh checkout (documented in
  the README's Path B step 1).
- `bash -n` and `shellcheck` on `deploy.sh` and `teardown.sh`, plus a live
  drive of `run_step()` for both a fatal error (for example an invalid
  queue name, which must halt with the real Cloudflare error text) and an
  idempotent-ok response (which must not halt).
- For a live Path A test, use a throwaway timestamp-named Worker and
  queue against a bucket you own: deploy, call `/__captain/selftest`
  several times and confirm zero `__captain/healthcheck/*` objects remain,
  confirm create and delete events arrive through the queue, then run
  `teardown.sh` and verify the Worker, both queues, and the secret are
  gone (`wrangler deployments list`, `wrangler queues list`). The stack
  never creates or deletes buckets, so the bucket should be untouched.
- Path B needs a real `CLOUDFLARE_API_TOKEN` to exercise live.
