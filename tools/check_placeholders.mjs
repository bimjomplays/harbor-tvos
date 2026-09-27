#!/usr/bin/env node
// Placeholder-parity checker for tools/locales-tvos.json (the tvOS-only strings that
// tools/build_locales.mjs merges after upstream's own catalogs). Every language's translation of a
// key must carry exactly the placeholders the key itself declares — same tokens, same count — or a
// language can silently drop an argument (a crash in String(format:)) or lose a piece of the
// sentence (the {name} token literally shows up on screen instead of a value). This is cheap to get
// wrong when 15 languages are filled in for ~200 keys, so it is checked by machine, not by eye.
//
//   node tools/check_placeholders.mjs        exits 1 and prints every violation, else prints OK.
//
// Two placeholder styles appear in this file (see its "_about" key and tools/build_locales.mjs):
//   - "{name}" tokens: build_locales.mjs's swiftForms() turns each one into the Swift %@/%lld twins,
//     re-numbered by the KEY's first occurrence of that name, so a translation may reorder {name}
//     tokens freely but must reuse the exact same token spelling (case included) the key declares —
//     no more, no fewer, none invented.
//   - literal "%@" / "%lld" (a key with no "{"): these are copied through untouched, so a
//     translation must contain the same COUNT of "%@" and the same COUNT of "%lld" as the key, in
//     the same left-to-right order (no positional "%1$@" support for this style — see the file's
//     own convention: every literal-%-style key currently used is a single- or same-order multi-arg
//     sentence, never one a language needs to reorder).
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const file = path.join(root, "tools/locales-tvos.json");
const extras = JSON.parse(fs.readFileSync(file, "utf8"));

const LANGS = ["ar", "de", "es", "fr", "hi", "id", "it", "ja", "ko", "pl", "pt", "ru", "tr", "vi", "zh"];
const NAME_TOKEN = /\{([A-Za-z0-9_]+)\}/g;
const PCT_TOKEN = /%(lld|@)/g;

let problems = 0;
const report = (key, msg) => { problems++; console.error(`${JSON.stringify(key)}: ${msg}`); };

for (const [key, byLang] of Object.entries(extras)) {
  if (key.startsWith("_")) continue;
  if (typeof byLang !== "object" || byLang === null) { report(key, "not an object"); continue; }

  const usesNamed = key.includes("{");
  const keyNames = usesNamed ? [...new Set([...key.matchAll(NAME_TOKEN)].map((m) => m[1]))] : [];
  const keyPct = usesNamed ? [] : [...key.matchAll(PCT_TOKEN)].map((m) => `%${m[1]}`);

  for (const lang of LANGS) {
    const v = byLang[lang];
    if (typeof v !== "string" || v.length === 0) { report(key, `missing or empty "${lang}"`); continue; }

    if (usesNamed) {
      const gotNames = new Set([...v.matchAll(NAME_TOKEN)].map((m) => m[1]));
      for (const n of keyNames) if (!gotNames.has(n)) report(key, `"${lang}" is missing placeholder {${n}}`);
      for (const n of gotNames) if (!keyNames.includes(n)) report(key, `"${lang}" has an extra placeholder {${n}} the key does not declare`);
      // A named key must not also introduce a raw %@/%lld (that would bypass swiftForms entirely).
      if (PCT_TOKEN.test(v)) report(key, `"${lang}" mixes a literal %@/%lld into a {name}-style key`);
    } else if (keyPct.length) {
      const gotPct = [...v.matchAll(PCT_TOKEN)].map((m) => `%${m[1]}`);
      if (gotPct.length !== keyPct.length) {
        report(key, `"${lang}" has ${gotPct.length} placeholder(s), key has ${keyPct.length} (${keyPct.join(", ")})`);
      } else if (gotPct.some((p, i) => p !== keyPct[i])) {
        report(key, `"${lang}" placeholder order/type is ${gotPct.join(", ")}, key wants ${keyPct.join(", ")} (literal %@/%lld keys must keep left-to-right order)`);
      }
    } else {
      // A plain key (no placeholders) must not gain one — that argument would never be supplied.
      if (NAME_TOKEN.test(v) || PCT_TOKEN.test(v)) report(key, `"${lang}" adds a placeholder the key has none of`);
    }
  }
}

if (problems) {
  console.error(`\n${problems} placeholder problem(s) in tools/locales-tvos.json`);
  process.exit(1);
}
console.log(`OK: placeholder parity holds across all ${LANGS.length} languages for every key in tools/locales-tvos.json.`);
