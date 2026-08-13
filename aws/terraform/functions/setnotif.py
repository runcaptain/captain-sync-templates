# Captain S3 sync: additive bucket-notification setter (Terraform variant).
#
# Invoked by the aws_lambda_invocation resource with lifecycle_scope = "CRUD",
# so Terraform calls this on create, update, AND destroy. The action is in
# event["tf"]["action"].
#
# WHY a Lambda instead of Terraform's aws_s3_bucket_notification resource:
# that resource is AUTHORITATIVE, it owns the bucket's single notification
# configuration and would silently wipe any SNS/SQS/Lambda/EventBridge hooks the
# customer already has. This function does an ADDITIVE read-merge-write instead:
# it appends only our TopicConfiguration (Id = captain-<syncId>, unique per sync)
# and on destroy removes only ours, leaving every sibling hook untouched. That
# matches the CloudFormation custom resource exactly.
#
# CONFIRMED LIMIT (adversarial testing): "additive" only works when it does not
# collide with what is already there. A bucket has exactly ONE notification
# configuration, and S3 itself rejects PutBucketNotificationConfiguration with
# InvalidArgument "Configurations overlap" whenever our new config's event type
# (ObjectCreated/ObjectRemoved) overlaps an EXISTING hook's event type on an
# overlapping prefix. A whole-bucket sync (empty prefix) overlaps ANY existing
# ObjectCreated/ObjectRemoved hook. So before writing, this function reads the
# existing config and checks for that overlap itself, and fails fast with a
# specific, actionable error (naming the conflicting hook's id/event/prefix)
# instead of letting S3's opaque InvalidArgument surface. This fails SAFE
# either way -- the PUT is atomic, so a rejected/skipped write never touches
# the existing config -- but the deploy itself does not succeed for a bucket
# that already has an overlapping hook. The only way out today is a
# non-overlapping object_prefix; see ../../../NOTES.md.
#
# Heavy, structured, single-line logging under the CAPTAIN-SETNOTIF prefix.
import json
import os

import boto3

DEBUG = os.environ.get("CAPTAIN_DEBUG", "true").lower() == "true"
s3 = boto3.client("s3")

# Event types our own notification config always registers. Any existing hook
# whose Events include one of these (as a prefix match, so "s3:ObjectCreated:Put"
# matches "s3:ObjectCreated") shares an event category with ours.
OUR_EVENT_PREFIXES = ("s3:ObjectCreated", "s3:ObjectRemoved")


def log(tag, **kw):
    if not DEBUG and tag.endswith("-debug"):
        return
    print("CAPTAIN-SETNOTIF %s %s" % (tag, json.dumps(kw, default=str)))


def _prefixes_overlap(a, b):
    # Two S3 key prefixes overlap if one is a prefix of the other (an empty
    # prefix -- "whole bucket" -- is a prefix of everything, so it overlaps
    # any other prefix too).
    return a.startswith(b) or b.startswith(a)


def find_notification_conflict(cfg, config_id, prefix):
    """Look for an EXISTING notification config (not ours) whose event type
    overlaps ours (ObjectCreated/ObjectRemoved) on a prefix that overlaps
    `prefix`. S3 rejects PutBucketNotificationConfiguration with InvalidArgument
    "Configurations overlap" in that case, so we check BEFORE writing instead of
    letting the PUT fail opaquely.

    Returns (existing_id, conflicting_event, existing_prefix) or None.
    """
    all_configs = (
        list(cfg.get("TopicConfigurations") or [])
        + list(cfg.get("QueueConfigurations") or [])
        + list(cfg.get("LambdaFunctionConfigurations") or [])
    )
    for entry in all_configs:
        if entry.get("Id") == config_id:
            continue  # our own prior config; about to be replaced, not a conflict
        existing_prefix = ""
        rules = ((entry.get("Filter") or {}).get("Key") or {}).get("FilterRules") or []
        for rule in rules:
            if (rule.get("Name") or "").lower() == "prefix":
                existing_prefix = rule.get("Value") or ""
        conflicting_events = [
            e for e in (entry.get("Events") or []) if e.startswith(OUR_EVENT_PREFIXES)
        ]
        if conflicting_events and _prefixes_overlap(prefix, existing_prefix):
            return entry.get("Id", "<unknown>"), conflicting_events[0], existing_prefix
    return None


def handler(event, context):
    action = (event.get("tf") or {}).get("action", "create")
    bucket = event.get("BucketName")
    topic = event.get("TopicArn")
    config_id = event.get("ConfigId") or "captain-sync"
    prefix = event.get("ObjectPrefix") or ""
    log("invoke", action=action, bucket=bucket, topic=topic,
        configId=config_id, prefix=prefix,
        logStream=getattr(context, "log_stream_name", None))

    try:
        if not bucket or not topic:
            raise ValueError("missing BucketName or TopicArn in event")
        cfg = s3.get_bucket_notification_configuration(Bucket=bucket)
        cfg.pop("ResponseMetadata", None)
        existing = cfg.get("TopicConfigurations", [])
        # Log the full shape so a customer can see we preserve siblings.
        log("existing-config",
            topicConfigs=len(existing),
            queueConfigs=len(cfg.get("QueueConfigurations", [])),
            lambdaConfigs=len(cfg.get("LambdaFunctionConfigurations", [])),
            eventBridge=("EventBridgeConfiguration" in cfg))
        topics = [t for t in existing if t.get("Id") != config_id]
        removed = len(existing) - len(topics)  # prior copies of ours

        if action in ("create", "update"):
            conflict = find_notification_conflict(cfg, config_id, prefix)
            if conflict is not None:
                conflict_id, conflict_event, conflict_prefix = conflict
                msg = (
                    "Existing notification config %r on this bucket already "
                    "handles %s on prefix %r, which overlaps the prefix %r this "
                    "sync would write. S3 does not allow two notification "
                    "configs with overlapping event types on overlapping "
                    "prefixes (PutBucketNotificationConfiguration rejects it "
                    "with InvalidArgument: Configurations overlap). Set a "
                    "non-overlapping object_prefix for this sync (see NOTES.md)."
                    % (conflict_id, conflict_event, conflict_prefix, prefix)
                )
                log("overlap-conflict", conflictId=conflict_id,
                    conflictEvent=conflict_event, conflictPrefix=conflict_prefix,
                    ourPrefix=prefix)
                raise ValueError(msg)
            entry = {
                "Id": config_id,
                "TopicArn": topic,
                "Events": ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"],
            }
            if prefix:
                entry["Filter"] = {"Key": {"FilterRules": [
                    {"Name": "prefix", "Value": prefix}]}}
            topics.append(entry)
            log("merged", oursAdded=1, siblingsPreserved=len(topics) - 1,
                priorCopiesReplaced=removed)
        else:  # delete: do not re-add ours -> it is removed.
            log("removing-ours", siblingsPreserved=len(topics),
                oursRemoved=removed)

        if topics:
            cfg["TopicConfigurations"] = topics
        else:
            cfg.pop("TopicConfigurations", None)
        s3.put_bucket_notification_configuration(
            Bucket=bucket, NotificationConfiguration=cfg)
        log("put-ok")

        siblings = len([t for t in topics if t.get("Id") != config_id])
        return {"ok": True, "action": action, "configId": config_id,
                "siblingsPreserved": siblings, "prefix": prefix}
    except Exception as e:
        log("error", action=action, error=str(e))
        # On destroy, never fail the run on a teardown error.
        if action == "delete":
            return {"ok": True, "action": "delete", "tolerated_error": str(e)}
        return {"ok": False, "action": action, "error": str(e)}
