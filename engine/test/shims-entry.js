// Test-only entry: exposes the shims themselves so test/shims.test.mjs can compare them
// against Node's real implementations inside a bare vm context (the JSC analogue).
import { shims } from "../shims/index.js";
export { shims };
export const globals = {
  URL: globalThis.URL,
  URLSearchParams: globalThis.URLSearchParams,
  TextEncoder: globalThis.TextEncoder,
  TextDecoder: globalThis.TextDecoder,
  Headers: globalThis.Headers,
  Response: globalThis.Response,
  Request: globalThis.Request,
  AbortController: globalThis.AbortController,
  fetch: globalThis.fetch,
  crypto: globalThis.crypto,
  localStorage: globalThis.localStorage,
  atob: globalThis.atob,
  btoa: globalThis.btoa,
  structuredClone: globalThis.structuredClone,
};
