// atob / btoa. JavaScriptCore has neither (they are HTML globals, not ECMAScript).
const CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const LOOKUP = (() => {
  const t = new Int16Array(256).fill(-1);
  for (let i = 0; i < CHARS.length; i++) t[CHARS.charCodeAt(i)] = i;
  return t;
})();

export function btoaShim(input) {
  const s = String(input);
  let out = "";
  for (let i = 0; i < s.length; i += 3) {
    const c0 = s.charCodeAt(i);
    const c1 = i + 1 < s.length ? s.charCodeAt(i + 1) : NaN;
    const c2 = i + 2 < s.length ? s.charCodeAt(i + 2) : NaN;
    if (c0 > 0xff || (c1 === c1 && c1 > 0xff) || (c2 === c2 && c2 > 0xff)) {
      throw new Error("btoa: string contains characters outside of the Latin1 range");
    }
    const n = (c0 << 16) | ((c1 === c1 ? c1 : 0) << 8) | (c2 === c2 ? c2 : 0);
    out += CHARS[(n >> 18) & 63] + CHARS[(n >> 12) & 63];
    out += c1 === c1 ? CHARS[(n >> 6) & 63] : "=";
    out += c2 === c2 ? CHARS[n & 63] : "=";
  }
  return out;
}

export function atobShim(input) {
  let s = String(input).replace(/[\t\n\f\r ]/g, "");
  if (s.length % 4 === 0) s = s.replace(/={1,2}$/, "");
  if (s.length % 4 === 1) throw new Error("atob: invalid base64 length");
  let out = "";
  let buffer = 0;
  let bits = 0;
  for (let i = 0; i < s.length; i++) {
    const v = LOOKUP[s.charCodeAt(i)];
    if (v < 0) throw new Error("atob: invalid base64 character");
    buffer = (buffer << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out += String.fromCharCode((buffer >> bits) & 0xff);
    }
  }
  return out;
}

export function bytesToBase64(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoaShim(binary);
}

export function base64ToBytes(value) {
  const binary = atobShim(value);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}
