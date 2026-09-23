// Stage 3 glue: from a title (+ episode) to ranked streams and a playable URL.
// Mirrors views/play-picker/use-imdb-id.ts, use-addons.ts and use-pipeline-result.ts without React.
import type { Addon } from "@/lib/addons";
import { torboxAddonFor, userAddons, withDebridKeys } from "@/lib/addons";
import { fetchInstalledAddons, fetchManifestAt, filterEnabled } from "@/lib/addon-store";
import { applyOrderToItems, loadDisplayOrder } from "@/lib/addons-store/reorder";
import { narrowMediaType, isAddonNativeMeta, type Meta } from "@/lib/cinemeta";
import { buildDebridClients } from "@/lib/debrid/registry";
import type { DebridStore } from "@/lib/debrid/types";
import { animeKitsuMeta } from "@/lib/providers/anime-kitsu-addon";
import { externalToKitsu, kitsuToImdb } from "@/lib/providers/anime-mapping";
import { tmdbImdbId } from "@/lib/providers/tmdb";
import { loadEffective } from "@/lib/settings/profile-store";
import type { Settings } from "@/lib/settings/types";
import { buildStreamIdsWithIdentity } from "@/lib/streams/anime-identity";
import { buildEpisodePipelineInput } from "@/lib/streams/episode-pipeline-input";
import { runPipeline, type PipelineResult } from "@/lib/streams/pipeline";
import { resolveStream, type ResolveResult } from "@/lib/streams/resolve";
import type { ScoredStream } from "@/lib/streams/types";
import type { PlayEpisode } from "@/lib/view";
import { cinemetaImdbFallback, stampAddonOrder } from "@/views/play-picker/picker-utils";
import { shims } from "./shims/index.js";

export type ResolvedImdb = { id: string | null; verified: boolean };
const UNRESOLVED: ResolvedImdb = { id: null, verified: false };

/** use-imdb-id.ts as a function. */
export async function resolveImdb(meta: Meta, tmdbKey: string | undefined): Promise<ResolvedImdb> {
  if (meta.id.startsWith("tt")) return { id: meta.id, verified: true };
  const ext = meta.id.match(/^(kitsu|mal|anilist|anidb):(\d+)$/);
  if (ext) {
    const source = ext[1] === "mal" ? "myanimelist" : ext[1];
    const rawId = parseInt(ext[2], 10);
    let kitsuId = source === "kitsu" ? rawId : null;
    if (source !== "kitsu" && Number.isFinite(rawId)) kitsuId = await externalToKitsu(source, rawId).catch(() => null);
    if (kitsuId && Number.isFinite(kitsuId)) {
      const addonRes = await animeKitsuMeta(`kitsu:${kitsuId}`).catch(() => null);
      if (addonRes?.imdb_id) return { id: addonRes.imdb_id, verified: true };
      const fromXml = await kitsuToImdb(kitsuId).catch(() => null);
      return fromXml ? { id: fromXml, verified: true } : UNRESOLVED;
    }
    return UNRESOLVED;
  }
  if (isAddonNativeMeta(meta)) return UNRESOLVED;
  if (tmdbKey) {
    const id = await tmdbImdbId(tmdbKey, meta.id).catch(() => null);
    if (id) return { id, verified: true };
  }
  const fallback = await cinemetaImdbFallback(meta.name, narrowMediaType(meta.type), meta.releaseInfo).catch(() => null);
  return fallback ? { id: fallback, verified: false } : UNRESOLVED;
}

const hasAnyResources = (a: Addon) => (a.manifest.resources ?? []).length > 0;

/** use-addons.ts as a function: Stremio account addons + locally installed, manifests resolved,
 * user order applied, debrid keys injected, TorBox auto-added. Stream plugins come later. */
export async function gatherStreamAddons(authKey: string | null, settings: Settings): Promise<Addon[]> {
  const stremioAddons = filterEnabled(authKey ? await userAddons(authKey).catch(() => [] as Addon[]) : []);
  const installed = filterEnabled(await fetchInstalledAddons().catch(() => [] as Addon[]));
  const merged: Addon[] = [];
  const idxByUrl = new Map<string, number>();
  for (const a of [...stremioAddons, ...installed]) {
    const existing = idxByUrl.get(a.transportUrl);
    if (existing === undefined) { idxByUrl.set(a.transportUrl, merged.length); merged.push(a); continue; }
    if (!hasAnyResources(merged[existing]) && hasAnyResources(a)) merged[existing] = a;
  }
  const resolved = await Promise.all(merged.map(async (a) => {
    if (hasAnyResources(a)) return a;
    const manifest = await fetchManifestAt(a.transportUrl).catch(() => null);
    return manifest ? { ...a, manifest } : a;
  }));
  const savedOrder = loadDisplayOrder();
  const ordered = savedOrder.length > 0 ? applyOrderToItems(resolved, savedOrder) : resolved;
  const list = withDebridKeys(ordered, { rdKey: settings.rdKey, tbKey: settings.tbKey, adKey: settings.adKey, pmKey: settings.pmKey, dlKey: settings.dlKey });
  const torbox = torboxAddonFor(settings.tbKey);
  if (torbox) {
    const i = list.findIndex((a) => a.manifest.id === "app.torbox.stremio" || a.transportUrl?.includes("stremio.torbox.app"));
    if (i >= 0) { if (list[i].transportUrl !== torbox.transportUrl) list[i] = torbox; } else list.push(torbox);
  }
  return list;
}

function debridsFor(settings: Settings): DebridStore[] {
  return buildDebridClients({ rdKey: settings.rdKey, tbKey: settings.tbKey, adKey: settings.adKey, pmKey: settings.pmKey, dlKey: settings.dlKey });
}

export type StreamSearch = {
  token: string;
  imdb: ResolvedImdb;
  streamIds: string[];
  addonCount: number;
  result: PipelineResult | null;
  error?: string;
};

const searches = new Map<string, AbortController>();
const lastResults = new Map<string, PipelineResult>();

/**
 * Runs the whole picker pipeline for a title. Partial results arrive as
 * `harbor-tvos:streams` events `{ token, phase: "partial" | "progress", ... }`; the returned
 * value is the final result. `cancelSearch(token)` aborts.
 */
export async function search(
  token: string,
  profileId: string,
  linked: boolean,
  authKey: string | null,
  meta: Meta,
  episode: PlayEpisode | null,
  opts: { strictMode?: boolean; filterDisabled?: boolean } = {},
): Promise<StreamSearch> {
  const settings = loadEffective(profileId, linked);
  const ac = new AbortController();
  searches.get(token)?.abort();
  searches.set(token, ac);
  try {
    const imdb = await resolveImdb(meta, settings.tmdbKey || undefined);
    const streamIds = await buildStreamIdsWithIdentity(meta.id, episode ?? undefined, imdb.id, meta.behaviorHints?.defaultVideoId);
    if (streamIds.length === 0) return { token, imdb, streamIds, addonCount: 0, result: null, error: "no-stream-ids" };
    const addons = await gatherStreamAddons(authKey, settings);
    const input = buildEpisodePipelineInput({
      meta, episode: episode ?? undefined, imdbId: imdb.id, streamIds, addons, debrids: debridsFor(settings), settings,
      strictMode: opts.strictMode ?? false, filterDisabled: opts.filterDisabled ?? false, animeTitles: null,
    });
    const result = await runPipeline(
      input,
      ac.signal,
      (partial) => {
        if (ac.signal.aborted || partial.picker.all.length === 0) return;
        stampAddonOrder(partial.picker.all, partial.raw.addon);
        lastResults.set(token, partial);
        shims.events.emit("harbor-tvos:streams", { token, phase: "partial", picker: partial.picker, rejected: partial.rejected.length, debridErrors: partial.debridErrors ?? [] });
      },
      (progress) => {
        if (ac.signal.aborted) return;
        shims.events.emit("harbor-tvos:streams", { token, phase: "progress", ...progress });
      },
    );
    stampAddonOrder(result.picker.all, result.raw.addon);
    lastResults.set(token, result);
    return { token, imdb, streamIds, addonCount: addons.length, result };
  } catch (e) {
    return { token, imdb: UNRESOLVED, streamIds: [], addonCount: 0, result: null, error: (e as Error).message };
  } finally {
    if (searches.get(token) === ac) searches.delete(token);
  }
}

export function cancelSearch(token: string): void {
  searches.get(token)?.abort();
  searches.delete(token);
}

/** Turn a picked stream into a playable link (debrid unrestrict, direct URL, or P2P handoff). */
export async function resolve(
  profileId: string,
  linked: boolean,
  token: string,
  streamIndex: number,
  userCommitted = true,
): Promise<ResolveResult | { ok: false; code: "no-such-stream"; tried: [] }> {
  const settings = loadEffective(profileId, linked);
  const stream: ScoredStream | undefined = lastResults.get(token)?.picker.all[streamIndex];
  if (!stream) return { ok: false, code: "no-such-stream", tried: [] };
  const ac = new AbortController();
  return resolveStream(stream, debridsFor(settings), ac.signal, userCommitted);
}

export function forget(token: string): void {
  lastResults.delete(token);
}
