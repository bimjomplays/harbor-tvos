#!/usr/bin/env node
// Reports user-visible Swift string literals that have no entry in a generated catalog
// (App/Locales/<lang>.lproj/Localizable.strings, from tools/build_locales.mjs), per file.
//
//   node tools/l10n_coverage.mjs [--lang de] [--list [--all]] [--json] [paths…]   (default: App/Sources)
//   --list prints each miss (kind! = no key; borrow! = a letter-free SwiftUI key such as "%@ %@" that
//   some language re-orders, so it must be a String instead); --all also prints the literals that matched.
//
// A literal counts when it sits where it will be shown: a SwiftUI text initialiser (Text, Button,
// Label, Toggle, …: looked up as a LocalizedStringKey, so "\(n) left" is the key "%lld left"),
// T("…") (App/L10n.swift), a UI-ish argument label (text:, title:, message:, placeholder:, …), or
// a bare prose-looking literal (return / case / ternary / array element) that is probably a label.
// Interpolation outside a SwiftUI initialiser bakes the value into the key, so it never matches:
// such strings want a T("… %@ …", value) format key. Heuristic, not a compiler: use it to find
// untranslated copy and to compare coverage before/after, not as a gate.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const flag = (f) => { const i = args.indexOf(f); if (i < 0) return false; args.splice(i, 1); return true; };
const opt = (f, d) => { const i = args.indexOf(f); if (i < 0) return d; const v = args[i + 1]; args.splice(i, 2); return v; };
const lang = opt("--lang", "de");
const list = flag("--list");
const all = flag("--all"); // with --list: matched literals too (to check they reach T()/a SwiftUI initialiser)
const asJson = flag("--json");
const targets = args.length ? args : ["App/Sources"];

const stringsPath = path.join(root, `App/Locales/${lang}.lproj/Localizable.strings`);
if (!fs.existsSync(stringsPath)) {
  console.error(`${path.relative(root, stringsPath)} missing: run node tools/build_locales.mjs first`);
  process.exit(1);
}
const unesc = (s) => s.replace(/\\(U[0-9a-fA-F]{4}|.)/g, (_, c) =>
  c[0] === "U" && c.length === 5 ? String.fromCharCode(parseInt(c.slice(1), 16)) : ({ n: "\n", r: "\r", t: "\t" })[c] ?? c);
const keys = new Set();
for (const line of fs.readFileSync(stringsPath, "utf8").split("\n")) {
  const m = /^"((?:[^"\\]|\\.)*)" = "/.exec(line);
  if (m) keys.add(unesc(m[1]));
}
// "%lld of %@" and "%1$@" all fold to one shape, so a Swift key matches whichever twin exists.
const fold = (k) => k.replace(/%(\d+\$)?(lld|ld|d|@|f|\.\d+f)/g, "%@");
const folded = new Set([...keys].map(fold));

// Letter-free keys ("%@ %@", "%@: %@") that some language re-orders or re-punctuates: a SwiftUI
// literal like Text("\(a) \(b)") looks one up and borrows that unrelated entry (review 20).
const risky = new Set();
for (const d of fs.readdirSync(path.join(root, "App/Locales"))) {
  if (!d.endsWith(".lproj")) continue;
  for (const line of fs.readFileSync(path.join(root, "App/Locales", d, "Localizable.strings"), "utf8").split("\n")) {
    const m = /^"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";/.exec(line);
    if (!m || /\p{L}/u.test(m[1].replace(/%(lld|@)/g, ""))) continue;
    let i = 0;
    if (m[2] !== m[1].replace(/%(lld|@)/g, (_, t) => `%${++i}$${t}`)) risky.add(unesc(m[1]));
  }
}

// SwiftUI initialisers whose first unlabeled literal is a LocalizedStringKey.
const SWIFTUI = new Set(["Text", "Button", "Label", "Toggle", "TextField", "SecureField", "Section", "Picker", "Menu",
  "navigationTitle", "accessibilityLabel", "accessibilityHint", "help", "alert", "confirmationDialog", "LocalizedStringKey",
  "ProgressView", "LabeledContent", "Link", "ShareLink", "Stepper", "ContentUnavailableView"]);
// Argument labels that carry display copy.
const UI_LABELS = new Set(["text", "title", "label", "message", "heading", "subtitle", "sub", "placeholder", "hint", "body",
  "bodyText", "caption", "detail", "prompt", "eyebrow", "kicker", "note", "empty", "emptyText", "emptyTitle", "emptyBody",
  "cta", "actionLabel", "headline", "blurb", "copy", "confirm", "cancel", "tagline", "description", "info", "tip", "badge"]);
// Calls whose literals are data, not copy.
const SKIP_CALLS = new Set(["call", "Image", "systemName", "print", "NSLog", "URL", "URLComponents", "URLQueryItem", "Color",
  "hasPrefix", "hasSuffix", "contains", "replacingOccurrences", "components", "split", "range", "firstIndex", "trimmingCharacters",
  "string", "bool", "int", "double", "object", "data", "set", "removeObject", "fatalError", "precondition", "assert", "assertionFailure",
  "Logger", "log", "debug", "info", "error", "notice", "fault", "font", "custom", "Font", "named", "Notification", "Name",
  "forResource", "path", "url", "value", "setValue", "addValue", "dateFormat", "DateFormatter", "Locale", "TimeZone",
  "identifier", "id", "tag", "accessibilityIdentifier", "matchedGeometryEffect", "namespace", "decode", "encode",
  "CodingKeys", "key", "Key", "forKey", "forHTTPHeaderField", "rawValue", "NSPredicate", "Regex", "NSRegularExpression",
  "Bundle", "UIImage", "SFSymbol", "resource", "cString", "dlsym", "getenv", "Selector", "ofType", "withExtension"]);
const SKIP_LABELS = new Set(["systemImage", "systemName", "id", "key", "forKey", "icon", "image", "symbol", "glyph", "kind", "type",
  "route", "action", "event", "name", "code", "lang", "url", "path", "format", "identifier", "accessibilityIdentifier", "tag",
  "keyPath", "sfSymbol", "mode", "style", "fn", "method", "category", "sport", "league", "provider", "source", "scheme", "host"]);

/** Split a Swift source into single-line string literals with their call context. */
function literals(src) {
  const out = [];
  const stack = []; // { callee, label } per open paren/bracket
  let i = 0, line = 1, label = "", lastWord = "", prevTok = "";
  const n = src.length;
  while (i < n) {
    const c = src[i];
    if (c === "\n") { line++; i++; continue; }
    if (c === "/" && src[i + 1] === "/") { while (i < n && src[i] !== "\n") i++; continue; }
    if (c === "/" && src[i + 1] === "*") { const e = src.indexOf("*/", i + 2); const end = e < 0 ? n : e + 2; line += (src.slice(i, end).match(/\n/g) || []).length; i = end; continue; }
    if (c === '"' && src.startsWith('"""', i)) { const e = src.indexOf('"""', i + 3); const end = e < 0 ? n : e + 3; line += (src.slice(i, end).match(/\n/g) || []).length; i = end; prevTok = "str"; continue; }
    if (c === '"' || (c === "#" && src[i + 1] === '"')) {
      const raw = c === "#";
      let j = raw ? i + 2 : i + 1, text = "", interp = false, depth = 0;
      while (j < n) {
        const d = src[j];
        if (!raw && d === "\\" && src[j + 1] === "(") {
          // interpolation: skip balanced parens, nested strings included
          let k = j + 2, p = 1;
          while (k < n && p > 0) {
            if (src[k] === '"') { k++; while (k < n && src[k] !== '"') { if (src[k] === "\\") k++; k++; } }
            else if (src[k] === "(") p++;
            else if (src[k] === ")") p--;
            k++;
          }
          text += "\u0000"; interp = true; j = k; continue;
        }
        if (!raw && d === "\\") { const e = src[j + 1]; text += ({ n: "\n", t: "\t", r: "\r", "0": "\0" })[e] ?? e; j += 2; continue; }
        if (d === '"' && (!raw || src[j + 1] === "#")) break;
        if (d === "\n") break;
        text += d; j++;
      }
      const top = stack[stack.length - 1];
      out.push({ line, text, interp, callee: top?.callee ?? "", bracket: top?.bracket ?? false, label: top ? label : "", prevTok });
      void depth;
      i = j + (raw ? 2 : 1); prevTok = "str"; continue;
    }
    if (c === "(" || c === "[") {
      stack.push({ callee: prevTok === "word" ? lastWord : "", bracket: c === "[", savedLabel: label });
      label = ""; prevTok = c; i++; continue;
    }
    if (c === ")" || c === "]") { const s = stack.pop(); label = s?.savedLabel ?? ""; prevTok = "close"; i++; continue; }
    if (c === "{" ) { stack.push({ callee: "{", bracket: false, savedLabel: label }); label = ""; prevTok = "{"; i++; continue; }
    if (c === "}") { const s = stack.pop(); label = s?.savedLabel ?? ""; prevTok = "close"; i++; continue; }
    if (c === ",") { label = ""; prevTok = ","; i++; continue; }
    if (/[A-Za-z_]/.test(c)) {
      let j = i; while (j < n && /[A-Za-z0-9_]/.test(src[j])) j++;
      const w = src.slice(i, j);
      // "label:" (not "::" nor a ternary "a ? b : c" — a label directly follows "(" or ",")
      let k = j; while (src[k] === " ") k++;
      if (src[k] === ":" && src[k + 1] !== ":" && (prevTok === "(" || prevTok === ",")) { label = w; i = k + 1; prevTok = ":label"; continue; }
      lastWord = w; prevTok = w === "return" ? "return" : "word"; i = j; continue;
    }
    if (c === "=" && src[i + 1] === "=") { prevTok = "=="; i += 2; continue; }
    if (c === "!" && src[i + 1] === "=") { prevTok = "=="; i += 2; continue; }
    if (" \t\r".includes(c)) { i++; continue; }
    prevTok = c; i++;
  }
  return out;
}

const PROSE = /^[A-Z¿¡][^\n]*[a-z]/; // capitalised and has a lowercase letter
const DATAISH = /^[a-z0-9_.-]+$|:\/\/|^X?\/|^[A-Za-z]+\.[A-Za-z.]+$|^[A-Z0-9_]+$|^#?[0-9A-Fa-f]{6,8}$|\.(jpe?g|JPE?G|png|PNG|gif|svg|webp|json|m3u8?)$/;

function classify(l) {
  const t = l.text;
  if (!/[A-Za-z]/.test(t.replace(/\u0000/g, ""))) return null;
  if (l.label && SKIP_LABELS.has(l.label)) return null;
  if (SKIP_CALLS.has(l.callee)) return null;
  if (l.prevTok === "==") return null;
  if (l.callee === "T" && !l.label) return "T";
  if (SWIFTUI.has(l.callee) && !l.label) return "swiftui";
  if (SWIFTUI.has(l.callee) && (l.label === "title" || l.label === "label")) return "swiftui";
  if (l.label && UI_LABELS.has(l.label)) return "arg";
  const plain = t.replace(/\u0000/g, "X");
  if (DATAISH.test(plain) || !PROSE.test(plain)) return null;
  if (l.bracket && l.prevTok !== "," && l.prevTok !== "[") return null; // subscript key
  if (["return", "=", "?", ":", ":label", "??", "[", ",", "(", "+", "{", "str", "word"].includes(l.prevTok)) return "bare";
  return null;
}

/** The catalog key this literal would be looked up by, or null when it cannot match. */
function keyOf(l, kind) {
  if (!l.interp) return l.text;
  if (kind === "swiftui") return l.text.replace(/%/g, "%%").replace(/\u0000/g, "%@");
  return null; // interpolated before lookup: the value is baked into the key
}

function* swiftFiles(p) {
  const abs = path.resolve(root, p);
  const st = fs.statSync(abs);
  if (st.isFile()) { if (abs.endsWith(".swift")) yield abs; return; }
  for (const e of fs.readdirSync(abs, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    yield* swiftFiles(path.join(abs, e.name));
  }
}

const rows = [];
let total = 0, hit = 0;
for (const t of targets) for (const file of swiftFiles(t)) {
  const misses = [];
  let ft = 0, fh = 0;
  for (const l of literals(fs.readFileSync(file, "utf8"))) {
    if (l.interp && SWIFTUI.has(l.callee) && !l.label && !/[A-Za-z]/.test(l.text.replace(/\u0000/g, ""))) {
      const k = keyOf(l, "swiftui");
      if ([...risky].some((r) => fold(r) === fold(k))) {
        ft++;
        misses.push({ line: l.line, kind: "borrow!", text: l.text.replace(/\u0000/g, "\\(…)") });
      }
      continue;
    }
    const kind = classify(l);
    if (!kind) continue;
    ft++;
    const key = keyOf(l, kind);
    const ok = key !== null && (keys.has(key) || folded.has(fold(key)) || folded.has(fold(key.replace(/%%/g, "%"))));
    if (ok) fh++;
    if (!ok || all) misses.push({ line: l.line, kind: ok ? kind : `${kind}!`, text: l.text.replace(/\u0000/g, "\\(…)") });
  }
  if (!ft) continue;
  total += ft; hit += fh;
  rows.push({ file: path.relative(root, file), total: ft, matched: fh, misses });
}

if (asJson) {
  console.log(JSON.stringify({ lang, total, matched: hit, files: rows }, null, 1));
} else {
  const w = Math.max(...rows.map((r) => r.file.length), 4);
  for (const r of rows) {
    console.log(`${r.file.padEnd(w)}  ${String(r.matched).padStart(4)}/${String(r.total).padEnd(4)} ${(100 * r.matched / r.total).toFixed(0).padStart(3)}%`);
    if (list) for (const m of r.misses) console.log(`    ${String(m.line).padStart(4)} ${m.kind.padEnd(8)} ${JSON.stringify(m.text)}`);
  }
  console.log(`${"TOTAL".padEnd(w)}  ${String(hit).padStart(4)}/${String(total).padEnd(4)} ${total ? (100 * hit / total).toFixed(1) : "0"}%  (${lang})`);
}
