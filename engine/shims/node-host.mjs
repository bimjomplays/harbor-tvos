// The __harbor_host contract implemented on Node, so `node smoke.mjs` exercises the exact
// same bundle Swift will load. Swift's implementation must match the semantics documented
// in docs/engine-report.md.
import { randomBytes, randomUUID } from "node:crypto";
import { LAZY_PREFIXES } from "./storage.js";

/**
 * @param {{storage?: Map<string,string>, log?: (level: string, msg: string) => void,
 *          offline?: boolean, onFetch?: (req: any) => void}} [options]
 */
export function createNodeHost(options = {}) {
  const storage = options.storage ?? new Map();
  const timers = new Map();
  const inflight = new Map();
  /** @type {{requests: number, bytes: number}} */
  const stats = { requests: 0, bytes: 0 };
  let fire = null;

  const host = {
    // ---- network ----
    async fetch(req) {
      stats.requests++;
      if (options.onFetch) options.onFetch(req);
      if (options.offline) throw new Error("offline (node-host)");
      const controller = new AbortController();
      inflight.set(req.requestId, controller);
      const timeout = setTimeout(() => controller.abort(), req.timeoutMs || 30000);
      try {
        const body =
          req.bodyBase64 != null
            ? Buffer.from(req.bodyBase64, "base64")
            : req.body != null
              ? req.body
              : undefined;
        const res = await fetch(req.url, {
          method: req.method,
          headers: req.headers,
          body,
          redirect: req.redirect === "manual" || req.redirect === "error" ? "manual" : "follow",
          signal: controller.signal,
        });
        const buf = Buffer.from(await res.arrayBuffer());
        stats.bytes += buf.length;
        const headers = {};
        res.headers.forEach((v, k) => {
          headers[k] = v;
        });
        const wantsBase64 = req.responseType === "base64";
        return {
          status: res.status,
          statusText: res.statusText,
          headers,
          url: res.url,
          redirected: res.redirected,
          body: wantsBase64 ? null : buf.toString("utf8"),
          bodyBase64: wantsBase64 ? buf.toString("base64") : null,
        };
      } finally {
        clearTimeout(timeout);
        inflight.delete(req.requestId);
      }
    },
    abort(requestId) {
      const c = inflight.get(requestId);
      if (c) c.abort();
    },

    // ---- storage ----
    // Like KeyValueStore.snapshot(): the lazy namespaces are read with storageGet when asked for.
    storageSnapshot() {
      return Object.fromEntries([...storage].filter(([k]) => !LAZY_PREFIXES.some((p) => k.startsWith(p))));
    },
    storageGet(key) {
      return storage.has(key) ? storage.get(key) : null;
    },
    storageSet(key, value) {
      storage.set(key, value);
    },
    storageRemove(key) {
      storage.delete(key);
    },
    storageClear() {
      storage.clear();
    },

    // ---- clock / entropy ----
    now() {
      return Date.now();
    },
    randomUUID() {
      return randomUUID();
    },
    randomBytes(n) {
      return randomBytes(n).toString("base64");
    },

    // ---- logging ----
    log(level, msg) {
      if (options.log) options.log(level, msg);
      else if (level === "error" || level === "warn") console.error(`[engine:${level}] ${msg}`);
    },

    // ---- timers ----
    setTimeout(ms, id) {
      const t = setTimeout(() => {
        timers.delete(id);
        if (fire) fire(id);
      }, ms);
      timers.set(id, t);
    },
    clearTimeout(id) {
      const t = timers.get(id);
      if (t !== undefined) {
        clearTimeout(t);
        timers.delete(id);
      }
    },
  };

  return {
    host,
    storage,
    stats,
    /** The host must be told how to call back into the bundle when a timer fires. */
    bindTimerFire(fn) {
      fire = fn;
    },
    /** Cancels anything still pending so Node can exit. */
    dispose() {
      for (const t of timers.values()) clearTimeout(t);
      timers.clear();
      for (const c of inflight.values()) c.abort();
      inflight.clear();
    },
  };
}
