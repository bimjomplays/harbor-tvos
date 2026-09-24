// WebSocket over the host. JavaScriptCore has no sockets; upstream's Watch Together client
// (lib/together/client.ts) and Listen Together speak to the relay over `new WebSocket(url)`.
//
// Optional host functions (docs/engine-report.md §3): a host without them still boots, and
// `new WebSocket()` then throws, which TogetherClient.openSocket already treats as a failed
// attempt (its try/catch → failAttempt → the relay diagnosis the UI shows).
//   wsOpen(url, id)            start a connection; the host reports back through __harbor_ws_event
//   wsSend(id, text)           send one text frame
//   wsClose(id, code, reason)  close it (the host still reports "close" once it has)
// Host → JS: globalThis.__harbor_ws_event(id, kind, data)
//   kind "open"               data unused
//   kind "message"            data = the text frame
//   kind "error"              data = a message for the log
//   kind "close"              data = JSON {code, reason, wasClean}
import { hostCall, hostHas } from "./host.js";
import { EventTargetShim, EventShim } from "./events.js";

export const WS_HOST_FUNCTIONS = ["wsOpen", "wsSend", "wsClose"];

const CONNECTING = 0;
const OPEN = 1;
const CLOSING = 2;
const CLOSED = 3;

export function installWebSocket(g) {
  let nextId = 1;
  /** @type {Map<number, WebSocketShim>} */
  const live = new Map();

  class WebSocketShim extends EventTargetShim {
    constructor(url, protocols) {
      super();
      if (!WS_HOST_FUNCTIONS.every((n) => hostHas(n))) {
        throw new Error("HarborEngine: this host has no WebSocket support");
      }
      const u = String(url);
      if (!/^wss?:\/\//i.test(u)) {
        // The DOM throws a SyntaxError for a non-ws URL; same here.
        const e = new Error(`Failed to construct 'WebSocket': The URL '${u}' is invalid.`);
        e.name = "SyntaxError";
        throw e;
      }
      this.url = u;
      this.protocol = "";
      this.extensions = "";
      this.binaryType = "blob";
      this.bufferedAmount = 0;
      this.readyState = CONNECTING;
      this.onopen = null;
      this.onmessage = null;
      this.onerror = null;
      this.onclose = null;
      void protocols;
      this._id = nextId++;
      live.set(this._id, this);
      hostCall("wsOpen", u, this._id);
    }

    send(data) {
      if (this.readyState === CONNECTING) {
        const e = new Error("Failed to execute 'send' on 'WebSocket': Still in CONNECTING state.");
        e.name = "InvalidStateError";
        throw e;
      }
      if (this.readyState !== OPEN) return;
      hostCall("wsSend", this._id, typeof data === "string" ? data : String(data));
    }

    close(code, reason) {
      if (this.readyState === CLOSING || this.readyState === CLOSED) return;
      this.readyState = CLOSING;
      hostCall("wsClose", this._id, typeof code === "number" ? code : 1000, reason == null ? "" : String(reason));
    }

    _fire(type, event) {
      const handler = this["on" + type];
      if (typeof handler === "function") {
        try {
          handler.call(this, event);
        } catch (e) {
          if (g.console) g.console.error("WebSocket on" + type + " threw", e);
        }
      }
      this.dispatchEvent(event);
    }
  }
  WebSocketShim.CONNECTING = CONNECTING;
  WebSocketShim.OPEN = OPEN;
  WebSocketShim.CLOSING = CLOSING;
  WebSocketShim.CLOSED = CLOSED;
  Object.assign(WebSocketShim.prototype, { CONNECTING, OPEN, CLOSING, CLOSED });

  g.__harbor_ws_event = (rawId, kind, data) => {
    const ws = live.get(Number(rawId));
    if (!ws) return;
    if (kind === "open") {
      if (ws.readyState !== CONNECTING) return;
      ws.readyState = OPEN;
      ws._fire("open", new EventShim("open"));
    } else if (kind === "message") {
      if (ws.readyState !== OPEN) return;
      const ev = new EventShim("message");
      ev.data = data == null ? "" : String(data);
      ev.origin = ws.url;
      ws._fire("message", ev);
    } else if (kind === "error") {
      ws._fire("error", new EventShim("error"));
    } else if (kind === "close") {
      live.delete(ws._id);
      let info = {};
      try {
        info = typeof data === "string" && data ? JSON.parse(data) : {};
      } catch {}
      ws.readyState = CLOSED;
      const ev = new EventShim("close");
      ev.code = typeof info.code === "number" ? info.code : 1006;
      ev.reason = typeof info.reason === "string" ? info.reason : "";
      ev.wasClean = !!info.wasClean;
      ws._fire("close", ev);
    }
  };

  if (g.WebSocket === undefined) g.WebSocket = WebSocketShim;
  return { open: () => live.size };
}
