// Letterboxd through Stremboxd without React (lib/stremboxd/provider.tsx + settings
// letterboxd-panel.tsx "public" mode): a public username is all the TV needs. It turns on the
// Library's Letterboxd tab (use-bp-library-services useLetterboxdFeed: the watchlist catalog)
// and the Letterboxd rows on Movies (use-bp-movies useBpLetterboxdRows). Full mode (password
// sign-in through Stremboxd) is desktop-only here; a session made elsewhere is still honoured.
import type { Meta } from "@/lib/cinemeta";
import type { HomeRow } from "@/views/home/home-types";
import { fetchFullModeCatalog, fetchStremboxdCatalog, validateStremboxdConfig } from "@/lib/stremboxd/client";
import { buildStremboxdConfig } from "@/lib/stremboxd/settings-helper";
import { buildLetterboxdHomeRows } from "@/lib/stremboxd/home-rails";
import { invalidateLetterboxdCache } from "@/lib/stremboxd/cache";
import { stremboxdMetaToMeta } from "@/lib/stremboxd/to-meta";
import { getLetterboxdSession } from "@/lib/stremboxd/session";
import type { StremboxdMeta } from "@/lib/stremboxd/types";
import type { LetterboxdSettings } from "@/lib/settings/types";
import { loadEffective, persistEffective } from "@/lib/settings/profile-store";
import { markSettingsPatched } from "./sync";

function settingsOf(profileId: string, linked: boolean): LetterboxdSettings {
  return loadEffective(profileId, linked).letterboxd;
}

function write(profileId: string, linked: boolean, next: LetterboxdSettings): void {
  const s = loadEffective(profileId, linked);
  persistEffective({ ...s, letterboxd: next }, profileId, linked);
  markSettingsPatched(["letterboxd"]);
  if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent("harbor:settings-updated", { detail: { profileId, fields: ["letterboxd"] } }));
}

export type LetterboxdStatus = { enabled: boolean; mode: "public" | "full"; username: string; active: boolean; fullConnected: boolean };

/** provider.tsx: isActive = enabled && (full ? signed in : has a public username). */
export function status(profileId: string, linked: boolean): LetterboxdStatus {
  const lb = settingsOf(profileId, linked);
  const session = getLetterboxdSession();
  const fullConnected = !!session;
  const active = lb.enabled && (lb.mode === "full" ? fullConnected : lb.username.trim().length > 0);
  return { enabled: lb.enabled, mode: lb.mode, username: lb.username, active, fullConnected };
}

/** provider.tsx useBpLetterboxdRows `ready`: an active identity with something to ask for. */
function ready(profileId: string, linked: boolean): boolean {
  const lb = settingsOf(profileId, linked);
  const st = status(profileId, linked);
  const session = getLetterboxdSession();
  return st.active && !(lb.mode === "full" && !session) && !(lb.mode === "public" && !lb.encodedConfig);
}

/** letterboxd-panel.tsx handleVerify: check the username against Stremboxd, then turn it on. */
export async function connect(profileId: string, linked: boolean, username: string): Promise<{ ok: boolean; catalogs: number; message: string | null }> {
  const lb = settingsOf(profileId, linked);
  const name = username.trim().replace(/^@/, "");
  const config = buildStremboxdConfig({ ...lb, username: name, selectedCatalogs: lb.selectedCatalogs });
  const result = await validateStremboxdConfig(config, name.length > 0);
  if (!result.ok) return { ok: false, catalogs: 0, message: result.message };
  // The TV only offers public mode, so a full-mode setting with no session here falls back to it.
  const mode = lb.mode === "full" && getLetterboxdSession() ? "full" : "public";
  write(profileId, linked, { ...lb, enabled: true, mode, username: name, encodedConfig: config });
  invalidateLetterboxdCache();
  return { ok: true, catalogs: result.catalogs, message: null };
}

/** letterboxd-panel "Enable Letterboxd integration" switched off. */
export function disable(profileId: string, linked: boolean): void {
  const lb = settingsOf(profileId, linked);
  write(profileId, linked, { ...lb, enabled: false });
  invalidateLetterboxdCache();
}

/** Only the fields a TV card or detail page reads. */
function slim(m: StremboxdMeta): Meta {
  const full = stremboxdMetaToMeta(m);
  return {
    id: full.id, type: "movie", name: full.name, poster: full.poster, background: full.background,
    description: full.description, releaseInfo: full.releaseInfo, imdbRating: full.imdbRating,
    genres: full.genres, runtime: full.runtime,
  } as Meta;
}

/** use-bp-library-services useLetterboxdFeed: the first page of the watchlist catalog. */
export async function watchlist(profileId: string, linked: boolean): Promise<{ metas: Meta[]; status: "ready" | "error" }> {
  if (!status(profileId, linked).active) return { metas: [], status: "ready" };
  const lb = settingsOf(profileId, linked);
  const userId = getLetterboxdSession()?.userId ?? null;
  try {
    const page = userId
      ? await fetchFullModeCatalog(userId, "letterboxd-watchlist", 0)
      : await fetchStremboxdCatalog(lb.encodedConfig, "letterboxd-watchlist", 0);
    return { metas: page.metas.map(slim), status: "ready" };
  } catch {
    return { metas: [], status: "error" };
  }
}

/**
 * use-bp-extra-rows.ts `letterboxdRows`: stremboxd/home-rails rows as upstream builds them (Home
 * takes them verbatim, between the Simkl rails and the anime rows); empty unless `lbReady`.
 */
export async function homeRailRows(profileId: string, linked: boolean): Promise<HomeRow[]> {
  if (!ready(profileId, linked)) return [];
  const lb = settingsOf(profileId, linked);
  return buildLetterboxdHomeRows({
    configSegment: lb.encodedConfig,
    selectedCatalogs: lb.selectedCatalogs,
    hiddenCatalogs: lb.hiddenCatalogs,
    catalogOrder: lb.catalogOrder,
    session: getLetterboxdSession(),
    listRefs: lb.listRefs,
  }).catch(() => [] as HomeRow[]);
}

/** use-bp-extra-rows.ts letterboxdRows deps: null while not `lbReady`, else what the rows depend on. */
export function homeRailKey(profileId: string, linked: boolean): string | null {
  if (!ready(profileId, linked)) return null;
  const lb = settingsOf(profileId, linked);
  return JSON.stringify([lb.encodedConfig, lb.selectedCatalogs, lb.hiddenCatalogs, lb.catalogOrder, lb.listRefs, getLetterboxdSession()?.userId ?? null]);
}

/** use-bp-movies useBpLetterboxdRows: home-rails rows (four titles or more), no paging. */
export async function movieRows(profileId: string, linked: boolean): Promise<Array<{ key: string; name: string; metas: Meta[] }>> {
  const rows = await homeRailRows(profileId, linked);
  return rows.map((r) => ({ key: r.key, name: r.name, metas: r.metas.map((m) => ({ id: m.id, type: "movie", name: m.name, poster: m.poster, background: m.background, releaseInfo: m.releaseInfo, imdbRating: m.imdbRating } as Meta)) }));
}
