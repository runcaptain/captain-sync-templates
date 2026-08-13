# Captain deploy

One-click deploy templates that wire your own cloud storage to Captain's
near-real-time sync. Captain is a headless indexing and retrieval API. Change
events have to originate inside YOUR cloud account, so each provider ships a
template you launch yourself, in your account, with your credentials.

[![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/quickcreate?stackName=captain-s3-sync&templateURL=https://captain-templates.s3.amazonaws.com/templates/2026-08-13/captain-s3-sync.yaml)

The button opens CloudFormation in your own AWS account with the template
loaded; you review the parameters and click Create. Details, required IAM, and
a Terraform alternative are in the [`aws/`](aws/) folder.

| Cloud | How you deploy | Folder |
| --- | --- | --- |
| AWS S3 | One click (button above) or Terraform | [`aws/`](aws/) |
| Google Cloud Storage | Cloud Shell script or Terraform | [`gcp/`](gcp/) |
| Azure Blob | Deploy to Azure button or `az` CLI (not yet available) | [`azure/`](azure/) |
| Cloudflare R2 | Follow the [S3-compatible setup guide](https://docs.captain.dev/guides/sync/set-up#s3-compatible); advanced real-time events in [`r2/`](r2/) | [`r2/`](r2/) |
| Backblaze B2 | One copy-paste script or Terraform | [`b2/`](b2/) |

Captain normally generates the exact launch link or command per sync with every
parameter pre-filled, so you review and click. Each folder's README is a full
quickstart: what gets created in your account, the permissions you need, how to
confirm it worked, and how to tear it down.

## How it works

Every template stands up the same three things in your account:

1. **Event wiring** so object changes reach Captain in near real time (SNS,
   Pub/Sub, Event Grid, Queues, or webhooks, depending on the cloud).
2. **A read-only grant** Captain uses to list and fetch objects. No long-lived
   master keys ever leave your account.
3. **An enroll call to Captain**: the deploy registers the new event wiring
   with Captain's API and only reports success once Captain returns your
   sync's subscribe URL.

One thing to know today: Captain pre-generates the launch links and keys per
sync, so have your sync id and Captain API key from Captain before you launch.

## Layout

```
captain-sync-templates/
  README.md                          this file
  aws/
    cloudformation/
      captain-s3-sync.yaml           SNS + read role + phone-home (CFN custom resource)
      README.md                      Launch Stack button, IAM, region, debugging
    terraform/
      main.tf, variables.tf, ...     same stack as IaC
      functions/                     enroll.py, setnotif.py (Lambdas the Terraform path invokes)
      README.md                      apply/destroy, retrying a failed apply
  gcp/
    README.md                        Cloud Shell one-click, Terraform path, permissions, debugging
    terraform/                       Pub/Sub + reader binding + phone-home, as IaC
    gcloud/                          setup.sh / teardown.sh, the imperative equivalent
  azure/
    README.md                        Deploy to Azure button, admin consent, debugging
    bicep/captain-blob-sync.bicep    source of truth
    arm/captain-blob-sync.json       compiled ARM (what the portal button and az deploy consume)
  r2/
    README.md                        Wrangler path (A) vs Terraform path (B), state/secrets
    deploy.sh / teardown.sh          Path A: one-command Wrangler deploy
    worker/                          queue consumer + keyless read proxy + phone-home
    terraform/                       Path B: IaC, mints a scoped R2 read token
  b2/
    README.md                        setup script vs Terraform, event-notification gating, debugging
    setup/captain-b2-sync.sh         provision + teardown, the one-command equivalent
    terraform/                       same stack as IaC
```

## Contributing

Issues and pull requests are welcome. Each cloud folder is self-contained, so
changes to one provider never touch another. The `NOTES.md` file in each
cloud folder (and at the repo root) holds engineering context for
contributors and is not part of the customer-facing docs.
