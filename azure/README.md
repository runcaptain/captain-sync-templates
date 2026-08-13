# Captain Blob sync (Azure)

Azure Blob sync is not yet available to customers. The button below will not
work until Captain publishes the template and turns on Azure Blob syncs;
contact Captain for status. The Captain API this template phones home to is
live today: to deploy you need your sync id (`sync_...`), a Captain API key,
and the `subscribe_url` Captain mints for the sync. Setup guide:
https://docs.captain.dev/guides/sync/set-up

One deploy stands up everything Captain needs to keep an Azure Blob container
synced in your own Azure subscription: an Event Grid system topic fed by the
storage account's blob change events, a read-only cross-tenant role assignment
Captain uses (no keys, no SAS), and a self-verifying phone-home so a green deploy
actually means a working sync.

Reconcile (polling) on Captain's side is the always-on backstop. The Event Grid
webhook is the latency optimization on top of it: if a webhook is ever missed,
reconcile still catches the change.

## Deploy to Azure (not yet available)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fcaptaindeploytemplates.blob.core.windows.net%2Ftemplates%2F2026-08-13%2Fcaptain-blob-sync.json)

The link, expanded:

```
https://portal.azure.com/#create/Microsoft.Template/uri/
  https%3A%2F%2Fcaptaindeploytemplates.blob.core.windows.net%2Ftemplates%2F2026-08-13%2Fcaptain-blob-sync.json
```

Captain normally generates this whole link per sync and pre-fills the
parameters (`captainEventWebhookUrl`, `captainApiKey`, `captainPrincipalId`,
`location`, `storageAccountName`, `syncId`) so you only review and click
Create. `captainApiBase` defaults to `https://api.captain.dev` and only changes
if Captain support points you at a staging environment.

There are two artifacts in this folder:

- `bicep/captain-blob-sync.bicep` is the source of truth.
- `arm/captain-blob-sync.json` is compiled from it (`az bicep build`) and is what
  the Deploy to Azure button and `az deployment group create` consume.

## Before you deploy: one-time admin consent

The cross-tenant read grant is keyless. Captain reads with a token minted for its
OWN service principal, and your tenant grants that principal a read role. For the
role assignment to reference it, Captain's service principal has to EXIST in your
tenant first. That happens when a tenant admin grants consent to the Captain
enterprise application once:

```
https://login.microsoftonline.com/common/adminconsent?client_id=<CaptainAppId>
```

Captain gives you this consent link. After consent, Captain reads back the object
id of its now-present service principal in your tenant and fills it into the
deploy link as `captainPrincipalId`. No consent means no principal to grant, and
Captain cannot read your blobs until it is fixed.

## Prerequisites

- Resource providers registered in the target subscription (one-time):
  - `Microsoft.EventGrid` (the system topic and event subscription).
  - `Microsoft.Storage` and `Microsoft.ContainerInstance` (the phone-home is an
    Azure `deploymentScripts` resource, which runs in a container backed by a
    storage account).

  ```bash
  az provider register --namespace Microsoft.EventGrid --wait
  az provider register --namespace Microsoft.Storage --wait
  az provider register --namespace Microsoft.ContainerInstance --wait
  ```

- The storage account must already exist, in the SAME resource group you deploy
  into, and `location` must match the account's region (an Event Grid storage
  system topic is same-region).

## Permissions the deploying user needs

The person clicking Deploy needs, on the target resource group:

- `Microsoft.Resources/deployments/*` (create the deployment).
- `Microsoft.EventGrid/systemTopics/*` and
  `Microsoft.EventGrid/systemTopics/eventSubscriptions/*` (event wiring).
- `Microsoft.Authorization/roleAssignments/write` (the read grant). This is the
  one that trips people up: only **Owner** or **User Access Administrator** can
  create role assignments. Plain Contributor cannot.
- `Microsoft.Resources/deploymentScripts/*`, plus the ability to create the
  script's backing resources (`Microsoft.Storage/storageAccounts/*`,
  `Microsoft.ContainerInstance/containerGroups/*`).

The simplest working combination is **Owner** on the resource group, or
**Contributor + User Access Administrator**. No credentials ever leave your
account: Captain only ever reads with its own identity, scoped to the one storage
account by the role assignment.

One scope detail worth knowing: the grant is **Storage Blob Data Reader on the
whole storage account**, even when a container name narrows the event filter.
That means Captain can read every container on that account, not just the one
being synced. If you need container-level read scoping, ask Captain about a
narrower assignment; the account-level grant is the documented default.

## How the deploy verifies itself

Ordinary "deploy and hope" templates go green even when the wiring is wrong, and
the sync just silently never works. This one closes the loop in two places, and
BOTH must pass for the deployment to succeed:

1. **Event delivery (native, at create time).** The Event Grid event subscription
   points at `captainEventWebhookUrl`, which is the `subscribe_url` Captain
   minted for your sync. When Azure creates it, Event Grid POSTs a
   `Microsoft.EventGrid.SubscriptionValidationEvent` to that URL and waits up to
   30 seconds for Captain to echo back the validation code. If Captain does not
   own / cannot answer that endpoint, the event subscription resource FAILS and
   the whole deployment fails. Proof that events can be delivered, enforced by
   Azure with no code.

2. **Webhook enrollment (phone-home).** After the event subscription and the
   role assignment are in place, the `deploymentScripts` resource POSTs to
   `{captainApiBase}/v2/syncs/<syncId>/webhooks` with
   `Authorization: Bearer <captainApiKey>` and an empty JSON body (Azure Blob is
   not an S3-family sync, so no `sns_topic_arn`). Captain answers `2xx` with the
   sync's `subscribe_url`, plus `secret_set` and `instructions`. A `2xx` with a
   `subscribe_url` IS successful enrollment; anything else makes the script exit
   non-zero, which fails the deployment with a human-readable reason. The script
   also warns if the returned `subscribe_url` differs from the
   `captainEventWebhookUrl` the event subscription delivers to.

So a successful deployment means Event Grid proved it can deliver to Captain's
live ingest URL, and Captain confirmed the webhook is enrolled on your sync
under your API key. Read access rides the role assignment; if that part is
misconfigured, Captain's reconcile surfaces it in your dashboard rather than at
deploy time.

## Debugging a failed deploy

- **Deployment-script logs (the phone-home).** In the portal: Resource group →
  Deployments → your deployment → the `captain-enroll-<syncSlug>` resource, or the
  `Microsoft.Resources/deploymentScripts` resource directly, which has a **Logs**
  tab. From the CLI:

  ```bash
  az deployment-scripts show-log \
    --resource-group <rg> --name captain-enroll-<syncSlug>
  ```

  The script logs every fact it sent (the API key is redacted), the HTTP status
  from Captain, the response body, and a labeled list of common causes on
  failure.

- **Event subscription handshake failure.** If the deployment failed on the
  `Microsoft.EventGrid/.../eventSubscriptions` resource with a validation error,
  Captain's webhook did not complete the 30-second handshake: wrong
  `captainEventWebhookUrl` (it must be the `subscribe_url` Captain minted for
  this sync), or the endpoint is unreachable. Check the deployment error detail
  in `az deployment group show`.

- **Captain-side sync state.** Check the sync in your Captain dashboard, or
  contact Captain support with your `syncId` and the `deploymentId` output
  (`dep_<token>`, a client-side correlation id from the phone-home logs).

- **Common causes:**
  - HTTP 401/403 from the phone-home: `captainApiKey` is wrong, revoked, or
    belongs to a different Captain workspace than the sync.
  - HTTP 404: `syncId` does not exist or is not visible to this API key.
  - HTTP 422 mentioning `sns_topic_arn`: the `syncId` points at an S3-family
    sync; this template is for Azure Blob syncs only.
  - `captainPrincipalId` wrong, or admin consent never granted. This does not
    fail the deploy, but Captain cannot read your blobs and your dashboard will
    show the sync stalled.
  - `location` does not match the storage account's region (system topic create
    fails).
  - A resource provider above is not registered.

## Provision and test it for real (CLI)

```bash
# 0. Register providers (one-time per subscription).
az provider register --namespace Microsoft.EventGrid --wait
az provider register --namespace Microsoft.Storage --wait
az provider register --namespace Microsoft.ContainerInstance --wait

# 1. Preflight validate against your resource group (no resources created).
az deployment group validate \
  --resource-group <rg> \
  --template-file arm/captain-blob-sync.json \
  --parameters \
      storageAccountName=<existingaccount> \
      location=<accountRegion> \
      captainEventWebhookUrl='<subscribe_url Captain minted for this sync>' \
      captainApiKey='<your Captain API key>' \
      captainPrincipalId=<captain-sp-object-id> \
      syncId=sync_...
# captainApiBase defaults to https://api.captain.dev; override it only for a
# Captain staging environment.

# 2. What-if: show exactly what will be created before you commit.
az deployment group what-if \
  --resource-group <rg> \
  --template-file arm/captain-blob-sync.json \
  --parameters storageAccountName=<existingaccount> location=<accountRegion> \
      captainEventWebhookUrl='...' captainApiKey='...' \
      captainPrincipalId=<...> syncId=sync_...

# 3. Deploy for real. Succeeds only if the handshake passes AND Captain
#    confirms the webhook enrollment.
az deployment group create \
  --resource-group <rg> \
  --name captain-blob-sync \
  --template-file arm/captain-blob-sync.json \
  --parameters storageAccountName=<existingaccount> location=<accountRegion> \
      captainEventWebhookUrl='...' captainApiKey='...' \
      captainPrincipalId=<...> syncId=sync_...

# 4. Read the phone-home output.
az deployment group show --resource-group <rg> --name captain-blob-sync \
  --query properties.outputs

# 5. If it failed, read the enroll script's logs.
az deployment-scripts show-log --resource-group <rg> --name captain-enroll-<syncSlug>
```

Deploying from Bicep directly works too (`--template-file bicep/captain-blob-sync.bicep`);
the CLI compiles it on the fly. The committed `arm/captain-blob-sync.json` exists
so the portal button and environments without the Bicep CLI can deploy.

## Teardown

Delete the resource group, or delete these resources: the deployment script, the
event subscription, the system topic, and the read role assignment. ARM
deployment scripts do not run on delete (unlike a CloudFormation custom resource),
and there is no unsubscribe call to make: Captain detects the dead event source,
and reconcile continues as the backstop until you delete the sync in Captain.

## Outputs

- `deploymentId`: the `dep_<token>` correlation id; quote it with your `syncId`
  to Captain support.
- `subscribeUrl`: the per-sync ingest URL Captain confirmed during enrollment.
- `webhookSecretSet`: whether Captain reports a webhook signing secret is set.
- `readRoleAssignmentId`: the cross-tenant read role assignment Captain uses.
- `systemTopicName` / `eventSubscriptionName`: the event wiring that was created.
- `whatToDoNext`: one-line next step.
