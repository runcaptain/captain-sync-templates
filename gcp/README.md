# Captain deploy: Google Cloud Storage (GCS)

Coming next, see CAP-570.

Same shape as `../aws/cloudformation`: event wiring (Pub/Sub notifications on the
bucket), a read-only cross-account grant Captain uses, and a self-verifying
phone-home so a green deploy is a confirmed deploy.
