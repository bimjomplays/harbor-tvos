// Headers / Request / Response / fetch over __harbor_host.fetch.
//
// The host does the actual HTTP (NSURLSession on tvOS, undici on Node). Bodies cross the
// bridge as strings: text for anything textual, base64 when the caller asked for bytes or
// the response is not decodable as UTF-8. Nothing here fakes a response: a host failure
// rejects, exactly like a real network error.
import { hostCall } from "./host.js";
import { TextDecoderShim, TextEncoderShim } from "./text.js";
import { base64ToBytes, bytesToBase64 } from "./base64.js";
import { DOMExceptionShim } from "./events.js";

const FORBIDDEN_BODY_METHODS = new Set(["GET", "HEAD"]);

function normalizeName(name) {
  const n = String(name);
  if (!/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(n)) throw new TypeError(`Invalid header name: ${n}`);
  return n.toLowerCase();
}
function normalizeValue(value) {
  return String(value).replace(/^[\s\u0000]+|[\s\u0000]+$/g, "");
}

export class HeadersShim {
  constructor(init) {
    Object.defineProperty(this, "_map", { value: new Map(), enumerable: false });
    if (init instanceof HeadersShim) {
      for (const [k, v] of init._map) this._map.set(k, v);
    } else if (Array.isArray(init)) {
      for (const pair of init) {
        if (!pair || pair.length !== 2) throw new TypeError("Headers init pair must have 2 items");
        this.append(pair[0], pair[1]);
      }
    } else if (init && typeof init === "object") {
      if (typeof init.forEach === "function" && typeof init.get === "function") {
        init.forEach((v, k) => this.append(k, v));
      } else {
        for (const k of Object.keys(init)) this.append(k, init[k]);
      }
    } else if (init != null) {
      throw new TypeError("Invalid Headers init");
    }
  }
  append(name, value) {
    const k = normalizeName(name);
    const v = normalizeValue(value);
    const prev = this._map.get(k);
    this._map.set(k, prev === undefined ? v : `${prev}, ${v}`);
  }
  set(name, value) {
    this._map.set(normalizeName(name), normalizeValue(value));
  }
  get(name) {
    const v = this._map.get(normalizeName(name));
    return v === undefined ? null : v;
  }
  has(name) {
    return this._map.has(normalizeName(name));
  }
  delete(name) {
    this._map.delete(normalizeName(name));
  }
  forEach(cb, thisArg) {
    for (const k of Array.from(this._map.keys()).sort()) cb.call(thisArg, this._map.get(k), k, this);
  }
  *entries() {
    for (const k of Array.from(this._map.keys()).sort()) yield [k, this._map.get(k)];
  }
  *keys() {
    for (const [k] of this.entries()) yield k;
  }
  *values() {
    for (const [, v] of this.entries()) yield v;
  }
  [Symbol.iterator]() {
    return this.entries();
  }
  getSetCookie() {
    const v = this._map.get("set-cookie");
    return v === undefined ? [] : [v];
  }
  /** Plain object for the bridge. */
  toObject() {
    const out = {};
    for (const [k, v] of this._map) out[k] = v;
    return out;
  }
}

class Body {
  constructor(bodyInit, headers) {
    this.bodyUsed = false;
    this._bytes = null;
    this._text = null;
    if (bodyInit == null) {
      this._text = null;
    } else if (typeof bodyInit === "string") {
      this._text = bodyInit;
      if (headers && !headers.has("content-type")) headers.set("content-type", "text/plain;charset=UTF-8");
    } else if (bodyInit instanceof Uint8Array) {
      this._bytes = bodyInit;
    } else if (ArrayBuffer.isView(bodyInit)) {
      this._bytes = new Uint8Array(bodyInit.buffer, bodyInit.byteOffset, bodyInit.byteLength);
    } else if (bodyInit instanceof ArrayBuffer) {
      this._bytes = new Uint8Array(bodyInit);
    } else if (typeof globalThis.URLSearchParams === "function" && bodyInit instanceof globalThis.URLSearchParams) {
      this._text = bodyInit.toString();
      if (headers && !headers.has("content-type"))
        headers.set("content-type", "application/x-www-form-urlencoded;charset=UTF-8");
    } else {
      throw new TypeError("HarborEngine fetch: unsupported body type (use string, URLSearchParams or bytes)");
    }
  }
  _consume() {
    if (this.bodyUsed) throw new TypeError("Body has already been consumed");
    this.bodyUsed = true;
  }
  async text() {
    this._consume();
    if (this._text !== null) return this._text;
    if (this._bytes) return new TextDecoderShim().decode(this._bytes);
    return "";
  }
  async json() {
    const t = await this.text();
    return JSON.parse(t);
  }
  async arrayBuffer() {
    this._consume();
    const b = this._bytes ?? new TextEncoderShim().encode(this._text ?? "");
    return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength);
  }
  async bytes() {
    return new Uint8Array(await this.arrayBuffer());
  }
  async blob() {
    throw new Error("HarborEngine fetch: Blob is not available on tvOS; use arrayBuffer()");
  }
  /**
   * A one-chunk stand-in for `response.body`: the host hands over whole bodies, so the
   * reader yields everything at once. Enough for upstream's bounded/streaming readers
   * (iptv/bounded-response.ts, iptv/xmltv.ts) that only need `getReader()` and `cancel()`.
   */
  get body() {
    if (this._text === null && !this._bytes) return null;
    const self = this;
    let handed = false;
    return {
      getReader() {
        self._consume();
        return {
          async read() {
            if (handed) return { done: true, value: undefined };
            handed = true;
            const b = self._bytes ?? new TextEncoderShim().encode(self._text ?? "");
            return { done: false, value: b };
          },
          async cancel() { handed = true; },
          releaseLock() {},
        };
      },
      async cancel() { handed = true; },
      get locked() { return false; },
    };
  }
  /** What actually crosses the bridge. */
  _wireBody() {
    if (this._bytes) return { body: null, bodyBase64: bytesToBase64(this._bytes) };
    return { body: this._text, bodyBase64: null };
  }
}

export class RequestShim extends Body {
  constructor(input, init = {}) {
    const base = input instanceof RequestShim ? input : null;
    const url = base ? base.url : String(input && input.href ? input.href : input);
    const headers = new HeadersShim(init.headers ?? (base ? base.headers : undefined));
    const method = String(init.method ?? (base ? base.method : "GET")).toUpperCase();
    const bodyInit = init.body !== undefined ? init.body : base ? base._rawBody : undefined;
    if (bodyInit != null && FORBIDDEN_BODY_METHODS.has(method)) {
      throw new TypeError(`Request with method ${method} cannot have a body`);
    }
    super(bodyInit, headers);
    this._rawBody = bodyInit;
    this.url = url;
    this.method = method;
    this.headers = headers;
    this.signal = init.signal ?? (base ? base.signal : undefined) ?? null;
    this.redirect = init.redirect ?? (base ? base.redirect : "follow");
    this.credentials = init.credentials ?? "same-origin";
    this.mode = init.mode ?? "cors";
    this.cache = init.cache ?? "default";
    this.integrity = init.integrity ?? "";
    this.keepalive = !!init.keepalive;
    this.referrer = init.referrer ?? "";
    this.referrerPolicy = init.referrerPolicy ?? "";
  }
  clone() {
    return new RequestShim(this, { body: this._rawBody });
  }
}

export class ResponseShim extends Body {
  constructor(bodyInit, init = {}) {
    const headers = new HeadersShim(init.headers);
    super(bodyInit, headers);
    this._rawBody = bodyInit;
    this.headers = headers;
    this.status = init.status === undefined ? 200 : Number(init.status);
    this.statusText = init.statusText === undefined ? "" : String(init.statusText);
    this.url = init.url ?? "";
    this.redirected = !!init.redirected;
    this.type = init.type ?? "default";
  }
  get ok() {
    return this.status >= 200 && this.status < 300;
  }
  clone() {
    const r = new ResponseShim(this._rawBody, {
      status: this.status,
      statusText: this.statusText,
      headers: this.headers,
      url: this.url,
    });
    return r;
  }
  static json(data, init = {}) {
    const r = new ResponseShim(JSON.stringify(data), init);
    if (!r.headers.has("content-type")) r.headers.set("content-type", "application/json");
    return r;
  }
  static error() {
    const r = new ResponseShim(null, { status: 0 });
    r.type = "error";
    return r;
  }
}

let nextRequestId = 1;

/** The global fetch. `init.harborResponseType: "base64"` asks the host for raw bytes. */
export function fetchShim(input, init = {}) {
  let request;
  try {
    request = input instanceof RequestShim && init === undefined ? input : new RequestShim(input, init ?? {});
  } catch (e) {
    return Promise.reject(e);
  }
  const signal = request.signal;
  if (signal && signal.aborted) {
    return Promise.reject(signal.reason ?? new DOMExceptionShim("This operation was aborted", "AbortError"));
  }
  const id = nextRequestId++;
  const wire = request._wireBody();
  const payload = {
    requestId: id,
    url: request.url,
    method: request.method,
    headers: request.headers.toObject(),
    body: wire.body,
    bodyBase64: wire.bodyBase64,
    responseType: (init && init.harborResponseType) === "base64" ? "base64" : "text",
    redirect: request.redirect,
    timeoutMs: (init && init.harborTimeoutMs) || 30000,
  };
  request.bodyUsed = false; // the request body was only read for the bridge

  return new Promise((resolve, reject) => {
    let settled = false;
    const onAbort = () => {
      if (settled) return;
      settled = true;
      try {
        hostCall("abort", id);
      } catch {}
      reject(signal.reason ?? new DOMExceptionShim("This operation was aborted", "AbortError"));
    };
    if (signal) signal.addEventListener("abort", onAbort);
    const done = (fn) => (v) => {
      if (settled) return;
      settled = true;
      if (signal) signal.removeEventListener("abort", onAbort);
      fn(v);
    };
    let p;
    try {
      p = hostCall("fetch", payload);
    } catch (e) {
      done(reject)(e);
      return;
    }
    Promise.resolve(p).then(
      done((raw) => {
        try {
          resolve(toResponse(raw, request.url));
        } catch (e) {
          reject(e);
        }
      }),
      done((e) => reject(normalizeNetworkError(e))),
    );
  });
}

function normalizeNetworkError(e) {
  if (e instanceof Error) return e;
  const msg = typeof e === "string" ? e : e && e.message ? e.message : "network error";
  const name = e && e.name ? String(e.name) : "";
  if (name === "AbortError" || name === "TimeoutError") return new DOMExceptionShim(msg, name);
  return new TypeError(`fetch failed: ${msg}`);
}

function toResponse(raw, requestUrl) {
  if (!raw || typeof raw !== "object") throw new TypeError("__harbor_host.fetch resolved with a non-object");
  if (typeof raw.status !== "number") throw new TypeError("__harbor_host.fetch response is missing `status`");
  const headers = new HeadersShim();
  const rh = raw.headers;
  if (rh && typeof rh === "object") for (const k of Object.keys(rh)) headers.set(k, rh[k]);
  const body =
    typeof raw.bodyBase64 === "string"
      ? base64ToBytes(raw.bodyBase64)
      : typeof raw.body === "string"
        ? raw.body
        : null;
  return new ResponseShim(raw.status === 204 || raw.status === 304 ? null : body, {
    status: raw.status,
    statusText: typeof raw.statusText === "string" ? raw.statusText : "",
    headers,
    url: typeof raw.url === "string" && raw.url ? raw.url : requestUrl,
    redirected: !!raw.redirected,
  });
}
