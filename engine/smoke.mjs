// Runs the bundle the way JavaScriptCore will: no DOM, no Node globals, just the script text.
import { readFileSync } from "node:fs";
import vm from "node:vm";
const ctx = vm.createContext({ console });
vm.runInContext(readFileSync(new URL("./dist/harbor-engine.js", import.meta.url), "utf8"), ctx);
const r = vm.runInContext("HarborEngine.benchmark(50)", ctx);
console.log(JSON.stringify(r));
