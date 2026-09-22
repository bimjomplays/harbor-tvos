// Access to the native host bridge. On tvOS Swift installs `__harbor_host` on the
// JSContext global BEFORE this bundle is evaluated; on Node `shims/node-host.mjs` does
// the same. Every function is listed in docs/engine-report.md.
//
// Nothing here invents a fallback: if the host is missing a function the call throws, so
// a module can never think a request/read succeeded when it did not.

export const HOST_FUNCTIONS = [
  "fetch",
  "abort",
  "storageSnapshot",
  "storageGet",
  "storageSet",
  "storageRemove",
  "storageClear",
  "now",
  "randomUUID",
  "randomBytes",
  "log",
  "setTimeout",
  "clearTimeout",
];

/** @returns {Record<string, Function>} */
export function host() {
  const h = globalThis.__harbor_host;
  if (!h || typeof h !== "object") {
    throw new Error(
      "HarborEngine: __harbor_host is not installed. The native side must set globalThis.__harbor_host " +
        "before evaluating harbor-engine.js (see docs/engine-report.md).",
    );
  }
  return h;
}

export function hostCall(name, ...args) {
  const h = host();
  const fn = h[name];
  if (typeof fn !== "function") {
    throw new Error(`HarborEngine: __harbor_host.${name}() is not implemented by the host`);
  }
  return fn.apply(h, args);
}

export function hostHas(name) {
  const h = globalThis.__harbor_host;
  return !!h && typeof h[name] === "function";
}

/** Reports what the host is missing; used by HarborEngine.hostReport(). */
export function missingHostFunctions() {
  const h = globalThis.__harbor_host;
  if (!h) return HOST_FUNCTIONS.slice();
  return HOST_FUNCTIONS.filter((n) => typeof h[n] !== "function");
}
