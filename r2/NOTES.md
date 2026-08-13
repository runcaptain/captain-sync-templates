# NOTES: honest flags for captain-r2-sync (CAP-572)

The Worker bundles clean (`wrangler deploy --dry-run`, typecheck clean) and the
Terraform validates clean (`tofu validate` + `tofu fmt`, OpenTofu 1.12,
cloudflare provider 5.23). NOT deployed. Some pieces it depends on are Captain
BACKEND work or Cloudflare-account realities that need to be settled before a real
customer launch.

## Cloudflare / auth realities observed in this environment

1. **Minting an R2 S3 API token via OAuth is BLOCKED.** The wrangler session here
   is an OAuth token, and the OAuth flow could not mint an R2 S3 API token. Impact
   by path:
   - Path A (Wrangler) sidesteps this entirely: reads go through the Worker's
     keyless proxy, so no S3 token is minted at all.
   - Path B (Terraform) mints the scoped read token with a real Cloudflare API
     token (`CLOUDFLARE_API_TOKEN` with API Tokens: Edit), NOT OAuth, so a
     customer running Terraform with their own API token is fine. It cannot be
     exercised from this OAuth-only environment.

2. **CORRECTED: the earlier "R2 event notifications delivered ZERO events" finding
   did not reproduce.** A real write against the actual remote bucket delivered
   both a create event and a delete event through the queue to the Worker in
   about 6 seconds. The likely cause of the original 0-events observation: the
   object write in that earlier test went through `wrangler r2 object put`
   WITHOUT the flag that targets the real remote bucket, which by default writes
   to Miniflare's local R2 simulator instead. A write to the local simulator
   never touches the real bucket, so no real event notification could have fired
   for it, which looks identical to "notifications are broken" if you are not
   watching for it. Path A's Queue path works end to end when writes actually
   hit the real bucket. The design still does not depend on this being reliable
   in every account: scheduled reconcile through the read path remains the
   source of truth, and `/__captain/selftest` (which writes through the R2
   binding, always the real bucket, never the local simulator) exists to let a
   customer confirm event delivery in their own account before trusting it as
   more than a latency optimization.

3. **FIXED (round 3): `deploy.sh` and `teardown.sh` were silently swallowing
   real wrangler failures.** All 9 call sites piped wrangler's output through
   `grep -v ... || true` and never checked wrangler's own exit code. Since
   grep exits 0 whenever any line survives its filter, and the trailing
   `|| true` guaranteed success on top of that, a fatal wrangler failure
   (expired auth, permission denial, rate limit, invalid resource name,
   network blip) never stopped the script; it printed "Done" regardless of
   whether the step actually worked. Fixed by capturing each wrangler call's
   output and real exit code directly from a command substitution (no pipe),
   in a shared `run_step()` helper: a step is fatal only when the real exit
   code is non-zero AND the output does not match the step's known
   idempotent-ok text; the `grep -v` that used to decide success/failure is
   now purely cosmetic, hiding the noisy idempotent line from what gets
   echoed.
   - Live-testing this against a real account caught a second bug the first
     pass would have shipped: the idempotent-ok text patterns were guesses
     ("already exists") that do not match Cloudflare's actual API error
     text. A real re-run of `wrangler queues create` on a name that already
     exists returns "is already taken", not "already exists". A real re-run
     of `wrangler r2 bucket notification create` on a rule that already
     exists returns a rule-conflict/overlap message (code 11020) with
     neither word in it. Both patterns were corrected against the real
     response text, confirmed live (create, idempotent re-create, delete,
     idempotent re-delete, and an invalid-name create that must halt the
     script) against a throwaway timestamp-named queue and a real R2
     notification rule, torn down after. The "not found"/"does not exist"
     delete-side patterns did match Cloudflare's real text on the first try
     and needed no change.
   - Takeaway for anyone touching these two scripts again: never trust a
     guessed idempotent-error substring without confirming it against a
     real wrangler run. A first pass at this fix used "already exists" as
     the idempotent-ok pattern for both queue create and notification
     create, by analogy with the surrounding comments; that pattern reads
     correctly but does not match reality. Only running it live against a
     real account caught it, before it shipped. Left uncaught, it would
     have made a legitimate idempotent re-deploy fail loudly, which is
     exactly the failure mode this fix exists to prevent.

4. **FIXED (round 4): the round-3 `run_step()` fix was itself broken, and
   defeated the entire point of `run_step()`.** Round 3 wrote:
   ```
   out="$("$@" 2>&1)"
   status=$?
   ```
   as a bare assignment statement. Under this script's own `set -euo
   pipefail`, bash's `errexit` is NOT suspended for a plain `var=$(cmd)`
   assignment. It IS suspended when the same command substitution is the
   condition of an `if`/`while`, or sits on the left of `&&`/`||`, but a
   bare assignment gets no such exemption. So the instant the wrapped
   wrangler command exited non-zero, the whole script died right there,
   on that line, before `status=$?` ever ran, before the `ok_pattern`
   idempotency check ever ran, before `die()` ever printed anything. That
   is the one case `run_step()` exists to handle: an idempotent-ok
   failure (a Cloudflare "already exists" / "not found" response,
   confirmed by round 3 to exit non-zero on real infra) killed the
   script instead of being recognized as a no-op. A genuine fatal error
   also killed the script, but with zero diagnostic output, because
   `die()` never got a chance to run either. Round 3's shellcheck and
   `bash -n` passes did not catch this: both are syntax-level, and
   `var=$(cmd)` under `set -e` is syntactically fine, so nothing short of
   actually driving a failing command through the real script under `set
   -e` surfaces it. Round 3's live tests happened to only exercise the
   round-2 pattern-guessing question (does the ok_pattern text match?)
   and never independently drove a case where `run_step` had to survive
   its own wrangler call failing, so the errexit abort went unnoticed.
   - The fix: move the command substitution to be the condition of an
     `if`, which bash explicitly exempts from `errexit`:
     ```
     if out="$("$@" 2>&1)"; then
       status=0
     else
       status=$?
     fi
     ```
   - Proved this exact form is errexit-safe before touching the real
     files: wrote a throwaway two-function repro script under `set -euo
     pipefail`, one function using the bare-assignment (buggy) form
     around `false`, one using the `if`-form (fixed). Ran both. The buggy
     form's function body never even reached its own `echo` after the
     assignment; the whole script exited 1 immediately. The fixed form's
     function printed its post-assignment line, correctly reported
     `status=1`, and the script exited 0. Only after seeing that did the
     same `if`-form get applied to the real `run_step()` in both
     `deploy.sh` and `teardown.sh` (identical function bodies in both
     files; confirmed byte-identical with `diff` after the edit).
   - `shellcheck` and `bash -n` pass clean on both files post-fix (as
     expected: this bug was never a syntax-level problem).
   - Live-verified both scenarios against the real internal test account,
     driving the actual fixed
     `run_step()` function body (extracted verbatim, not
     reimplemented) against real wrangler calls, not a simulation:
     - **Idempotent-ok, exact repro:** created a throwaway queue, then
       ran `wrangler r2 bucket notification delete` for a notification
       rule that was never wired to it. Real wrangler response: exit 1,
       `"Event notification config not found for the bucket 'r2-test'
       and queue '...': configuration not found for bucket and queue.
       [code: 11011]"`. Fed through the fixed `run_step()`: the script
       did not abort, a marker printed immediately after the call,
       execution continued normally, and the harness exited 0. Threwaway
       queue deleted immediately after.
     - **Genuine fatal, no ok_pattern match:** ran `wrangler queues
       create` with an invalid name (spaces and `!!`, violates
       Cloudflare's `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$` naming rule).
       Real wrangler response: exit 1, `"Queue name '...' is invalid:
       ... [code: 11003]"`. Fed through the fixed `run_step()`: the real
       Cloudflare error text printed to the terminal, `die()` fired, the
       script halted with exit 1, and a marker placed immediately after
       the call ("should never print") correctly never printed.
     - Confirmed no leftover resources afterward: `wrangler queues list`
       returned empty, `wrangler r2 bucket notification list r2-test`
       returned "no configurations found for bucket" (code 11015).

5. **FIXED (round 5): `/__captain/selftest` canary cleanup never actually ran.**
   The Worker wrote a canary object, then scheduled its deletion 60s later via
   `ctx.waitUntil(async () => { await sleep(60_000); await env.R2.delete(...) })`.
   Live-verified against the real account that this does not work: a fresh
   deploy, one `/__captain/selftest` call, then polling the real bucket via
   the Cloudflare API every 5s for 100+ seconds straight, the canary was
   never deleted. Independently corroborated by four leftover canary objects,
   up to ~40 minutes old, already sitting in the bucket from an earlier
   round's testing before this round touched anything. A bare `setTimeout`
   inside `waitUntil` with nothing else pending is not a reliable way to keep
   a Workers isolate alive that long, and this was customer-facing:
   `deploy.sh` runs `/__captain/selftest` on every deploy (step 7), and every
   idempotent re-run keys a new canary off `Date.now()`, so a real customer
   running Launch would get a permanently-growing pile of
   `__captain/healthcheck/*.txt` objects in their real production bucket,
   each one a real `PutObject` Captain's ingest has no documented reason to
   filter out.
   - Fix: delete the canary synchronously, in the same request, right after
     the write, instead of deferring it. The R2 event notification for the
     `PutObject` (and now also the `DeleteObject`) fires the moment each
     operation happens; the object does not need to still exist in the
     bucket for that notification to already be queued, so there was never
     a reason to hold it around for 60s. No `ctx.waitUntil`, no timer, no
     isolate-lifetime assumptions.
   - Live-verified the fix against the real internal test account
     (throwaway Worker + queue against
     the `r2-test` bucket, uniquely timestamped): deployed, called
     `/__captain/selftest` four times in a row (simulating repeated
     idempotent deploy re-runs), got `"cleanup": "done"` on every response,
     and confirmed via the read proxy immediately after each call, and again
     after all four, that zero `__captain/healthcheck/*` objects remained in
     the bucket. Also found and deleted the three pre-existing stale
     canaries left over from the earlier round's live testing, confirmed via
     a fresh listing that the bucket now has zero objects under that prefix.
     Full teardown afterward via `teardown.sh` itself: confirmed the Worker,
     both queues, and the secret are gone (`wrangler deployments list`
     returns "This Worker does not exist" [code: 10007]; `wrangler queues
     list` shows nothing matching); the `r2-test` bucket itself was left
     untouched, as this stack never creates or deletes buckets.

## Captain backend dependencies (do not exist yet)

The Worker and the Terraform phone-home speak a contract Captain must implement:

1. **Ingest receiver** (`CAPTAIN_INGEST_URL`, default
   `https://api.runcaptain.com/v1/deploy/r2/ingest`). Accepts
   `{source:"r2", syncId, bucket, accountId, templateVersion, events:[{op, key,
   size, eTag, action, eventTime}]}` with `Authorization: Bearer <secret>` and
   `x-captain-sync-id`. MUST be idempotent per `(syncId, key, eventTime)` because
   the Worker retries whole batches on any non-2xx. Confirm the exact path + shape.

2. **Enroll receiver** (`CAPTAIN_ENROLL_URL`, default
   `https://api.runcaptain.com/v1/deploy/r2/enroll`). Accepts the enroll body
   (`deploymentId, templateVersion, action, source, accountId, bucket, syncId,
   workerUrl, readStrategy, ...`; Path A sends the shared `secret`, Path B also
   sends `readAccessKeyId` + `readSecretKey`). It must actually verify before
   returning `{"verified": true}`:
   - Path A: call back the Worker read proxy (`GET {workerUrl}/__captain/objects`
     with the bearer secret) and confirm it can list.
   - Path B: use the scoped `readAccessKeyId`/`readSecretKey` against the R2 S3
     API and confirm it can list.
   Any non-2xx or `verified != true` fails the deploy (deploy.sh exits non-zero;
   Terraform postcondition fails the apply). Without real verification here,
   "verified" is meaningless.

3. **Read strategy wiring in Captain's R2 sync.** Path B produces an S3
   access_key_id/secret_access_key that plugs straight into the existing
   `captain_create_r2_sync` (which already authenticates with an R2 access key).
   Path A's keyless proxy is a NEW read mode Captain's reconcile does not have yet:
   it needs to fetch list/object over HTTPS from `{workerUrl}/__captain/*` with the
   bearer secret instead of via the S3 API. That reconcile adapter is new work.

4. **Deployment-state / teardown.** No per-`dep_<token>` state endpoint exists for
   debugging. Path A now ships `teardown.sh` (deletes the event notification,
   secret, queue consumer, Worker, and both queues; the AWS template's delete
   path is the model). Path B teardown is `tofu destroy`. Neither one currently
   tells Captain the sync went away: there is no delete/teardown handshake wired
   yet (ideally an enroll `action:"delete"` Captain should honor). Reconcile
   orphaned enrollments on the backend until that exists.

## Design choices worth knowing

- **One Worker, three roles** (queue consumer, keyless read proxy, phone-home).
  Keeps the deploy to a single artifact and makes the keyless read path possible.
- **Two read strategies on purpose.** Keyless proxy (Path A) is the cleanest "no
  long-lived keys" story but needs the new reconcile adapter (dep #3). Scoped
  token (Path B) works with Captain's R2 sync as it exists today but is a
  long-lived credential (R2 has no assume-role equivalent), mitigated by
  read-only scope, single-bucket scope (not account-wide), and expiry. That
  token id/value (and its SHA-256-derived S3 secret) live in Terraform state in
  plaintext; state MUST be on an encrypted backend (see `terraform/versions.tf`).
- **Per-sync naming** (`captain-r2-sync` Worker/queue) collides if two syncs share
  one account. Override `WORKER_NAME`/`QUEUE_NAME` (Path A) or `worker_name`/
  `queue_name` (Path B) to run more than one.
- **Dead-letter queue** parks messages after `max_retries` so a broken ingest does
  not loop forever; reconcile covers whatever lands there.

## Validation inventory (moved from README)

The Worker typechecks and bundles clean (`wrangler deploy --dry-run`). The
Terraform validates clean (`tofu validate` + `tofu fmt`), once the Worker
bundle has been built first (`cd worker && npm install && npm run build`):
`main.tf`'s `content_sha256` reads `worker/dist/index.js` off disk, so
`tofu validate` run before that build exists fails with "content_sha256 must
be specified" (this build-first requirement is now documented in the README's
Path B step 1). Path A (deploy.sh + teardown.sh) has been live-tested end to
end against a real Cloudflare account and R2 bucket.
