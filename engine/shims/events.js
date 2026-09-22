// Event / CustomEvent / EventTarget / AbortController / AbortSignal / DOMException.
// JavaScriptCore has none of them, and upstream Harbor leans on them heavily:
// AbortSignal for request cancellation and window CustomEvents for cross-module signals.

export class DOMExceptionShim extends Error {
  constructor(message = "", name = "Error") {
    super(message);
    this.name = name;
  }
}

export class EventShim {
  constructor(type, init = {}) {
    this.type = String(type);
    this.bubbles = !!init.bubbles;
    this.cancelable = !!init.cancelable;
    this.composed = !!init.composed;
    this.defaultPrevented = false;
    this.target = null;
    this.currentTarget = null;
    this.timeStamp = Date.now();
    this._stopped = false;
  }
  preventDefault() {
    if (this.cancelable) this.defaultPrevented = true;
  }
  stopPropagation() {
    this._stopped = true;
  }
  stopImmediatePropagation() {
    this._stopped = true;
    this._immediate = true;
  }
}

export class CustomEventShim extends EventShim {
  constructor(type, init = {}) {
    super(type, init);
    this.detail = init.detail === undefined ? null : init.detail;
  }
}

export class EventTargetShim {
  constructor() {
    Object.defineProperty(this, "_listeners", { value: new Map(), enumerable: false });
  }
  addEventListener(type, listener, options) {
    if (!listener) return;
    const key = String(type);
    let list = this._listeners.get(key);
    if (!list) this._listeners.set(key, (list = []));
    const once = typeof options === "object" && options ? !!options.once : false;
    if (list.some((e) => e.listener === listener)) return;
    list.push({ listener, once });
  }
  removeEventListener(type, listener) {
    const list = this._listeners.get(String(type));
    if (!list) return;
    const i = list.findIndex((e) => e.listener === listener);
    if (i >= 0) list.splice(i, 1);
  }
  dispatchEvent(event) {
    const list = this._listeners.get(String(event.type));
    event.target = this;
    event.currentTarget = this;
    if (list) {
      for (const entry of list.slice()) {
        if (entry.once) this.removeEventListener(event.type, entry.listener);
        try {
          if (typeof entry.listener === "function") entry.listener.call(this, event);
          else if (typeof entry.listener.handleEvent === "function") entry.listener.handleEvent(event);
        } catch (e) {
          // A throwing listener must not break the dispatcher, same as the DOM.
          reportListenerError(e);
        }
        if (event._immediate) break;
      }
    }
    return !event.defaultPrevented;
  }
}

let listenerErrorSink = (e) => {
  try {
    console.error("HarborEngine: event listener threw", e);
  } catch {}
};
export function setListenerErrorSink(fn) {
  listenerErrorSink = fn;
}
function reportListenerError(e) {
  listenerErrorSink(e);
}

export class AbortSignalShim extends EventTargetShim {
  constructor() {
    super();
    this.aborted = false;
    this.reason = undefined;
    this.onabort = null;
  }
  throwIfAborted() {
    if (this.aborted) throw this.reason;
  }
  static abort(reason) {
    const s = new AbortSignalShim();
    s.aborted = true;
    s.reason = reason === undefined ? new DOMExceptionShim("signal is aborted without reason", "AbortError") : reason;
    return s;
  }
  static timeout(ms) {
    const s = new AbortSignalShim();
    const t = setTimeout(() => abortSignal(s, new DOMExceptionShim("signal timed out", "TimeoutError")), ms);
    if (t && typeof t === "object" && "unref" in t) t.unref();
    return s;
  }
  static any(signals) {
    const out = new AbortSignalShim();
    for (const s of signals) {
      if (s.aborted) {
        abortSignal(out, s.reason);
        return out;
      }
      s.addEventListener("abort", () => abortSignal(out, s.reason));
    }
    return out;
  }
}

function abortSignal(signal, reason) {
  if (signal.aborted) return;
  signal.aborted = true;
  signal.reason = reason === undefined ? new DOMExceptionShim("This operation was aborted", "AbortError") : reason;
  const ev = new EventShim("abort");
  if (typeof signal.onabort === "function") {
    try {
      signal.onabort.call(signal, ev);
    } catch (e) {
      reportListenerError(e);
    }
  }
  signal.dispatchEvent(ev);
}

export class AbortControllerShim {
  constructor() {
    this.signal = new AbortSignalShim();
  }
  abort(reason) {
    abortSignal(this.signal, reason);
  }
}
