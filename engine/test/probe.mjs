// Tries to bundle each candidate upstream module on its own, using the real build config,
// and reports what it drags in plus which host-provided globals it touches.
//   node test/probe.mjs addons cinemeta providers/tmdb ...
import { build } from "esbuild";
import path from "node:path";
import { common, here } from "../bundle-config.mjs";

const PATTERNS = [
  ["localStorage", /\blocalStorage\./],
  ["CustomEvent", /new CustomEvent\(/],
  ["window.event", /window\.(dispatchEvent|addEventListener)/],
  ["document", /\bdocument\.(?!visibilityState|hidden|addEventListener|removeEventListener)/],
  ["navigator", /\bnavigator\./],
  ["crypto", /\bcrypto\.(randomUUID|getRandomValues|subtle)/],
  ["TextEncoder", /new Text(Encoder|Decoder)\(/],
  ["URL", /new URL(SearchParams)?\(/],
  ["timers", /\bset(Timeout|Interval)\(/],
  ["structuredClone", /structuredClone\(/],
  ["atob/btoa", /\b(atob|btoa)\(/],
  ["performance", /performance\.now\(/],
  ["WebSocket", /new WebSocket\(/],
  ["Worker", /new Worker\(/],
  ["Blob", /new Blob\(/],
  ["indexedDB", /\bindexedDB\b/],
  ["FormData", /new FormData\(/],
  ["Intl", /\bIntl\./],
];

for (const t of process.argv.slice(2)) {
  const spec = t.startsWith("@/") ? t : "@/lib/" + t;
  try {
    const r = await build({
      ...common,
      stdin: { contents: `import * as m from ${JSON.stringify(spec)}; globalThis.__x = m;`, resolveDir: here, loader: "ts" },
      format: "iife",
      write: false,
      logLevel: "silent",
    });
    const ins = Object.keys(r.metafile.inputs);
    const code = r.outputFiles[0].text;
    const tsx = ins.filter((f) => f.endsWith(".tsx"));
    const flags = PATTERNS.filter(([, re]) => re.test(code)).map(([n]) => n);
    console.log(
      `OK   ${t.padEnd(34)} ${String(ins.length).padStart(4)}f ${(r.outputFiles[0].contents.length / 1024).toFixed(0).padStart(5)}KB  tsx:${tsx.length}  ${flags.join(" ")}`,
    );
    if (process.env.VERBOSE && tsx.length) console.log("       tsx: " + tsx.map((f) => f.replace(/.*src\//, "")).join(" "));
  } catch (e) {
    const msg = (e.errors ?? []).map((x) => `${x.text} @ ${(x.location?.file ?? "").replace(/.*src\//, "")}:${x.location?.line}`).slice(0, 2).join(" | ") || e.message;
    console.log(`FAIL ${t.padEnd(34)} ${msg}`);
  }
}
