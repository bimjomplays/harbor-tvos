// Bundles upstream Harbor's framework-free logic into one script for JavaScriptCore.
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const upstream = path.resolve(here, "../reference/harbor/src");

const stubs = {
  name: "harbor-stubs",
  setup(b) {
    // Desktop-only modules that the bundle must never pull in.
    b.onResolve({ filter: /^@tauri-apps\// }, (a) => ({ path: a.path, namespace: "stub" }));
    b.onLoad({ filter: /.*/, namespace: "stub" }, () => ({ contents: "export default {}; export const fetch = globalThis.fetch;", loader: "js" }));
  },
};

const r = await build({
  entryPoints: [path.join(here, "entry.ts")],
  bundle: true,
  format: "iife",
  globalName: "HarborEngine",
  platform: "neutral",
  target: ["safari16"],
  mainFields: ["module", "main"],
  outfile: path.join(here, "dist/harbor-engine.js"),
  alias: { "@": upstream },
  nodePaths: [path.join(here, "node_modules")],
  plugins: [stubs],
  metafile: true,
  logLevel: "warning",
  minify: false,
  sourcemap: false,
});
const inputs = Object.keys(r.metafile.inputs);
console.log(`bundled ${inputs.length} files, ${(r.metafile.outputs["dist/harbor-engine.js"].bytes / 1024).toFixed(0)} KB`);
const outside = inputs.filter((f) => !f.includes("reference/harbor/src/lib/streams") && !f.includes("node_modules"));
console.log("outside streams/:", outside.length); console.log(outside.slice(0, 60).join("\n"));
