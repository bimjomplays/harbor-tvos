// Synchronous localStorage over an async-free host bridge.
//
// Upstream reads localStorage synchronously all over the place (settings, addon store,
// caches), so the shim keeps an in-memory map that is the source of truth for reads and
// writes through to the host. The host preloads the map at boot via storageSnapshot();
// if it cannot, reads fall back to a synchronous storageGet() and are memoized.
import { hostCall, hostHas } from "./host.js";

/**
 * (review 12) Lazy namespaces: the host's boot snapshot leaves these keys out (Swift
 * KeyValueStore.lazyPrefixes must match), so a key under them is read with storageGet the first
 * time it is asked for, then served from the map. Only the media-server per-title details and
 * their index (engine/media/index-store.ts) live here: thousands of small Caches files the app
 * needs only on the Media Servers tab. They are not in length / key() / __harborKeys until read,
 * as upstream kept them in IndexedDB, out of localStorage's enumerations.
 */
export const LAZY_PREFIXES = ["harbor.media-server.meta.v1.", "harbor.media-server.meta-index.v1"];
const isLazy = (key) => LAZY_PREFIXES.some((p) => key.startsWith(p));

export function createLocalStorage() {
  /** @type {Map<string,string>} */
  const map = new Map();
  /** Lazy keys the host said it does not have (a title without details is asked on every read). */
  const lazyMisses = new Set();
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
    const lazy = isLazy(key);
    if (preloaded && !lazy) return null;
    if (lazy && lazyMisses.has(key)) return null;
    if (!hostHas("storageGet")) return null;
    const v = hostCall("storageGet", key);
    const value = typeof v === "string" ? v : null;
    if (value !== null) map.set(key, value);
    else if (lazy) lazyMisses.add(key);
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
      lazyMisses.delete(k);
      hostCall("storageSet", k, v);
    },
    removeItem(key) {
      const k = String(key);
      map.delete(k);
      if (isLazy(k)) lazyMisses.add(k);
      hostCall("storageRemove", k);
    },
    clear() {
      map.clear();
      lazyMisses.clear();
      hostCall("storageClear");
    },
    /** Non-standard: lets the host push a changed key in without a rebuild. */
    __harborSync(key, value) {
      const k = String(key);
      if (value === null || value === undefined) {
        map.delete(k);
        if (isLazy(k)) lazyMisses.add(k);
      } else {
        map.set(k, String(value));
        lazyMisses.delete(k);
      }
    },
    /** Non-standard: every key the bundle has touched, for debugging/reporting. */
    __harborKeys() {
      return Array.from(map.keys());
    },
  };
  return storage;
}
