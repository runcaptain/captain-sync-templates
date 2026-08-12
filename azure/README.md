# Captain deploy: Azure Blob Storage

Coming next, see CAP-571.

Same shape as `../aws/cloudformation`: event wiring (Event Grid on the storage
account), a read-only cross-account grant Captain uses, and a self-verifying
phone-home so a green deploy is a confirmed deploy.
