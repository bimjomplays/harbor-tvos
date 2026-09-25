// The Addons manager (views/addons.tsx and views/addons/*) without React: the catalog the three
// tabs read (lib/addons-store/store.ts useAddonsCatalog), the stremio-addons.net browse list with
// its categories, sort modes and search (community-browse-list.tsx), the Discover spotlight and
// community rail, the addon detail page (addon-detail.tsx + RemoteOrLocalDetail), install /
// configure / uninstall (addons.tsx onInstall, install-modal.tsx tryResolve), the Organize page
// (organize/page.tsx over lib/addons-store/reorder.ts) and the adult-addon age check
// (components/age-gate-modal.tsx). Every rule is upstream's; this file only removes the hooks.
import { resolveAddonLogo } from "@/components/addon-logo";
import { getUserAddonsRaw, userAddons, type Addon } from "@/lib/addons";
import {
  fetchInstalledAddons,
  fetchManifestAt,
  findHostnameMatch,
  installAddon,
  installFromUrl,
  isAddonEnabled,
  isInstalled,
  loadInstalled,
  manifestToConfigureUrl,
  manifestToShareUrl,
  parseAddonUrl,
  reorderInstalled,
  uninstallAddon,
  type InstalledAddon,
} from "@/lib/addon-store";
import { fetchCommunityAddons, fetchManifest } from "@/lib/addons-store/community";
import { CURATED_ADDONS } from "@/lib/addons-store/curated";
import { moveDeviceAddonsToAccount } from "@/lib/addons-store/move-to-account";
import { recallPendingAddon, rememberPendingAddon } from "@/lib/addons-store/pending-detail";
import { recommendedAddons, relatedAddons } from "@/lib/addons-store/recommend";
import {
  applyOrderToItems,
  loadBackups,
  loadDisplayOrder,
  pushBackup,
  saveCollectionOrder,
  saveDisplayOrder,
  sequencesEqual,
} from "@/lib/addons-store/reorder";
import { categorizeAddon, isAdultAddon, type ResolvedAddon } from "@/lib/addons-store/store";
import { t } from "@/lib/i18n";
import {
  addonSiteUrl,
  getAddon,
  isAdultAddon as isAdultSA,
  listAddons,
  listCategories,
  listRising,
  rateOnSiteUrl,
  risingEntryFor,
  type SAAddon,
  type SACategory,
  type SARisingAddon,
} from "@/lib/providers/stremio-addons";
import { communityFor, communityForLoose, ensureCommunityIndex } from "@/lib/providers/stremio-addons-index";
import { computeMovers, recordVelocitySnapshot } from "@/lib/providers/stremio-addons-velocity";
import { categoryLabel } from "@/views/addons/addons-types";
import { addonKey, idOf, nameOf, resourceLabels, subtitleFromManifest } from "@/views/addons/addons-utils";
import { entriesOf, noticeFor } from "@/views/addons/organize/utils";
import ageGateSource from "@/components/age-gate-modal.tsx?raw";

type Manifest = Addon["manifest"];

/** One addon as every list on the TV draws it (a row, a tile, the spotlight). */
export type AddonCard = {
  key: string;
  id: string;
  name: string;
  description: string;
  subtitle: string;
  logo: string | null;
  background: string | null;
  transportUrl: string;
  /** addon-store manifestToConfigureUrl: the addon's setup page. */
  configureUrl: string;
  installed: boolean;
  configurable: boolean;
  types: string[];
  stars: number;
  /** community-browse-list showRising: +N stars and the window in days (1 = 24h). */
  rising: number | null;
  risingWindow: number | null;
  /** community-browse-list showNew: createdAt within 14 days, "Just added" mode only. */
  isNew: boolean;
  slug: string | null;
  /** Installed pane only. */
  enabled: boolean;
  position: number;
};

// (bug pass 2) Community-directory and account manifests are whatever their authors wrote: a
// numeric name, an object description or a `types` entry that is not a string threw inside
// upstream's string helpers (normalizeAddonName, subtitleFromManifest, resolveAddonLogo) or
// reached Swift as the wrong type, and either way the whole list failed to load. Manifests are
// coerced where they enter this module, and every card is coerced to AddonCard's types on the
// way out.
const strOf = (v: unknown): string | undefined =>
  typeof v === "string" ? v : typeof v === "number" && Number.isFinite(v) ? String(v) : undefined;
const strList = (v: unknown): string[] =>
  Array.isArray(v) ? v.map(strOf).filter((x): x is string => typeof x === "string" && x.length > 0) : [];
const numOf = (v: unknown): number | null => {
  if (typeof v === "number") return Number.isFinite(v) ? v : null;
  if (typeof v === "string" && v.trim() !== "") {
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  }
  return null;
};

/** A copy of `m` whose fields the cards and detail page read have the types the Manifest type claims. */
export function cleanManifest<M>(m: M): M {
  if (!m || typeof m !== "object" || Array.isArray(m)) return (null as unknown) as M;
  const o = m as unknown as Record<string, unknown>;
  const out: Record<string, unknown> = { ...o };
  for (const k of ["id", "name", "description", "logo", "background", "version"]) {
    if (!(k in o)) continue;
    // A number is a fine name or version, never an image URL.
    const v = k === "logo" || k === "background" ? (typeof o[k] === "string" ? (o[k] as string) : undefined) : strOf(o[k]);
    if (v === undefined) delete out[k];
    else out[k] = v;
  }
  if ("types" in o) out.types = strList(o.types);
  if ("idPrefixes" in o) out.idPrefixes = strList(o.idPrefixes);
  if ("resources" in o) {
    out.resources = Array.isArray(o.resources)
      ? o.resources.filter((r) => typeof r === "string" || (!!r && typeof r === "object" && typeof (r as { name?: unknown }).name === "string"))
      : [];
  }
  if ("catalogs" in o) out.catalogs = Array.isArray(o.catalogs) ? o.catalogs.filter((c) => !!c && typeof c === "object") : [];
  if ("behaviorHints" in o && (!o.behaviorHints || typeof o.behaviorHints !== "object")) delete out.behaviorHints;
  return out as unknown as M;
}

/** Addons with an object manifest, cleaned (a stored or directory entry without one is left out). */
function cleanAddons<T extends { manifest?: unknown }>(list: T[] | null | undefined): T[] {
  if (!Array.isArray(list)) return [];
  const out: T[] = [];
  for (const a of list) {
    if (!a || typeof a !== "object") continue;
    const tu = (a as { transportUrl?: unknown }).transportUrl;
    if (tu !== undefined && typeof tu !== "string") continue;
    const manifest = cleanManifest(a.manifest);
    if (!manifest) continue;
    out.push({ ...a, manifest });
  }
  return out;
}

/** AddonCard with every field of its declared type (the Swift decode is strict per card). */
function safeCard(c: AddonCard): AddonCard {
  const str = (v: unknown) => strOf(v) ?? "";
  const strOrNull = (v: unknown) => strOf(v) || null;
  return {
    key: str(c.key),
    id: str(c.id),
    name: str(c.name),
    description: str(c.description),
    subtitle: str(c.subtitle),
    logo: strOrNull(c.logo),
    background: strOrNull(c.background),
    transportUrl: str(c.transportUrl),
    configureUrl: str(c.configureUrl),
    installed: c.installed === true,
    configurable: c.configurable === true,
    types: strList(c.types).slice(0, 4),
    stars: numOf(c.stars) ?? 0,
    rising: numOf(c.rising),
    risingWindow: numOf(c.risingWindow),
    isNew: c.isNew === true,
    slug: strOrNull(c.slug),
    enabled: c.enabled !== false,
    position: Math.trunc(numOf(c.position) ?? 0),
  };
}

function hintsOf(m: Manifest | null | undefined): { configurable: boolean; required: boolean } {
  const h = (m as { behaviorHints?: { configurable?: boolean; configurationRequired?: boolean } } | null | undefined)?.behaviorHints;
  return { configurable: h?.configurable === true, required: h?.configurationRequired === true };
}

// ------------------------------------------------------------------------------------ catalog
// store.ts useAddonsCatalog, the effect body: curated, account and local installs, the
// stremio-addons.net top 200 plus Stremio's community directories, re-keyed and deduplicated.
const ALWAYS_HIDDEN_IDS = new Set<string>(["org.stremio.opensubtitles", "com.opensubtitles.v3"]);

function normalizeAddonName(name: string | undefined): string {
  if (!name) return "";
  return name
    .toLowerCase()
    .replace(/\[[^\]]*\]/g, "")
    .replace(/\|.*$/g, "")
    .replace(/\b(rd|tb|ad|premiumize|debrid|elfhosted|community|official|free|paid|sponsored|by\s+\S+)\b/g, "")
    .replace(/[^a-z0-9]+/g, "")
    .trim();
}

type CatalogState = { at: number; sig: string; byId: Map<string, ResolvedAddon>; installedIds: Set<string> };
let catalogState: CatalogState | null = null;
let catalogInflight: { sig: string; p: Promise<CatalogState> } | null = null;

async function buildCatalog(authKey: string | null, adultsAllowed: boolean): Promise<CatalogState> {
  const local = cleanAddons(await fetchInstalledAddons().catch(() => [] as Addon[]));
  const stremio = cleanAddons(authKey ? await userAddons(authKey).catch(() => [] as Addon[]) : []);
  const installed = new Set<string>([...local.map((a) => a.manifest.id), ...stremio.map((a) => a.manifest.id)]);
  const map = new Map<string, ResolvedAddon>();
  for (const e of CURATED_ADDONS) {
    map.set(e.id, { curated: e, manifest: null, transportUrl: e.transportUrl, source: "curated", installed: installed.has(e.id) });
  }
  for (const a of stremio) {
    const existing = map.get(a.manifest.id);
    map.set(a.manifest.id, { curated: existing?.curated, manifest: a.manifest, transportUrl: a.transportUrl, source: existing ? existing.source : "stremio-user", installed: true });
  }
  for (const a of local) {
    const existing = map.get(a.manifest.id);
    map.set(a.manifest.id, { curated: existing?.curated, manifest: a.manifest, transportUrl: a.transportUrl, source: existing ? existing.source : "harbor-local", installed: true });
  }
  const [community, saList] = await Promise.all([
    fetchCommunityAddons().then(cleanAddons, () => [] as Addon[]),
    listAddons({ limit: 200, sort_by: "stars", order: "desc" })
      .then((r) => cleanAddons(r.addons.map((a): Addon => ({ manifest: a.manifest, transportUrl: a.manifestUrl }))))
      .catch(() => [] as Addon[]),
  ]);
  const saIds = new Set<string>();
  const saManifestById = new Map<string, Manifest>();
  for (const a of saList) {
    const id = a.manifest?.id;
    if (id) {
      saIds.add(id);
      saManifestById.set(id, a.manifest);
    }
  }
  const mergedCommunity: Addon[] = [];
  const seenCommunityIds = new Set<string>();
  for (const a of [...saList, ...community]) {
    const id = a.manifest?.id;
    if (!id || seenCommunityIds.has(id)) continue;
    seenCommunityIds.add(id);
    mergedCommunity.push(a);
  }
  const byTransportUrl = new Map<string, string>();
  for (const [id, r] of map) byTransportUrl.set(r.transportUrl.toLowerCase(), id);
  for (const a of mergedCommunity) {
    const realId = a.manifest.id;
    const url = a.transportUrl;
    const existingIdByUrl = byTransportUrl.get(url.toLowerCase());
    if (existingIdByUrl && existingIdByUrl !== realId) {
      const existing = map.get(existingIdByUrl)!;
      existing.manifest = a.manifest;
      map.delete(existingIdByUrl);
      map.set(realId, { ...existing, manifest: a.manifest, transportUrl: url, installed: existing.installed || installed.has(realId) });
      byTransportUrl.set(url.toLowerCase(), realId);
      continue;
    }
    if (!map.has(realId)) {
      map.set(realId, { manifest: a.manifest, transportUrl: url, source: "community", installed: installed.has(realId) });
      byTransportUrl.set(url.toLowerCase(), realId);
    } else {
      const existing = map.get(realId)!;
      if (!existing.manifest) existing.manifest = a.manifest;
    }
  }
  const curatedNeedingFetch = [...map.values()].filter((r) => !r.manifest && r.source === "curated");
  await Promise.all(
    curatedNeedingFetch.map(async (r) => {
      const m = cleanManifest(await fetchManifest(r.transportUrl).catch(() => null));
      if (m) r.manifest = m;
    }),
  );
  const reKeyed = new Map<string, ResolvedAddon>();
  for (const [oldKey, r] of map) {
    const realId = r.manifest?.id;
    if (!realId || realId === oldKey) {
      reKeyed.set(oldKey, r);
      continue;
    }
    const existing = reKeyed.get(realId);
    if (existing) {
      existing.curated = existing.curated ?? r.curated;
      existing.installed = existing.installed || r.installed || installed.has(realId);
      if (!existing.manifest) existing.manifest = r.manifest;
    } else {
      reKeyed.set(realId, { ...r, installed: r.installed || installed.has(realId) });
    }
  }
  map.clear();
  for (const [k, v] of reKeyed) map.set(k, v);
  for (const [id, r] of map) {
    const sa = saManifestById.get(id);
    if (!sa || !r.manifest) continue;
    r.manifest = {
      ...r.manifest,
      name: sa.name ?? r.manifest.name,
      logo: r.manifest.logo ?? sa.logo,
      description: sa.description ?? r.manifest.description,
      background: r.manifest.background ?? sa.background,
    };
  }
  const byNormalizedName = new Map<string, string[]>();
  for (const [id, r] of map) {
    const norm = normalizeAddonName(r.manifest?.name);
    if (!norm) continue;
    const bucket = byNormalizedName.get(norm) ?? [];
    bucket.push(id);
    byNormalizedName.set(norm, bucket);
  }
  for (const [, ids] of byNormalizedName) {
    if (ids.length <= 1) continue;
    const installedInBucket = ids.filter((id) => map.get(id)?.installed);
    if (installedInBucket.length > 0) {
      for (const id of ids) if (!map.get(id)?.installed) map.delete(id);
      continue;
    }
    const curatedIds = ids.filter((id) => map.get(id)?.curated);
    const saIdsHit = ids.filter((id) => saIds.has(id));
    const winner = curatedIds[0] ?? saIdsHit[0] ?? ids[0];
    for (const id of ids) if (id !== winner) map.delete(id);
  }
  for (const id of ALWAYS_HIDDEN_IDS) map.delete(id);
  if (!adultsAllowed) {
    for (const [id, r] of map) if (isAdultAddon(r)) map.delete(id);
  }
  return { at: Date.now(), sig: `${authKey ?? ""}|${adultsAllowed ? 1 : 0}`, byId: map, installedIds: installed };
}

/** The catalog for this account + adult setting; `fresh` re-reads it (upstream's refetch()). */
async function catalogFor(authKey: string | null, adultsAllowed: boolean, fresh = false): Promise<CatalogState> {
  const sig = `${authKey ?? ""}|${adultsAllowed ? 1 : 0}`;
  if (!fresh && catalogState && catalogState.sig === sig) return catalogState;
  if (catalogInflight && catalogInflight.sig === sig) return catalogInflight.p;
  const p = buildCatalog(authKey, adultsAllowed)
    .then((s) => {
      catalogState = s;
      return s;
    })
    .finally(() => {
      if (catalogInflight?.p === p) catalogInflight = null;
    });
  catalogInflight = { sig, p };
  return p;
}

/** Installed ids as the last catalog saw them (community rows ask before the catalog lands). */
function installedIdSet(): Set<string> {
  const out = new Set<string>(catalogState?.installedIds ?? []);
  for (const a of loadInstalled()) out.add(a.id);
  return out;
}

function cardFromResolved(r: ResolvedAddon, installedIds: Set<string>, position = 0): AddonCard {
  const m = r.manifest;
  const id = idOf(r);
  return safeCard({
    key: addonKey(r),
    id,
    name: nameOf(r),
    description: m?.description ?? "",
    subtitle: subtitleFromManifest(r),
    logo: resolveAddonLogo(m?.logo, r.transportUrl),
    background: m?.background ?? null,
    transportUrl: r.transportUrl,
    configureUrl: manifestToConfigureUrl(r.transportUrl),
    installed: r.installed || installedIds.has(id),
    configurable: hintsOf(m).configurable || hintsOf(m).required,
    types: Array.isArray(m?.types) ? m!.types!.slice(0, 4) : [],
    stars: communityFor(m?.id)?.stars ?? 0,
    rising: null,
    risingWindow: null,
    isNew: false,
    slug: communityFor(m?.id)?.slug ?? null,
    enabled: isAddonEnabled(r.transportUrl),
    position,
  });
}

const NEW_WINDOW_MS = 14 * 24 * 60 * 60 * 1000;
function isNewlyAdded(createdAt: string | undefined): boolean {
  if (!createdAt) return false;
  const ts = Date.parse(createdAt);
  return Number.isFinite(ts) && Date.now() - ts < NEW_WINDOW_MS;
}

/** Community manifests seen in a list, so opening one carries it (rememberPendingAddon). */
const seenCommunity = new Map<string, { manifestUrl: string; manifest: unknown }>();

function cardFromSA(a: SAAddon, installedIds: Set<string>, extra: Partial<AddonCard> = {}): AddonCard {
  // (bug pass 2) cleaned: see cleanManifest.
  const m = cleanManifest(a.manifest);
  a = { ...a, manifest: m, manifestUrl: strOf(a.manifestUrl) ?? "", slug: strOf(a.slug) ?? "" } as SAAddon;
  const id = m?.id ?? "";
  if (id) {
    seenCommunity.set(id, { manifestUrl: a.manifestUrl, manifest: a.manifest });
    if (seenCommunity.size > 400) seenCommunity.delete(seenCommunity.keys().next().value as string);
  }
  const name = m?.name ?? a.slug;
  return safeCard({
    key: strOf(a.uuid) || `${id}:${a.manifestUrl}`,
    id,
    name,
    description: m?.description ?? "",
    subtitle: (m?.description ?? "").split(/[.\n]/)[0]?.slice(0, 90) ?? "",
    logo: resolveAddonLogo(m?.logo, a.manifestUrl),
    background: m?.background ?? null,
    transportUrl: a.manifestUrl,
    configureUrl: manifestToConfigureUrl(a.manifestUrl),
    installed: !!id && installedIds.has(id),
    configurable: hintsOf(m).configurable || hintsOf(m).required,
    types: Array.isArray(m?.types) ? m.types.slice(0, 4) : [],
    stars: a.stars ?? 0,
    rising: null,
    risingWindow: null,
    isNew: false,
    slug: a.slug ?? null,
    enabled: true,
    position: 0,
    ...extra,
  });
}

/**
 * addons.tsx: the catalog load behind all three tabs, and the Installed tab's list in upstream's
 * order (saved display order first, then the local install order), with each row's switch state.
 */
export async function load(authKey: string | null, adultsAllowed: boolean, fresh = false): Promise<{ installed: AddonCard[]; installedCount: number; total: number }> {
  const s = await catalogFor(authKey, adultsAllowed, fresh);
  void ensureCommunityIndex().catch(() => undefined);
  const seq = [...loadDisplayOrder(), ...loadInstalled().map((e) => e.transportUrl)];
  const rank = new Map<string, number>();
  seq.forEach((url, i) => {
    if (!rank.has(url)) rank.set(url, i);
  });
  const installed = [...s.byId.values()]
    .filter((r) => r.installed)
    .sort((a, b) => (rank.get(a.transportUrl) ?? Number.MAX_SAFE_INTEGER) - (rank.get(b.transportUrl) ?? Number.MAX_SAFE_INTEGER));
  return {
    installed: installed.map((r, i) => cardFromResolved(r, s.installedIds, i + 1)),
    installedCount: s.installedIds.size,
    total: s.byId.size,
  };
}

// ------------------------------------------------------------------------------ browse / discover
// stremio-addons.ts DEFAULT_SA_CATEGORIES: useCategories' answer until (or unless) the API replies.
const DEFAULT_SA_CATEGORIES: SACategory[] = [
  { name: "anime", slug: "anime" },
  { name: "asian drama", slug: "asian+drama" },
  { name: "bollywood", slug: "bollywood" },
  { name: "debrid support", slug: "debrid+support" },
  { name: "http streams", slug: "http+streams" },
  { name: "live tv", slug: "live+tv" },
  { name: "metadata", slug: "metadata" },
  { name: "misc", slug: "misc" },
  { name: "movies", slug: "movies" },
  { name: "music", slug: "music" },
  { name: "nsfw", slug: "nsfw" },
  { name: "radios", slug: "radios" },
  { name: "subtitles", slug: "subtitles" },
  { name: "torrents", slug: "torrents" },
  { name: "tv shows", slug: "tv+shows" },
  { name: "usenet", slug: "usenet" },
];

/** addons.tsx category chips: stremio-addons.net's categories, "nsfw" only with adult addons on. */
export async function categories(adultsAllowed: boolean): Promise<SACategory[]> {
  const cats = await listCategories().catch(() => [] as SACategory[]);
  const list = cats.length > 0 ? cats : DEFAULT_SA_CATEGORIES;
  return list.filter((c) => adultsAllowed || c.slug !== "nsfw");
}

export type BrowseMode = "top" | "new" | "rising";
export type BrowsePage = { items: AddonCard[]; hasMore: boolean; empty: "none" | "velocity" | "results" };

let risingMemo: { at: number; list: SARisingAddon[] } | null = null;
async function rising(): Promise<SARisingAddon[]> {
  if (risingMemo && Date.now() - risingMemo.at < 10 * 60 * 1000) return risingMemo.list;
  const list = await listRising().catch(() => [] as SARisingAddon[]);
  risingMemo = { at: Date.now(), list };
  return list;
}

/**
 * community-browse-list.tsx: "top" and "new" page through the API 50 at a time (nsfw excluded
 * unless adult addons are on or the nsfw category is picked); "rising" is the official 24 h list,
 * falling back to the star velocity Harbor records between visits.
 */
export async function browse(mode: BrowseMode, category: string | null, search: string | null, adultsAllowed: boolean, page = 1): Promise<BrowsePage> {
  const installedIds = installedIdSet();
  const q = search?.trim() ?? "";
  const cat = q ? null : category;
  if (mode === "rising") {
    const official = await rising();
    const ql = q.toLowerCase();
    const officialFiltered = official.filter((a) => {
      // The age gate covers the rising list too (upstream only checks behaviorHints.adult here) (review 30).
      if (!adultsAllowed && cat !== "nsfw" && isAdultSA(a)) return false;
      if (cat && !a.categories.some((c) => c.slug === cat)) return false;
      if (ql) {
        const m = a.manifest as { name?: string; description?: string } | undefined;
        // (bug pass 2) String(): directory fields are not always strings.
        const name = String(m?.name ?? "").toLowerCase();
        const desc = String(m?.description ?? "").toLowerCase();
        if (!name.includes(ql) && !String(a.slug ?? "").toLowerCase().includes(ql) && !desc.includes(ql)) return false;
      }
      return true;
    });
    if (officialFiltered.length > 0) {
      return { items: officialFiltered.map((a) => cardFromSA(a, installedIds, { rising: a.recentStars, risingWindow: 1 })), hasMore: false, empty: "none" };
    }
    await recordVelocitySnapshot().catch(() => undefined);
    const movers = computeMovers(80).filter((m) => {
      if (cat && !m.community.categories.some((c) => c.slug === cat)) return false;
      // The velocity fallback's index is fetched without nsfw=exclude: gate it here (review 30).
      if (!adultsAllowed && cat !== "nsfw" && m.community.categories.some((c) => c.slug === "nsfw")) return false;
      if (ql) {
        const name = String(m.community.name ?? "").toLowerCase();
        const slug = String(m.community.slug ?? "").toLowerCase();
        const desc = String(m.community.description ?? "").toLowerCase();
        if (!name.includes(ql) && !slug.includes(ql) && !desc.includes(ql)) return false;
      }
      return true;
    });
    if (movers.length === 0) return { items: [], hasMore: false, empty: "velocity" };
    return {
      items: movers.map((m) => {
        const synthetic = {
          uuid: m.community.uuid,
          slug: m.community.slug,
          url: m.community.url,
          manifestUrl: m.community.manifestUrl,
          manifest: {
            id: m.community.manifestId ?? "",
            name: m.community.name ?? m.community.slug,
            description: m.community.description ?? "",
            logo: m.community.logo,
            background: m.community.background,
          },
          stars: m.community.stars,
          categories: m.community.categories,
          configureUrl: null,
          createdAt: m.community.createdAt,
          updatedAt: m.community.updatedAt,
        } as unknown as SAAddon;
        return cardFromSA(synthetic, installedIds, { rising: m.delta, risingWindow: m.windowDays });
      }),
      hasMore: false,
      empty: "none",
    };
  }
  const [official, res] = await Promise.all([
    rising(),
    listAddons({
      page,
      limit: 50,
      sort_by: mode === "top" ? "stars" : "createdAt",
      order: "desc",
      ...(adultsAllowed || cat === "nsfw" ? {} : { nsfw: "exclude" as const }),
      ...(cat ? { category: cat } : {}),
      ...(q ? { search: q } : {}),
    }).catch(() => null),
  ]);
  if (!res) return { items: [], hasMore: false, empty: page === 1 ? "results" : "none" };
  const items = res.addons.map((a) => {
    const r = risingEntryFor(official, a);
    return cardFromSA(a, installedIds, {
      rising: r?.recentStars ?? null,
      risingWindow: r ? 1 : null,
      isNew: mode === "new" && isNewlyAdded(a.createdAt),
    });
  });
  return { items, hasMore: res.pagination.hasNextPage, empty: page === 1 && items.length === 0 ? "results" : "none" };
}

/** addon-spotlight.tsx: the first trending addon with a background, else the top-rated one. */
export async function spotlight(adultsAllowed: boolean): Promise<{ addon: AddonCard; trending: boolean } | null> {
  const installedIds = installedIdSet();
  const ok = (a: SAAddon) => !!a.manifest?.id && (adultsAllowed || !isAdultSA(a));
  const usable = (a: SAAddon) => ok(a) && !!a.manifest?.background;
  const trendList = (await rising()).filter(ok);
  const trend = trendList.find(usable) ?? trendList[0];
  if (trend) return { addon: cardFromSA(trend, installedIds), trending: true };
  const top = await listAddons({ limit: 14, sort_by: "stars", order: "desc", nsfw: adultsAllowed ? undefined : "exclude" }).catch(() => null);
  const clean = (top?.addons ?? []).filter(ok);
  const best = clean.find(usable) ?? clean[0];
  return best ? { addon: cardFromSA(best, installedIds), trending: false } : null;
}

/** community-addons-rail.tsx: Trending / Top rated / Just added, 24 at most, installed ones left out. */
export async function rail(sortMode: "trending" | "stars" | "createdAt", adultsAllowed: boolean): Promise<AddonCard[]> {
  const nsfw: "exclude" | undefined = adultsAllowed ? undefined : "exclude";
  const topRated = () => listAddons({ limit: 40, sort_by: "stars", order: "desc", nsfw }).then((r) => r.addons);
  const addons: SAAddon[] = await (sortMode === "trending"
    ? listRising().then((r) => (r.length ? r : topRated())).catch(topRated)
    : sortMode === "stars"
      ? topRated()
      : listAddons({ limit: 40, sort_by: sortMode, order: "desc", nsfw }).then((r) => r.addons)
  ).catch(() => [] as SAAddon[]);
  const clean = adultsAllowed ? addons : addons.filter((a) => !isAdultSA(a));
  const installedIds = installedIdSet();
  return clean
    .slice(0, 24)
    .map((a) => cardFromSA(a, installedIds))
    .filter((c) => !c.installed);
}

// -------------------------------------------------------------------------------------- detail
export type AddonDetail = {
  card: AddonCard;
  eyebrow: string;
  version: string | null;
  types: string[];
  resources: string[];
  catalogs: Array<{ name: string; type: string }>;
  stats: Array<{ label: string; value: string; mono: boolean }>;
  configurable: boolean;
  configurationRequired: boolean;
  adult: boolean;
  configureUrl: string;
  stremioUrl: string;
  maskedUrl: string;
  community: { stars: number; slug: string; siteUrl: string; rateUrl: string } | null;
  risingStars: number | null;
  documentation: string | null;
  related: AddonCard[];
  recommended: AddonCard[];
};

/**
 * addons.tsx RemoteOrLocalDetail + addon-detail.tsx: the catalog entry, or a community addon
 * carried from the list it was opened in, or one found through the stremio-addons.net index.
 * null when nothing resolves (upstream goes back).
 */
export async function detail(addonId: string, authKey: string | null, adultsAllowed: boolean): Promise<AddonDetail | null> {
  const s = await catalogFor(authKey, adultsAllowed);
  const seen = seenCommunity.get(addonId);
  if (seen) rememberPendingAddon(addonId, seen.manifestUrl, seen.manifest);
  let resolved: ResolvedAddon | null = s.byId.get(addonId) ?? null;
  if (!resolved) {
    const carried = recallPendingAddon(addonId);
    if (carried) {
      const manifest = cleanManifest((carried.manifest as Manifest | null) ?? ((await fetchManifestAt(carried.manifestUrl).catch(() => null)) as Manifest | null));
      if (manifest) resolved = { manifest, transportUrl: carried.manifestUrl, source: "community", installed: s.installedIds.has(addonId) };
    }
  }
  if (!resolved) {
    await ensureCommunityIndex().catch(() => undefined);
    const community = communityForLoose(addonId);
    if (!community) return null;
    try {
      const d = await getAddon(community.slug);
      resolved = { manifest: cleanManifest(d.manifest as Manifest), transportUrl: d.manifestUrl, source: "community", installed: s.installedIds.has(addonId) };
    } catch {
      return null;
    }
  }
  const r = resolved;
  const all = [...s.byId.values()];
  const related = relatedAddons(r, all, 8);
  const exclude = new Set(related.map((x) => x.manifest?.id ?? x.curated?.id ?? x.transportUrl));
  exclude.add(addonId);
  const recommended = recommendedAddons(r, all, s.installedIds, exclude, 8);

  await ensureCommunityIndex().catch(() => undefined);
  const m = r.manifest;
  const community = communityFor(m?.id);
  const risingList = community ? await rising() : [];
  const risingEntry = community ? risingEntryFor(risingList, community) : null;
  const documentation = community?.slug
    ? await getAddon(community.slug).then((d) => d.documentation?.trim() || null).catch(() => null)
    : null;

  const humanize = (v: string) => (v ? v.charAt(0).toUpperCase() + v.slice(1) : v);
  const resources = resourceLabels(m?.resources ?? []).map(humanize);
  const types = (m?.types ?? []).map(humanize);
  const idPrefixes = m?.idPrefixes ?? [];
  const prefixValue = idPrefixes.slice(0, 3).join(", ") + (idPrefixes.length > 3 ? ` +${idPrefixes.length - 3}` : "");
  const catalogCount = m?.catalogs?.length ?? 0;
  const stats: AddonDetail["stats"] = [];
  const push = (label: string, value: unknown, mono = false) => stats.push({ label, value: String(value ?? ""), mono });
  if (m?.version) push(t("Version"), m.version);
  if (resources.length) push(t("Resources"), resources.join(", "));
  if (types.length) push(t("Types"), types.join(", "));
  if (idPrefixes.length > 0) push(t("ID prefixes"), prefixValue);
  if (catalogCount > 0) push(t("Catalogs"), String(catalogCount));
  if (m?.behaviorHints?.p2p) push(t("P2P"), t("Yes"));
  if (m?.id) push(t("ID"), m.id, true);

  const maskedUrl = (() => {
    try {
      const u = new URL(r.transportUrl);
      return `${u.protocol}//${u.hostname}/…/manifest.json`;
    } catch {
      return "••••••••••••••••";
    }
  })();
  const hints = hintsOf(m);
  const card = cardFromResolved(r, s.installedIds);
  if (community) {
    card.stars = numOf(community.stars) ?? 0;
    card.slug = strOf(community.slug) || null;
  }
  const kind = r.curated?.tags.includes("official") ? t("Official") : t("Community");
  return {
    card,
    eyebrow: `${kind} · ${categoryLabel(r.curated?.category ?? categorizeAddon(r)) ?? t("Addon")}`,
    version: m?.version ?? null,
    types,
    resources,
    // A manifest can omit a catalog's type: coerced so one odd entry can't fail the page's decode (review 30).
    catalogs: (m?.catalogs ?? []).map((c) => ({ name: String(c.name ?? c.id ?? ""), type: String(c.type ?? "") })),
    stats,
    configurable: hints.configurable || hints.required,
    configurationRequired: hints.required,
    adult: m?.behaviorHints?.adult === true,
    configureUrl: manifestToConfigureUrl(r.transportUrl),
    stremioUrl: manifestToShareUrl(r.transportUrl, "stremio"),
    maskedUrl,
    community: community ? { stars: community.stars, slug: community.slug, siteUrl: addonSiteUrl(community.slug), rateUrl: rateOnSiteUrl(community.slug) } : null,
    risingStars: risingEntry?.recentStars ?? null,
    documentation,
    related: related.map((x) => cardFromResolved(x, s.installedIds)),
    recommended: recommended.map((x) => cardFromResolved(x, s.installedIds)),
  };
}

// ------------------------------------------------------------------------------ install / remove
export type InstallOutcome =
  | { kind: "installed"; id: string; name: string; logo: string | null; toast: string }
  | { kind: "configure"; id: string; name: string; logo: string | null; configureUrl: string }
  | { kind: "error"; message: string };

/**
 * addons.tsx onInstall / community-browse-list install: an addon that asks to be configured goes
 * to its setup page (on the TV: a QR for the phone), everything else installs straight away.
 */
export async function install(id: string, transportUrl: string): Promise<InstallOutcome> {
  try {
    let manifest: Manifest | null = (seenCommunity.get(id)?.manifest as Manifest | undefined) ?? catalogState?.byId.get(id)?.manifest ?? null;
    if (!manifest?.behaviorHints) manifest = await fetchManifestAt(transportUrl).catch(() => manifest);
    const hints = hintsOf(manifest);
    const name = manifest?.name ?? id;
    const logo = resolveAddonLogo(manifest?.logo, transportUrl);
    if (hints.configurable || hints.required) {
      return { kind: "configure", id: manifest?.id ?? id, name, logo, configureUrl: manifestToConfigureUrl(transportUrl) };
    }
    const addon = await installAddon(manifest?.id ?? id, transportUrl);
    markInstalled(addon.manifest.id, true);
    return { kind: "installed", id: addon.manifest.id, name: addon.manifest.name, logo: resolveAddonLogo(addon.manifest.logo, transportUrl) ?? logo, toast: t("Installed") };
  } catch (e) {
    return { kind: "error", message: e instanceof Error ? e.message : t("Install failed.") };
  }
}

/**
 * addon-detail.tsx "Install default": the manifest as published, without the setup page.
 * Upstream routes this through onInstall, which sends a configurable addon back to its own
 * detail page, so the button does nothing there; the TV installs as the label says.
 */
export async function installDefault(id: string, transportUrl: string): Promise<InstallOutcome> {
  try {
    const addon = await installAddon(id, transportUrl);
    markInstalled(addon.manifest.id, true);
    return { kind: "installed", id: addon.manifest.id, name: addon.manifest.name, logo: resolveAddonLogo(addon.manifest.logo, transportUrl), toast: t("Installed") };
  } catch (e) {
    return { kind: "error", message: e instanceof Error ? e.message : t("Install failed.") };
  }
}

export type UrlMatch = {
  url: string;
  name: string;
  logo: string | null;
  version: string | null;
  description: string;
  matchKind: "fresh" | "id-match" | "hostname-match";
  replaceId: string | null;
  replaceName: string | null;
};

/**
 * install-modal.tsx tryResolve: read the pasted link's manifest and decide whether it is a new
 * addon, an update of one already installed (same id), or a re-configure of one on the same host
 * (manage mode: the addon being managed) that should replace it.
 */
export async function resolveUrl(rawUrl: string, manage: { id: string; name: string } | null): Promise<UrlMatch | { error: string }> {
  try {
    const parsed = parseAddonUrl(rawUrl);
    if (parsed.kind === "error") throw new Error(t(parsed.message));
    const manifest = await fetchManifestAt(parsed.url);
    let matchKind: UrlMatch["matchKind"] = "fresh";
    let replaceId: string | null = null;
    let replaceName: string | null = null;
    if (manage && manage.id) {
      if (manage.id === manifest.id) {
        matchKind = "id-match";
      } else {
        matchKind = "hostname-match";
        replaceId = manage.id;
        replaceName = manage.name;
      }
    } else if (isInstalled(manifest.id)) {
      matchKind = "id-match";
    } else {
      const host = findHostnameMatch(parsed.url);
      if (host) {
        matchKind = "hostname-match";
        replaceId = host.id;
        replaceName = host.manifest?.name ?? host.id;
      }
    }
    return {
      url: parsed.url,
      name: manifest.name,
      logo: resolveAddonLogo(manifest.logo, parsed.url),
      version: manifest.version ?? null,
      description: manifest.description ?? "",
      matchKind,
      replaceId,
      replaceName,
    };
  } catch (e) {
    return { error: e instanceof Error ? e.message : t("Couldn't read that addon URL.") };
  }
}

/** addons.tsx install-modal onInstall: installFromUrl with the toast upstream shows. */
export async function installUrl(rawUrl: string, replaceId: string | null): Promise<
  { ok: true; replaced: boolean; id: string; name: string; logo: string | null; toast: string } | { ok: false; message: string }
> {
  try {
    const result = await installFromUrl(rawUrl, replaceId ? { replaceId } : {});
    markInstalled(result.addon.manifest.id, true);
    return {
      ok: true,
      replaced: result.replaced,
      id: result.addon.manifest.id,
      name: result.addon.manifest.name,
      logo: resolveAddonLogo(result.addon.manifest.logo, result.addon.transportUrl),
      toast: result.replaced ? t("Updated") : result.syncedToStremio ? t("Installed") : t("Installed locally"),
    };
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : t("Install failed.") };
  }
}

/** addons.tsx onUninstall. */
export async function uninstall(id: string, transportUrl: string): Promise<{ ok: boolean; toast: string }> {
  if (!id) return { ok: false, toast: t("Couldn't remove. Try again.") };
  try {
    await uninstallAddon(id, transportUrl);
    markInstalled(id, false);
    return { ok: true, toast: t("Removed") };
  } catch {
    return { ok: false, toast: t("Couldn't remove. Try again.") };
  }
}

/** store.ts's harbor:addons-changed listener: flip the flag now, re-read on the next load. */
function markInstalled(id: string, on: boolean): void {
  if (!catalogState) return;
  const r = catalogState.byId.get(id);
  if (r) catalogState.byId.set(id, { ...r, installed: on });
  if (on) catalogState.installedIds.add(id);
  else catalogState.installedIds.delete(id);
  catalogState.sig = `${catalogState.sig}|stale`;
}

// ------------------------------------------------------------------------------------ organize
// organize/page.tsx: the account list (Stremio's order, synced everywhere) and this device's own
// installs, each reordered on the TV and saved through saveCollectionOrder / reorderInstalled.
type OrganizeState = { authKey: string | null; cloud: Addon[]; device: InstalledAddon[]; backedUp: boolean };
let organizeState: OrganizeState | null = null;

type OrganizeRow = { key: string; name: string; host: string; addonId: string; logo: string | null };
// (bug pass 2) Cleaned manifests (the keys depend on transportUrl only) and string fields: a stray
// numeric name failed the whole Organize load in Swift.
const rowsOf = (items: Array<{ transportUrl: string; manifest?: Manifest }>): OrganizeRow[] =>
  entriesOf(items.map((it) => ({ ...it, manifest: cleanManifest(it.manifest) ?? undefined }))).map((e) => ({
    key: String(e.key), name: strOf(e.name) ?? String(e.host ?? ""), host: String(e.host ?? ""), addonId: strOf(e.addonId) ?? "", logo: strOf(e.logo) || null,
  }));

export async function organizeLoad(authKey: string | null, reset = false): Promise<{ ok: boolean; signedIn: boolean; cloud: OrganizeRow[]; device: OrganizeRow[]; backups: number }> {
  if (!authKey) {
    const device = loadInstalled();
    organizeState = { authKey: null, cloud: [], device, backedUp: false };
    return { ok: true, signedIn: false, cloud: [], device: rowsOf(device), backups: loadBackups().length };
  }
  const cloud = await getUserAddonsRaw(authKey);
  if (cloud == null) {
    organizeState = null;
    return { ok: false, signedIn: true, cloud: [], device: [], backups: loadBackups().length };
  }
  const cloudUrls = new Set(cloud.map((a) => a.transportUrl));
  const device = loadInstalled().filter((d) => !cloudUrls.has(d.transportUrl));
  organizeState = { authKey, cloud, device, // organize/page.tsx backedUpRef lives per page mount: a new Organize visit backs up again
  // before its first write; only Reload / Try again keep the flag (review 30).
  backedUp: !reset && organizeState?.authKey === authKey ? organizeState.backedUp : false };
  return { ok: true, signedIn: true, cloud: rowsOf(cloud), device: rowsOf(device), backups: loadBackups().length };
}

/** A working order (row keys) back onto the baseline items; unknown keys are dropped, missing ones kept at the end. */
function reorderByKeys<T extends { transportUrl: string; manifest?: Manifest }>(items: T[], keys: string[]): T[] {
  const rows = entriesOf(items);
  const byKey = new Map(rows.map((row, i) => [row.key, items[i]]));
  const out: T[] = [];
  const used = new Set<string>();
  for (const k of keys) {
    const it = byKey.get(k);
    if (!it || used.has(k)) continue;
    used.add(k);
    out.push(it);
  }
  rows.forEach((row, i) => {
    if (!used.has(row.key)) out.push(items[i]);
  });
  return out;
}

/**
 * organize/page.tsx handleSave: the account order goes through saveCollectionOrder (validate,
 * re-fetch for drift, back up once, write, read back); either way the local mirror follows
 * (saveDisplayOrder + reorderInstalled). Returns upstream's notice on a failed step.
 */
export async function organizeSave(cloudKeys: string[], deviceKeys: string[]): Promise<{ ok: true; scope: "cloud" | "local"; toast: string } | { ok: false; tone: string; text: string; retry: boolean; reload: boolean }> {
  const st = organizeState;
  if (!st) return { ok: false, tone: "danger", text: t("Something unexpected went wrong. Nothing may have been written. Retry to re-check."), retry: false, reload: true };
  const workingCloud = reorderByKeys(st.cloud, cloudKeys);
  const workingDevice = reorderByKeys(st.device, deviceKeys);
  const urlsOf = (items: Array<{ transportUrl: string }>) => items.map((i) => i.transportUrl);
  const cloudDirty = !sequencesEqual(urlsOf(workingCloud), urlsOf(st.cloud));
  const mirrorLocal = () => {
    const urls = [...urlsOf(workingCloud), ...urlsOf(workingDevice)];
    try {
      saveDisplayOrder(urls);
      reorderInstalled(urls);
    } catch {
      /* organize/page.tsx: the mirror is best effort */
    }
  };
  try {
    if (cloudDirty && st.authKey) {
      const result = await saveCollectionOrder(st.authKey, st.cloud, workingCloud, st.backedUp);
      if (!result.ok) {
        if (result.stage === "write" || result.stage === "verify") st.backedUp = true;
        const n = noticeFor(result);
        return { ok: false, tone: n.tone, text: n.text, retry: !!n.retry, reload: !!n.reload };
      }
      st.backedUp = true;
      mirrorLocal();
      return { ok: true, scope: "cloud", toast: t("Addon order synced to your Stremio account") };
    }
    mirrorLocal();
    return { ok: true, scope: "local", toast: t("Addon order saved on this device") };
  } catch {
    return { ok: false, tone: "danger", text: t("Something unexpected went wrong. Nothing may have been written. Retry to re-check."), retry: true, reload: false };
  }
}

/** backups-card.tsx: the last five account orders, newest first. */
export function organizeBackups(): Array<{ index: number; at: number; count: number; names: string[] }> {
  return loadBackups().map((b, index) => ({ index, at: b.at, count: b.urls.length, names: b.names.slice(0, 6) }));
}

/** organize/page.tsx handleBackupNow: the account order as it stands in the editor. */
export function organizeBackupNow(cloudKeys: string[]): { ok: boolean; text: string } {
  const st = organizeState;
  if (!st || st.cloud.length === 0) return { ok: false, text: "" };
  pushBackup(reorderByKeys(st.cloud, cloudKeys));
  return { ok: true, text: t("Backed up. The current account order is saved in the Backups panel.") };
}

/** organize/page.tsx handleRestore: a backup's order laid over the loaded list (row keys). */
export function organizeRestore(index: number): { keys: string[]; text: string } | null {
  const st = organizeState;
  const b = loadBackups()[index];
  if (!st || !b) return null;
  const ordered = applyOrderToItems(st.cloud, b.urls);
  // Keys are positional per URL (entriesOf), so map each reordered item back to its row key.
  const rows = entriesOf(st.cloud);
  const used = new Set<number>();
  const keys: string[] = [];
  for (const item of ordered) {
    const i = st.cloud.findIndex((x, j) => !used.has(j) && x === item);
    if (i < 0) continue;
    used.add(i);
    keys.push(rows[i].key);
  }
  return { keys, text: t("Backup loaded into the editor. Addons added since stay at the end. Nothing changes until you press Save.") };
}

/** organize/page.tsx handleMoveAll: every device-only addon onto the account. */
export async function organizeMoveAll(): Promise<{ ok: boolean; text: string; reload: boolean }> {
  const st = organizeState;
  if (!st || !st.authKey || st.device.length === 0) return { ok: false, text: "", reload: false };
  const result = await moveDeviceAddonsToAccount(st.authKey, st.device);
  if (!result.ok) {
    return {
      ok: false,
      reload: true,
      text:
        result.stage === "fetch"
          ? t("Couldn't reach Stremio to confirm your collection. Nothing was written.")
          : result.stage === "write"
            ? t("Stremio didn't confirm the move. Your collection may be unchanged. Reload to see the current state.")
            : t("Moved, but Harbor couldn't confirm the result. Reload to see the current state."),
    };
  }
  if (result.moved === 0) return { ok: true, text: t("Everything here is already in your account."), reload: false };
  const movedText =
    result.moved === 1
      ? t("Moved 1 addon to your Stremio account. It now syncs everywhere you sign in.")
      : t("Moved {n} addons to your Stremio account. They now sync everywhere you sign in.", { n: result.moved });
  const skippedText = result.skipped.length > 0 ? " " + t("Couldn't reach {names}, so they stayed on this device.", { names: result.skipped.join(", ") }) : "";
  return { ok: true, text: movedText + skippedText, reload: false };
}


// ------------------------------------------------------------------------------------ age gate
// components/age-gate-modal.tsx: three everyday questions from upstream's own banks (read from
// the component's source, so the questions track upstream), shuffled by pickThree's LCG.
type Question = { q: string; options: string[]; correct: number };

/** A reader for the literal subset the question banks use: arrays, objects, strings, numbers. */
function parseLiteral(src: string, start: number): { value: unknown; end: number } {
  let i = start;
  const ws = () => {
    for (;;) {
      while (i < src.length && /\s/.test(src[i])) i++;
      if (src.startsWith("//", i)) {
        while (i < src.length && src[i] !== "\n") i++;
        continue;
      }
      if (src.startsWith("/*", i)) {
        const e = src.indexOf("*/", i + 2);
        i = e < 0 ? src.length : e + 2;
        continue;
      }
      return;
    }
  };
  const str = (): string => {
    const quote = src[i++];
    let out = "";
    while (i < src.length && src[i] !== quote) {
      if (src[i] === "\\") {
        const c = src[i + 1];
        out += c === "n" ? "\n" : c === "t" ? "\t" : c;
        i += 2;
      } else out += src[i++];
    }
    i++;
    return out;
  };
  const value = (): unknown => {
    ws();
    const c = src[i];
    if (c === "[") {
      i++;
      const arr: unknown[] = [];
      for (;;) {
        ws();
        if (src[i] === "]") { i++; return arr; }
        arr.push(value());
        ws();
        if (src[i] === ",") i++;
      }
    }
    if (c === "{") {
      i++;
      const obj: Record<string, unknown> = {};
      for (;;) {
        ws();
        if (src[i] === "}") { i++; return obj; }
        let key: string;
        if (src[i] === '"' || src[i] === "'") key = str();
        else {
          const m = /^[A-Za-z_$][\w$]*/.exec(src.slice(i));
          if (!m) throw new Error("age gate: bad key");
          key = m[0];
          i += key.length;
        }
        ws();
        if (src[i] !== ":") throw new Error("age gate: expected :");
        i++;
        obj[key] = value();
        ws();
        if (src[i] === ",") i++;
      }
    }
    if (c === '"' || c === "'" || c === "`") return str();
    const m = /^-?\d+(\.\d+)?/.exec(src.slice(i));
    if (m) { i += m[0].length; return Number(m[0]); }
    throw new Error(`age gate: unexpected ${c}`);
  };
  const v = value();
  return { value: v, end: i };
}

function readBank(name: string): Question[] {
  const src = String(ageGateSource ?? "");
  const hit = new RegExp(`const ${name}\\s*:\\s*Question\\[\\]\\s*=\\s*\\[`).exec(src);
  if (!hit) return [];
  try {
    // The literal's own "[" is the last character of the match (the first one is Question[]).
    const { value } = parseLiteral(src, hit.index + hit[0].length - 1);
    return (value as Question[]).filter((q) => q && typeof q.q === "string" && Array.isArray(q.options) && typeof q.correct === "number");
  } catch {
    return [];
  }
}

let banks: { en: Question[]; ar: Question[] } | null = null;
function questionBanks(): { en: Question[]; ar: Question[] } {
  if (!banks) banks = { en: readBank("QUESTION_BANK"), ar: readBank("AR_QUESTION_BANK") };
  return banks;
}

function pickThree(seed: number, bank: Question[]): Question[] {
  const indices = [...bank.keys()];
  for (let i = indices.length - 1; i > 0; i--) {
    seed = (seed * 9301 + 49297) % 233280;
    const j = Math.floor((seed / 233280) * (i + 1));
    [indices[i], indices[j]] = [indices[j], indices[i]];
  }
  return indices.slice(0, 3).map((i) => bank[i]);
}

/** A fresh round: three questions (Arabic bank for an Arabic UI), translated like upstream's t(). */
export function ageGate(uiLanguage: string, seed: number = Date.now() % 1_000_000): { questions: Question[]; bankSize: number } {
  const b = questionBanks();
  const isAr = uiLanguage === "ar";
  const bank = isAr ? b.ar : b.en;
  return {
    questions: pickThree(seed, bank).map((q) => ({ q: t(q.q), options: q.options.map((o) => t(o)), correct: q.correct })),
    bankSize: bank.length,
  };
}
