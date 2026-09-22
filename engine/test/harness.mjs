// Loads dist/harbor-engine.js the way JavaScriptCore will: a bare context with the
// ECMAScript library and nothing else, plus the __harbor_host bridge.
import { readFileSync, statSync } from "node:fs";
import vm from "node:vm";
import { createNodeHost } from "../shims/node-host.mjs";

const BUNDLE = new URL("../dist/harbor-engine.js", import.meta.url);

export function loadEngine(hostOptions = {}) {
  const source = readFileSync(BUNDLE, "utf8");
  const node = createNodeHost(hostOptions);
  // Only __harbor_host is injected. No console, no URL, no fetch, no timers - exactly
  // what a fresh JSContext on tvOS gives us.
  const ctx = vm.createContext({ __harbor_host: node.host });
  const t0 = process.hrtime.bigint();
  vm.runInContext(source, ctx, { filename: "harbor-engine.js" });
  const loadMs = Number(process.hrtime.bigint() - t0) / 1e6;
  node.bindTimerFire((id) => {
    const fire = vm.runInContext("__harbor_timer_fire", ctx);
    fire(id);
  });
  return {
    ctx,
    node,
    loadMs,
    bytes: statSync(BUNDLE).size,
    /** Evaluate an expression against HarborEngine and await it. */
    run: (expr) => vm.runInContext(expr, ctx),
    engine: vm.runInContext("HarborEngine", ctx),
    dispose: () => node.dispose(),
  };
}

export function createReporter(label) {
  let pass = 0;
  const failures = [];
  const timings = [];
  return {
    ok(name, cond, detail = "") {
      if (cond) pass++;
      else failures.push(`${name}${detail ? `\n      ${detail}` : ""}`);
      return cond;
    },
    eq(name, actual, expected) {
      return this.ok(name, JSON.stringify(actual) === JSON.stringify(expected), `got ${JSON.stringify(actual)} want ${JSON.stringify(expected)}`);
    },
    async timed(name, fn) {
      const t0 = process.hrtime.bigint();
      try {
        const v = await fn();
        timings.push([name, Number(process.hrtime.bigint() - t0) / 1e6]);
        return v;
      } catch (e) {
        timings.push([name, Number(process.hrtime.bigint() - t0) / 1e6]);
        failures.push(`${name} THREW\n      ${e && e.stack ? e.stack.split("\n").slice(0, 3).join("\n      ") : e}`);
        return undefined;
      }
    },
    timings,
    finish() {
      console.log(`\n${label}: ${pass} checks passed, ${failures.length} failed`);
      if (timings.length) {
        console.log("timings:");
        for (const [n, ms] of timings) console.log(`  ${n.padEnd(42)} ${ms.toFixed(0).padStart(6)} ms`);
      }
      if (failures.length) {
        for (const f of failures) console.log("  FAIL " + f);
        process.exitCode = 1;
      }
      return failures.length === 0;
    },
  };
}
