# Captain S3 sync: self-verifying enrollment (Terraform variant).
#
# Invoked by the aws_lambda_invocation resource with lifecycle_scope = "CRUD",
# so Terraform calls this on create, update, AND destroy. The action is in
# event["tf"]["action"]. Unlike the CloudFormation variant, there is no
# CloudFormation response URL to answer: Terraform reads this function's RETURN
# value and a postcondition asserts result.verified == true, so a rejected
# registration fails `terraform apply` the same way a failed enrollment rolls
# back a CloudFormation stack.
#
# The real Captain contract this calls:
#   POST {CaptainApiBase}/v2/syncs/{SyncId}/webhooks
#   Authorization: Bearer {CaptainApiKey}
#   Body: {"sns_topic_arn": "<the topic this module created>"}
#     (sns_topic_arn is required for S3-family syncs; the API returns 422
#     without it)
#   Success: 2xx JSON with subscribe_url (the per-sync ingest URL Captain
#   minted), secret_set, and instructions. A 2xx with a subscribe_url IS
#   successful enrollment: Captain subscribing to the topic is the
#   verification.
#
# On destroy this function calls nothing: there is no documented unsubscribe
# endpoint, and none is needed. Destroying the module removes the SNS topic;
# Captain detects the dead event source and reconcile remains the backstop.
#
# Heavy, structured, single-line logging under the CAPTAIN-ENROLL prefix. The
# Captain API key is NEVER logged (redacted to its length).
import json
import os
import secrets
import string
import urllib.error
import urllib.request

DEBUG = os.environ.get("CAPTAIN_DEBUG", "true").lower() == "true"
ALPHABET = string.ascii_letters + string.digits
REDACT = ("apiKey", "ApiKey", "CaptainApiKey", "authorization")
TEMPLATE_VERSION = "2026-08-13"


def log(tag, **kw):
    if not DEBUG and tag.endswith("-debug"):
        return
    safe = {}
    for k, v in kw.items():
        if k in REDACT and v:
            safe[k] = "***redacted(len=%d)***" % len(str(v))
        else:
            safe[k] = v
    print("CAPTAIN-ENROLL %s %s" % (tag, json.dumps(safe, default=str)))


def new_deployment_id():
    # Stripe-style dep_<token>, no bare UUIDs in customer-facing output.
    return "dep_" + "".join(secrets.choice(ALPHABET) for _ in range(24))


def register_webhook(api_base, api_key, sync_id, topic_arn):
    url = "%s/v2/syncs/%s/webhooks" % (api_base.rstrip("/"), sync_id)
    data = json.dumps({"sns_topic_arn": topic_arn}).encode()
    log("webhook-post", url=url, syncId=sync_id, snsTopicArn=topic_arn,
        apiKey=api_key)
    req = urllib.request.Request(
        url, data=data, method="POST",
        headers={"content-type": "application/json",
                 "authorization": "Bearer %s" % api_key,
                 "user-agent": "captain-tf-enroll/%s" % TEMPLATE_VERSION})
    with urllib.request.urlopen(req, timeout=45) as resp:
        raw = resp.read().decode("utf-8", "replace")
        status = getattr(resp, "status", 200)
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = {"raw": raw[:512]}
        if not isinstance(parsed, dict):
            parsed = {"raw": str(parsed)[:512]}
        log("webhook-response", httpStatus=status,
            subscribeUrl=parsed.get("subscribe_url"),
            secretSet=parsed.get("secret_set"))
        return status, parsed


def preflight(event):
    # Human-readable validation. Returned problems become the Terraform
    # postcondition error message (result.error) verbatim.
    problems = []
    base = event.get("CaptainApiBase") or ""
    if not base.startswith("https://"):
        problems.append("CaptainApiBase must be https:// (got %r)" % base[:48])
    for key in ("SnsTopicArn", "SyncId", "CaptainApiKey"):
        if not event.get(key):
            problems.append("missing required input: %s" % key)
    return problems


def handler(event, context):
    action = (event.get("tf") or {}).get("action", "create")
    dep_id = event.get("DeploymentId") or new_deployment_id()
    if not str(dep_id).startswith("dep_"):
        dep_id = new_deployment_id()
    log("invoke", action=action, deploymentId=dep_id,
        logStream=getattr(context, "log_stream_name", None))

    if action == "delete":
        # No Captain call on teardown: there is no documented unsubscribe
        # endpoint, and none is needed. The destroy removes the SNS topic;
        # Captain detects the dead event source and reconcile remains the
        # backstop. Return verified=true so the destroy-time postcondition
        # (if evaluated) passes.
        log("teardown", note="no unsubscribe call; Captain detects the removed topic")
        return {"verified": True, "deploymentId": dep_id,
                "action": "delete", "status": "torn_down"}

    problems = preflight(event)
    if problems:
        reason = "preflight failed: " + "; ".join(problems)
        log("preflight-failed", problems=problems)
        return {"verified": False, "deploymentId": dep_id, "error": reason}

    try:
        status, resp = register_webhook(
            event.get("CaptainApiBase"), event.get("CaptainApiKey"),
            event.get("SyncId"), event.get("SnsTopicArn"))
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8", "replace")[:400]
        except Exception:
            pass
        log("http-error", code=e.code, detail=detail)
        return {"verified": False, "deploymentId": dep_id, "httpStatus": e.code,
                "error": "Captain API returned HTTP %s: %s" % (e.code, detail)}
    except Exception as e:
        log("unhandled-error", error=str(e))
        return {"verified": False, "deploymentId": dep_id,
                "error": "Could not reach the Captain API: %s" % e}

    subscribe_url = resp.get("subscribe_url")
    verified = bool(200 <= status < 300 and subscribe_url)
    log("result", verified=verified, httpStatus=status)
    return {
        "verified": verified,
        "deploymentId": dep_id,
        "httpStatus": status,
        "subscribeUrl": subscribe_url,
        "secretSet": resp.get("secret_set"),
        "instructions": resp.get("instructions"),
        "error": None if verified else (
            "Captain returned HTTP %s without a subscribe_url" % status),
    }
