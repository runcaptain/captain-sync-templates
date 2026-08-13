# Captain deploy: Cloudflare R2

**Start with the docs instead.** For most R2 users the fastest path is the
[S3-compatible setup guide](https://docs.captain.dev/guides/sync/set-up#s3-compatible):
create an R2 API token, paste it into a sync, done. Scheduled reconciliation
keeps the collection current with no infrastructure to deploy at all.

What this folder adds is the ADVANCED path: near-real-time event delivery.
A one-command deploy that wires R2 event notifications through a Queue and a
Worker in YOUR Cloudflare account, same shape as the AWS S3 template: event
wiring, a read grant Captain uses, and enrollment through Captain's webhook
API. Set this up only if minutes-level reconciliation is not fresh enough for
your use case.

## What it stands up

```
R2 bucket  --(object change)-->  event notification  -->  Queue  -->  Worker
                                                                        |  drains the queue
                                                                        v
                                                              Captain ingest (near-real-time)

Captain reconcile (always-on backstop) --> reads objects via:
   - the Worker's keyless read proxy   (Wrangler path, no long-lived keys), OR
   - a scoped read-only R2 API token   (Terraform path, feeds Captain's R2 sync)
```

Reconcile/polling is the always-on backstop. The Queue path is the latency
optimization. If events go quiet, scheduled reconcile still keeps the collection
correct.

Cloudflare has no CloudFormation-style "Launch Stack" button, so the one-click
equivalent is a single command. Pick ONE of the two paths below (do not run both
against the same sync: they both create the same Worker and queue).

What you need before you start: your sync id (`sync_...`, create the sync in
Captain first), your Captain API key, and a 16+ character shared secret you
choose for the Worker read proxy. The deploy enrolls the sync by calling
Captain's webhook API (`POST https://api.captain.dev/v2/syncs/<sync_id>/webhooks`);
Captain answers with the per-sync `subscribe_url` your Worker forwards events to.

The default Worker and queue names (`captain-r2-sync`) are shared, so two syncs
in one Cloudflare account will collide. Running more than one sync? Override
`WORKER_NAME` / `QUEUE_NAME` (Path A) or `worker_name` / `queue_name` (Path B)
so each sync gets its own Worker and queue.

## Layout

```
r2/
  deploy.sh                 one-command Wrangler deploy (the "Launch" equivalent)
  teardown.sh                undoes deploy.sh: Worker, queues, notification, secret
  worker/
    src/index.ts            queue consumer + keyless read proxy + self-test
    wrangler.jsonc          Worker + queue consumer + R2 binding (committed template)
    package.json  tsconfig.json
  terraform/
    main.tf variables.tf outputs.tf versions.tf
    terraform.tfvars.example
```

---

## Path A: Wrangler (recommended for a quick, keyless deploy)

Captain gives you `SYNC_ID` and your `CAPTAIN_API_KEY`. You supply your account
id, your bucket, and a `CAPTAIN_SECRET` you choose (16+ characters; it guards
the Worker's read-proxy routes, and you configure the same value on your
Captain sync).

```bash
cd r2
export CLOUDFLARE_ACCOUNT_ID=$(npx wrangler whoami | grep -oE '[0-9a-f]{32}' | head -1)
export SYNC_ID=sync_xxxxxxxx
export BUCKET_NAME=my-r2-bucket
export CAPTAIN_API_KEY=your-captain-api-key
export CAPTAIN_SECRET=a-16-plus-char-secret-you-choose
# optional: export PREFIX=docs/   DEBUG=true   WORKER_NAME=...   QUEUE_NAME=...
# optional: export CAPTAIN_API_BASE=...   # staging only; defaults to https://api.captain.dev
./deploy.sh
```

`deploy.sh` preflights your tools and inputs, then enrolls the sync FIRST:
`POST $CAPTAIN_API_BASE/v2/syncs/$SYNC_ID/webhooks` with your API key and an
empty JSON body. A 2xx response carrying the minted `subscribe_url` is
confirmed enrollment; anything else exits non-zero before a single Cloudflare
resource is created. It then creates the queue + dead-letter queue, deploys the
Worker wired to that `subscribe_url`, sets the secret, wires the R2 event
notification, and self-tests the event path. Re-running is safe (idempotent).

Reads in this path are keyless: Captain fetches objects through the Worker's
`/__captain/objects` and `/__captain/object` routes, authenticated with the shared
secret. No standing R2 credential ever leaves your account.

To remove everything this created, run `./teardown.sh` with the same env vars
(deletes the R2 event notification, the Worker's secret, the queue consumer, the
Worker, and both queues; never touches the bucket itself). Teardown makes no
Captain-side call: Captain detects the dead event source on its own, and
scheduled reconcile continues as the backstop. To stop the sync entirely,
delete it in Captain too.

## Path B: Terraform / OpenTofu (infrastructure as code)

Use this if you manage infra declaratively or you want Captain to read via the S3
API with a scoped token instead of the Worker proxy.

```bash
# 1. Build the Worker bundle Terraform uploads. Do this BEFORE tofu init or
#    validate: main.tf reads worker/dist/index.js off disk, so tofu validate
#    fails with "content_sha256 must be specified" until the bundle exists.
cd r2/worker && npm install && npm run build   # writes dist/index.js

# 2. Apply:
cd ../terraform
export CLOUDFLARE_API_TOKEN=...                 # token scopes below
cp terraform.tfvars.example terraform.tfvars    # then edit it
tofu init
tofu apply
```

The apply enrolls the sync through Captain's webhook API: `data.http.subscribe`
POSTs to `{captain_api_base}/v2/syncs/{sync_id}/webhooks` with your Captain API
key, and a postcondition FAILS THE APPLY unless Captain returns 2xx with the
minted `subscribe_url` (which the Worker is then wired to). On success, read
the scoped credentials out to feed Captain's R2 sync:

```bash
tofu output -raw read_access_key_id
tofu output -raw read_secret_access_key
```

(These are the `access_key_id` / `secret_access_key` values Captain's R2 sync
asks for. Access key id = the token id; secret = SHA-256 of the token value,
per Cloudflare's documented S3 credential derivation.)

To remove everything Path B created (Worker, queues, notification, the scoped
read token), run `tofu destroy` from `r2/terraform`. The bucket itself is never
touched, and no Captain-side call is made on destroy: Captain detects the dead
event source and scheduled reconcile continues as the backstop.

---

## Permissions required

### Path A (Wrangler)
Your `wrangler login` session (or `CLOUDFLARE_API_TOKEN`) needs, on the account
that owns the bucket:

- Workers Scripts: Edit  (deploy the Worker, set the secret)
- Queues: Edit           (create the queue + dead-letter queue, attach consumer)
- Workers R2 Storage: Edit (create the bucket event notification)

### Path B (Terraform)
`CLOUDFLARE_API_TOKEN` needs the above PLUS:

- API Tokens: Edit       (mint the scoped read-only child token)

The token Terraform creates for Captain is read-only AND scoped to this one
bucket, not the account: it holds the bucket-level "Workers R2 Storage Bucket
Item Read" permission group on the
`com.cloudflare.edge.r2.bucket.<account>_<jurisdiction>_<bucket>` resource, not
the account-wide "Workers R2 Storage Read" group. (The account-wide group
grants read on every bucket in the account regardless of what goes in
`resources`, which is why this template does not use it.) It expires after
`read_token_ttl_days` (default 90); re-apply to rotate. See "State and secrets"
below: this token's id and derived secret live in Terraform state in plaintext.

---

## State and secrets (Path B / Terraform)

Terraform state for this stack holds, in plaintext: the Worker's shared
read-proxy secret (`var.captain_secret`), your Captain API key
(`var.captain_api_key`, recorded in the http data source's request headers),
and the scoped R2 read token Terraform mints (its id and the SHA-256-derived
S3 secret). `sensitive = true` on those variables and outputs only hides them
from CLI output, it does NOT encrypt state.

You MUST run this against an encrypted remote backend, for example S3 with
`encrypt = true` (and ideally a KMS key) or Terraform/OpenTofu Cloud (encrypted
at rest by default). Local state (the default with no `backend` block) is
unencrypted on disk and is fine for a throwaway local test, never for anything
real. See `terraform/versions.tf` for a worked backend example.

To rotate: re-apply before `read_token_ttl_days` expires (or `tofu taint
cloudflare_api_token.read` then apply, to force it early); change
`captain_secret` and re-apply to rotate the shared read-proxy secret, which
also rewrites the Worker's `CAPTAIN_SECRET` (update the same value on your
Captain sync). Rotation replaces the value going
forward; it does not scrub the old value out of your backend's state history,
so use a backend with access control, not a shared file with unrestricted read
access.

---

## Debugging a failed deploy

Everything logs. The Worker emits structured JSON lines; set `DEBUG=true` for
per-message tracing.

| Symptom | Where to look |
| --- | --- |
| `deploy.sh` fails at preflight | The error names the missing tool or env var. Fix and re-run. |
| `deploy.sh` fails at the webhook subscribe | Captain's HTTP status and body are printed. A 401/403 means the `CAPTAIN_API_KEY` is wrong; a 404 means the `SYNC_ID` does not exist (create the sync in Captain first). Nothing was created in Cloudflare yet; fix and re-run. |
| Terraform apply fails on the subscribe postcondition | The error prints Captain's HTTP status and first 400 bytes of the body. Check `sync_id` and `captain_api_key`, then re-apply; the deployment id is stable. |
| No events arriving | Live-tail the Worker: `cd worker && npx wrangler tail -c wrangler.generated.jsonc` (Path A) or `npx wrangler tail captain-r2-sync` (Path B). Then POST the self-test below. |
| Worker health | `curl https://<worker-url>/healthz` shows config presence (never secret values). |
| Prove the event path end to end | `curl -X POST https://<worker-url>/__captain/selftest -H "Authorization: Bearer $CAPTAIN_SECRET"` writes and deletes a canary object; watch `wrangler tail` for a queue batch with the canary key within ~30s. |
| Events stuck / failing ingest | Check the dead-letter queue `captain-r2-sync-dlq` in the Queues dashboard. Messages land there after `max_retries`. |

### Confirming event delivery
Run the `/__captain/selftest` call above to confirm event delivery in YOUR
account. Treat the queue path as a latency optimization either way: scheduled
reconcile through the read path is the always-on backstop, so a missed event
never means a missed object.
