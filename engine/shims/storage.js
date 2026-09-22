// Synchronous localStorage over an async-free host bridge.
//
// Upstream reads localStorage synchronously all over the place (settings, addon store,
// caches), so the shim keeps an in-memory map that is the source of truth for reads and
// writes through to the host. The host preloads the map at boot via storageSnapshot();
// if it cannot, reads fall back to a synchronous storageGet() and are memoized.
import { hostCall, hostHas } from "./host.js";

export function createLocalStorage() {
  /** @type {Map<string,string>} */
  const map = new Map();
  let preloaded = false;

  if (hostHas("storageSnapshot")) {
    const snap = hostCall("storageSnapshot");
    if (snap && typeof snap === "object") {
      for (const k of Object.keys(snap)) {
        const v = snap[k];
        if (typeof v === "string") map.set(k, v);
      }
      preloaded = true;
    }
  }

  const readThrough = (key) => {
    if (map.has(key)) return map.get(key);
    if (preloaded) return null;
    if (!hostHas("storageGet")) return null;
    const v = hostCall("storageGet", key);
    const value = typeof v === "string" ? v : null;
    if (value !== null) map.set(key, value);
    return value;
  };

  const storage = {
    get length() {
      return map.size;
    },
    key(i) {
      const n = Number(i);
      if (!Number.isFinite(n) || n < 0) return null;
      let j = 0;
      for (const k of map.keys()) if (j++ === n) return k;
      return null;
    },
    getItem(key) {
      const k = String(key);
      const v = readThrough(k);
      return v === undefined ? null : v;
    },
    setItem(key, value) {
      const k = String(key);
      const v = String(value);
      map.set(k, v);
      hostCall("storageSet", k, v);
    },
    removeItem(key) {
      const k = String(key);
      map.delete(k);
      hostCall("storageRemove", k);
    },
    clear() {
      map.clear();
      hostCall("storageClear");
    },
    /** Non-standard: lets the host push a changed key in without a rebuild. */
    __harborSync(key, value) {
      if (value === null || value === undefined) map.delete(String(key));
      else map.set(String(key), String(value));
    },
    /** Non-standard: every key the bundle has touched, for debugging/reporting. */
    __harborKeys() {
      return Array.from(map.keys());
    },
  };
  return storage;
}
