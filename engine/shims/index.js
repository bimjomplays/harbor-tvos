// Installs every polyfill JavaScriptCore lacks onto the global object. This module MUST be
// the first import of engine/entry.ts: esbuild keeps import order, so it runs before any
// upstream module's top-level code.
//
// JSC on tvOS gives us the full ECMAScript library (including Intl and Promise) and nothing
// else: no fetch, no URL, no TextEncoder, no timers, no crypto, no storage, no DOM.
import "core-js/web/url";
import "core-js/web/url-search-params";

import { hostCall, hostHas, missingHostFunctions, HOST_FUNCTIONS } from "./host.js";
import { TextDecoderShim, TextEncoderShim } from "./text.js";
import { atobShim, btoaShim, base64ToBytes, bytesToBase64 } from "./base64.js";
import {
  AbortControllerShim,
  AbortSignalShim,
  CustomEventShim,
  DOMExceptionShim,
  EventShim,
  EventTargetShim,
  setListenerErrorSink,
} from "./events.js";
import { createCrypto, sha256 } from "./crypto.js";
import { createLocalStorage } from "./storage.js";
import { installTimers } from "./timers.js";
import { fetchShim, HeadersShim, RequestShim, ResponseShim } from "./fetch.js";
import { createDom } from "./dom.js";
import { installWebSocket, WS_HOST_FUNCTIONS } from "./websocket.js";

const g = globalThis;
const define = (name, value) => {
  if (g[name] === undefined) g[name] = value;
};

// --- console first, so anything below can report ---------------------------------------
const levels = ["log", "info", "warn", "error", "debug", "trace"];
const nativeConsole = g.console;
const consoleShim = {};
for (const level of levels) {
  consoleShim[level] = (...args) => {
    const msg = args
      .map((a) => {
        if (typeof a === "string") return a;
        if (a instanceof Error) return a.stack || `${a.name}: ${a.message}`;
        try {
          return JSON.stringify(a);
        } catch {
          return String(a);
        }
      })
      .join(" ");
    if (hostHas("log")) {
      try {
        hostCall("log", level === "debug" || level === "trace" ? "debug" : level, msg);
        return;
      } catch {}
    }
    if (nativeConsole && typeof nativeConsole[level] === "function") nativeConsole[level](...args);
  };
}
consoleShim.group = consoleShim.log;
consoleShim.groupEnd = () => {};
consoleShim.table = consoleShim.log;
consoleShim.time = () => {};
consoleShim.timeEnd = () => {};
consoleShim.assert = (cond, ...rest) => {
  if (!cond) consoleShim.error("assertion failed:", ...rest);
};
g.console = consoleShim;

// --- text / base64 ----------------------------------------------------------------------
define("TextEncoder", TextEncoderShim);
define("TextDecoder", TextDecoderShim);
define("atob", atobShim);
define("btoa", btoaShim);

// --- events -----------------------------------------------------------------------------
define("Event", EventShim);
define("CustomEvent", CustomEventShim);
define("EventTarget", EventTargetShim);
define("DOMException", DOMExceptionShim);
define("AbortController", AbortControllerShim);
define("AbortSignal", AbortSignalShim);
setListenerErrorSink((e) => consoleShim.error("event listener threw", e));

// --- timers -------------------------------------------------------------------------------
const timers = installTimers(g);

// --- clocks -------------------------------------------------------------------------------
const bootWall = hostHas("now") ? hostCall("now") : Date.now();
define("performance", {
  now: () => (hostHas("now") ? hostCall("now") : Date.now()) - bootWall,
  timeOrigin: bootWall,
  mark: () => {},
  measure: () => {},
  getEntriesByName: () => [],
  clearMarks: () => {},
  clearMeasures: () => {},
});

// --- crypto -------------------------------------------------------------------------------
define("crypto", createCrypto());

// --- storage ------------------------------------------------------------------------------
const localStorage = createLocalStorage();
define("localStorage", localStorage);
define("sessionStorage", createLocalStorage());

// --- network ------------------------------------------------------------------------------
define("Headers", HeadersShim);
define("Request", RequestShim);
define("Response", ResponseShim);
define("fetch", fetchShim);

// --- WebSocket (optional host functions; see websocket.js) ------------------------------------
const sockets = installWebSocket(g);

// --- structuredClone ------------------------------------------------------------------------
define("structuredClone", (value) => {
  // JSON round-trip: enough for the plain data (metas, settings, catalogs) this bundle
  // clones. It throws on Map/Set/Date-sensitive input rather than silently degrading.
  if (value === undefined) return undefined;
  const seen = new WeakSet();
  const check = (v) => {
    if (v === null || typeof v !== "object") return;
    if (v instanceof Date || v instanceof Map || v instanceof Set || ArrayBuffer.isView(v) || v instanceof ArrayBuffer) {
      throw new Error("HarborEngine structuredClone: only JSON-shaped values are supported");
    }
    if (seen.has(v)) throw new DOMExceptionShim("cyclic value", "DataCloneError");
    seen.add(v);
    for (const k of Object.keys(v)) check(v[k]);
    seen.delete(v);
  };
  check(value);
  return JSON.parse(JSON.stringify(value));
});

// --- DOM-ish --------------------------------------------------------------------------------
const dom = createDom(g);
define("window", dom.window);
define("document", dom.document);
define("location", dom.location);
define("navigator", dom.navigator);
define("self", g);

export const shims = {
  events: dom.events,
  lifecycle: dom.lifecycle,
  localStorage,
  sha256,
  bytesToBase64,
  base64ToBytes,
  timers,
  hostFunctions: HOST_FUNCTIONS,
  missingHostFunctions,
  sockets,
  /** Optional host functions this host lacks (WebSocket); boot does not require them. */
  missingOptionalHostFunctions: () => WS_HOST_FUNCTIONS.filter((n) => !hostHas(n)),
};
