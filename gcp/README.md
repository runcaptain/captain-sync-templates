# Captain GCS sync (Google Cloud)

One run stands up everything Captain needs to keep a Google Cloud Storage bucket
synced in your own GCP project: a Pub/Sub topic fed by the bucket's object-change
notifications, a push subscription that delivers those events to Captain over an
authenticated OIDC channel, a read-only grant on the bucket for Captain's own
service account (no long-lived keys), and a self-verifying phone-home so a clean
run actually means a working sync.

Two equivalent paths ship here. Pick one:

- `terraform/` for teams that manage infrastructure as code.
- `gcloud/setup.sh` for a single imperative script (Cloud Shell friendly).

One thing to know today: Captain's enrollment endpoint for this template is not
yet live, so a run currently completes the setup steps in your project and then
fails loudly at the final verification step. Contact Captain for activation
status for your sync.

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
./setup.sh \
  --project YOUR_PROJECT --bucket YOUR_BUCKET \
  --sync-id sync_xxx --external-id XXXX --secret XXXX \
  --reader-sa captain-reader@captain-prod.iam.gserviceaccount.com
```

Prefer your own terminal? Clone the repo and run `gcloud/setup.sh` directly
with the values Captain generated for your sync. Contact Captain if you do
not yet have your sync id, external id, secret, or the reader service
account email.

## Terraform path

```bash
cd gcp/terraform
cp terraform.tfvars.example terraform.tfvars   # Captain generates this for you
terraform init
terraform apply                                # self-verifies before it finishes
```

A successful `apply` has already phoned home and been confirmed by Captain. The
`deployment_id` (`dep_<token>`), topic, subscription, push service account, and
reader binding are in the outputs. `terraform destroy` removes everything and
sends Captain a best-effort, authenticated teardown notice (the real
`enrollment_secret` from state, the same one `apply` used).

## gcloud teardown

```bash
cd gcp/gcloud
./teardown.sh --project YOUR_PROJECT --bucket YOUR_BUCKET \
  --sync-id sync_xxx --secret XXXX --deployment-id dep_xxx \
  --reader-sa captain-reader@captain-prod.iam.gserviceaccount.com
```

`--secret` is the same enrollment secret you passed to `setup.sh --secret`,
and `--deployment-id` is the `dep_<token>` the setup run printed. Both are
needed for the teardown notice to Captain; without them the script still
deletes every resource, it just skips the notice rather than send it
unauthenticated (Captain reconciles the orphan on its own schedule instead).
`--push-sa` is optional:
the push service account id is derived deterministically from `--sync-id`
(the same derivation `setup.sh` uses), so teardown finds it even if you
don't remember it.

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
account, and only the object-viewer role on exactly this one bucket.

## How the deploy verifies itself

"Run it and hope" gives you green resources even when the wiring is wrong, and the
sync silently never works. This closes the loop.

1. The topic, publish grant, notification, push subscription (with OIDC), and the
   reader binding are created.
2. The phone-home POSTs the enrollment facts to `captain_enroll_url`: `deploymentId`,
   `syncId`, `secret`, `pubsubTopic`, `pubsubSubscription`, `pushServiceAccount`,
   `readerServiceAccount`, `bucket`, `projectId`, `oidcAudience`, `ingestUrl`,
   `externalId`.
3. Captain probes the read grant (LIST/GET on the bucket as its reader SA, proving
   objectViewer really propagated) and confirms it can receive the push / allowlists
   the push SA, then returns `2xx` with `{"verified": true}` only if BOTH pass.
4. Anything else (non-2xx, timeout, or `verified` not true) makes the phone-home
   exit non-zero, which fails the `terraform apply` (or `setup.sh`) with a
   human-readable reason. You see the failure now, not days later.

## Debugging a failed run

- The failing step prints a `[captain-...] ERROR ...` line with the actual cause,
  for example `Captain rejected enrollment (http 403): unknown sync` or `Captain
  reached but did NOT verify the deployment (verified=false), status=reader
  binding not propagated`.
- IAM propagation lag is the most common false failure. The reader binding or the
  token-creator grant can take up to ~60s to be visible. Re-run; both paths are
  idempotent (existing resources are detected and reused).
- Look at the subscription's push state:
  `gcloud pubsub subscriptions describe captain-gcs-push-<syncId> --project <p>`.
  Check `pushConfig.pushEndpoint` and `pushConfig.oidcToken.serviceAccountEmail`.
- Confirm the notification exists:
  `gcloud storage buckets notifications list gs://<bucket>`.
- Captain's side: look up the deployment by the `deployment_id` (`dep_<token>`)
  output. Captain's per-deployment status view (subscription seen? read probe
  passed? last handshake result?) is not yet available; until it is, contact
  Captain support with the `deployment_id`.
- Common causes: wrong `captain_reader_service_account` (read probe fails), an
  OIDC audience Captain's verifier does not expect, the Pub/Sub service agent not
  yet materialized on a brand-new project (setup.sh force-creates it; Terraform
  users on a fresh project may need one re-apply), or APIs not enabled with
  `manage_apis = false`.

## Existing bucket, existing notifications

Unlike S3 (one notification slot per bucket), a GCS bucket can carry several
notification configs. This template ADDS one and, on teardown, removes only the
one it created. Notifications you already have are left untouched.

## Outputs

- `deployment_id`: the `dep_<token>` id; use it to look up deployment state.
- `pubsub_topic` / `pubsub_subscription`: the wiring Captain subscribes behind.
- `push_service_account`: the OIDC subject Captain allowlists.
- `captain_reader_binding`: the reader SA and role granted on your bucket.
- `storage_notification_id`: the notification config attached to the bucket.
- `what_to_do_next`: one-line next step.
