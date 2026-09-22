// Shared esbuild configuration: the stub plugin and the JavaScriptCore-shaped options.
// build.mjs and test/probe.mjs both use it so a probe result always matches a real build.
import { fileURLToPath } from "node:url";
import path from "node:path";
import { execFileSync } from "node:child_process";
import fs from "node:fs";

export const here = path.dirname(fileURLToPath(import.meta.url));
export const upstream = path.resolve(here, "../reference/harbor/src");

/**
 * Every identifier upstream imports from any `@tauri-apps/*` package, scanned from the
 * submodule at build time so the stub tracks upstream instead of going stale. Each one
 * becomes an export that throws when called: a desktop-only API must fail loudly on tvOS,
 * never return a plausible value.
 */
export const tauriImportedNames = (() => {
  const names = new Set(["invoke", "isTauri", "convertFileSrc", "listen", "emit", "once"]);
  const walk = (dir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) walk(full);
      else if (/\.(ts|tsx|js|jsx)$/.test(e.name)) {
        const src = fs.readFileSync(full, "utf8");
        if (!src.includes("@tauri-apps/")) continue;
        for (const m of src.matchAll(/import\s*(?:type\s*)?\{([^}]*)\}\s*from\s*["']@tauri-apps\/[^"']+["']/g)) {
          for (const part of m[1].split(",")) {
            const id = part.trim().replace(/^type\s+/, "").split(/\s+as\s+/)[0].trim();
            if (/^[A-Za-z_$][\w$]*$/.test(id)) names.add(id);
          }
        }
      }
    }
  };
  try {
    walk(upstream);
  } catch {}
  return Array.from(names).sort();
})();

/** The upstream commit this bundle was made from, so the app can report what it is running. */
export const upstreamRev = (() => {
  try {
    return execFileSync("git", ["-C", path.resolve(here, "../reference/harbor"), "rev-parse", "--short", "HEAD"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return "unknown";
  }
})();

export const stubs = {
  name: "harbor-stubs",
  setup(b) {
    // --- Tauri desktop shell -------------------------------------------------------------
    b.onResolve({ filter: /^@tauri-apps\// }, (a) => ({ path: a.path, namespace: "tauri-stub" }));
    b.onLoad({ filter: /.*/, namespace: "tauri-stub" }, (a) => ({
      loader: "js",
      contents: [
        `const missing = (name) => () => { throw new Error("HarborEngine: ${a.path}." + name + "() is desktop-only and is not available on tvOS"); };`,
        // The http plugin's fetch is only reached on the Tauri branch of safe-fetch, which
        // isTauri===false disables - but wire it to the host fetch anyway so a stray call
        // does the right thing instead of exploding.
        ...tauriImportedNames.map((n) =>
          n === "fetch"
            ? "export const fetch = (...a) => globalThis.fetch(...a);"
            : n === "isTauri"
              ? "export const isTauri = false;"
              : `export const ${n} = missing(${JSON.stringify(n)});`,
        ),
        "export default {};",
      ].join("\n"),
    }));

    // --- React ---------------------------------------------------------------------------
    // Several upstream files mix pure helpers with a hook in the same module. We import the
    // pure helpers; the hooks are never called. The stub is a CommonJS Proxy so ANY named
    // import resolves, and every one of them throws when actually called - so a mistake
    // shows up as a loud exception instead of a wrong value.
    // Icon packs are pure UI: every named import becomes a component that renders nothing.
    // CommonJS so named imports need no static export list.
    b.onResolve({ filter: /^lucide-react($|\/)/ }, (a) => ({ path: a.path, namespace: "icon-stub" }));
    b.onLoad({ filter: /.*/, namespace: "icon-stub" }, () => ({
      contents: "module.exports = new Proxy({}, { get: (_, name) => name === '__esModule' ? true : function IconStub() { return null; } });",
      loader: "js",
    }));
    b.onResolve({ filter: /^react($|\/)|^react-dom($|\/)|^scheduler($|\/)/ }, (a) => ({
      path: a.path,
      namespace: "react-stub",
    }));
    b.onLoad({ filter: /.*/, namespace: "react-stub" }, (a) => ({
      loader: "js",
      contents: `
// Anything that only SHAPES a module (createContext, memo, forwardRef, lazy) returns an
// inert value, because upstream calls those at module top level. Anything that RENDERS or
// is a hook throws, so a mistake is a loud exception and never a wrong value.
const dead = (name) =>
  function harborReactStub() {
    throw new Error(
      "HarborEngine: ${a.path}." + name + "() was called, but tvOS has no React. " +
      "Import the pure helper next to the hook instead (see docs/engine-report.md).",
    );
  };
export const Fragment = Symbol.for("react.fragment");
export const StrictMode = Symbol.for("react.strict_mode");
export const Suspense = Symbol.for("react.suspense");
export const Profiler = Symbol.for("react.profiler");
export const version = "0.0.0-harbor-stub";
export const createContext = (defaultValue) => ({
  $$typeof: Symbol.for("react.context"),
  Provider: dead("Context.Provider"),
  Consumer: dead("Context.Consumer"),
  displayName: undefined,
  _currentValue: defaultValue,
  _currentValue2: defaultValue,
});
export const memo = (c) => c;
export const forwardRef = (c) => c;
export const lazy = (loader) => ({ $$typeof: Symbol.for("react.lazy"), _payload: loader });
export const createRef = () => ({ current: null });
export const isValidElement = () => false;
export const Children = {
  map: dead("Children.map"), forEach: dead("Children.forEach"),
  count: dead("Children.count"), only: dead("Children.only"), toArray: dead("Children.toArray"),
};
export const useState = dead("useState");
export const useEffect = dead("useEffect");
export const useLayoutEffect = dead("useLayoutEffect");
export const useInsertionEffect = dead("useInsertionEffect");
export const useMemo = dead("useMemo");
export const useCallback = dead("useCallback");
export const useRef = dead("useRef");
export const useContext = dead("useContext");
export const useReducer = dead("useReducer");
export const useImperativeHandle = dead("useImperativeHandle");
export const useDebugValue = dead("useDebugValue");
export const useSyncExternalStore = dead("useSyncExternalStore");
export const useTransition = dead("useTransition");
export const useDeferredValue = dead("useDeferredValue");
export const useId = dead("useId");
export const useOptimistic = dead("useOptimistic");
export const useActionState = dead("useActionState");
export const use = dead("use");
export const startTransition = dead("startTransition");
export const createElement = dead("createElement");
export const cloneElement = dead("cloneElement");
export const act = dead("act");
export const Component = dead("Component");
export const PureComponent = dead("PureComponent");
// react/jsx-runtime
export const jsx = dead("jsx");
export const jsxs = dead("jsxs");
export const jsxDEV = dead("jsxDEV");
// react-dom
export const createPortal = dead("createPortal");
export const flushSync = dead("flushSync");
export const findDOMNode = dead("findDOMNode");
export const createRoot = dead("createRoot");
export const hydrateRoot = dead("hydrateRoot");
export const render = dead("render");
export const unstable_batchedUpdates = (fn) => fn();
export default {
  Fragment, StrictMode, Suspense, Profiler, version, createContext, memo, forwardRef, lazy,
  createRef, isValidElement, Children, useState, useEffect, useLayoutEffect, useMemo,
  useCallback, useRef, useContext, useReducer, useSyncExternalStore, useId, createElement,
  cloneElement, startTransition,
};
`,
    }));

    // --- Vite asset imports ----------------------------------------------------------------
    // \`import poster from "@/assets/x.png"\` is a Vite URL string. tvOS ships no web assets,
    // so it becomes a stable "harbor-asset:" identifier the Swift side can map to a bundled
    // image (or ignore). Never a data URI: that would put megabytes in the JS.
    b.onResolve({ filter: /\.(png|jpe?g|gif|webp|avif|svg|woff2?|ttf|otf|mp3|wav|mp4|webm)$/ }, (a) => ({
      path: a.path.replace(/^.*[\\/]assets[\\/]/, ""),
      namespace: "asset-stub",
    }));
    b.onLoad({ filter: /.*/, namespace: "asset-stub" }, (a) => ({
      loader: "js",
      contents: `export default ${JSON.stringify("harbor-asset:/" + a.path)};`,
    }));
  },
};

export const common = {
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
    // Upstream is a Vite app: import.meta.env is its build-time config object. Defining the
    // whole object (not just .DEV) keeps esbuild's "import.meta in iife" warning quiet and
    // lets config/endpoints.ts fall back to its production defaults.
    "import.meta.env": '{"DEV":false,"PROD":true,"MODE":"production","SSR":false}',
    "import.meta.env.DEV": "false",
    "import.meta.env.PROD": "true",
    "import.meta.env.MODE": '"production"',
    "process.env.NODE_ENV": '"production"',
    __HARBOR_UPSTREAM_REV__: JSON.stringify(upstreamRev),
    __HARBOR_BUILT_AT__: JSON.stringify(new Date().toISOString().slice(0, 19) + "Z"),
  },
  loader: { ".json": "json" },
};

