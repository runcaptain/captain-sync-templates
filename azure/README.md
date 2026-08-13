# Captain Blob sync (Azure)

This deploy path is not yet available. The button below will not work until
Captain publishes the template and activates the endpoints it phones home to;
contact Captain for status.

One deploy stands up everything Captain needs to keep an Azure Blob container
synced in your own Azure subscription: an Event Grid system topic fed by the
storage account's blob change events, a read-only cross-tenant role assignment
Captain uses (no keys, no SAS), and a self-verifying phone-home so a green deploy
actually means a working sync.

Reconcile (polling) on Captain's side is the always-on backstop. The Event Grid
webhook is the latency optimization on top of it: if a webhook is ever missed,
reconcile still catches the change.

## Deploy to Azure (not yet available)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fcaptaindeploytemplates.blob.core.windows.net%2Ftemplates%2F2026-08-12%2Fcaptain-blob-sync.json)

The link, expanded:

```
https://portal.azure.com/#create/Microsoft.Template/uri/
  https%3A%2F%2Fcaptaindeploytemplates.blob.core.windows.net%2Ftemplates%2F2026-08-12%2Fcaptain-blob-sync.json
```

Captain normally generates this whole link per sync and pre-fills the
parameters (`captainEventWebhookUrl`, `captainEnrollUrl`, `captainPrincipalId`,
`captainTenantId`, `location`, `storageAccountName`, `syncId`, `secret`) so you
only review and click Create.

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
the deploy's read-access verification will fail with a clear message.

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
   points at Captain's HTTPS webhook. When Azure creates it, Event Grid POSTs a
   `Microsoft.EventGrid.SubscriptionValidationEvent` to that URL and waits up to
   30 seconds for Captain to echo back the validation code. If Captain does not
   own / cannot answer that endpoint, the event subscription resource FAILS and
   the whole deployment fails. Proof that events can be delivered, enforced by
   Azure with no code.

2. **Read access + sync binding (phone-home).** After the event subscription and
   the role assignment are in place, the `deploymentScripts` resource POSTs the
   enrollment facts to `captainEnrollUrl`: `subscriptionId`, `resourceGroup`,
   `storageAccountId`, `systemTopic`, `eventSubscription`, `captainPrincipalId`,
   `roleAssignmentId`, `syncId`, `secret`, and a generated `deploymentId`
   (`dep_<token>`). Captain then mints a token for its service principal and does
   a probe list/read against the account (proving the role assignment really
   works), confirms the subscription is live, and returns `2xx` with
   `{"verified": true}` only if BOTH hold. Anything else makes the script exit
   non-zero, which fails the deployment with a human-readable reason.

So a successful deployment means Captain has confirmed, end to end, that it can
both receive change events and read your blobs.

## Debugging a failed deploy

- **Deployment-script logs (the phone-home).** In the portal: Resource group →
  Deployments → your deployment → the `captain-enroll-<syncSlug>` resource, or the
  `Microsoft.Resources/deploymentScripts` resource directly, which has a **Logs**
  tab. From the CLI:

  ```bash
  az deployment-scripts show-log \
    --resource-group <rg> --name captain-enroll-<syncSlug>
  ```

  The script logs every fact it sent (the secret is redacted), the HTTP status
  from Captain, the response body, and a labeled list of common causes on
  failure.

- **Event subscription handshake failure.** If the deployment failed on the
  `Microsoft.EventGrid/.../eventSubscriptions` resource with a validation error,
  Captain's webhook did not complete the 30-second handshake: wrong
  `captainEventWebhookUrl`, endpoint down, or the endpoint is not the built
  Captain ingest receiver. Check the deployment error detail in
  `az deployment group show`.

- **Captain-side deployment state.** Look up the deployment by the `deploymentId`
  output (`dep_<token>`). Captain's per-deployment status view (subscription
  confirmed? read probe passed? last handshake result?) is not yet available;
  until it is, contact Captain support with the `deploymentId`.

- **Common causes:**
  - `captainPrincipalId` wrong, or admin consent never granted, so Captain's read
    probe cannot get a token.
  - Role assignment has not propagated yet (Azure AD can take a few minutes);
    Captain retries the probe, but re-run the deploy if it timed out.
  - `captainEnrollUrl` or `secret` does not match the sync (HTTP 401/403/404).
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
      captainEventWebhookUrl='https://api.runcaptain.com/v1/deploy/azure/blob/events?sync=sync_...&token=...' \
      captainEnrollUrl='https://api.runcaptain.com/v1/deploy/azure/blob/enroll' \
      captainPrincipalId=<captain-sp-object-id> \
      captainTenantId=<captain-tenant-id> \
      syncId=sync_... \
      secret=<one-time-secret>

# 2. What-if: show exactly what will be created before you commit.
az deployment group what-if \
  --resource-group <rg> \
  --template-file arm/captain-blob-sync.json \
  --parameters storageAccountName=<existingaccount> location=<accountRegion> \
      captainEventWebhookUrl='...' captainEnrollUrl='...' \
      captainPrincipalId=<...> captainTenantId=<...> syncId=sync_... secret=<...>

# 3. Deploy for real. Succeeds only if Captain verifies BOTH halves.
az deployment group create \
  --resource-group <rg> \
  --name captain-blob-sync \
  --template-file arm/captain-blob-sync.json \
  --parameters storageAccountName=<existingaccount> location=<accountRegion> \
      captainEventWebhookUrl='...' captainEnrollUrl='...' \
      captainPrincipalId=<...> captainTenantId=<...> syncId=sync_... secret=<...>

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
so teardown does not phone home. Captain's reconcile notices the subscription and
role are gone and marks the deployment torn down on its side.

## Outputs

- `deploymentId`: the `dep_<token>` id; use it to look up deployment state.
- `captainStatus`: Captain-reported enrollment status.
- `readRoleAssignmentId`: the cross-tenant read role assignment Captain uses.
- `systemTopicName` / `eventSubscriptionName`: the event wiring that was created.
- `whatToDoNext`: one-line next step.
