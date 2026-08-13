# Engineering notes: azure/ (captain-blob-sync)

The Bicep compiles clean to ARM (`az bicep build`, `az bicep lint`).
Enrollment verification is not yet activated on the Captain backend, so a
real `az deployment group create` fails at the native Event Grid webhook
validation handshake (the receiver is not there to answer it); that is the
intended fail-closed behavior of a self-verifying template, not a template
defect. `validate` and `what-if` succeed today.

## Design choices

- **deploymentScripts, not a managed identity.** The phone-home script only
  makes an outbound HTTPS call to Captain, so it carries no Azure
  credential of its own. The trade is that the script cannot do Azure-side
  preflight (for example confirm the event subscription provisioning
  state); that verification is delegated to Captain's enroll probe, which
  is the authority anyway.
- **No delete-time phone-home.** ARM deployment scripts do not run on stack
  delete the way a CloudFormation custom resource does. Teardown therefore
  does not notify Captain; Captain's reconcile must detect the removed
  subscription or role assignment and mark the deployment torn down.
- **Role scope is the whole storage account.** The grant is `Storage Blob
  Data Reader` on the account even when `containerName` narrows the event
  filter. Container-level scoping is possible but adds a
  required-existing-container dependency; account-level read plus the
  event filter is the simpler, documented default.
- **ARM parameters have no regex.** Unlike CloudFormation's
  `AllowedPattern`, ARM cannot enforce formats like `sync_<token>` on a
  parameter. Format rules live in the parameter `@description` text and
  the deployment-script preflight, and malformed names also fail naturally
  against Azure's own resource-name validation. Captain pre-fills these
  anyway.
- **Multi-sync per account.** Names derive from the sync id
  (`captain-blob-<syncSlug>`, `captain-sub-<syncSlug>`), so two syncs on
  the same account get distinct system topics and subscriptions. The role
  assignment name is a `guid()` of account + principal + role, so a second
  sync reusing the same principal reuses the same idempotent role
  assignment, which is correct.

## The enroll script and the pinned CLI image

The deployment script runs in the pinned
`mcr.microsoft.com/azure-cli:2.60.0` image, which ships neither `openssl`
nor `curl`. Both matter:

- The deployment token is generated with `python3 -c 'import secrets; ...'`
  rather than an `openssl rand` call or a `tr ... | head -c` pipeline (the
  latter dies with SIGPIPE under the script's `set -euo pipefail`).
- The phone-home POST uses a `python3` `urllib.request` call (same headers,
  45s timeout, response body written to a temp file with the status code
  reported) rather than curl. python3 is already a hard dependency of the
  script, so neither choice adds a tool.

Response parsing is deliberately defensive. `verified` and `status` are
parsed as two independent fields: `CAPTAIN_VERIFIED` is the only success
signal, and `CAPTAIN_STATUS` is display-only, defaulting to `verified`
when absent or empty. `status` is coerced to a string for every JSON type
before any concatenation (`None` becomes empty, strings pass through,
anything else goes through `json.dumps` with a `str()` fallback), and the
parser checks that the top-level response is a JSON object at all.
Non-JSON or unexpected bodies degrade to a readable
`0|<unparseable response body>` style result instead of a swallowed
exception, so a parsing problem is distinguishable from a genuine
`verified: false`. The `secret` compiles to `securestring` and is passed
to the deployment script as a `secureValue` environment variable; it must
never appear in the script's own log output.

## Captain and Azure AD dependencies

1. **Multi-tenant Captain enterprise application with admin consent.** The
   keyless cross-tenant read grant assigns a role to Captain's service
   principal as it exists in the customer's tenant, which only appears
   after a tenant admin consents to the Captain app. Captain must run that
   app registration and, post-consent, read back the principal's object id
   to fill `captainPrincipalId` into the deploy link. No other cloud in
   this repo carries an equivalent dependency.
2. **Enroll receiver** (placeholder
   `https://api.runcaptain.com/v1/deploy/azure/blob/enroll`) accepting
   `{deploymentId, templateVersion, action, cloud, provider,
   subscriptionId, tenantId, captainTenantId, resourceGroup,
   storageAccountId, storageAccountName, containerName, systemTopic,
   eventSubscription, eventWebhookUrl, captainPrincipalId,
   roleAssignmentId, location, syncId, secret}`, authenticating `secret`
   against `syncId` and returning `2xx` with `{"verified": true, ...}`.
3. **A read-access probe** as part of enroll: mint a token for Captain's
   principal and list/read against `storageAccountId` under the `Storage
   Blob Data Reader` assignment. Azure AD role assignments can take
   minutes to propagate, so the probe should retry for a couple of minutes
   rather than fail on the first denied read.
4. **Event webhook receiver** that answers the
   `Microsoft.EventGrid.SubscriptionValidationEvent` synchronously within
   30 seconds by echoing `validationResponse` (this is what makes the
   event-delivery half self-verifying at create time), then handles
   `BlobCreated`/`BlobDeleted` events, routing by the per-sync token in
   the webhook URL.
5. **Per-deployment state** keyed by the `dep_<token>` id, for the
   README's debugging steps.

## Testing changes

- `az bicep build` and `az bicep lint` must pass with zero diagnostics.
  Any change to `bicep/captain-blob-sync.bicep` must be recompiled to
  `arm/captain-blob-sync.json`; diff the compiled output to confirm only
  the parts you intended to change moved (a script-only edit should touch
  only `scriptContent` and `templateHash`).
- Run `bash -n` and `shellcheck -s bash` on the extracted `scriptContent`;
  both should be clean.
- Test script behavior inside the real pinned
  `mcr.microsoft.com/azure-cli:2.60.0` image via Docker, not just on your
  host, since the image's missing binaries are exactly what bites here.
  Point the script at a local mock HTTPS server with a CA-trusted cert
  (install the cert into the container's trust store so the real TLS path
  is exercised) and cover at least: `verified: true` with string, empty,
  missing, and non-string `status` values; `verified: false`; a non-JSON
  body; and a non-object top-level body. The secret should appear in the
  POST body but never in the script's log output.
- For a live test, create a throwaway uniquely named resource group with a
  real `StorageV2` account, run `az deployment group validate` and
  `what-if` (expect the system topic, event subscription, deployment
  script, and role assignment to create, the existing storage account
  ignored), then a real create, which should fail at the Event Grid
  webhook handshake while the backend receiver is not live. Tear down
  with `az group delete --yes`, poll `az group exists` to `false`, and
  confirm no residue with `az group list`.
