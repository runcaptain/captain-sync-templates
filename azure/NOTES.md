# NOTES: honest flags for captain-blob-sync (Azure, CAP-571)

The Bicep is built and compiles clean to ARM (`az bicep build`, `az bicep lint`,
zero warnings, zero errors). It is written to a contract that partly depends on
Captain BACKEND and Azure AD setup that does NOT exist yet. Those are the
dependency tickets for this to actually run against a live tenant.

## Fix round: pre-launch QA gate finding fixed (this round)

**Bug: `status`-parsing TypeError when Captain's response has a non-string
`status` field (bicep, enroll script, the `CAPTAIN_PARSED` python block).**
This is the same function a prior round already patched once (see "Fix
round: QA sweep findings addressed" below, for the `status: ""` case). That
patch fixed the falsy-empty-string case but left a second, separate bug in
the same lines:

```python
status = (d.get('status') or 'verified') if verified else (d.get('status') or '')
print(('1' if verified else '0') + '|' + status)
```

If Captain's response has a **non-string, truthy** `status` value, for
example `{"verified": true, "status": 200}`, or `status` is a nested object,
a list, or the boolean `true`, the `or` short-circuits to that raw
non-string value, and the final `+ status` string concat throws
`TypeError: can only concatenate str (not "int") to str` (or `"dict"`,
`"list"`, `"bool"` depending on the type). That crash was already inside a
blanket `try/except Exception: print('0|')`, so the deployment did not hang
or blow up visibly: it printed `verified: false` and failed closed, safe,
but silently wrong. A live Captain that actually returned `verified: true`
with a non-string `status` would report enrollment failure with a
misleading "verified: false" and zero indication that the real cause was a
parsing exception, not a real verification failure. That is not acceptable
to ship "fixed" a second time on the same function.

**Fix:** rewrote the parsing block to coerce `status` to a string for every
JSON type BEFORE the concat (`None` -> `''`; `str` -> itself; anything else
-> `json.dumps(value)`, falling back to `str(value)` if that somehow
fails), and to explicitly check the top-level response is a JSON object at
all rather than relying on the exception handler to catch a non-dict body.
Non-JSON / unparseable bodies still degrade cleanly to
`0|<unparseable response body>` instead of a bare swallowed exception.
Added a `status` line to the failure-branch echo block so these new
messages actually surface in the deployment-script logs instead of only
existing in an internal variable. Recompiled to `arm/captain-blob-sync.json`
via `az bicep build` (only the `scriptContent` string and `templateHash`
changed; diffed to confirm no other resource in the compiled JSON moved).

**Live-reproduced the original crash first, in the pinned
`mcr.microsoft.com/azure-cli:2.60.0` image (not just on the host), to
confirm this was a real bug and not a host-python-version artifact:**

```
$ echo '{"verified": true, "status": 200}' > /tmp/captain_resp.json
$ docker run --rm -v ...:/old_harness.py:ro mcr.microsoft.com/azure-cli:2.60.0 python3 /old_harness.py
[non-string status: int] raw (no except) exit=1
  TypeError: can only concatenate str (not "int") to str
[non-string status: int] through OLD except-swallower -> stdout='0|' (WRONG: Captain said verified:true)

[non-string status: nested object] raw (no except) exit=1
  TypeError: can only concatenate str (not "dict") to str
[non-string status: nested object] through OLD except-swallower -> stdout='0|' (WRONG: Captain said verified:true)
```

**Then live-verified the fix, extracting the actual `CAPTAIN_PARSED` python
block out of the real, recompiled `arm/captain-blob-sync.json` (not a
standalone rewrite) and running it in the same pinned image against every
response shape that used to crash, plus the previously-fixed regression
cases, plus new edge cases:**

```
case                                          input                                         output     crashed?
non-string status: int                        {"verified": true, "status": 200}             1|200                                    False
status: null                                  {"verified": true, "status": null}            1|verified                               False
non-string status: nested object              {"verified": true, "status": {"code": "acti   1|{"code": "active"}                     False
non-string status: list                       {"verified": true, "status": ["a","b"]}       1|["a", "b"]                             False
non-string status: bool true                  {"verified": true, "status": true}            1|true                                   False
non-string status: bool false                 {"verified": true, "status": false}           1|false                                  False
regression case: empty string status          {"verified": true, "status": ""}              1|verified                               False
normal string status                          {"verified": true, "status": "active"}        1|active                                 False
status key omitted                            {"verified": true}                            1|verified                               False
verified false                                {"verified": false, "status": "denied"}       0|denied                                 False
top-level JSON is a list                      ["not","an","object"]                         0|<unexpected response shape: top-level  False
unparseable body                              not json at all                               0|<unparseable response body>            False

ALL PASS (zero crashes)
```

Every case that used to be a swallowed `TypeError` now produces a correct,
readable `verified|status` pair with the actual status value preserved
(coerced to a string), not thrown away. The regression case from the prior
round (`status: ""`) and the omitted-key case still correctly fall back to
`'verified'`, unchanged behavior.

**Then re-ran the full live-deploy check against a real Azure subscription**
(throwaway, uniquely-timestamped resource group, to confirm the recompiled
template still deploys with no regression from the fix):

- `az group create --name captain-azure-fix-verify-status-1786640750
  --location eastus` + a real `StorageV2` account in the same group.
- `az deployment group validate` against the recompiled
  `arm/captain-blob-sync.json` -> `Succeeded`.
- `az deployment group what-if` -> `Resource changes: 4 to create, 1 to
  ignore` (system topic, event subscription, deployment script, role
  assignment; the existing storage account ignored), matching the
  previously-verified shape exactly, no drift from the parsing fix.
- `az deployment group create` (real create) -> failed exactly as
  architecture demands, at the native
  `Microsoft.EventGrid/.../eventSubscriptions` resource: `Webhook endpoint
  validation failed ... (404) Not Found`. Same expected failure as every
  prior round, because the backend receiver still does not exist. Proof the
  recompile did not regress the live-deploy path; not a template defect.
- Teardown: `az group delete --yes`, then polled `az group exists` every
  10s (7 polls, ~70s, until `false`). Verified zero residue TWO independent
  ways, not just the one `exists` call: `az group list --query "[?starts_with(name,
  'captain-azure')].name"` returned empty, and `az group show` on the exact
  deleted name returned `ResourceGroupNotFound`.

## Fix round: QA sweep findings addressed (earlier round)

A pre-launch QA sweep with real Azure CLI auth (contradicting the "no auth"
assumption below, which was true in an earlier round but is stale) found one
real code bug and confirmed the backend-dependency blocker already disclosed
here. Both addressed:

1. **README Deploy-to-Azure button was clickable with no warning that it is
   dead today.** The placeholder host does not resolve, and neither backend
   receiver exists, so a real customer's first click fails. Fixed:
   `README.md` now opens with a customer-phrased "not yet available" notice
   above the button. This is a docs/rollout fix, not a template fix: the
   template itself was never the problem, gating expectations around the
   button is. See "Live deploy is BLOCKED right now" below for the
   underlying dependency status, which has not changed.

2. **`CAPTAIN_STATUS` parsing conflated `verified` with a non-empty `status`
   string (bicep, enroll script, ~line 360).** Old code:
   `d.get('status', 'verified') if d.get('verified') is True else ''`. Since
   `dict.get(key, default)` only returns `default` when `key` is MISSING, a
   response of `{"verified": true, "status": ""}` (present but empty, a
   plausible in-progress/edge shape) made `CAPTAIN_STATUS` empty, which
   failed `[ -n "${CAPTAIN_STATUS}" ]` and failed the deployment even though
   Captain said `verified: true`. The failure branch then printed
   `verified : false`, contradicting the raw response shown one line above
   it. Fixed by parsing `verified` and `status` as two independent fields:
   `CAPTAIN_VERIFIED` (the only success signal) and `CAPTAIN_STATUS`
   (display-only, defaults to `'verified'` when absent or falsy/empty).
   Success now gates purely on `CAPTAIN_VERIFIED = "1"`. Recompiled to
   `arm/captain-blob-sync.json` via `az bicep build` (byte-identical output,
   zero warnings). This also happened to eliminate the one pre-existing
   `SC2155` shellcheck style warning noted below, since the fix separates
   command substitution from `export`; `shellcheck -s bash` is now fully
   clean, zero diagnostics.

   Live-verified in the pinned `mcr.microsoft.com/azure-cli:2.60.0` image via
   Docker, against a local mock HTTPS server with a properly CA-trusted cert
   (cert installed into the container's trust store via
   `update-ca-certificates`, exercising the real `urllib.request` TLS path,
   not a bypassed-verification test):
   - `{"verified": true, "status": ""}` (the exact regression case) → exit 0,
     `SUCCESS`, output `captainStatus: "verified"`. Previously: exit 1 with a
     misleading `verified: false`.
   - `{"verified": true, "status": "active"}` → exit 0, `SUCCESS`, output
     `captainStatus: "active"`.
   - `{"verified": true}` (status key omitted) → exit 0, `SUCCESS`, output
     `captainStatus: "verified"`.
   - `{"verified": false, "status": "denied"}`, HTTP 403 → exit 1, correctly
     fails as before.
   - Non-JSON/HTML body (proxy/WAF simulation) → still exit 1, no crash,
     unaffected by this change (`json.load` throws, caught, treated as not
     verified).
   In every case the secret was present in the POST body but never appeared
   in the script's own log output.

3. **Process finding (not a template bug): NOTES.md's "NOTHING was deployed"
   claim below was stale.** A prior round's QA left a real, undeleted
   resource group (`captain-azure-audit-test-1786599367`) in the Azure
   subscription. The reviewer deleted it and confirmed removal by polling
   before this round started. This round's own live verification (see next
   section) created its own throwaway, uniquely-timestamped resource group
   and confirmed it was fully deleted (`az group exists` polled to `false`,
   `az group list` shows zero `captain-azure-*` residue) before finishing.

## Live verification this round (real Azure subscription, auth available)

Auth was available (`az account show` succeeds), contradicting the "no Azure
CLI auth" note below, which was accurate for an earlier round only. Ran a
real, throwaway, uniquely-timestamped test:

- Created resource group `captain-azure-fix-verify-<unix-ts>` + a real
  `StorageV2` account in `eastus`. `Microsoft.EventGrid`, `Microsoft.Storage`,
  `Microsoft.ContainerInstance` providers were already registered on the
  subscription.
- `az deployment group validate` against the fixed `arm/captain-blob-sync.json`
  → `Succeeded`.
- `az deployment group what-if` → matches the four declared resources exactly
  (system topic, event subscription, deployment script, role assignment), no
  drift.
- `az deployment group create` (real create, pointed `captainEventWebhookUrl`
  at the real `api.runcaptain.com` host with a fake path) → failed exactly as
  architecture demands, at the native `Microsoft.EventGrid/.../eventSubscriptions`
  resource, with `Webhook endpoint validation failed ... (404) Not Found`.
  This is the expected, correct failure mode given the backend receiver does
  not exist yet: proof the native Event Grid self-verification works, not a
  template defect.
- Teardown: `az group delete --yes`, then polled `az group exists` every 10s
  until `false` (7 polls, ~70s). Confirmed via `az group list` that no
  `captain-azure-*` resource group remains in the subscription.

## Fixed: two bugs that silently killed the phone-home (found in adversarial testing)

Adversarial testing against the pinned `mcr.microsoft.com/azure-cli:2.60.0`
image found that the enroll deployment script's phone-home, the entire point
of this artifact, never actually ran. Two independent bugs, both now fixed:

1. **Token generator died under `pipefail` (both testers, 5/5 repro).**
   `TOKEN=$(cat /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 24)` ran
   under `set -euo pipefail`. `head -c 24` closes the pipe once it has its 24
   bytes; the upstream `cat`/`tr` then get `SIGPIPE` (exit 141); `pipefail` +
   `set -e` aborted the whole script before it ever built the payload or
   POSTed to Captain. Live-reproduced in the pinned image:
   ```
   set -euo pipefail; cat /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 24; echo AFTER_OK
   -> exits 141, "AFTER_OK" never printed
   ```
   Fixed by generating the token with `python3 -c 'import secrets; print(secrets.token_hex(12))'`
   (24 hex chars, matches the prior length/format). `openssl rand -hex 12` was
   the first fix attempted, per the standard recommendation for this class of
   bug, but was rejected: **`openssl` is not installed in the pinned
   `mcr.microsoft.com/azure-cli:2.60.0` image** (it is Alpine 3.19 based and
   ships no openssl binary). python3 is already a hard dependency of this
   script (used elsewhere to build and parse JSON), so the fix adds no new
   tool. Searched the full script for any other infinite-source-into-head or
   similar pipe-under-pipefail pattern; the only other `head` usage is
   `head -c 800 /tmp/captain_resp.json`, which reads a bounded regular file
   with no upstream process in the pipe, so there is nothing for `pipefail`
   to trip on there.

2. **`curl` is not installed in the pinned image either (found here during
   live re-verification, not previously flagged).** The phone-home POST used
   `curl -sS -o ... -w '%{http_code}' ...`. In the real pinned image this
   fails `command not found`, and the script's own
   `HTTP_CODE=$(curl ... || echo "000")` fallback silently swallows that
   into "Captain did not verify", exit 1, on every single run, healthy
   backend or not. Same class of bug as #1: the phone-home never actually
   reaches Captain. Fixed by replacing the curl call with a `python3`
   `urllib.request` POST (same headers, same 45s timeout, same behavior of
   writing the response body to `/tmp/captain_resp.json` and reporting the
   status code), again adding no new tool dependency.

Both fixes are in `bicep/captain-blob-sync.bicep` (the source) and
`arm/captain-blob-sync.json` (recompiled via `az bicep build`, byte-consistent
with the source).

### Live verification (this round)

- Pulled `mcr.microsoft.com/azure-cli:2.60.0`, confirmed the original bug
  reproduces exactly as reported (exit 141, script never reaches the payload
  build). Confirmed via `apk info -e curl` and `which curl` that curl is
  absent from this image (only `wget` ships).
- Extracted the fixed `scriptContent` from the recompiled ARM JSON and ran it
  standalone in that exact image with dummy enrollment env vars pointed at
  `https://example.com/...`: the script now generates a well-formed
  `dep_<24-hex>` id, builds the JSON payload, makes a real outbound HTTPS POST
  (confirmed by a real `405` response and body from example.com, not a
  swallowed `000`), and lands cleanly in its own "ENROLLMENT NOT CONFIRMED"
  branch with `exit 1`, exactly as designed for a non-Captain endpoint.
- Separately unit-verified the success path: ran the same token-generation +
  payload-build + POST logic in the pinned image against a local mock HTTP
  server that asserts the payload's `secret` and `deploymentId` shape and
  replies `200 {"verified": true, "status": "active"}`. The script correctly
  parses that into `HTTP_CODE=200`, `CAPTAIN_STATUS=active`, and reaches the
  `SUCCESS` branch. The mock server's assertions on payload shape did not
  fail.
- No permanent Azure resources were created or touched; both live checks ran
  against a local Docker container and a local mock HTTP server only.

## Live deploy is BLOCKED right now

- Azure CLI auth turned out to BE available in a later round (see "Live
  verification this round" above); the "no auth" limitation below was
  accurate only for the round that wrote it. What actually blocks a live
  deploy today is the backend, not the environment: `captaindeploytemplates.blob.core.windows.net`
  (the README button's host) does not resolve, and neither
  `captainEnrollUrl` nor `captainEventWebhookUrl` is a live Captain endpoint
  yet. `az deployment group validate` and `what-if` both succeed against the
  fixed template; `az deployment group create` correctly fails at the native
  Event Grid webhook handshake with `404 Not Found`, because the receiver
  isn't there to answer it. This is the intended failure mode of a
  self-verifying template pointed at a backend that hasn't shipped, not a
  template bug. The README's Deploy to Azure button stays marked "not yet
  available" until both endpoints are real and the ARM JSON is hosted
  somewhere that resolves.
- Earlier-round note, now superseded: "No Azure CLI auth in this environment
  ... NOTHING was deployed. No Azure resources were created." That was true
  for that round only; do not read it as still true. See the two live
  verification sections above for what has actually been exercised, and
  their teardown confirmation.

## Captain / Azure AD dependencies (do not exist yet)

1. **Captain multi-tenant enterprise application + admin-consent flow.** The
   keyless cross-tenant read grant assigns a role to Captain's service principal
   AS IT EXISTS IN THE CUSTOMER'S TENANT. That principal only appears after a
   tenant admin consents to the Captain app
   (`https://login.microsoftonline.com/common/adminconsent?client_id=<CaptainAppId>`).
   Captain must run that app registration and, post-consent, read back the
   principal's object id to fill `captainPrincipalId` into the deploy link.

2. **`captainEnrollUrl` enroll receiver.** An HTTPS endpoint (placeholder
   `https://api.runcaptain.com/v1/deploy/azure/blob/enroll`) that accepts the
   POST body `{deploymentId, templateVersion, action, cloud, provider,
   subscriptionId, tenantId, captainTenantId, resourceGroup, storageAccountId,
   storageAccountName, containerName, systemTopic, eventSubscription,
   eventWebhookUrl, captainPrincipalId, roleAssignmentId, location, syncId,
   secret}`. It must authenticate `secret` against `syncId`, do the read probe
   (below), and return `2xx` with `{"verified": true, "status": "..."}`. Anything
   else fails the deployment.

3. **The read-access probe.** On enroll, Captain must mint a token for its
   service principal and do a probe list/read against `storageAccountId` (scoped
   by the `Storage Blob Data Reader` assignment this template created), proving
   the grant actually works before returning `verified: true`. Azure AD role
   assignments can take a few minutes to propagate, so the receiver should RETRY
   the probe for a couple of minutes rather than fail on the first denied read.

4. **`captainEventWebhookUrl` ingest receiver with the Event Grid handshake.**
   The event subscription destination must be a live Captain endpoint that:
   - answers the `Microsoft.EventGrid.SubscriptionValidationEvent` synchronously
     within 30 seconds by echoing `validationResponse` (this is what makes the
     event-delivery half self-verifying at create time), and
   - handles `Microsoft.Storage.BlobCreated` / `BlobDeleted` events afterward,
     routing by the per-sync token carried in the webhook URL.
   Standard Event Grid webhook plumbing, but it is real work on the receiver.

5. **Deployment-state object / endpoint.** Captain must expose per-deployment
   state keyed by the `dep_<token>` id (handshake result, read-probe result, last
   status) so the README's debugging steps resolve. Does not exist yet.

## Design choices worth knowing

- **deploymentScripts, not a managed identity.** The phone-home script only makes
  an outbound HTTPS call to Captain, so it carries NO Azure credential of its own.
  This keeps the footprint keyless. The trade is that the script cannot do
  Azure-side preflight (e.g. confirm the event subscription provisioning state);
  that verification is delegated to Captain's enroll probe instead, which is the
  authority anyway.

- **No delete-time phone-home.** ARM deployment scripts do not run on stack
  delete the way a CloudFormation custom resource does. Teardown therefore does
  not notify Captain; Captain's reconcile must detect the removed subscription /
  role and mark the deployment torn down. Backend reconcile should handle
  orphaned subscriptions.

- **Role scope is the whole storage account.** The grant is `Storage Blob Data
  Reader` on the account, even when `containerName` narrows the EVENT filter.
  Container-level read scoping is possible (assign at the container resource) but
  adds a required-existing-container dependency; the account-level read plus the
  event filter is the simpler, documented default. Narrow it later if a customer
  needs least-privilege at container granularity.

- **ARM parameters have no regex.** Unlike CloudFormation's `AllowedPattern`, ARM
  cannot enforce formats like `sync_<token>` on a parameter. Format rules live in
  the parameter `@description` text and the deployment-script preflight (which
  emits human-readable errors). Malformed names also fail naturally against
  Azure's own resource-name validation. Captain pre-fills these anyway.

- **Multi-sync per account.** Names are derived from the sync id
  (`captain-blob-<syncSlug>`, `captain-sub-<syncSlug>`), so two Captain syncs on
  the same account get distinct system topics and subscriptions and do not
  collide. The role assignment name is a `guid()` of account + principal + role,
  so a second sync reusing the same principal reuses the same (idempotent) role
  assignment, which is correct.

## Validation status

- `az bicep build` : PASS, zero warnings, zero errors, re-run this round
  after the `status`-parsing fix. Emits `arm/captain-blob-sync.json`; diffed
  against the pre-fix compiled output and confirmed only `scriptContent` and
  `templateHash` changed, no other resource moved.
- `az bicep lint` : PASS, zero diagnostics, re-run this round.
- `bash -n` on the extracted `scriptContent` : PASS, re-run this round on
  the post-fix script.
- `shellcheck -s bash` on the extracted `scriptContent` : PASS, zero
  diagnostics, re-run this round. The one pre-existing `SC2155` style
  warning noted in earlier rounds (`export CAPTAIN_STATUS="$(...)"` masks a
  return value) is gone: the `CAPTAIN_STATUS` / `CAPTAIN_VERIFIED` parsing
  fix (see "Fix round: QA sweep findings addressed (earlier round)" below)
  separates the command substitution from the `export`, which incidentally
  cleared it.
- ARM JSON : valid JSON; `secret` compiles to `securestring`; the secret is passed
  to the deployment script as a `secureValue` environment variable (never logged).
- **This round's fix (`status`-parsing TypeError):** live-reproduced the
  crash in the pinned `mcr.microsoft.com/azure-cli:2.60.0` image, then
  live-verified the fix in the same image by extracting the actual
  `CAPTAIN_PARSED` block out of the real recompiled ARM JSON and running it
  against 12 response shapes including every non-string `status` type
  (int, null, nested object, list, bool true/false), the prior round's
  regression case (`status: ""`), a non-object top-level body, and an
  unparseable body. Zero crashes across all 12. See "Fix round: pre-launch
  QA gate finding fixed (this round)" above for the full case table.
- Live-verified the phone-home end to end inside the pinned
  `mcr.microsoft.com/azure-cli:2.60.0` image via Docker, across all four
  realistic response shapes from an earlier round, TLS-trusted (not
  bypassed) mock server; see "Fix round: QA sweep findings addressed
  (earlier round)" below for the exact cases and results.
- Live-verified against a real Azure subscription, re-run this round with a
  fresh throwaway resource group (`captain-azure-fix-verify-status-<ts>`):
  `validate` succeeded, `what-if` matched declared resources exactly (4 to
  create, 1 to ignore), and a real `deployment group create` failed at the
  expected point (Event Grid webhook handshake, `404`) given the backend
  isn't live, same as every prior round. Full teardown confirmed by polling
  `az group exists` to `false`, AND independently confirmed by both
  `az group list` (filtered for `captain-azure*`, empty) and `az group show`
  on the deleted name (`ResourceGroupNotFound`). No residue left in the
  subscription.
- Still not a working end-to-end deploy against a live Captain backend,
  because that backend does not exist yet (see "Captain / Azure AD
  dependencies" below). That is a backend/hosting gap, not a template gap:
  the template's own verification logic and Azure-side behavior are now
  fully live-verified, including how it behaves when Captain's response
  shape does not match the documented contract.

## Publish-time TODO (moved from README)

The README's Deploy to Azure link points at
`captaindeploytemplates.blob.core.windows.net`, a PLACEHOLDER host that does
not resolve. Before making the button live: publish `arm/captain-blob-sync.json`
to a public HTTPS location under a DATE-based version segment
(`.../templates/2026-08-12/...`) and put that dated URL in the README link
(Azure's portal fetches the ARM JSON, not the Bicep). Also confirm both
`captainEnrollUrl` and `captainEventWebhookUrl` are live before removing the
README's "not yet available" notice.
