// UTF-8 TextEncoder / TextDecoder. JavaScriptCore has neither.
// Encoder follows the WHATWG algorithm including lone-surrogate -> U+FFFD.
// Decoder implements UTF-8 with the spec's error handling (invalid sequences -> U+FFFD,
// rejecting overlongs, surrogates and > U+10FFFF), plus `fatal` and `ignoreBOM`.

export class TextEncoderShim {
  get encoding() {
    return "utf-8";
  }
  encode(input = "") {
    const s = String(input);
    // Worst case 3 bytes per UTF-16 unit (4 for a surrogate pair, but that is 2 units).
    const out = new Uint8Array(s.length * 3);
    let p = 0;
    for (let i = 0; i < s.length; i++) {
      let cp = s.charCodeAt(i);
      if (cp >= 0xd800 && cp <= 0xdbff) {
        const next = i + 1 < s.length ? s.charCodeAt(i + 1) : 0;
        if (next >= 0xdc00 && next <= 0xdfff) {
          cp = (cp - 0xd800) * 0x400 + (next - 0xdc00) + 0x10000;
          i++;
        } else {
          cp = 0xfffd;
        }
      } else if (cp >= 0xdc00 && cp <= 0xdfff) {
        cp = 0xfffd;
      }
      if (cp < 0x80) {
        out[p++] = cp;
      } else if (cp < 0x800) {
        out[p++] = 0xc0 | (cp >> 6);
        out[p++] = 0x80 | (cp & 0x3f);
      } else if (cp < 0x10000) {
        out[p++] = 0xe0 | (cp >> 12);
        out[p++] = 0x80 | ((cp >> 6) & 0x3f);
        out[p++] = 0x80 | (cp & 0x3f);
      } else {
        out[p++] = 0xf0 | (cp >> 18);
        out[p++] = 0x80 | ((cp >> 12) & 0x3f);
        out[p++] = 0x80 | ((cp >> 6) & 0x3f);
        out[p++] = 0x80 | (cp & 0x3f);
      }
    }
    return out.subarray(0, p);
  }
  encodeInto(source, dest) {
    const bytes = this.encode(source);
    const n = Math.min(bytes.length, dest.length);
    dest.set(bytes.subarray(0, n));
    // `read` is approximate for a truncated write; callers in this bundle do not use it.
    return { read: source.length, written: n };
  }
}

function viewOf(input) {
  if (input == null) return new Uint8Array(0);
  if (input instanceof Uint8Array) return input;
  if (ArrayBuffer.isView(input)) return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
  if (input instanceof ArrayBuffer) return new Uint8Array(input);
  throw new TypeError("TextDecoder.decode expects a BufferSource");
}

export class TextDecoderShim {
  constructor(label = "utf-8", options = {}) {
    const enc = String(label).toLowerCase();
    if (enc !== "utf-8" && enc !== "utf8" && enc !== "unicode-1-1-utf-8") {
      throw new RangeError(`TextDecoder: only utf-8 is supported, got ${label}`);
    }
    this.fatal = !!options.fatal;
    this.ignoreBOM = !!options.ignoreBOM;
  }
  get encoding() {
    return "utf-8";
  }
  decode(input) {
    const b = viewOf(input);
    let i = 0;
    if (!this.ignoreBOM && b.length >= 3 && b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf) i = 3;
    let out = "";
    let chunk = [];
    const push = (cp) => {
      if (cp > 0xffff) {
        cp -= 0x10000;
        chunk.push(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
      } else {
        chunk.push(cp);
      }
      if (chunk.length > 4096) {
        out += String.fromCharCode.apply(null, chunk);
        chunk = [];
      }
    };
    const bad = () => {
      if (this.fatal) throw new TypeError("TextDecoder: invalid UTF-8 (fatal)");
      push(0xfffd);
    };
    while (i < b.length) {
      const a = b[i];
      if (a < 0x80) {
        push(a);
        i++;
        continue;
      }
      let need, cp, lo, hi;
      if (a >= 0xc2 && a <= 0xdf) { need = 1; cp = a & 0x1f; lo = 0x80; hi = 0xbf; }
      else if (a === 0xe0) { need = 2; cp = 0; lo = 0xa0; hi = 0xbf; }
      else if (a >= 0xe1 && a <= 0xec) { need = 2; cp = a & 0x0f; lo = 0x80; hi = 0xbf; }
      else if (a === 0xed) { need = 2; cp = 0x0d; lo = 0x80; hi = 0x9f; }
      else if (a >= 0xee && a <= 0xef) { need = 2; cp = a & 0x0f; lo = 0x80; hi = 0xbf; }
      else if (a === 0xf0) { need = 3; cp = 0; lo = 0x90; hi = 0xbf; }
      else if (a >= 0xf1 && a <= 0xf3) { need = 3; cp = a & 0x07; lo = 0x80; hi = 0xbf; }
      else if (a === 0xf4) { need = 3; cp = 4; lo = 0x80; hi = 0x8f; }
      else { bad(); i++; continue; }
      if (a === 0xe0) cp = 0;
      let ok = true;
      for (let k = 1; k <= need; k++) {
        const c = b[i + k];
        const min = k === 1 ? lo : 0x80;
        const max = k === 1 ? hi : 0xbf;
        if (c === undefined || c < min || c > max) {
          bad();
          i += k; // resync at the first byte that did not fit
          ok = false;
          break;
        }
        cp = (cp << 6) | (c & 0x3f);
      }
      if (!ok) continue;
      push(cp);
      i += need + 1;
    }
    if (chunk.length) out += String.fromCharCode.apply(null, chunk);
    return out;
  }
}
