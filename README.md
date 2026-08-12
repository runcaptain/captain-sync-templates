# Captain deploy

One-click deploy templates that wire a customer's own cloud storage to Captain's
near-real-time sync. Captain is a headless indexing and retrieval API. Change
events have to be created inside the CUSTOMER'S cloud account (Captain cannot
click in someone else's console), so each provider ships a template the customer
launches themselves. Every template stands up the same three things in the
customer account:

1. Event wiring so object changes reach Captain.
2. A read-only cross-account grant Captain uses to list and fetch objects (no
   long-lived keys).
3. A self-verifying phone-home so a successful deploy is a CONFIRMED deploy, not
   a hopeful one.

## Layout

```
captain-deploy/
  README.md                          this file
  aws/
    cloudformation/
      captain-s3-sync.yaml           the S3 template (SNS + read role + phone-home)
      README.md                      Launch Stack button, IAM, region, debugging
  gcp/    README.md                  coming next (CAP-570)
  azure/  README.md                  coming next (CAP-571)
  r2/     README.md                  coming next (CAP-572)
  b2/     README.md                  coming next (CAP-568)
```

## Conventions

- Template versions and any versioned URL path segment are DATE-based,
  `YYYY-MM-DD` (for example `.../templates/2026-08-12/captain-s3-sync.yaml`).
- Customer-facing object ids are Stripe-style `prefix_token`
  (`dep_...` deployment ids, `sync_...` sync ids). No bare UUIDs in outputs.

## Status

AWS S3 is the first provider (CAP-569). The template validates with
`aws cloudformation validate-template` and `cfn-lint`. Some receiver-side pieces
it phones home to are Captain backend work that does not exist yet; see
`NOTES.md` for the exact dependency list.
