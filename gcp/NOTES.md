# NOTES: honest flags for captain GCS sync (CAP-570)

Both paths (Terraform and gcloud) are built and statically validated. Like the
AWS template, they are written to a contract that partly depends on Captain
BACKEND work that does NOT exist yet, and LIVE provisioning is currently blocked
by the build machine's auth (details below).

## Fix round 5 (final pre-launch QA gate, gcp only, third occurrence of this bug class)

One issue, confirmed and fixed: `teardown.sh --dry-run` could still exit 0
with "Done. Captain GCS sync resources for $SYNC_ID removed." even when a
genuine failure happened during the dry run.

**Root cause: exit-code ordering, not the classifier this time.** Round 4
fixed the dry-run banner (item 1 there) by adding a `DRY_RUN` branch ahead of
the final `TEARDOWN_HAD_FAILURE` check:

```
if [ "$DRY_RUN" = "1" ]; then
  step "Dry run only. Nothing was deleted and no teardown notice was sent."
  exit 0
fi
if [ "$TEARDOWN_HAD_FAILURE" = "1" ]; then
  step "Done with errors. ..."
  exit 1
fi
```

That fixed the case round 4 tested (dry run, no failures) but reintroduced
the exact bug class in a new spot: the `--dry-run` branch runs and returns
`exit 0` unconditionally, before the script ever looks at
`TEARDOWN_HAD_FAILURE`. The bucket-notification list call (the "Bucket
notification" step) is a real read, not gated by `DRY_RUN` at all -- it runs
during a dry run exactly as it does during a real one, because listing what
exists is how the script decides what a real run would delete. If that call
fails for a genuine reason (permission denied, wrong bucket, a transient API
error), `run "Bucket notification"`'s own error handling correctly sets
`TEARDOWN_HAD_FAILURE=1` and logs a `FAILED` line -- but the dry-run branch
below it exits 0 before that flag is ever read, so the script still printed
"Done, removed" over a `FAILED` line still visible a few lines up.

Fixed by checking `TEARDOWN_HAD_FAILURE` FIRST, before the `DRY_RUN` branch,
so a real failure always exits 1 regardless of `--dry-run`, and `--dry-run`
only gets to print its "nothing was deleted, exit 0" message when there was
in fact no failure:

```
if [ "$TEARDOWN_HAD_FAILURE" = "1" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    step "Dry run found errors. Nothing was deleted, but see FAILED lines above..."
  else
    step "Done with errors. Some resources for ${SYNC_ID} may still exist..."
  fi
  exit 1
fi
if [ "$DRY_RUN" = "1" ]; then
  step "Dry run only. Nothing was deleted and no teardown notice was sent."
  exit 0
fi
step "Done. Captain GCS sync resources for ${SYNC_ID} removed."
```

A `--dry-run` run that hits no real failures still exits 0 with the existing
honest message, unchanged from round 4. A `--dry-run` run that hits a real
failure now exits 1 with a message that says so, instead of silently
reporting success.

This is the third time a "dry-run reports success when it should not" bug
has shipped in `gcloud/teardown.sh` in this repo (round 3's `setup.sh`
banner, round 4's `teardown.sh` banner, now round 4's own fix for that
banner). Each fix addressed the specific case the previous round's live test
exercised without checking whether a case existed the test didn't cover.
This round's live test (below) specifically targets the ordering, not just
the message, by forcing a genuine failure during `--dry-run` and checking
the exit code, not just eyeballing the final line.

## Validation status (round 5)

- `bash -n` on `gcloud/setup.sh`, `gcloud/teardown.sh`, `terraform/enroll.sh`
  : PASS.
- `shellcheck` on the same three files : PASS, clean, no new nits.
- `terraform fmt -check -diff` (`gcp/terraform`) : PASS, no diff.
- `terraform validate` (`gcp/terraform`) : PASS, "The configuration is
  valid."
- Real GCP live testing is still BLOCKED in this environment: `gcloud auth
  list` shows an active account (the build machine's credential) but every actual
  API call (`gcloud storage buckets list`, `gcloud auth print-access-token`)
  fails with "Reauthentication failed: cannot prompt during non-interactive
  execution," and there is no application-default credential either. Same
  blocker every prior round hit; not something this fix can work around.
  Because of that, no real GCS bucket, Pub/Sub topic, or IAM binding was
  created or deleted this round, and there is no "zero residue" claim to
  make about real GCP resources, because none were touched.
- In place of real GCP, ran the actual `teardown.sh` script (not a
  reimplementation) against a minimal mock `gcloud` on `PATH`
  (`/private/tmp/.../gcp-fix-mockbin/gcloud`, not committed to the repo,
  deleted after the test run) that answers only the exact subcommands
  `teardown.sh` calls. Every test used a fresh, timestamped, obviously-fake
  `sync-id` / `bucket` / `project` (`qafix-{bucket,project}-<UTC
  timestamp>`, `sync_qafix_<UTC timestamp>`) so runs never collide with each
  other or with anything real. Four scenarios, each run as the literal
  script with `PATH` pointed at the mock first:
  1. `--dry-run` where the notification-list call fails with a realistic
     permission-denied-style message (`HTTPError 403: caller does not have
     storage.buckets.get access to the bucket`) -- the exact scenario in
     this round's bug report. Before the fix this exited 0 with "Done,
     removed"; after the fix it logs the `FAILED` line, prints "Dry run
     found errors. Nothing was deleted, but see FAILED lines above," and
     exits 1. Verified by checking `$?` after the run, not by reading the
     log.
  2. `--dry-run` where the notification-list call succeeds (no failures at
     all) -- confirms the round-4 behavior is unchanged: prints "Dry run
     only. Nothing was deleted and no teardown notice was sent," exits 0.
  3. Full run (no `--dry-run`), everything `NOT_FOUND` -- regression check,
     confirms non-dry-run success path still exits 0 with "Done ...
     removed."
  4. Full run (no `--dry-run`), a real `PERMISSION_DENIED` on the Pub/Sub
     topic delete -- regression check, confirms non-dry-run failure path
     still exits 1 with "Done with errors."
  All four matched their expected exit code and message; raw output for
  scenario 1 (the reported bug, this round's actual fix target):

  ```
  [captain-teardown 17:04:08Z] ==== Bucket notification ====
  [captain-teardown 17:04:09Z]   FAILED (exit 1) listing notifications on gs://qafix-bucket-20260813T170408Z: ERROR: (gcloud.storage.buckets.notifications.list) HTTPError 403: caller does not have storage.buckets.get access to the bucket.
  [captain-teardown 17:04:09Z] no Captain notification for captain-gcs-sync-sync_qafix_20260813T170408Z on the bucket; skipping
  ...
  [captain-teardown 17:04:09Z] ==== Dry run found errors. Nothing was deleted, but see FAILED lines above -- a real run would likely hit the same failures. ====
  EXIT CODE: 1
  ```
- What a real tester with working `gcloud auth login` and a throwaway
  project/bucket should still do, unchanged from round 4's ask plus this
  round's specific case: run `teardown.sh --dry-run` against a bucket the
  caller genuinely lacks `storage.buckets.get` on (not a mock) and confirm
  the real `gcloud` error text still gets classified correctly by
  `already_gone()` and still exits 1; then run a real create/destroy cycle
  and confirm with `gcloud storage buckets notifications list`, `gcloud
  pubsub subscriptions list`, `gcloud pubsub topics list`, and `gcloud iam
  service-accounts list` (not just trusting the script's own "removed"
  message) that nothing is left behind.

## Fix round 4 (final pre-launch QA sweep, gcp only)

Two reviewers ran this round. One passed the round-3 fixes on live-mocked
tests (dry-run banner, teardown failure tracking, enroll.sh "000" fix,
terraform/.gitignore) and flagged two secondary issues. The other did a
static-only pass and failed the round on a real bug the first reviewer's
tests did not happen to exercise: `teardown.sh --dry-run` still printed
"removed" even though nothing was deleted, the same "--dry-run lies" class
of bug round 3 fixed in `setup.sh`'s banner but left standing here.

Four real issues fixed, all in `gcloud/setup.sh` and `gcloud/teardown.sh`
(`terraform/enroll.sh` and `terraform/.gitignore`'s core content needed no
further change beyond item 4 below):

1. **`teardown.sh --dry-run` claimed resources were removed.** Every `run()`
   call under `--dry-run` short-circuits before touching anything, so
   `TEARDOWN_HAD_FAILURE` never gets set, and the final banner
   (unconditional, no `DRY_RUN` check) always printed "Done. Captain GCS
   sync resources for $SYNC_ID removed." even on a dry run. Fixed by adding
   a `DRY_RUN` branch to the final banner, same as `setup.sh` already does:
   "Dry run only. Nothing was deleted and no teardown notice was sent."
   exit 0. Live-tested: dry run now prints the honest message and exits 0.

2. **The already-gone classifier was case-sensitive, so it could misfile a
   real failure as tolerated (low-severity, but a real gap).** `run()`'s
   `case "$out" in *NOT_FOUND*|*"not found"*|...)` only matched the exact
   casing gRPC-status-style errors (Pub/Sub, IAM) use. The GCS JSON API
   backing `storage buckets notifications delete` reports failures in a
   different style ("HTTPError 404: Not Found"), which the old pattern's
   *casing* did not reliably cover. Fixed by lowercasing the output before
   matching (`already_gone()` helper, shared by `run()` and the new
   notification-list check below), so "HTTPError 404: Not Found" is now
   correctly tolerated while still rejecting non-not-found errors.
   Live-tested with exactly that string: correctly logged
   "(already gone, ok)" instead of "FAILED".

3. **The bucket-notification lookup swallowed every error, not just "not
   found," in both `teardown.sh` and `setup.sh`.** Both scripts ran
   `gcloud storage buckets notifications list ... 2>/dev/null | jq ... ||
   true`, so a real failure (permission denied, wrong bucket, transient API
   error) silently defaulted to "no notification found" -- in `teardown.sh`
   that meant skipping the delete with no failure recorded (entirely outside
   `TEARDOWN_HAD_FAILURE`); in `setup.sh` it meant proceeding to CREATE a
   notification as if none existed, risking a duplicate or masking a
   permissions problem until the phone-home much later. Fixed in both: the
   list call's own exit status is now checked. In `teardown.sh`, a real
   failure logs `FAILED` and sets `TEARDOWN_HAD_FAILURE=1` (a
   bucket-not-found-style failure is still tolerated via `already_gone()`).
   In `setup.sh`, a real failure calls `die` immediately rather than
   silently falling through to a possibly-duplicate create. Both were caught
   and fixed only because live-testing this fix immediately surfaced a
   second bug: assigning a failing command substitution directly
   (`VAR="$(cmd)"; STATUS=$?`) trips `set -e` on the assignment itself
   before `$?` is ever read, killing the script instead of reaching the new
   error handling. Fixed with the `... && STATUS=0 || STATUS=$?` idiom
   (same shape `run()` already uses for the same reason). Live-tested three
   ways: (a) list fails with a permission-style error -- `teardown.sh` now
   logs FAILED and exits 1, continuing through the remaining steps rather
   than dying silently; `setup.sh` now dies immediately with a clear
   message instead of creating a stray notification; (b) list succeeds with
   an empty result -- both scripts behave exactly as before (no regression);
   (c) full happy-path dry run end to end in `setup.sh` still completes and
   prints a deploymentId, confirming the control-flow fix didn't break the
   round-3 mocked full-run test.
4. **`terraform/.gitignore` ignored `.terraform.lock.hcl`, unlike the
   sibling `aws/terraform/` and `b2/terraform/` gitignores.** Standard
   Terraform practice is to commit the lock file (it pins provider
   versions; it is not a secret or local state), and the patch's own
   description claimed to match sibling convention. Fixed by removing that
   line and adding a comment explaining why it's intentionally absent.
   Re-checked with `git check-ignore -v`: `.terraform/`, `terraform.tfstate`,
   and a synthetic `foo.tfvars` are still ignored; `terraform.tfvars.example`
   still survives the negation; `.terraform.lock.hcl` (the real file already
   on disk from `terraform init`) is now correctly NOT ignored.

Not changed: the `die_api` / `exit 2` item in one round's task description
does not apply here -- `die_api` only exists in `b2/setup/`, not anywhere
under `gcp/`. Confirmed by grepping the whole repo again this round.

## Validation status (round 4)

- `bash -n` on all three shell scripts : PASS.
- `shellcheck` on `gcloud/setup.sh`, `gcloud/teardown.sh`,
  `terraform/enroll.sh` : PASS, clean, no new nits.
- `terraform fmt -check -diff` : PASS (clean).
- `terraform validate` : PASS, "The configuration is valid."
- `git check-ignore -v` against `.terraform/`, `terraform.tfstate`,
  `foo.tfvars`, `terraform.tfvars.example`, `.terraform.lock.hcl` : all four
  gitignore behaviors correct, including the new `.terraform.lock.hcl`
  un-ignore.
- Live-tested `gcloud/teardown.sh` against a mock `gcloud`/`jq` on `PATH`
  (no real GCP resources touched, mock deleted after):
  - `--dry-run`: prints the new honest "nothing was deleted" banner, exit 0
    (previously printed "removed", the round-4 bug this round fixes).
  - Mixed run: notification delete returns GCS-JSON-style
    "HTTPError 404: Not Found" (tolerated via the new case-insensitive
    match), subscription/SA/binding deletes return gRPC-style `NOT_FOUND`
    (tolerated), topic delete returns `PERMISSION_DENIED` (FAILED, correctly
    not swallowed) -> exit 1 with "Done with errors," matching round 3's
    already-passing failure-tracking behavior plus the new casing fix.
  - Notification-list call itself fails (403-style error): now logged as
    FAILED and counted toward `TEARDOWN_HAD_FAILURE` instead of silently
    treated as "no notification, skipping" -- exit 1, script did not die
    partway through (confirms the `set -e`-under-assignment self-inflicted
    bug from writing this fix is actually fixed).
  - All-`NOT_FOUND` run: clean exit 0, "Done. ... removed." (no regression
    from round 3).
- Live-tested `gcloud/setup.sh` against the same style of mock, extending
  round 3's full mocked dry-run (auth list, project describe, service-agent
  lookup, all describe/list-before-create idempotency checks):
  - Notification-list call fails (403-style error): `setup.sh` now dies
    immediately with "could not list notifications on gs://..." instead of
    silently treating the failure as "no existing notification" and
    proceeding to create one. Exit 1, correct message, no stray mutating
    calls logged after the die.
  - Notification-list call succeeds with an empty result: full mocked
    `--dry-run` run still completes start to finish and prints a
    deploymentId, exactly as round 3 verified (no regression from this
    round's fix).
- Did NOT re-verify live against a real GCP project this round either --
  same auth block as every prior round (see "LIVE provisioning is BLOCKED"
  below, unchanged). Everything above is the mocked-gcloud level of rigor
  round 3 established, extended to the four fixes this round made. A real
  tester with working `gcloud auth login` and a throwaway project/bucket
  should still do the two things no mock can prove (see that section) plus,
  newly: run `teardown.sh --dry-run` for real and confirm nothing was
  deleted despite the (now-honest) success message, and run teardown against
  a bucket the caller does NOT have `storage.buckets.get` on and confirm it
  reports FAILED instead of silently skipping the notification step.

## Fix round 3 (adversarial test findings, gcp only)

Two more confirmed bugs in `gcloud/setup.sh`, both found by actually running the
script, neither catchable by `bash -n`, `shellcheck`, or `terraform validate`:

1. **`setup.sh` had its own separate random-id generator that crashed the
   script on every single invocation, including `--dry-run`.** Round 2 fixed
   this exact SIGPIPE bug in `terraform/enroll.sh` and in the B2 template's
   generators, but `setup.sh` (line ~117) had its OWN copy of the same
   `tr -dc ... | head -c` pipeline, never touched by that fix. Under this
   script's own `set -euo pipefail`, `head -c` closes its end of the pipe once
   it has read enough bytes, `tr` gets SIGPIPE on its next write, and the
   pipeline's exit status becomes 141 even though `head` itself exited 0
   (pipefail reports the rightmost non-zero exit in the pipe). That 141 trips
   `set -e` and kills the whole script building `DEPLOYMENT_ID`, before it
   ever reaches "Enabling required APIs", meaning the entire README gcloud
   one-click path was non-functional as shipped. Grepped the entire `gcp/`
   tree for every `tr`/`head -c`/`urandom` occurrence after the fix; this was
   the only one. Fixed the same way as the other two generators: wrap the
   pipeline so a benign SIGPIPE cannot abort the script:
   `rand() { { LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c "$1"; } || true; }`.
2. **`setup.sh`'s notification-existence check used the same unanchored
   substring match teardown.sh was fixed for in round 2, and was never given
   the same fix.** Line ~191 did
   `gcloud storage buckets notifications list ... | grep -F "$TOPIC" || true`.
   A bucket with an existing notification for a topic that is a PREFIX of the
   new sync's topic name (e.g. an existing `captain-gcs-sync-sync_abcxyz`
   notification against a new sync's `captain-gcs-sync-sync_abc`) false-matched,
   so `setup.sh` logged "already exists, reusing" and SKIPPED creating the
   notification for the new sync while still reporting a fully successful,
   verified deploy. That sync would silently never receive bucket events.
   Fixed by switching to the exact same `--format=json` + `jq` pattern with an
   `endswith("/topics/${TOPIC}")` match already implemented correctly in
   `teardown.sh`, instead of a grep substring scan of the default text output.

Read the diff in `gcloud/setup.sh`, not just this summary.

## Fix round 2 (adversarial test findings)

A prior round shipped four confirmed bugs, all fixed. Read the diffs, not just
this summary, before trusting the new behavior:

1. **teardown.sh orphaned the bucket notification.** It grepped the DEFAULT
   YAML output of `gcloud storage buckets notifications list` for the topic
   name, then tried to pull the notification id off the SAME line. Real YAML
   output puts `topic` and `id` on separate lines nested under
   `Notification Configuration`, so the id extraction silently returned
   nothing, the delete call was skipped, and the notification was left on
   the customer's bucket after its topic was deleted. Fixed by parsing
   `--format=json` with `jq`, matching on the actual nested `topic` field
   and reading `id` from the same object, not the same line. Verified against
   the real output shape read from the installed gcloud SDK source
   (`googlecloudsdk/.../buckets/notifications/list.py`), not an assumed
   inline format.
2. **setup.sh was not actually idempotent.** It picked a fresh random suffix
   for the push service account on every run, so a re-run created a brand
   new SA and orphaned the previous one; teardown.sh only ever knew about the
   last one it was told about. Fixed by deriving the SA id deterministically
   from `sync_id` (`cap-push-<sha256(sync_id)[:16]>`, well under the 30-char
   GCP service-account-id limit). Re-runs of `setup.sh` now reuse the same
   SA, matching how the Terraform path already persists it in state.
   teardown.sh derives the same id when `--push-sa` is omitted, so it can
   clean up the SA `setup.sh` created without being told its name.
3. **external_id went into the push endpoint URL unencoded**, validated only
   for length. Fixed two ways: a charset validation
   (`^[A-Za-z0-9._~-]+$`, RFC 3986 unreserved characters) in both
   `variables.tf` and `setup.sh`, and `urlencode()` on both `sync_id` and
   `external_id` when building `push_endpoint` (Terraform's built-in
   `urlencode()`; a small POSIX-shell equivalent in `setup.sh`). Either one
   alone stops the injection; both are in place.
4. **teardown.sh's delete-notice was unauthenticated**, sending a placeholder
   string instead of the real `enrollment_secret`, while `terraform destroy`
   sends the real secret from state. Fixed by adding a required `--secret`
   flag to `teardown.sh`. When it's supplied, the delete notice authenticates
   the same way the Terraform destroy path does. When it's omitted, the
   script skips the notice entirely (logged) rather than send a fake secret
   Captain would have to either reject or, worse, accept.

## Validation status (round 3)

- `bash -n` on all three shell scripts : PASS.
- `shellcheck` on `gcloud/setup.sh`, `gcloud/teardown.sh`, `terraform/enroll.sh` :
  PASS, clean, no new nits from either fix.
- `terraform fmt -check` and `terraform validate` : PASS (untouched this round;
  re-run anyway since the instructions asked for every validator, not just the
  ones for files touched).
- **Live-reproduced the SIGPIPE crash before fixing it**: ran the exact
  original `rand()` body under `set -euo pipefail` in isolation, got exit 141
  every time, confirming the bug is real and not a static-analysis false
  positive. After the fix, ran the fixed `rand()` 20 times in a row: 20/20
  produced a well-formed 24-char id, exit 0.
- **Ran the real, fixed `setup.sh --dry-run` end to end**, not just `rand()`
  in isolation. The build machine has no active `gcloud` credential (same
  auth block as every prior round, see below), so a bare `--dry-run` cannot
  get past the existing "no active gcloud credential" preflight check on this
  machine. To still exercise the real script's full control flow safely, put
  a mock `gcloud` binary first on `PATH` that answers the handful of
  existence-check calls `setup.sh` makes even under `--dry-run` (auth list,
  project describe, service-agent lookup, and the three
  describe/list-before-create idempotency checks) and fails loudly on any
  call it does not recognize, so a missing mock case cannot silently pass.
  Every mutating `gcloud` call stayed correctly gated behind `--dry-run` (only
  logged, never executed). Result: the real `setup.sh` ran start to finish,
  printed a deploymentId, and exited 0 -- something it could not do before
  this round's fix on ANY invocation.
- **Built the exact prefix-collision fixture the tester used** inside that
  same mock: an existing bucket notification for topic
  `captain-gcs-sync-sync_abcxyz` against a new sync targeting
  `captain-gcs-sync-sync_abc`. With the fixed `jq` + `endswith` check, the
  script correctly took the CREATE branch (did not false-match), logging
  `gcloud storage buckets notifications create ...` instead of "already
  exists, reusing." Also re-ran with the fixture's topic changed to an EXACT
  match: the script correctly logged "already exists, reusing" and did not
  attempt to create a duplicate. Both directions verified in the same run of
  the real script code, not a re-implementation of the check.
- No GCP resources were created or modified. The mock is local-only, invoked
  through `PATH`, and deleted after the test run.

## Validation status (round 2)

- `terraform fmt -check` : PASS (clean).
- `terraform validate` (google v6.50.0, random v3.9.0) : PASS, "The configuration
  is valid."
- `bash -n` on all three shell scripts : PASS.
- `shellcheck` on `gcloud/setup.sh`, `gcloud/teardown.sh`, `terraform/enroll.sh` :
  PASS, clean (one pre-existing SC2015 info-level nit in teardown.sh was fixed
  along the way).
- `terraform plan` with a deliberately bad `external_id` (spaces, `?`, `&`) :
  rejected at the variable-validation stage, before the provider is even
  reached, confirming the charset check actually runs. A valid `external_id`
  passes validation and stops only at the (expected) missing-credentials error.
- `terraform console` exercised `urlencode()` directly against a value with
  spaces and `&`/`=` and produced correctly percent-encoded output.
- The fixed `teardown.sh` notification-id `jq` extraction was tested against a
  JSON fixture built to match the real `gcloud storage buckets notifications
  list --format=json` schema (nested `Notification Configuration.topic` /
  `.id`, sourced from the installed SDK's own command source, not guessed):
  correctly extracts the id when the topic matches, correctly extracts
  nothing when it doesn't.
- Phone-home self-verification (`terraform/enroll.sh`) exercised against a local
  mock enroll endpoint over HTTPS:
    - verified:true  -> exit 0 (apply succeeds)
    - verified:false -> exit 1 with a human-readable reason (apply fails/rolls back)
    - http 4xx       -> exit 1 with the endpoint's error surfaced
    - delete action  -> exit 0 always (never blocks teardown)
- NOT deployed. No GCP resources were created. See the auth block below.

## LIVE provisioning is BLOCKED (auth) -- re-confirmed round 3

Still blocked, on this build machine too, for a different reason than round 2
reported: `gcloud auth list` here shows the build machine's account credentialed but
with no ACTIVE account set at all, so `setup.sh`'s own preflight
("no active gcloud credential. Run: gcloud auth login") stops any real
`--dry-run` before it reaches the code this round's fixes touch. That is
exactly why round 3's live verification used a mock `gcloud` on `PATH`
instead (see "Validation status (round 3)" above): it is the only way to
prove the real script's control flow reaches completion without either a
working `gcloud auth login` or a real bucket, neither available here. A real
tester with working auth and a throwaway bucket should still do the two
things a mock cannot prove: run `setup.sh --dry-run` bare (no mock) start to
finish, and run it for real against a bucket that already has one other
notification whose topic name happens to prefix-collide with the new sync's
topic, confirming the new notification actually gets created alongside the
old one.

Round 2's finding, for continuity:

```
$ gcloud pubsub topics list --project=<internal-project>
ERROR: ... does not have permission ... permission: pubsub.topics.list

$ gcloud storage buckets list --project=<internal-project>
ERROR: 403 ... Permission 'storage.buckets.list' denied
```

The only credentialed account on this build machine lacks
even LIST on Pub/Sub and Storage here, let alone `pubsub.topics.create` /
`storage.buckets.create`. So none of the four fixes above could be exercised
against a real bucket this round either; each was verified statically (schema
review against the installed gcloud SDK's own source, a JSON fixture matching
that schema, `terraform console`, and `terraform plan`'s variable-validation
pass) rather than end to end.

Precisely what is blocked and what is not:
- Blocked: `terraform apply`, `gcloud/setup.sh`, `gcloud/teardown.sh` against a
  real bucket (all three call create/delete on Pub/Sub or bind/list IAM on a
  bucket), and even a bare `gcloud/setup.sh --dry-run` with no mock (stops at
  the "no active gcloud credential" preflight check). A real tester needs a
  principal with the roles listed in `README.md` on a project they own, plus
  an existing bucket. That tester should specifically: re-run `setup.sh`
  twice in a row and confirm the second run reuses the same push SA (round 2
  fix #2), run `teardown.sh` and confirm the bucket notification is actually
  gone afterward (round 2 fix #1), confirm `setup.sh --dry-run` completes
  with no `gcloud` credential beyond being logged in (round 3 fix #1), and
  confirm a new sync's notification gets created (not skipped) on a bucket
  that already has an unrelated notification whose topic name prefix-collides
  with the new one (round 3 fix #2) -- none of these four is provable from
  this machine.
- Not blocked (already done here): `terraform init/validate/fmt`,
  `terraform console`, `bash -n`, `shellcheck`, the offline phone-home
  test against a mock endpoint, the isolated live reproduction and fix of the
  `rand()` SIGPIPE crash, and the mocked-`gcloud` full run of the real
  `setup.sh` control flow (round 3).

## Captain backend dependencies (do not exist yet)

The phone-home expects a specific contract. These receivers must be built before
a real customer run can verify end to end:

1. **Enroll receiver.** An HTTPS endpoint (placeholder
   `https://api.runcaptain.com/v1/deploy/gcp/gcs/enroll`, must be confirmed) that
   accepts the POST body:
   `{deploymentId, templateVersion, action, provider, storage, syncId, externalId,
   projectId, bucket, pubsubTopic, pubsubSubscription, pushServiceAccount,
   readerServiceAccount, ingestUrl, oidcAudience, secret}`.
   It must authenticate `secret` against `syncId`, perform enrollment, and return
   `2xx` with `{"verified": true, "status": "..."}`. Anything else fails the run.

2. **The verification handshake.** On enroll, Captain must actually:
   - LIST/GET on `bucket` as `readerServiceAccount` (its own identity) to prove the
     objectViewer grant propagated, and
   - confirm it can receive the push: allowlist `pushServiceAccount` as an accepted
     OIDC subject on `ingestUrl` for `oidcAudience`, and ideally observe a real
     delivery on `pubsubSubscription`.
   Only if both pass should it return `verified: true`.

3. **Ingest endpoint (Pub/Sub push receiver).** `ingestUrl` must:
   - verify the Google-signed OIDC bearer token (audience == `oidcAudience`, issuer
     accounts.google.com, subject == the enrolled `pushServiceAccount`),
   - map the delivery to a sync via the `sync_id` / `external_id` query params (and
     the allowlisted subject), and
   - return 2xx quickly so Pub/Sub does not redeliver. Non-2xx triggers Pub/Sub's
     retry/backoff, which is fine but noisy.

4. **Deployment-state object / endpoint.** Per-deployment state keyed by the
   `dep_<token>` id (subscription seen? read probe passed? last handshake result?),
   for the README's debugging pointer. Does not exist yet.

5. **Delete / teardown handling.** On destroy the phone-home POSTs
   `{action: "delete", ...}`. Captain should mark the deployment torn down and, since
   client-side teardown is best-effort, reconcile orphaned subscriptions/bindings.

The existing GCS index path (`captain_index_gcs`) is the read side; the enroll
receiver, the OIDC push verifier, and the deployment-state object are the new
pieces this template assumes.

## Design choices worth knowing

- **Cross-account read = Captain's own SA, not a customer key.** The GCP analog of
  the S3 assume-role. The customer only IAM-binds `captain_reader_service_account`
  (objectViewer, one bucket). Captain authenticates as itself from its own project,
  so no key material ever leaves the customer account. The confused-deputy guard
  that ExternalId provides on AWS is carried by `external_id` on the push endpoint
  and in the enroll payload; Captain must bind it to the sync.
- **Push auth is OIDC, not a shared secret in the URL.** Pub/Sub mints a Google-
  signed token as a dedicated push SA in the customer project; Captain verifies it.
  The one-time `enrollment_secret` is only for the enroll handshake, never for
  per-event auth.
- **Additive notification.** GCS buckets allow multiple notification configs, so
  this does not have the S3 single-slot clobber problem. Teardown removes only ours.
- **Fresh-project race.** The Pub/Sub service agent must exist before the
  token-creator binding. `setup.sh` force-creates it (`gcloud beta services identity
  create`); on a brand-new project a Terraform user may need one re-apply if the
  agent was not yet materialized. Documented in the README.
- **No em dashes, date-based versions (`2026-08-12`), Stripe-style ids (`dep_`,
  `sync_`), no bare UUIDs.** Matches the AWS conventions.

## Publish-time TODO (moved from README)

The README's Open in Cloud Shell button uses `cloudshell_git_repo` pointing at
`https://github.com/runcaptain/captain-sync-templates`, and the example
`--reader-sa` value `captain-reader@captain-prod.iam.gserviceaccount.com`.
Both are PLACEHOLDERS: publish this repo to that public location and confirm
Captain's real reader service account before handing customers the link.
Version any hosted copy under a DATE-based path
(`.../templates/2026-08-12/gcp/...`), matching the AWS convention. The README
now carries a customer-phrased "link not yet active" note; remove it once the
repo is published and the reader SA is confirmed.
