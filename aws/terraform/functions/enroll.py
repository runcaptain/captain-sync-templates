# Captain S3 sync: self-verifying phone-home (Terraform variant).
#
# Invoked by the aws_lambda_invocation resource with lifecycle_scope = "CRUD",
# so Terraform calls this on create, update, AND destroy. The action is in
# event["tf"]["action"]. Unlike the CloudFormation variant, there is no
# CloudFormation response URL to answer: Terraform reads this function's RETURN
# value and a postcondition asserts result.verified == true, so an unverified
# enrollment fails `terraform apply` the same way a bad handshake rolls back a
# CloudFormation stack.
#
# Heavy, structured, single-line logging under the CAPTAIN-ENROLL prefix. The
# one-time Secret is NEVER logged (redacted to its length).
import json
import os
import secrets
import string
import urllib.error
import urllib.request

DEBUG = os.environ.get("CAPTAIN_DEBUG", "true").lower() == "true"
ALPHABET = string.ascii_letters + string.digits
REDACT = ("secret", "Secret")
TEMPLATE_VERSION = "2026-08-12"


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


def phone_home(url, payload):
    data = json.dumps(payload).encode()
    log("phone-home-post", url=url, bytes=len(data),
        deploymentId=payload.get("deploymentId"), syncId=payload.get("syncId"),
        bucket=payload.get("bucket"), region=payload.get("region"),
        action=payload.get("action"), secret=payload.get("secret"))
    req = urllib.request.Request(
        url, data=data, method="POST",
        headers={"content-type": "application/json",
                 "user-agent": "captain-tf-enroll/%s" % TEMPLATE_VERSION})
    with urllib.request.urlopen(req, timeout=45) as resp:
        raw = resp.read().decode("utf-8", "replace")
        status = getattr(resp, "status", 200)
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = {"raw": raw[:512]}
        log("phone-home-response", httpStatus=status, body=parsed)
        return status, parsed


def preflight(event):
    # Human-readable validation. Returned problems become the Terraform
    # postcondition error message (result.error) verbatim.
    problems = []
    url = event.get("CaptainCallbackUrl") or ""
    if not url.startswith("https://"):
        problems.append("CaptainCallbackUrl must be https:// (got %r)" % url[:48])
    for key in ("BucketName", "SnsTopicArn", "RoleArn",
                "ExternalId", "SyncId", "Secret"):
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

    base = {
        "deploymentId": dep_id,
        "templateVersion": TEMPLATE_VERSION,
        "action": action,
        "partition": event.get("Partition"),
        "region": event.get("Region"),
        "bucket": event.get("BucketName"),
        "objectPrefix": event.get("ObjectPrefix") or "",
        "kmsKeyArn": event.get("KmsKeyArn") or "",
        "snsTopicArn": event.get("SnsTopicArn"),
        "roleArn": event.get("RoleArn"),
        "externalId": event.get("ExternalId"),
        "syncId": event.get("SyncId"),
        "secret": event.get("Secret"),
    }
    url = event.get("CaptainCallbackUrl")

    if action == "delete":
        # Best-effort teardown notice; never fail a destroy on it. Return
        # verified=true so the destroy-time postcondition (if evaluated) passes.
        try:
            phone_home(url, {**base, "action": "delete"})
        except Exception as e:
            log("teardown-notice-failed-tolerated", error=str(e))
        return {"verified": True, "deploymentId": dep_id,
                "action": "delete", "status": "torn_down"}

    problems = preflight(event)
    if problems:
        reason = "preflight failed: " + "; ".join(problems)
        log("preflight-failed", problems=problems)
        return {"verified": False, "deploymentId": dep_id, "error": reason}

    try:
        status, resp = phone_home(url, base)
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8", "replace")[:400]
        except Exception:
            pass
        log("http-error", code=e.code, detail=detail)
        return {"verified": False, "deploymentId": dep_id, "httpStatus": e.code,
                "error": "Captain callback returned HTTP %s: %s" % (e.code, detail)}
    except Exception as e:
        log("unhandled-error", error=str(e))
        return {"verified": False, "deploymentId": dep_id,
                "error": "Could not reach Captain callback: %s" % e}

    ok = isinstance(resp, dict) and resp.get("verified") is True
    verified = bool(200 <= status < 300 and ok)
    log("result", verified=verified, httpStatus=status)
    return {
        "verified": verified,
        "deploymentId": dep_id,
        "httpStatus": status,
        "captainStatus": (resp or {}).get("status"),
        "captainResponse": resp,
        "error": None if verified else (
            "Captain did not confirm enrollment (http %s, verified=%s)"
            % (status, ok)),
    }
