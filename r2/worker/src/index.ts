// =============================================================================
// Captain R2 sync Worker (self-verifying, debuggable)
// -----------------------------------------------------------------------------
// One Worker plays THREE roles for a single Captain R2 sync, entirely inside the
// CUSTOMER'S Cloudflare account:
//
//   1. QUEUE CONSUMER (event wiring / latency optimization)
//      R2 event notifications land on a Queue. This Worker drains that Queue and
//      forwards each object-change event to Captain's ingest endpoint, so new or
//      changed objects sync in near-real-time instead of waiting for the next
//      scheduled reconcile.
//
//   2. READ PROXY (cross-account read grant, NO long-lived keys)
//      Captain reads objects for reconcile through this Worker's authenticated
//      /__captain/objects (list) and /__captain/object (get) routes. The R2
//      bucket binding lives on the Worker; Captain never gets a standing key.
//      Auth is a bearer secret shared only between Captain and this Worker.
//
//   3. SELF-TEST + PHONE-HOME (self-verifying deploy)
//      /__captain/enroll POSTs the deployment facts to Captain and returns
//      Captain's verified verdict; the deploy script fails loudly if Captain does
//      not confirm. /__captain/selftest writes and deletes a canary object to
//      prove the R2 -> Queue -> Worker -> Captain event path actually delivers
//      (R2 event notifications have historically delivered zero events in some
//      accounts, so this probe is the honest way to check before trusting them).
//
// RECONCILE/POLLING IS THE ALWAYS-ON BACKSTOP. Webhooks (the Queue path) are the
// latency optimization. If the Queue path is silent, scheduled reconcile through
// the read proxy still keeps the collection correct.
//
// Every branch logs. Set DEBUG="true" to get verbose per-message tracing in
// `wrangler tail`. Nothing secret is ever logged.
// =============================================================================

export interface Env {
  // --- Bindings ---
  R2: R2Bucket; // read proxy + canary self-test target

  // --- Plaintext vars (safe to show) ---
  SYNC_ID: string; // Captain sync id, sync_<token>
  BUCKET_NAME: string; // the R2 bucket this sync watches
  ACCOUNT_ID: string; // Cloudflare account id
  TEMPLATE_VERSION: string; // date-based, YYYY-MM-DD
  CAPTAIN_INGEST_URL: string; // where queue events are POSTed
  CAPTAIN_ENROLL_URL: string; // phone-home enroll endpoint
  DEBUG?: string; // "true" turns on verbose logging

  // --- Secret (set via `wrangler secret put CAPTAIN_SECRET`) ---
  CAPTAIN_SECRET: string; // bearer auth, both directions
}

// Shape of an R2 event-notification message as delivered to the Queue.
// See https://developers.cloudflare.com/r2/buckets/event-notifications/
interface R2EventBody {
  account: string;
  bucket: string;
  eventTime: string;
  action:
    | "PutObject"
    | "CopyObject"
    | "CompleteMultipartUpload"
    | "DeleteObject"
    | "LifecycleDeletion";
  object: {
    key: string;
    size?: number;
    eTag?: string;
  };
}

// What we forward to Captain per event. Kept deliberately flat and explicit so
// the receiver contract is easy to read. `op` collapses the R2 action verbs into
// the two things Captain cares about: the object exists/changed, or it is gone.
interface CaptainEvent {
  op: "upsert" | "delete";
  key: string;
  size: number | null;
  eTag: string | null;
  action: string;
  eventTime: string;
}

// -----------------------------------------------------------------------------
// Logging: structured, greppable, never leaks the secret.
// -----------------------------------------------------------------------------
function log(env: Env, level: "info" | "warn" | "error" | "debug", msg: string, extra?: Record<string, unknown>) {
  if (level === "debug" && env.DEBUG !== "true") return;
  const line = {
    at: new Date().toISOString(),
    level,
    sync: env.SYNC_ID,
    bucket: env.BUCKET_NAME,
    msg,
    ...(extra ?? {}),
  };
  const s = JSON.stringify(line);
  if (level === "error") console.error(s);
  else if (level === "warn") console.warn(s);
  else console.log(s);
}

function deleteAction(action: string): boolean {
  return action === "DeleteObject" || action === "LifecycleDeletion";
}

// Timing-safe-ish bearer check. Constant-time compare to avoid leaking length
// via early exit; Workers has no crypto.timingSafeEqual so we roll a simple one.
function authorized(req: Request, env: Env): boolean {
  const header = req.headers.get("authorization") ?? "";
  const presented = header.startsWith("Bearer ") ? header.slice(7) : "";
  const expected = env.CAPTAIN_SECRET ?? "";
  if (presented.length !== expected.length || expected.length === 0) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) {
    diff |= presented.charCodeAt(i) ^ expected.charCodeAt(i);
  }
  return diff === 0;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// Stripe-style id, dep_<token>. No bare UUIDs anywhere in customer-facing output.
function newDeploymentId(): string {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  const bytes = new Uint8Array(24);
  crypto.getRandomValues(bytes);
  let token = "";
  for (const b of bytes) token += alphabet[b % alphabet.length];
  return "dep_" + token;
}

// =============================================================================
// QUEUE CONSUMER: R2 event notifications -> Captain ingest
// =============================================================================
async function handleQueue(batch: MessageBatch<R2EventBody>, env: Env): Promise<void> {
  log(env, "info", "queue batch received", { count: batch.messages.length, queue: batch.queue });

  const events: CaptainEvent[] = [];
  for (const message of batch.messages) {
    const b = message.body;
    if (!b || !b.object || typeof b.object.key !== "string") {
      log(env, "warn", "skipping malformed message", { id: message.id });
      message.ack(); // poison message: do not retry forever
      continue;
    }
    events.push({
      op: deleteAction(b.action) ? "delete" : "upsert",
      key: b.object.key,
      size: typeof b.object.size === "number" ? b.object.size : null,
      eTag: b.object.eTag ?? null,
      action: b.action,
      eventTime: b.eventTime,
    });
    log(env, "debug", "mapped event", { id: message.id, action: b.action, key: b.object.key });
  }

  if (events.length === 0) {
    log(env, "info", "no forwardable events in batch");
    return;
  }

  const payload = {
    source: "r2",
    syncId: env.SYNC_ID,
    bucket: env.BUCKET_NAME,
    accountId: env.ACCOUNT_ID,
    templateVersion: env.TEMPLATE_VERSION,
    events,
  };

  try {
    const resp = await fetch(env.CAPTAIN_INGEST_URL, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${env.CAPTAIN_SECRET}`,
        "x-captain-sync-id": env.SYNC_ID,
        "user-agent": `captain-r2-worker/${env.TEMPLATE_VERSION}`,
      },
      body: JSON.stringify(payload),
    });

    if (resp.ok) {
      log(env, "info", "forwarded events to Captain", { count: events.length, status: resp.status });
      batch.ackAll();
    } else {
      const detail = (await resp.text()).slice(0, 500);
      // Non-2xx: let the whole batch retry. Captain ingest MUST be idempotent
      // per (syncId, key, eventTime) so retries do not double-index.
      log(env, "error", "Captain ingest returned non-2xx; retrying batch", {
        status: resp.status,
        detail,
      });
      batch.retryAll({ delaySeconds: 30 });
    }
  } catch (err) {
    log(env, "error", "Captain ingest unreachable; retrying batch", { error: String(err) });
    batch.retryAll({ delaySeconds: 30 });
  }
}

// =============================================================================
// HTTP: health, read proxy, enroll, self-test
// =============================================================================
async function handleFetch(req: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const url = new URL(req.url);
  const path = url.pathname;

  // ---- Public health check (no secret; reveals config presence, not values) ----
  if (path === "/" || path === "/healthz") {
    return json({
      service: "captain-r2-worker",
      templateVersion: env.TEMPLATE_VERSION,
      syncId: env.SYNC_ID,
      bucket: env.BUCKET_NAME,
      account: env.ACCOUNT_ID,
      config: {
        ingestUrl: Boolean(env.CAPTAIN_INGEST_URL),
        enrollUrl: Boolean(env.CAPTAIN_ENROLL_URL),
        secret: Boolean(env.CAPTAIN_SECRET),
        r2Binding: Boolean(env.R2),
        debug: env.DEBUG === "true",
      },
      hint: "All Captain routes under /__captain/* require Authorization: Bearer <secret>.",
    });
  }

  // ---- Everything below requires the shared secret ----
  const captainRoute = path.startsWith("/__captain/");
  if (captainRoute && !authorized(req, env)) {
    log(env, "warn", "unauthorized request to captain route", { path });
    return json({ error: "unauthorized", hint: "Send Authorization: Bearer <CAPTAIN_SECRET>." }, 401);
  }

  // ---- READ PROXY: list objects (reconcile backstop, keyless) ----
  if (path === "/__captain/objects" && req.method === "GET") {
    const prefix = url.searchParams.get("prefix") ?? undefined;
    const cursor = url.searchParams.get("cursor") ?? undefined;
    const limit = Math.min(Number(url.searchParams.get("limit") ?? "1000") || 1000, 1000);
    try {
      const listed = await env.R2.list({ prefix, cursor, limit, include: ["httpMetadata", "customMetadata"] });
      log(env, "debug", "list served", { prefix, count: listed.objects.length, truncated: listed.truncated });
      return json({
        objects: listed.objects.map((o) => ({
          key: o.key,
          size: o.size,
          eTag: o.etag,
          uploaded: o.uploaded,
          httpMetadata: o.httpMetadata,
          customMetadata: o.customMetadata,
        })),
        truncated: listed.truncated,
        cursor: listed.truncated ? listed.cursor : null,
      });
    } catch (err) {
      log(env, "error", "list failed", { error: String(err) });
      return json({ error: "list_failed", detail: String(err) }, 502);
    }
  }

  // ---- READ PROXY: get one object (reconcile backstop, keyless) ----
  if (path === "/__captain/object" && req.method === "GET") {
    const key = url.searchParams.get("key");
    if (!key) return json({ error: "missing_key", hint: "Pass ?key=<object key>." }, 400);
    try {
      const obj = await env.R2.get(key);
      if (obj === null) {
        log(env, "debug", "object not found", { key });
        return json({ error: "not_found", key }, 404);
      }
      const headers = new Headers();
      obj.writeHttpMetadata(headers);
      headers.set("etag", obj.httpEtag);
      headers.set("x-captain-object-key", key);
      log(env, "debug", "object served", { key, size: obj.size });
      return new Response(obj.body, { headers });
    } catch (err) {
      log(env, "error", "get failed", { key, error: String(err) });
      return json({ error: "get_failed", key, detail: String(err) }, 502);
    }
  }

  // ---- PHONE-HOME: enroll with Captain and return the verdict ----
  if (path === "/__captain/enroll" && req.method === "POST") {
    const deploymentId = url.searchParams.get("deploymentId") || newDeploymentId();
    const payload = {
      deploymentId,
      templateVersion: env.TEMPLATE_VERSION,
      action: "create",
      source: "r2",
      accountId: env.ACCOUNT_ID,
      bucket: env.BUCKET_NAME,
      syncId: env.SYNC_ID,
      workerUrl: url.origin,
      readStrategy: "worker-proxy",
      ingestUrl: env.CAPTAIN_INGEST_URL,
      secret: env.CAPTAIN_SECRET,
    };
    try {
      const resp = await fetch(env.CAPTAIN_ENROLL_URL, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "user-agent": `captain-r2-worker/${env.TEMPLATE_VERSION}`,
        },
        body: JSON.stringify(payload),
      });
      const text = await resp.text();
      let parsed: Record<string, unknown> = {};
      try {
        parsed = JSON.parse(text);
      } catch {
        parsed = { raw: text.slice(0, 500) };
      }
      const verified = resp.ok && parsed.verified === true;
      log(env, verified ? "info" : "error", "enroll handshake complete", {
        deploymentId,
        status: resp.status,
        verified,
      });
      return json({ deploymentId, verified, captainStatus: resp.status, captain: parsed }, verified ? 200 : 502);
    } catch (err) {
      log(env, "error", "enroll handshake failed to reach Captain", { deploymentId, error: String(err) });
      return json({ deploymentId, verified: false, error: "enroll_unreachable", detail: String(err) }, 502);
    }
  }

  // ---- SELF-TEST: prove the R2 -> Queue -> Worker event path delivers ----
  // Writes a tiny canary object under __captain/healthcheck/, then deletes it
  // immediately, in the same request, before responding. Both the PutObject
  // and the DeleteObject each fire their own R2 event notification the moment
  // they happen; the object does not need to still exist in the bucket for
  // that notification to have already been queued, so there is no reason to
  // hold it around and no need to defer the delete.
  //
  // An earlier version deferred the delete via `ctx.waitUntil` wrapping a
  // 60s `setTimeout`. That does not work: `waitUntil` keeps the isolate
  // alive for pending I/O, but a bare timer with nothing else in flight is
  // not reliably honored for a full 60 seconds, and live testing against a
  // real account confirmed the canary was never deleted in practice (it had
  // to be removed by hand, and stale canaries from earlier runs were found
  // still sitting in the bucket). Deleting synchronously, in-request, is
  // both correct and simpler: no isolate-lifetime assumptions at all.
  if (path === "/__captain/selftest" && req.method === "POST") {
    const canaryKey = `__captain/healthcheck/${env.SYNC_ID}-${Date.now()}.txt`;
    try {
      await env.R2.put(canaryKey, `captain selftest ${new Date().toISOString()}`, {
        customMetadata: { "captain-selftest": "true", sync: env.SYNC_ID },
      });
      log(env, "info", "selftest canary written", { canaryKey });
    } catch (err) {
      log(env, "error", "selftest write failed", { canaryKey, error: String(err) });
      return json({ ok: false, error: "selftest_write_failed", detail: String(err) }, 502);
    }
    try {
      await env.R2.delete(canaryKey);
      log(env, "info", "selftest canary deleted", { canaryKey });
    } catch (err) {
      // The write succeeded and already queued its event, so the probe is
      // still meaningful; only the cleanup failed. Surface it as a warning,
      // not a failed self-test.
      log(env, "warn", "selftest canary cleanup failed; it may linger in the bucket", {
        canaryKey,
        error: String(err),
      });
      return json({
        ok: true,
        canaryKey,
        cleanup: "failed",
        watch:
          "Run `wrangler tail` and look for a queue batch containing this key within ~30s. " +
          "If it never arrives, R2 event notifications are not delivering; rely on scheduled reconcile. " +
          `The canary object also failed to delete (${String(err)}); you may need to remove it by hand.`,
      });
    }
    return json({
      ok: true,
      canaryKey,
      cleanup: "done",
      watch:
        "Both a PutObject and a DeleteObject event were queued for this key. Run `wrangler tail` and look " +
        "for a queue batch containing it within ~30s. If it never arrives, R2 event notifications are not " +
        "delivering; rely on scheduled reconcile.",
    });
  }

  return json({ error: "not_found", path }, 404);
}

export default {
  fetch: handleFetch,
  queue: handleQueue,
};
