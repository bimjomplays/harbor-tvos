// Bundles upstream Harbor's framework-free logic into one script for JavaScriptCore.
//
//   node build.mjs          -> dist/harbor-engine.js (+ dist/shims-test.js)
//   node build.mjs --min    -> also writes dist/harbor-engine.min.js
//
// Rules: nothing from upstream is ever copied into engine/. Every upstream module is
// imported through the `@` alias so re-bundling automatically tracks the submodule.
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";

const here = path.dirname(fileURLToPath(import.meta.url));
const upstream = path.resolve(here, "../reference/harbor/src");

/**
 * Modules that must never enter the bundle, each replaced by a stub that throws if it is
 * really used. A stub never returns a plausible-looking success value: a module that
 * depends on the desktop shell must fail loudly, not silently.
 */
const stubs = {
  name: "harbor-stubs",
  setup(b) {
    // --- Tauri desktop shell -------------------------------------------------------------
    b.onResolve({ filter: /^@tauri-apps\// }, (a) => ({ path: a.path, namespace: "tauri-stub" }));
    b.onLoad({ filter: /.*/, namespace: "tauri-stub" }, (a) => ({
      loader: "js",
      contents: `
const missing = (name) => () => {
  throw new Error("HarborEngine: ${a.path}." + name + "() is desktop-only and is not available on tvOS");
};
export const invoke = missing("invoke");
export const convertFileSrc = missing("convertFileSrc");
export const isTauri = false;
export const listen = missing("listen");
export const emit = missing("emit");
export const once = missing("once");
export const getCurrentWebview = missing("getCurrentWebview");
export const getCurrentWindow = missing("getCurrentWindow");
// The http plugin's fetch is only reached on the Tauri path, which isTauri===false disables.
export const fetch = (...a) => globalThis.fetch(...a);
export default {};
`,
    }));

    // --- React ---------------------------------------------------------------------------
    // Several upstream files mix pure helpers with a hook in the same module. We import the
    // pure helpers; the hooks are never called. The stub therefore throws when a hook runs,
    // so a mistake shows up as an exception instead of a wrong value.
    b.onResolve({ filter: /^react(\/.*)?$|^react-dom(\/.*)?$/ }, (a) => ({
      path: a.path,
      namespace: "react-stub",
    }));
    b.onLoad({ filter: /.*/, namespace: "react-stub" }, () => ({
      loader: "js",
      contents: `
const hook = (name) => () => {
  throw new Error("HarborEngine: React hook " + name + "() was called, but there is no React on tvOS. " +
    "Import the pure helper instead of the hook (see docs/engine-report.md).");
};
export const useState = hook("useState");
export const useEffect = hook("useEffect");
export const useLayoutEffect = hook("useLayoutEffect");
export const useMemo = hook("useMemo");
export const useCallback = hook("useCallback");
export const useRef = hook("useRef");
export const useContext = hook("useContext");
export const useReducer = hook("useReducer");
export const useSyncExternalStore = hook("useSyncExternalStore");
export const useId = hook("useId");
export const useTransition = hook("useTransition");
export const useDeferredValue = hook("useDeferredValue");
export const createContext = hook("createContext");
export const createElement = hook("createElement");
export const memo = (c) => c;
export const forwardRef = (c) => c;
export const Fragment = Symbol.for("react.fragment");
export default { useState, useEffect, useMemo, useCallback, useRef, useSyncExternalStore, createElement, Fragment, memo, forwardRef };
`,
    }));
  },
};

const common = {
  bundle: true,
  format: "iife",
  platform: "neutral",
  target: ["safari16"],
  mainFields: ["module", "main"],
  conditions: ["import", "default"],
  alias: { "@": upstream },
  nodePaths: [path.join(here, "node_modules")],
  plugins: [stubs],
  metafile: true,
  logLevel: "warning",
  sourcemap: false,
  define: {
    "import.meta.env.DEV": "false",
    "import.meta.env.PROD": "true",
    "import.meta.env.MODE": '"production"',
    "process.env.NODE_ENV": '"production"',
  },
  loader: { ".json": "json" },
};

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
