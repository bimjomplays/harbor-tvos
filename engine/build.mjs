// Bundles upstream Harbor's framework-free logic into one script for JavaScriptCore.
//
//   node build.mjs          -> dist/harbor-engine.js (+ dist/shims-test.js)
//   node build.mjs --min    -> also writes dist/harbor-engine.min.js
//
// Rules: nothing from upstream is ever copied into engine/. Every upstream module is
// imported through the `@` alias so re-bundling automatically tracks the submodule.
import { build } from "esbuild";
import path from "node:path";
import fs from "node:fs";
import { common, here } from "./bundle-config.mjs";

const kb = (n) => `${(n / 1024).toFixed(0)} KB`;

const main = await build({
  ...common,
  entryPoints: [path.join(here, "entry.ts")],
  globalName: "HarborEngine",
  outfile: path.join(here, "dist/harbor-engine.js"),
  minify: false,
});

const tests = await build({
  ...common,
  entryPoints: [path.join(here, "test/shims-entry.js")],
  globalName: "HarborShims",
  outfile: path.join(here, "dist/shims-test.js"),
  minify: false,
});

const out = main.metafile.outputs[path.relative(process.cwd(), path.join(here, "dist/harbor-engine.js"))] ??
  Object.values(main.metafile.outputs).find((o) => o.entryPoint);
const inputs = Object.keys(main.metafile.inputs);
const upstreamFiles = inputs.filter((f) => f.includes("reference/harbor/src"));
const vendor = inputs.filter((f) => f.includes("node_modules"));

console.log(
  `harbor-engine.js  ${kb(out.bytes)}  (${inputs.length} modules: ${upstreamFiles.length} upstream, ${vendor.length} vendor)`,
);
console.log(`shims-test.js     ${kb(Object.values(tests.metafile.outputs).find((o) => o.entryPoint).bytes)}`);

if (process.argv.includes("--min")) {
  const min = await build({
    ...common,
    entryPoints: [path.join(here, "entry.ts")],
    globalName: "HarborEngine",
    outfile: path.join(here, "dist/harbor-engine.min.js"),
    minify: true,
  });
  console.log(`harbor-engine.min.js ${kb(Object.values(min.metafile.outputs).find((o) => o.entryPoint).bytes)}`);
}

fs.writeFileSync(
  path.join(here, "dist/metafile.json"),
  JSON.stringify(main.metafile, null, 0),
);

// Guard rail: shout if anything DOM/React-ish sneaks in.
const suspicious = upstreamFiles.filter((f) => /\.tsx$/.test(f));
if (suspicious.length) {
  console.log(`\nNOTE: ${suspicious.length} .tsx file(s) in the bundle (React stubbed):`);
  for (const f of suspicious) console.log("  " + f);
}
