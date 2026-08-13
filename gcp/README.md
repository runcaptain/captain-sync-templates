# Captain GCS sync (Google Cloud)

One run stands up everything Captain needs to keep a Google Cloud Storage bucket
synced in your own GCP project: a Pub/Sub topic fed by the bucket's object-change
notifications, a push subscription that delivers those events to your sync's
Captain ingest URL over an authenticated OIDC channel, a read-only grant on the
bucket for Captain's own service account (no long-lived keys), and a final
webhook-registration call to the Captain API so a clean run means Captain has
this wiring on file.

Two equivalent paths ship here. Pick one:

- `terraform/` for teams that manage infrastructure as code.
- `gcloud/setup.sh` for a single imperative script (Cloud Shell friendly).

You need three values from Captain before you run either path: your sync id
(`sync_...`), a Captain API key, and the ingest URL Captain minted for the sync
(the `subscribe_url` from the webhook-registration endpoint). Captain generates
the deploy command with all three pre-filled; the guide at
https://docs.captain.dev/guides/sync/set-up shows where to find them.

## Mechanism

```
GCS bucket ──object change──▶ Pub/Sub topic ──push (OIDC token)──▶ Captain ingest
   │                                                                     ▲
   └── roles/storage.objectViewer for Captain's reader SA ──reconcile────┘
```

Reconcile (Captain listing the bucket as its reader service account) is the
always-on backstop. The Pub/Sub push is the near-real-time latency optimization
on top of it. If push delivery ever lapses, reconcile still catches every change.

## One-click launch (Open in Cloud Shell)

Google has no cross-account "Launch Stack" equivalent (change events must be
created inside YOUR project), so the closest one-click is Cloud Shell, which runs
in your account with your credentials and needs nothing installed locally:

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/open?cloudshell_git_repo=https://github.com/runcaptain/captain-sync-templates&cloudshell_workspace=gcp&cloudshell_tutorial=README.md)

The link, expanded:

```
https://shell.cloud.google.com/cloudshell/open
  ?cloudshell_git_repo=https://github.com/runcaptain/captain-sync-templates
  &cloudshell_workspace=gcp
  &cloudshell_tutorial=README.md
```

Then run the command Captain generated for you (it pre-fills every value):

```bash
cd gcp/gcloud
export CAPTAIN_API_KEY=XXXX     # preferred over --api-key (stays out of history)
./setup.sh \
  --project YOUR_PROJECT --bucket YOUR_BUCKET \
  --sync-id sync_xxx \
  --ingest-url https://THE_SUBSCRIBE_URL_CAPTAIN_MINTED \
  --reader-sa captain-reader@captain-prod.iam.gserviceaccount.com
```

`--ingest-url` has no default on purpose: it is the per-sync `subscribe_url`
Captain minted when it registered the webhook for your sync, and every sync
gets its own. Prefer your own terminal? Clone the repo and run
`gcloud/setup.sh` directly with the values Captain generated. If you do not
yet have your sync id, API key, or ingest URL, see
https://docs.captain.dev/guides/sync/set-up.

## Terraform path

```bash
cd gcp/terraform
cp terraform.tfvars.example terraform.tfvars   # Captain generates this for you
export TF_VAR_captain_api_key=XXXX             # preferred over putting it in tfvars
terraform init
terraform apply                                # registers the webhook before it finishes
```

A successful `apply` has already registered the webhook with the Captain API
and gotten the sync's `subscribe_url` back. The `deployment_id`
(`dep_<token>`), topic, subscription, push service account, and reader binding
are in the outputs. `terraform destroy` removes everything in your project; no
API call is made on destroy (there is no unsubscribe endpoint to call). Captain
detects the dead event source and the reconcile backstop keeps the sync
consistent.

## gcloud teardown

```bash
cd gcp/gcloud
./teardown.sh --project YOUR_PROJECT --bucket YOUR_BUCKET \
  --sync-id sync_xxx \
  --reader-sa captain-reader@captain-prod.iam.gserviceaccount.com
```

`--push-sa` is optional: the push service account id is derived
deterministically from `--sync-id` (the same derivation `setup.sh` uses), so
teardown finds it even if you don't remember it. Teardown only removes the GCP
resources; Captain notices the dead event source on its own and reconcile
continues as the backstop. Remove the sync itself in your Captain dashboard if
you no longer want it.

## Permissions the person running this needs

Run as a principal with these roles on the target project (Owner or Editor plus
Pub/Sub Admin covers it; the least-privilege list is below):

- `roles/pubsub.admin` (or the granular `pubsub.topics.*`, `pubsub.subscriptions.*`,
  and `pubsub.topics.setIamPolicy`) to create the topic, subscription, and grant
  the GCS agent publish.
- `roles/storage.admin` on the bucket, or at least `storage.buckets.update` and
  `storage.buckets.getIamPolicy` / `setIamPolicy`, to attach the notification and
  add the reader binding.
- `roles/iam.serviceAccountAdmin` to create the push service account and to let
  the Pub/Sub service agent mint OIDC tokens as it (the granular equivalent is
  `iam.serviceAccounts.create` plus `iam.serviceAccounts.setIamPolicy`).
- `roles/serviceusage.serviceUsageAdmin` if `manage_apis = true` (Terraform) or
  you let `setup.sh` enable the pubsub and storage APIs. Set `manage_apis = false`
  (or pre-enable the APIs) if your org enables services centrally.

No credentials ever leave your project. Captain only reads via its own service
account, and only the object-viewer role on exactly this one bucket. Your
Captain API key is sent only to the Captain API, as a Bearer header over https,
and is never logged.

## How the run confirms enrollment

"Run it and hope" gives you green resources even when the sync id is wrong or
the API key is dead, and the sync silently never works. This closes the loop.

1. The topic, publish grant, notification, push subscription (with OIDC), and the
   reader binding are created.
2. The run then calls the real Captain API:
   `POST {captain_api_base}/v2/syncs/{sync_id}/webhooks` with
   `Authorization: Bearer {captain_api_key}` and an empty JSON body (GCS syncs
   need no body fields).
3. A `2xx` response with a `subscribe_url` is a successful enrollment: Captain
   has the webhook on file for this sync. The script logs the returned
   `subscribe_url`, `secret_set`, and any `instructions` Captain sends back,
   and warns if the returned `subscribe_url` differs from the `--ingest-url`
   the push subscription was configured with.
4. Anything else (non-2xx, timeout, or a 2xx without `subscribe_url`) makes the
   call exit non-zero, which fails the `terraform apply` (or `setup.sh`) with a
   human-readable reason. You see the failure now, not days later.

## Debugging a failed run

- The failing step prints a `[captain-...] ERROR ...` line with the actual cause,
  for example `Captain rejected the webhook registration (http 401)` (bad or
  wrong-workspace API key) or `(http 404)` (sync id not found for that key).
- A `WARNING the push subscription delivers to ... but Captain returned ...`
  line means the `--ingest-url` you passed is not the URL Captain minted;
  re-run with the returned `subscribe_url` so events actually arrive.
- IAM propagation lag can delay the first push deliveries by up to ~60s (the
  reader binding and the token-creator grant). Both paths are idempotent
  (existing resources are detected and reused), so re-running is always safe.
- Look at the subscription's push state:
  `gcloud pubsub subscriptions describe captain-gcs-push-<syncId> --project <p>`.
  Check `pushConfig.pushEndpoint` (it must be exactly the minted
  `subscribe_url`) and `pushConfig.oidcToken.serviceAccountEmail`.
- Confirm the notification exists:
  `gcloud storage buckets notifications list gs://<bucket>`.
- Captain's side: check the sync's status in your Captain dashboard, or contact
  Captain support with your sync id and the `deployment_id` (`dep_<token>`)
  printed by the run (it is stamped on the run's logs for correlation).
- Common causes: a wrong or revoked API key (http 401/403), a sync id that does
  not belong to the key's workspace (http 404), an `--ingest-url` that is not
  the minted `subscribe_url`, the Pub/Sub service agent not yet materialized on
  a brand-new project (setup.sh force-creates it; Terraform users on a fresh
  project may need one re-apply), or APIs not enabled with `manage_apis = false`.

## Existing bucket, existing notifications

Unlike S3 (one notification slot per bucket), a GCS bucket can carry several
notification configs. This template ADDS one and, on teardown, removes only the
one it created. Notifications you already have are left untouched.

## Outputs

- `deployment_id`: the `dep_<token>` id stamped on this run's logs; quote it
  when debugging with Captain support.
- `pubsub_topic` / `pubsub_subscription`: the wiring behind the push delivery.
- `push_service_account`: the OIDC identity on each push delivery.
- `captain_reader_binding`: the reader SA and role granted on your bucket.
- `storage_notification_id`: the notification config attached to the bucket.
- `what_to_do_next`: one-line next step.
