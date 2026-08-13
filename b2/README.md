# Captain deploy: Backblaze B2

One command stands up everything Captain needs to keep a Backblaze B2 bucket
synced, entirely inside YOUR OWN Backblaze account: a scoped read-only
application key Captain uses to list and fetch objects (the always-on reconcile
backstop), a native B2 Event Notification rule that webhooks changes to Captain
(the latency optimization), and a self-verifying phone-home so a clean run means
a confirmed, working sync.

Backblaze has no CloudFormation and no console one-click, so the "launch button"
here is a single copy-paste command. Two equivalents ship:

- `setup/captain-b2-sync.sh` (recommended): a self-verifying setup script.
- `terraform/`: an IaC module for teams that manage cloud wiring with Terraform.

## Launch (the one-command equivalent)

Captain generates this whole command per-sync and pre-fills the parameters, so
you paste and run. Manually, it is:

```bash
curl -fsSL https://captain-templates.s3.amazonaws.com/templates/2026-08-13/captain-b2-sync.sh -o captain-b2-sync.sh
chmod +x captain-b2-sync.sh

export B2_APPLICATION_KEY_ID=...        # an operator key (see permissions below)
export B2_APPLICATION_KEY=...
export CAPTAIN_ENROLL_SECRET=...        # the one-time secret Captain minted for this sync

./captain-b2-sync.sh provision \
  --sync-id   sync_YOURSYNC \
  --bucket    your-existing-b2-bucket
```

Secrets go through environment variables, not `--secret` / `--b2-app-key` flags.
An argv flag is visible to other local users on the same machine via `ps` or
`/proc`, and it lands in your shell history. `--secret` still works (it reads
`CAPTAIN_ENROLL_SECRET` as its default), it is just not the recommended path.

Prefer to read before you run? Clone this repo and run
`setup/captain-b2-sync.sh` directly, it is the same file. One
thing to know today: Captain's enrollment endpoint is not yet live, so
a run currently completes the setup steps, fails at the final verification
with a clear message, and rolls back. Contact Captain for activation status
for your sync.

Pass `--debug` (or `CAPTAIN_DEBUG=1`) for a full trace, and `--dry-run` to
preflight without creating anything.

Prefer not to pipe a script from the internet? `terraform/` does the same thing;
see "Terraform" below.

## What it creates

1. **Scoped read key** (`captain-b2-read-<sync>`): read-only, restricted to the
   one bucket, capabilities `listBuckets,listFiles,readFiles,readBucketNotifications`.
   This is the cross-account grant. B2 has no assume-role, so a scoped key is the
   safe equivalent; the master key is NEVER sent to Captain. Add `--key-duration
   <seconds>` to give it an expiry for rotation. If you set an expiry, re-run
   provision before the key lapses: the sync stops reading once the key expires,
   and automatic rotation is not in place yet.
2. **Event Notification rule** (`captain-sync-<sync>`): webhooks
   `b2:ObjectCreated:*` and `b2:ObjectDeleted:*` to Captain's ingest endpoint,
   signed with a per-deployment HMAC secret. See the account-gating note below.
3. **A verified enrollment**: the script phones home to Captain, which proves it
   can read the bucket (and, when enabled, that the webhook is wired) before the
   script reports success.

## Heads up: B2 Event Notifications are account-gated

Backblaze enables Event Notifications per account, by support ticket. If your
account is not enabled, the EVENT path is BLOCKED. The script handles this
gracefully:

- `--event-path auto` (default): tries to set the rule; if the account is not
  enabled, it prints a clear warning, continues, and the reconcile backstop
  still runs. Your sync works, just not near-real-time yet.
- `--event-path force`: fail hard if the rule cannot be set (use once your
  account is enabled).
- `--event-path skip`: reconcile-only, never touch notification rules.

Open a Backblaze support ticket to enable Event Notifications, then re-run with
`--event-path force`.

## Permissions the operator key needs

The `B2_APPLICATION_KEY_ID` / `B2_APPLICATION_KEY` you run setup with is used
ONLY during setup and is never sent to Captain. It needs these B2 capabilities:

- `writeKeys` (mint the scoped read key), `deleteKeys` (teardown).
- `listBuckets` (resolve the bucket name to its id).
- `readBucketNotifications` + `writeBucketNotifications` (read-merge-write the
  notification rule). Only needed if the event path is not skipped.
- `listKeys` (teardown, to find the key by name).

A bucket-scoped admin key is enough and is safer than the master key. The master
key works but is broader than necessary. The scoped key this script MINTS for
Captain is separate and always read-only.

## How the deploy verifies itself

Ordinary "run and hope" setup leaves you with a green terminal and a sync that
silently never works. This closes the loop:

1. Authorize with B2, discover the region and S3 endpoint, resolve the bucket.
2. Mint the scoped read key.
3. Set the notification rule (additive: existing rules on the bucket are
   preserved by name; only our named rule is added). If your bucket already
   carries notification rules, list them after setup and verify they survived.
4. POST the enrollment facts to Captain, including the scoped key and the S3
   endpoint. Captain uses the key to `ListObjectsV2` + `GetObject`-probe the
   bucket, and returns `{"verified": true}` only if that succeeds.
5. On a verified response the script prints a machine-readable success summary.
   On anything else it ROLLS BACK (deletes the key and removes the rule it just
   added) and exits non-zero with a human-readable reason. Pass `--no-rollback`
   to leave the resources in place for inspection.

So a successful run means Captain has confirmed, end to end, that it can read
your objects.

## Debugging a failed run

- Re-run with `--debug` (or `CAPTAIN_DEBUG=1`) for a full HTTP trace. Secrets are
  redacted in every log line.
- Read the last `[ERROR]` line: it names the exact failure, for example
  `Bucket 'x' not found ...`, `b2_create_key failed (HTTP 401) ... needs 'writeKeys'`,
  or `Captain did not confirm enrollment (HTTP 403, verified=false)`.
- Exit codes: `1` usage/preflight, `2` a B2 API error, `3` Captain verify failed
  (rolled back unless `--no-rollback`).
- Event path blocked? That is a WARN, not a failure. The run still succeeds via
  the reconcile backstop (see "Heads up" above).
- Captain side: look up the deployment by the `deploymentId` (`dep_<token>`) the
  summary prints. Captain's per-deployment status view (read-probe result, and
  later webhook health) is not yet available; until it is, contact Captain
  support with the `deploymentId`.
- Common causes: wrong `--secret` or `--sync-id`, an operator key missing
  `writeKeys`, a bucket-restricted operator key pointed at the wrong bucket, or
  Captain's enroll endpoint being unreachable.

## Teardown

```bash
export CAPTAIN_ENROLL_SECRET=...   # optional; enables the Captain teardown notice

./captain-b2-sync.sh teardown \
  --sync-id sync_YOURSYNC \
  --bucket  your-existing-b2-bucket
```

Removes our notification rule (siblings preserved), deletes the scoped read
key(s) named for the sync, and sends Captain a best-effort teardown notice.

## Terraform

Same three things as IaC. Operator creds come from the environment so they stay
out of state.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # then fill it in
export B2_APPLICATION_KEY_ID=...
export B2_APPLICATION_KEY=...
terraform init
terraform apply
```

Notes specific to the module:

- `event_path` defaults to `"skip"` (Event Notifications are account-gated).
  Set it to `"enabled"` once Backblaze has enabled the feature on your account.
- The `b2_bucket_notification_rules` resource owns the FULL rule set for the
  bucket. If the bucket already carries other rules you want to keep, use the
  setup script (which merges) or `terraform import` them first.
- On a failed verify Terraform leaves the key/rule in state (it does not
  auto-destroy). Fix the cause and re-apply, or `terraform destroy`. The setup
  script rolls back automatically; that is the one behavioral difference.

Outputs: `deployment_id`, `read_key_id`, `s3_endpoint`, `region`, `event_path`,
`notification_rule_name`, `what_to_do_next`.

## Files

```
b2/
  README.md                     this file
  setup/
    captain-b2-sync.sh          the setup script (provision + teardown)
  terraform/
    versions.tf                 terraform + provider requirements, provider auth
    variables.tf                inputs with validation
    main.tf                     scoped key + notification rule + phone-home
    outputs.tf                  deployment id, S3 endpoint, next step
    phone_home.sh               self-verifying phone-home the module invokes
    terraform.tfvars.example    fill-in example
```
