// Runs the polyfills inside a bare vm context - which has exactly the globals
// JavaScriptCore on tvOS has (Intl/Promise/JSON and nothing else) - and compares them
// against Node's real implementations.
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { createNodeHost } from "../shims/node-host.mjs";

let pass = 0;
const failures = [];
function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) pass++;
  else failures.push(`${name}\n    got      ${a}\n    expected ${e}`);
}
function ok(name, cond, detail = "") {
  if (cond) pass++;
  else failures.push(`${name}${detail ? `\n    ${detail}` : ""}`);
}

const nodeHost = createNodeHost();
const ctx = vm.createContext({ __harbor_host: nodeHost.host });
vm.runInContext(readFileSync(new URL("../dist/shims-test.js", import.meta.url), "utf8"), ctx);
nodeHost.bindTimerFire((id) => vm.runInContext("__harbor_timer_fire", ctx)(id));
const run = (src) => vm.runInContext(src, ctx);

// ---------------------------------------------------------------- URL: differential test
const URL_CASES = [
  ["https://v3-cinemeta.strem.io/catalog/movie/top.json", null],
  ["https://a.com/b/c/d", "../../x"],
  ["https://a.com/b/c/d", "./e"],
  ["https://a.com/b/c/d", "/abs"],
  ["https://a.com/b/c/d", "//cdn.other.com/p?q"],
  ["https://a.com/b/c/d", "?only=query"],
  ["https://a.com/b/c/d", "#only-hash"],
  ["https://a.com/b/c/d", ""],
  ["https://a.com/b/c/d", "https://full.example/x"],
  ["https://a.com", "a/b/../../../c"],
  ["https://a.com/p", "..%2f..%2fetc"],
  ["http://a.com:80/x", null],
  ["https://a.com:443/x", null],
  ["https://a.com:8443/x", null],
  ["https://user:p@ss@a.com/x", null],
  ["https://a.com/p ath/with space?q=a b#h i", null],
  ["https://a.com/?q=%E6%97%A5%E6%9C%AC", null],
  ["https://日本.example/パス?検索=値#断片", null],
  ["https://xn--wgv71a.example/", null],
  ["https://a.com/p?a=1&a=2&b=&c", null],
  ["https://a.com/\\backslash", null],
  ["https://[2001:db8::1]:8080/p", null],
  ["https://127.0.0.1:11470/hlsv2/probe", null],
  ["stremio://addon.example.com/manifest.json", null],
  ["data:application/json;base64,eyJhIjoxfQ==", null],
  ["https://a.com/x", "mailto:a@b.c"],
  ["https://a.com/%zz", null],
  ["https://a.com/a%2Fb/c", null],
  ["HTTPS://A.COM/PaTh", null],
  ["  https://a.com/trimmed  ", null],
  ["https://a.com/p#frag?notquery", null],
  ["https://a.com/catalog/movie/top/genre=Science%20Fiction/skip=100.json", null],
];
for (const [base, rel] of URL_CASES) {
  const expr = rel === null ? `new URL(${JSON.stringify(base)})` : `new URL(${JSON.stringify(rel)}, ${JSON.stringify(base)})`;
  let mine, ref;
  const props = ["href", "protocol", "hostname", "port", "pathname", "search", "hash", "origin", "host", "username", "password"];
  try {
    mine = run(`(()=>{const u=${expr};return ${JSON.stringify(props)}.map(p=>String(u[p]))})()`);
  } catch (e) {
    mine = "THROW:" + e.name;
  }
  try {
    const u = rel === null ? new URL(base) : new URL(rel, base);
    ref = props.map((p) => String(u[p]));
  } catch (e) {
    ref = "THROW:" + e.name;
  }
  check(`URL ${JSON.stringify([base, rel])}`, mine, ref);
}

// invalid URLs must throw, not resolve to something plausible
for (const bad of ["not a url", "http://", "://x", "https://%%", ""]) {
  const mineThrows = (() => {
    try {
      run(`new URL(${JSON.stringify(bad)}).href`);
      return false;
    } catch {
      return true;
    }
  })();
  const refThrows = (() => {
    try {
      new URL(bad);
      return false;
    } catch {
      return true;
    }
  })();
  ok(`URL invalid ${JSON.stringify(bad)} throws==${refThrows}`, mineThrows === refThrows, `mine=${mineThrows} node=${refThrows}`);
}

// ------------------------------------------------------------- URLSearchParams behaviours
const SP_SCRIPTS = [
  `new URLSearchParams("a=1&b=two&a=3").getAll("a")`,
  `new URLSearchParams({a:"1",b:"x y"}).toString()`,
  `new URLSearchParams([["k","v"],["k","w"]]).toString()`,
  `(()=>{const p=new URLSearchParams();p.set("q","星 空 & 海");p.append("t","a+b");return p.toString()})()`,
  `new URLSearchParams("q=a+b&r=%20c%20").get("q")`,
  `new URLSearchParams("q=a+b&r=%20c%20").get("r")`,
  `(()=>{const p=new URLSearchParams("b=2&a=1&c=3");p.sort();return p.toString()})()`,
  `(()=>{const u=new URL("https://a.com/x?a=1");u.searchParams.set("b","é");return u.href})()`,
  `(()=>{const u=new URL("https://a.com/x?a=1&a=2");u.searchParams.delete("a");return u.href})()`,
  `[...new URLSearchParams("a=1&b=2").entries()]`,
  `new URLSearchParams("?leading=1").get("leading")`,
  `new URLSearchParams("a=%E2%9C%93").get("a")`,
];
for (const src of SP_SCRIPTS) {
  let mine, ref;
  try { mine = run(`JSON.stringify((${src}))`); } catch (e) { mine = "THROW:" + e.message; }
  try { ref = JSON.stringify(eval(src)); } catch (e) { ref = "THROW:" + e.message; }
  check(`USP ${src.slice(0, 60)}`, mine, ref);
}

// ------------------------------------------------------------------------- TextEncoder/Decoder
const TEXTS = ["", "ascii", "héllo wörld", "日本語テキスト", "emoji 👨‍👩‍👧‍👦 家族", "\u0000\u001f\u007f", "a".repeat(5000) + "é"];
for (const t of TEXTS) {
  check(`encode ${JSON.stringify(t.slice(0, 20))}`, run(`Array.from(new TextEncoder().encode(${JSON.stringify(t)}))`), Array.from(new TextEncoder().encode(t)));
  const bytes = Array.from(new TextEncoder().encode(t));
  check(`decode roundtrip ${JSON.stringify(t.slice(0, 20))}`, run(`new TextDecoder().decode(new Uint8Array(${JSON.stringify(bytes)}))`), t);
}
// lone surrogate -> U+FFFD, matching WHATWG
check("encode lone surrogate", run(`Array.from(new TextEncoder().encode("a\\uD800b"))`), Array.from(new TextEncoder().encode("a\uD800b")));
// invalid UTF-8 sequences -> U+FFFD, matching Node
for (const bytes of [[0xff], [0xc0, 0x80], [0xe0, 0x80, 0x80], [0xed, 0xa0, 0x80], [0xf5, 0x80, 0x80, 0x80], [0xe2, 0x28, 0xa1], [0xf0, 0x9f]]) {
  check(`decode invalid ${bytes}`, run(`new TextDecoder().decode(new Uint8Array(${JSON.stringify(bytes)}))`), new TextDecoder().decode(new Uint8Array(bytes)));
}
ok("decode fatal throws", (() => { try { run(`new TextDecoder("utf-8",{fatal:true}).decode(new Uint8Array([0xff]))`); return false; } catch { return true; } })());
check("decode strips BOM", run(`new TextDecoder().decode(new Uint8Array([0xef,0xbb,0xbf,0x41]))`), "A");

// ------------------------------------------------------------------------------ atob / btoa
for (const s of ["", "a", "ab", "abc", "hello world", "\u0000ÿ", "The quick brown fox"]) {
  check(`btoa ${JSON.stringify(s)}`, run(`btoa(${JSON.stringify(s)})`), Buffer.from(s, "latin1").toString("base64"));
  const b64 = Buffer.from(s, "latin1").toString("base64");
  check(`atob ${JSON.stringify(b64)}`, run(`atob(${JSON.stringify(b64)})`), s);
}
ok("btoa rejects non-latin1", (() => { try { run(`btoa("é★")`); return false; } catch { return true; } })());
ok("atob rejects garbage", (() => { try { run(`atob("!!!!")`); return false; } catch { return true; } })());

// --------------------------------------------------------------------------------- crypto
const uuid = run(`crypto.randomUUID()`);
ok("randomUUID shape", /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(uuid), uuid);
ok("randomUUID unique", run(`new Set(Array.from({length:200},()=>crypto.randomUUID())).size`) === 200);
ok("getRandomValues fills", run(`(()=>{const a=new Uint8Array(32);crypto.getRandomValues(a);return a.some(x=>x!==0)})()`));
const { createHash } = await import("node:crypto");
for (const s of ["", "abc", "harbor", "a".repeat(1000), "日本語"]) {
  const mine = await run(`(async()=>{const d=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(${JSON.stringify(s)}));return Array.from(new Uint8Array(d)).map(b=>b.toString(16).padStart(2,"0")).join("")})()`);
  check(`sha256 ${JSON.stringify(s.slice(0, 10))}`, mine, createHash("sha256").update(s, "utf8").digest("hex"));
}
ok("subtle rejects other algorithms", await run(`crypto.subtle.digest("SHA-1",new Uint8Array(1)).then(()=>false,()=>true)`));

// -------------------------------------------------------------------------------- headers
check("headers case-insensitive", run(`(()=>{const h=new Headers({"Content-Type":"application/json"});return [h.get("content-TYPE"),h.has("CONTENT-TYPE")]})()`), ["application/json", true]);
check("headers append joins", run(`(()=>{const h=new Headers();h.append("x","1");h.append("X","2");return h.get("x")})()`), "1, 2");
check("headers iterate sorted", run(`[...new Headers({b:"2",a:"1"}).entries()]`), [["a", "1"], ["b", "2"]]);

// ------------------------------------------------------------------------------ localStorage
run(`localStorage.setItem("harbor.test","{\\"a\\":1}")`);
check("localStorage read back", run(`localStorage.getItem("harbor.test")`), '{"a":1}');
check("localStorage wrote through to host", nodeHost.storage.get("harbor.test"), '{"a":1}');
check("localStorage missing is null", run(`localStorage.getItem("nope")`), null);
run(`localStorage.removeItem("harbor.test")`);
check("localStorage remove", [run(`localStorage.getItem("harbor.test")`), nodeHost.storage.has("harbor.test")], [null, false]);

// ----------------------------------------------------------------------------- structuredClone
check("structuredClone deep", run(`(()=>{const a={x:[1,{y:"z"}]};const b=structuredClone(a);b.x[1].y="q";return [a.x[1].y,b.x[1].y]})()`), ["z", "q"]);
ok("structuredClone rejects Map", (() => { try { run(`structuredClone(new Map())`); return false; } catch { return true; } })());

// ----------------------------------------------------------------------------------- timers
const timerOrder = await new Promise((resolve) => {
  run(`globalThis.__order = []`);
  run(`setTimeout(()=>__order.push("b"), 20)`);
  run(`setTimeout(()=>__order.push("a"), 1)`);
  const id = run(`setTimeout(()=>__order.push("never"), 5)`);
  run(`clearTimeout(${id})`);
  run(`queueMicrotask(()=>__order.push("micro"))`);
  setTimeout(() => resolve(run(`__order`)), 80);
});
check("timers fire in order, clearTimeout works", Array.from(timerOrder), ["micro", "a", "b"]);

// ---------------------------------------------------------------------- AbortController / fetch
ok("abort before fetch rejects", await run(`(()=>{const c=new AbortController();c.abort();return fetch("https://example.invalid",{signal:c.signal}).then(()=>false,e=>e.name==="AbortError")})()`));
ok("AbortSignal fires listeners", run(`(()=>{let hit=0;const c=new AbortController();c.signal.addEventListener("abort",()=>hit++);c.abort();c.abort();return hit===1&&c.signal.aborted})()`));
ok("fetch rejects on host failure", await (async () => {
  const offline = createNodeHost({ offline: true });
  const c2 = vm.createContext({ __harbor_host: offline.host });
  vm.runInContext(readFileSync(new URL("../dist/shims-test.js", import.meta.url), "utf8"), c2);
  return vm.runInContext(`fetch("https://example.com").then(()=>false,e=>e instanceof TypeError)`, c2);
})());

// ------------------------------------------------------------------------------ window events
check("window CustomEvent round-trip", run(`(()=>{const seen=[];window.addEventListener("harbor:test",(e)=>seen.push(e.detail));window.dispatchEvent(new CustomEvent("harbor:test",{detail:{n:1}}));return seen})()`), [{ n: 1 }]);
check("window.location.hostname is not harbor.site", run(`window.location.hostname`), "engine.harbor-tvos.local");
check("no __TAURI_INTERNALS__", run(`"__TAURI_INTERNALS__" in window`), false);
check("shims.events.on observes dispatch", run(`(()=>{const out=[];const off=HarborShims.shims.events.on((t,d)=>out.push([t,d]));window.dispatchEvent(new CustomEvent("harbor:x",{detail:7}));off();window.dispatchEvent(new CustomEvent("harbor:y",{detail:8}));return out})()`), [["harbor:x", 7]]);

// ------------------------------------------------------------------------------ real network
const cine = await run(`fetch("https://v3-cinemeta.strem.io/catalog/movie/top.json").then(async r=>({ok:r.ok,status:r.status,ct:r.headers.get("content-type"),n:(await r.json()).metas.length}))`);
ok("fetch cinemeta live", cine.ok && cine.status === 200 && cine.n > 0, JSON.stringify(cine));
ok("fetch 404 is ok:false not a throw", await run(`fetch("https://v3-cinemeta.strem.io/definitely-not-a-thing.json").then(r=>r.ok===false&&r.status>=400,()=>"threw")`) === true);

nodeHost.dispose();
console.log(`shims: ${pass} checks passed, ${failures.length} failed`);
if (failures.length) {
  for (const f of failures) console.log("  FAIL " + f);
  process.exit(1);
}
