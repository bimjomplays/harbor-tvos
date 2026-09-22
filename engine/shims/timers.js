// setTimeout / setInterval / clearTimeout / clearInterval / queueMicrotask over native timers.
// JavaScriptCore has no event loop of its own: every timer is a native one that calls back
// into __harbor_timer_fire(id).
import { hostCall, hostHas } from "./host.js";

export function installTimers(target) {
  let nextId = 1;
  /** @type {Map<number, {fn:Function, args:any[], interval:number|null}>} */
  const timers = new Map();

  const schedule = (id, ms) => hostCall("setTimeout", ms, id);

  const fire = (id) => {
    const t = timers.get(id);
    if (!t) return;
    if (t.interval === null) timers.delete(id);
    else schedule(id, t.interval);
    try {
      t.fn.apply(undefined, t.args);
    } catch (e) {
      reportUncaught(e);
    }
  };

  const make = (interval) =>
    function (fn, delay, ...args) {
      if (typeof fn !== "function") {
        // The string form of setTimeout is not supported (no eval on tvOS JSC by policy).
        throw new TypeError("HarborEngine setTimeout/setInterval requires a function");
      }
      const ms = Math.max(0, Number(delay) || 0);
      const id = nextId++;
      timers.set(id, { fn, args, interval: interval ? ms : null });
      schedule(id, ms);
      return id;
    };

  const clear = (id) => {
    const n = Number(id);
    if (!timers.has(n)) return;
    timers.delete(n);
    if (hostHas("clearTimeout")) hostCall("clearTimeout", n);
  };

  target.setTimeout = make(false);
  target.setInterval = make(true);
  target.clearTimeout = clear;
  target.clearInterval = clear;
  target.__harbor_timer_fire = fire;
  if (typeof target.queueMicrotask !== "function") {
    const resolved = Promise.resolve();
    target.queueMicrotask = (fn) => {
      resolved.then(fn).catch(reportUncaught);
    };
  }
  return { pending: () => timers.size };
}

function reportUncaught(e) {
  try {
    const msg = e && e.stack ? e.stack : String(e);
    if (hostHas("log")) hostCall("log", "error", `uncaught in timer: ${msg}`);
    else console.error(e);
  } catch {}
}
