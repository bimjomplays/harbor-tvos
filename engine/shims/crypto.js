// crypto.randomUUID / getRandomValues / subtle.digest("SHA-256").
// JavaScriptCore has no WebCrypto. Entropy comes from the host (Swift SecRandomCopyBytes
// / Node randomBytes); SHA-256 is pure JS so it works with no host support.
import { hostCall, hostHas } from "./host.js";
import { base64ToBytes } from "./base64.js";
import { TextEncoderShim } from "./text.js";

const K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

/** @param {Uint8Array} bytes @returns {Uint8Array} 32-byte digest */
export function sha256(bytes) {
  const len = bytes.length;
  const bitLenHi = Math.floor((len / 0x20000000) | 0);
  const bitLenLo = (len << 3) >>> 0;
  const withPad = ((len + 9 + 63) & ~63) >>> 0;
  const msg = new Uint8Array(withPad);
  msg.set(bytes);
  msg[len] = 0x80;
  const dv = new DataView(msg.buffer);
  dv.setUint32(withPad - 8, bitLenHi, false);
  dv.setUint32(withPad - 4, bitLenLo, false);

  let h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
  let h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;
  const w = new Uint32Array(64);

  for (let off = 0; off < withPad; off += 64) {
    for (let i = 0; i < 16; i++) w[i] = dv.getUint32(off + i * 4, false);
    for (let i = 16; i < 64; i++) {
      const x = w[i - 15], y = w[i - 2];
      const s0 = ((x >>> 7) | (x << 25)) ^ ((x >>> 18) | (x << 14)) ^ (x >>> 3);
      const s1 = ((y >>> 17) | (y << 15)) ^ ((y >>> 19) | (y << 13)) ^ (y >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
    for (let i = 0; i < 64; i++) {
      const S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
      const ch = (e & f) ^ (~e & g);
      const t1 = (h + S1 + ch + K[i] + w[i]) >>> 0;
      const S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (S0 + maj) >>> 0;
      h = g; g = f; f = e; e = (d + t1) >>> 0;
      d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    h0 = (h0 + a) >>> 0; h1 = (h1 + b) >>> 0; h2 = (h2 + c) >>> 0; h3 = (h3 + d) >>> 0;
    h4 = (h4 + e) >>> 0; h5 = (h5 + f) >>> 0; h6 = (h6 + g) >>> 0; h7 = (h7 + h) >>> 0;
  }
  const out = new Uint8Array(32);
  const odv = new DataView(out.buffer);
  [h0, h1, h2, h3, h4, h5, h6, h7].forEach((v, i) => odv.setUint32(i * 4, v, false));
  return out;
}

function randomBytes(n) {
  // The host returns base64 so the value survives the JSC <-> Swift boundary as a string.
  const b64 = hostCall("randomBytes", n);
  const bytes = base64ToBytes(b64);
  if (bytes.length < n) throw new Error(`__harbor_host.randomBytes(${n}) returned ${bytes.length} bytes`);
  return bytes.subarray(0, n);
}

export function createCrypto() {
  const encoder = new TextEncoderShim();
  return {
    getRandomValues(view) {
      if (!ArrayBuffer.isView(view)) throw new TypeError("getRandomValues expects a TypedArray");
      const bytes = randomBytes(view.byteLength);
      new Uint8Array(view.buffer, view.byteOffset, view.byteLength).set(bytes);
      return view;
    },
    randomUUID() {
      if (hostHas("randomUUID")) {
        const v = hostCall("randomUUID");
        if (typeof v === "string" && v.length === 36) return v;
      }
      const b = randomBytes(16);
      b[6] = (b[6] & 0x0f) | 0x40;
      b[8] = (b[8] & 0x3f) | 0x80;
      const h = Array.from(b, (x) => x.toString(16).padStart(2, "0"));
      return `${h.slice(0, 4).join("")}-${h.slice(4, 6).join("")}-${h.slice(6, 8).join("")}-${h.slice(8, 10).join("")}-${h.slice(10, 16).join("")}`;
    },
    subtle: {
      async digest(algorithm, data) {
        const name = (typeof algorithm === "string" ? algorithm : algorithm && algorithm.name) || "";
        if (String(name).toUpperCase() !== "SHA-256") {
          throw new Error(`HarborEngine crypto.subtle.digest: only SHA-256 is implemented, got ${name}`);
        }
        const bytes =
          typeof data === "string"
            ? encoder.encode(data)
            : data instanceof Uint8Array
              ? data
              : ArrayBuffer.isView(data)
                ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
                : new Uint8Array(data);
        const out = sha256(bytes);
        return out.buffer.slice(out.byteOffset, out.byteOffset + out.byteLength);
      },
    },
  };
}
