// TextEncoder / TextDecoder. JavaScriptCore has neither.
// Encoder follows the WHATWG algorithm including lone-surrogate -> U+FFFD.
// Decoder implements UTF-8 with the spec's error handling (invalid sequences -> U+FFFD,
// rejecting overlongs, surrogates and > U+10FFFF), plus `fatal` and `ignoreBOM`, and the
// WHATWG UTF-16LE/BE and single-byte legacy encodings (legacy-text.js).

import { SINGLE_BYTE, SINGLE_BYTE_LABELS } from "./legacy-text.js";

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

const UTF8_LABELS = new Set(["unicode-1-1-utf-8", "unicode11utf8", "unicode20utf8", "utf-8", "utf8", "x-unicode20utf8"]);
const UTF16LE_LABELS = new Set(["csunicode", "iso-10646-ucs-2", "ucs-2", "unicode", "unicodefeff", "utf-16", "utf-16le"]);
const UTF16BE_LABELS = new Set(["unicodefffe", "utf-16be"]);

// (player tracks pass) Beside UTF-8, the WHATWG UTF-16 and single-byte legacy decoders: upstream's
// lib/subtitles/encoding.ts tries windows-1252 / windows-1256 / iso-8859-6 (and a provider's
// declared encoding, a UTF-16 BOM) with `new TextDecoder(label)`. With UTF-8 only, every one of
// those threw, so a Latin-1 / Cyrillic / Arabic / UTF-16 subtitle was "decode-unhealthy" and
// could not be added at all.
export class TextDecoderShim {
  constructor(label = "utf-8", options = {}) {
    const enc = String(label).trim().toLowerCase();
    if (UTF8_LABELS.has(enc)) this._enc = "utf-8";
    else if (UTF16LE_LABELS.has(enc)) this._enc = "utf-16le";
    else if (UTF16BE_LABELS.has(enc)) this._enc = "utf-16be";
    else if (Object.prototype.hasOwnProperty.call(SINGLE_BYTE_LABELS, enc)) this._enc = SINGLE_BYTE_LABELS[enc];
    else throw new RangeError(`TextDecoder: the encoding ${label} is not supported`);
    this.fatal = !!options.fatal;
    this.ignoreBOM = !!options.ignoreBOM;
  }
  get encoding() {
    return this._enc;
  }
  decode(input) {
    if (this._enc === "utf-16le" || this._enc === "utf-16be") return this._decodeUtf16(viewOf(input), this._enc === "utf-16be");
    if (this._enc !== "utf-8") return this._decodeSingleByte(viewOf(input), SINGLE_BYTE[this._enc]);
    return this._decodeUtf8(viewOf(input));
  }
  _decodeSingleByte(b, table) {
    let out = "";
    let chunk = [];
    for (let i = 0; i < b.length; i++) {
      const byte = b[i];
      const cp = byte < 0x80 ? byte : table.charCodeAt(byte - 0x80);
      if (cp === 0xfffd && this.fatal) throw new TypeError("TextDecoder: invalid byte (fatal)");
      chunk.push(cp);
      if (chunk.length > 4096) {
        out += String.fromCharCode.apply(null, chunk);
        chunk = [];
      }
    }
    if (chunk.length) out += String.fromCharCode.apply(null, chunk);
    return out;
  }
  _decodeUtf16(b, bigEndian) {
    let i = 0;
    if (!this.ignoreBOM && b.length >= 2 && (bigEndian ? b[0] === 0xfe && b[1] === 0xff : b[0] === 0xff && b[1] === 0xfe)) i = 2;
    let out = "";
    let chunk = [];
    const bad = () => {
      if (this.fatal) throw new TypeError("TextDecoder: invalid UTF-16 (fatal)");
      chunk.push(0xfffd);
    };
    let lead = -1;
    for (; i + 1 < b.length; i += 2) {
      const unit = bigEndian ? (b[i] << 8) | b[i + 1] : b[i] | (b[i + 1] << 8);
      if (lead >= 0) {
        if (unit >= 0xdc00 && unit <= 0xdfff) {
          chunk.push(lead, unit);
          lead = -1;
          continue;
        }
        lead = -1;
        bad();
      }
      if (unit >= 0xd800 && unit <= 0xdbff) lead = unit;
      else if (unit >= 0xdc00 && unit <= 0xdfff) bad();
      else chunk.push(unit);
      if (chunk.length > 4096) {
        out += String.fromCharCode.apply(null, chunk);
        chunk = [];
      }
    }
    if (lead >= 0 || i < b.length) bad();
    if (chunk.length) out += String.fromCharCode.apply(null, chunk);
    return out;
  }
  _decodeUtf8(b) {
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
