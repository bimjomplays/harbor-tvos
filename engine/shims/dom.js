// The smallest `window` / `document` / `navigator` / `location` that lets upstream's
// framework-free modules run. This is NOT a DOM: there is no element, no layout, no
// styling. It exists because upstream uses `window` as an event bus
// (`window.dispatchEvent(new CustomEvent("harbor:...")`) and reads `window.location.hostname`
// in safe-fetch to decide whether it is running on harbor.site (it is not, so every request
// goes direct).
//
// Every CustomEvent dispatched on `window` is mirrored to HarborEngine.events so the Swift
// side can observe or inject them; docs/engine-report.md lists the ones that matter.
import { CustomEventShim, EventShim, EventTargetShim } from "./events.js";

export function createDom(globals) {
  const listeners = new Set();

  class HarborWindow extends EventTargetShim {
    dispatchEvent(event) {
      const ok = super.dispatchEvent(event);
      for (const fn of listeners) {
        try {
          fn(event.type, event instanceof CustomEventShim ? event.detail : undefined);
        } catch {}
      }
      return ok;
    }
  }

  // `document.documentElement` is a no-op attribute holder. The bundle carries no UI, so
  // there is nothing for `dir`, `lang`, a class or a CSS custom property to affect - but
  // upstream's i18n store writes them at import time. Anything that would need a REAL
  // element (createElement, body, querySelector) is deliberately absent so a UI module
  // pulled in by mistake throws instead of half-working.
  const documentElement = {
    dir: "ltr",
    lang: "en",
    style: { setProperty() {}, removeProperty() {}, getPropertyValue: () => "" },
    classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
    setAttribute() {},
    removeAttribute() {},
    getAttribute: () => null,
    dataset: {},
  };
  const doc = new EventTargetShim();
  Object.assign(doc, {
    visibilityState: "visible",
    hidden: false,
    readyState: "complete",
    title: "Harbor",
    documentElement,
    head: documentElement,
  });

  const win = new HarborWindow();
  const location = {
    href: "harbor-tvos://engine/",
    protocol: "harbor-tvos:",
    // Not harbor.site and not localhost, so safe-fetch's web proxy rewrite stays off and
    // every request goes straight out through the host.
    hostname: "engine.harbor-tvos.local",
    host: "engine.harbor-tvos.local",
    origin: "harbor-tvos://engine.harbor-tvos.local",
    pathname: "/",
    search: "",
    hash: "",
    reload() {},
    assign() {},
    replace() {},
    toString() {
      return this.href;
    },
  };
  const navigator = {
    userAgent: "HarborEngine/tvOS",
    language: "en-US",
    languages: ["en-US"],
    onLine: true,
    platform: "tvOS",
    hardwareConcurrency: 2,
  };

  Object.assign(win, {
    location,
    navigator,
    document: doc,
    setTimeout: globals.setTimeout,
    clearTimeout: globals.clearTimeout,
    setInterval: globals.setInterval,
    clearInterval: globals.clearInterval,
    requestAnimationFrame: (fn) => globals.setTimeout(() => fn(globals.performance.now()), 16),
    cancelAnimationFrame: (id) => globals.clearTimeout(id),
    matchMedia: (query) => ({
      media: String(query),
      matches: false,
      addEventListener() {},
      removeEventListener() {},
      addListener() {},
      removeListener() {},
    }),
  });
  win.window = win;
  win.self = win;
  win.globalThis = globals;

  // The app's lifecycle, from the host (tvOS: UIApplication background/foreground and
  // NWPathMonitor). Upstream flushes and wakes on these: profile-sync's scheduler pushes its
  // queue on hidden and pulls when it comes back stale, the account session refresh runs on
  // wake and on "online", storage-recovery and the Suwayomi progress bridge flush on hidden,
  // Trakt/Simkl pending syncs retry on "online", and a failed MAL token refresh only signs
  // out while navigator.onLine is true. Without these the bundle always looked visible and
  // online, so none of that ever ran on a TV.
  const lifecycle = {
    /** Returns true when the state changed (and the events went out). */
    setVisibility(visible) {
      const state = visible ? "visible" : "hidden";
      if (doc.visibilityState === state) return false;
      doc.visibilityState = state;
      doc.hidden = !visible;
      // A browser fires it at the document and it propagates to the window; upstream listens
      // on both.
      doc.dispatchEvent(new EventShim("visibilitychange"));
      win.dispatchEvent(new EventShim("visibilitychange"));
      return true;
    },
    setOnline(online) {
      const next = !!online;
      if (navigator.onLine === next) return false;
      navigator.onLine = next;
      win.dispatchEvent(new EventShim(next ? "online" : "offline"));
      return true;
    },
  };

  return {
    window: win,
    document: doc,
    location,
    navigator,
    lifecycle,
    events: {
      /** Observe every event dispatched on `window`. Returns an unsubscribe function. */
      on(fn) {
        listeners.add(fn);
        return () => listeners.delete(fn);
      },
      /** Dispatch one into the bundle (Swift -> JS direction). */
      emit(type, detail) {
        win.dispatchEvent(detail === undefined ? new EventShim(type) : new CustomEventShim(type, { detail }));
      },
    },
  };
}
