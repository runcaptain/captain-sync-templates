# Captain deploy: Backblaze B2

One command stands up everything Captain needs to keep a Backblaze B2 bucket
synced, entirely inside YOUR OWN Backblaze account: an enrollment call to
Captain's API that mints the per-sync subscribe URL, a native B2 Event
Notification rule that webhooks changes to that URL (the latency optimization),
and a scoped read-only application key for the always-on reconcile backstop. A
clean run means Captain answered the enrollment itself, not a hopeful green
terminal.

Backblaze has no CloudFormation and no console one-click, so the "launch button"
here is a single copy-paste command. Two equivalents ship:

- `setup/captain-b2-sync.sh` (recommended): a self-verifying setup script.
- `terraform/`: an IaC module for teams that manage cloud wiring with Terraform.

You need three things from Captain before you run either: your sync id
(`sync_<token>`), a Captain API key, and a sync that already exists. Creating
the sync is covered in https://docs.captain.dev/guides/sync/set-up.

## Launch (the one-command equivalent)

Captain generates this whole command per-sync and pre-fills the parameters, so
you paste and run. Manually, it is:

```bash
curl -fsSL https://captain-templates.s3.amazonaws.com/templates/2026-08-13/captain-b2-sync.sh -o captain-b2-sync.sh
chmod +x captain-b2-sync.sh

export B2_APPLICATION_KEY_ID=...        # an operator key (see permissions below)
export B2_APPLICATION_KEY=...
export CAPTAIN_API_KEY=...              # your Captain API key

./captain-b2-sync.sh provision \
  --sync-id   sync_YOURSYNC \
  --bucket    your-existing-b2-bucket
```

Secrets go through environment variables, not `--api-key` / `--b2-app-key`
flags. An argv flag is visible to other local users on the same machine via
`ps` or `/proc`, and it lands in your shell history. `--api-key` still works
(it reads `CAPTAIN_API_KEY` as its default), it is just not the recommended
path.

Prefer to read before you run? Clone this repo and run
`setup/captain-b2-sync.sh` directly, it is the same file.

Pass `--debug` (or `CAPTAIN_DEBUG=1`) for a full trace, and `--dry-run` to
preflight without creating anything.

Prefer not to pipe a script from the internet? `terraform/` does the same thing;
see "Terraform" below.

## What it creates

1. **A webhook enrollment with Captain**: the script POSTs to
   `https://api.captain.dev/v2/syncs/<sync-id>/webhooks` with your API key
   (Bearer header, empty JSON body). Captain answers with the per-sync
   `subscribe_url` it minted; that 2xx response IS the confirmed enrollment.
2. **Event Notification rule** (`captain-sync-<sync>`): webhooks
   `b2:ObjectCreated:*` and `b2:ObjectDeleted:*` to the minted subscribe URL,
   signed with a per-deployment HMAC secret on the B2 side. See the
   account-gating note below.
3. **Scoped read key** (`captain-b2-read-<sync>`): read-only, restricted to the
   one bucket, capabilities `listBuckets,listFiles,readFiles,readBucketNotifications`.
   This is the cross-account grant for the reconcile backstop. B2 has no
   assume-role, so a scoped key is the safe equivalent; your master key never
   leaves your machine. The key id and secret are printed ONCE in the success
   summary so you can set them as the sync's Backblaze credentials in Captain
   (https://docs.captain.dev/guides/sync/set-up). Add `--key-duration <seconds>`
   to give the key an expiry for rotation. If you set an expiry, re-run
   provision before the key lapses: the sync stops reading once the key
   expires, and automatic rotation is not in place yet.

## Heads up: B2 Event Notifications are account-gated

Backblaze enables Event Notifications per account, by support ticket. If your
account is not enabled, the EVENT path is BLOCKED. The script handles this
gracefully:

- `--event-path auto` (default): tries to set the rule; if the account is not
  enabled, it prints a clear warning, continues, and the reconcile backstop
  still runs. Your sync works, just not near-real-time yet.
- `--event-path force`: fail hard if the rule cannot be set (use once your
  account is enabled).
- `--event-path skip`: reconcile-only, never touch notification rules. The
  enrollment still runs, so the subscribe URL is minted and ready for when you
  enable events.

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

## How the run verifies itself

Ordinary "run and hope" setup leaves you with a green terminal and a sync that
silently never works. This closes the loop:

1. Authorize with B2, discover the region and S3 endpoint, resolve the bucket.
2. Mint the scoped read key.
3. Enroll with Captain: `POST https://api.captain.dev/v2/syncs/<sync-id>/webhooks`
   with `Authorization: Bearer <your API key>` and an empty JSON body. Captain
   returns the minted `subscribe_url` (plus `secret_set` and `instructions`).
   A 2xx with a `subscribe_url` is the confirmation; anything else makes the
   script ROLL BACK the key it just minted and exit non-zero with a
   human-readable reason. Pass `--no-rollback` to leave it in place for
   inspection.
4. Set the notification rule targeting the minted subscribe URL (additive:
   existing rules on the bucket are preserved by name; only our named rule is
   added). If your bucket already carries notification rules, list them after
   setup and verify they survived.
5. Print a machine-readable success summary, including the subscribe URL and
   the scoped key credentials (shown once, stdout only) to set on the sync in
   Captain.

## Debugging a failed run

- Re-run with `--debug` (or `CAPTAIN_DEBUG=1`) for a full HTTP trace. Secrets are
  redacted in every log line.
- Read the last `[ERROR]` line: it names the exact failure, for example
  `Bucket 'x' not found ...`, `b2_create_key failed (HTTP 401) ... needs 'writeKeys'`,
  or `Captain enrollment failed ... HTTP 401`.
- Exit codes: `1` usage/preflight, `2` a B2 API error, `3` Captain enrollment
  failed (rolled back unless `--no-rollback`).
- Event path blocked? That is a WARN, not a failure. The run still succeeds via
  the reconcile backstop (see "Heads up" above).
- Captain side: quote the `deploymentId` (`dep_<token>`) from the summary when
  you contact Captain support.
- Common causes: wrong `--sync-id`, an invalid or revoked Captain API key, an
  operator key missing `writeKeys`, or a bucket-restricted operator key pointed
  at the wrong bucket.

## Teardown

```bash
./captain-b2-sync.sh teardown \
  --sync-id sync_YOURSYNC \
  --bucket  your-existing-b2-bucket
```

Removes our notification rule (siblings preserved) and deletes the scoped read
key(s) named for the sync. There is no unsubscribe call to Captain: Captain
detects the dead event source on its own, and the scheduled reconcile backstop
keeps the sync consistent until you pause or delete it in Captain.

## Terraform

Same three things as IaC. Operator credentials and the Captain API key come
from the environment so they stay out of tfvars and state.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # then fill it in
export B2_APPLICATION_KEY_ID=...
export B2_APPLICATION_KEY=...
export CAPTAIN_API_KEY=...
terraform init
terraform apply
```

Notes specific to the module:

- Enrollment is an external data source (`enroll_webhook.sh`) that POSTs to
  `{api_base}/v2/syncs/<sync-id>/webhooks` and returns the minted
  `subscribe_url` for the rule to target. It runs on plan and apply; the call
  is idempotent per sync, so re-planning is safe. A failed enrollment fails
  the plan with the reason on stderr.
- `event_path` defaults to `"skip"` (Event Notifications are account-gated).
  Set it to `"enabled"` once Backblaze has enabled the feature on your account.
- The `b2_bucket_notification_rules` resource owns the FULL rule set for the
  bucket. If the bucket already carries other rules you want to keep, use the
  setup script (which merges) or `terraform import` them first.
- On a failed apply Terraform leaves the key/rule in state (it does not
  auto-destroy). Fix the cause and re-apply, or `terraform destroy`. The setup
  script rolls back automatically; that is the one behavioral difference.

Outputs: `deployment_id`, `read_key_id`, `read_application_key` (sensitive),
`subscribe_url`, `s3_endpoint`, `region`, `event_path`,
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
    main.tf                     enrollment + notification rule + scoped key
    outputs.tf                  deployment id, subscribe URL, next step
    enroll_webhook.sh           webhook enrollment helper (external data source)
    terraform.tfvars.example    fill-in example
```
