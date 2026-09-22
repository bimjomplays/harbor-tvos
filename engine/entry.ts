// Stage 0.4 spike: upstream's stream engine (parse → trust → score → rank) bundled for JavaScriptCore.
import { parseStream } from "@/lib/streams/parser";
import { computeCorpusStats, scoreStream, rankAndPick } from "@/lib/streams/scoring";
import { applyTrust } from "@/lib/streams/trust";
import { ADDON_SAMPLES } from "@/lib/streams/__fixtures__/addon-samples";
import type { Stream } from "@/lib/streams/types";

export { parseStream, applyTrust, computeCorpusStats, scoreStream, rankAndPick };

/** Runs the whole pipeline on upstream's own fixture streams, repeated to make timing visible. */
export function benchmark(rounds = 50): { streams: number; kept: number; best: string; ms: number } {
  const raw: Stream[] = [];
  for (let i = 0; i < rounds; i++) for (const s of ADDON_SAMPLES) raw.push(s.raw);
  const t0 = Date.now();
  const parsed = raw.map(parseStream);
  const { keep } = applyTrust(parsed, { disabled: false, strict: false });
  const opts = { activeDebrids: ["torbox" as const], mediaKind: "movie" as const };
  const corpus = computeCorpusStats(keep, opts);
  const scored = keep.map((s) => scoreStream(s, opts, corpus));
  const ranked = rankAndPick(scored, ["torbox"]);
  const best = ranked.primary ?? ranked.all[0];
  return {
    streams: raw.length,
    kept: keep.length,
    best: best ? `${best.resolution ?? "?"} ${best.parsedTitle ?? best.title ?? ""}`.trim() : "none",
    ms: Date.now() - t0,
  };
}
