# Engineering notes: azure/ (captain-blob-sync)

The Bicep compiles clean to ARM (`az bicep build`, `az bicep lint`).
The phone-home targets the live Captain API contract:
`POST {captainApiBase}/v2/syncs/<syncId>/webhooks` with Bearer auth, empty
JSON body, success = `2xx` with `subscribe_url`. The endpoint exists; what
does not exist yet is customer availability for this cloud, so a real
`az deployment group create` needs a real sync id, a Captain API key, and
the `subscribe_url` Captain minted for the sync (which is what
`captainEventWebhookUrl` must be set to, or the native Event Grid
validation handshake fails by design). `validate` and `what-if` succeed
today without any of that.

## Design choices

- **deploymentScripts, not a managed identity.** The phone-home script only
  makes an outbound HTTPS call to Captain, so it carries no Azure
  credential of its own. The trade is that the script cannot do Azure-side
  preflight (for example confirm the event subscription provisioning
  state); the Event Grid handshake already covers delivery, and read-side
  problems surface through Captain's reconcile.
- **No delete-time phone-home.** ARM deployment scripts do not run on stack
  delete the way a CloudFormation custom resource does, and Captain
  documents no unsubscribe endpoint, so teardown makes no Captain call at
  all. Captain detects the dead event source and reconcile continues as
  the backstop until the sync is deleted in Captain.
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
- **`captainApiBase` is a parameter, not a constant.** It defaults to
  `https://api.captain.dev` and exists only so Captain staging can be
  targeted; the preflight refuses non-https values because the API key
  rides the Authorization header.

## The enroll script and the pinned CLI image

The deployment script runs in the pinned
`mcr.microsoft.com/azure-cli:2.60.0` image, which ships neither `openssl`
nor `curl`. Both matter:

- The local `dep_<token>` correlation id is generated with
  `python3 -c 'import secrets; ...'` rather than an `openssl rand` call or
  a `tr ... | head -c` pipeline (the latter dies with SIGPIPE under the
  script's `set -euo pipefail`).
- The phone-home POST uses a `python3` `urllib.request` call (Bearer
  header, 45s timeout, response body written to a temp file with the
  status code reported) rather than curl. python3 is already a hard
  dependency of the script, so neither choice adds a tool.

Response parsing is deliberately defensive. `subscribe_url` is the ONLY
success signal: success is a `2xx` status AND a non-empty string
`subscribe_url` in a top-level JSON object. `secret_set` and
`instructions` are display-only and never gate success; both are coerced
to readable text whatever JSON type arrives. Non-JSON bodies, a non-object
top level, and a missing or non-string `subscribe_url` each degrade to a
labeled `parse_note` instead of a swallowed exception, so a parsing
problem is distinguishable from a genuine enrollment failure (an earlier
build of this script proved a blanket `except` makes a healthy backend
indistinguishable from a dead one). The script also compares the returned
`subscribe_url` to `captainEventWebhookUrl` and prints a warning on
mismatch. `captainApiKey` compiles to `securestring`, is passed to the
deployment script as a `secureValue` environment variable, is read from
the environment inside python (never an argument list), and must never
appear in the script's own log output.

## Captain and Azure AD dependencies

1. **Multi-tenant Captain enterprise application with admin consent.** The
   keyless cross-tenant read grant assigns a role to Captain's service
   principal as it exists in the customer's tenant, which only appears
   after a tenant admin consents to the Captain app. Captain must run that
   app registration and, post-consent, read back the principal's object id
   to fill `captainPrincipalId` into the deploy link. No other cloud in
   this repo carries an equivalent dependency.
2. **Webhook enrollment endpoint (live).**
   `POST https://api.captain.dev/v2/syncs/<syncId>/webhooks`,
   `Authorization: Bearer <apiKey>`, body `{}` for non-S3 syncs
   (S3-family syncs require `{"sns_topic_arn": ...}` and 422 without it,
   which is a useful wrong-sync-id tell here). Success is `2xx` JSON with
   `subscribe_url`, `secret_set`, and `instructions`.
3. **Event webhook receiver at the minted `subscribe_url`** that answers
   the `Microsoft.EventGrid.SubscriptionValidationEvent` synchronously
   within 30 seconds by echoing `validationResponse` (this is what makes
   the event-delivery half self-verifying at create time), then handles
   `BlobCreated`/`BlobDeleted` events, routing by the per-sync token in
   the URL. This receiver behavior is the gating item for Azure customer
   availability.
4. **Read-side verification stays out of the deploy.** The webhook
   enrollment call does not probe blob access; a wrong
   `captainPrincipalId` or missing consent leaves a green deploy with a
   stalled sync that Captain's reconcile and dashboard surface. Azure AD
   role-assignment propagation delays (minutes) therefore cannot fail the
   deploy either.
5. **`dep_<token>` is client-side only.** The empty enrollment body means
   Captain never receives it; it exists for logs, outputs, and support
   conversations alongside the `syncId`.

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
  is exercised) and cover at least: `2xx` with a string `subscribe_url`
  (matching and mismatching `captainEventWebhookUrl`); `subscribe_url`
  missing, empty, or non-string; `secret_set` true/false/absent;
  `instructions` absent, empty, and containing non-string items; `401`,
  `404`, and `422` bodies; a non-JSON body; and a non-object top-level
  body. The API key should appear in the `Authorization` request header
  but never in the script's log output.
- For a live test, create a throwaway uniquely named resource group with a
  real `StorageV2` account, run `az deployment group validate` and
  `what-if` (expect the system topic, event subscription, deployment
  script, and role assignment to create, the existing storage account
  ignored), then a real create with a real sync id, API key, and minted
  `subscribe_url`. Without a real `subscribe_url` the create fails at the
  Event Grid webhook handshake, which is the fail-closed behavior working
  as designed, not a template defect. Tear down with
  `az group delete --yes`, poll `az group exists` to `false`, and confirm
  no residue with `az group list`.
