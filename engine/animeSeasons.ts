// Anime named seasons and episode orders for the detail page, without React (parity audit item 5):
//   - views/detail/anime-episodes/use-anime-tvdb-panel.ts: the TVDB panel. The series id comes from
//     the Kitsu → TVDB mapping (else TVDB's remote-id search on the IMDb id), its order types are the
//     non-empty ones of tvdbSeasonTypes, the active type is settings.tvdbSeasonType (official → aired,
//     else aired, else the first), and the order's seasons become named chips with their air-date span.
//   - views/detail/anime-episodes/use-anime-order.ts + anime-order-utils.ts buildAnimeOrder: the
//     same seasons without a type toggle, used when the panel is off or never resolved.
//   - views/detail/anime-episodes/use-anime-preferred-season.ts: which season opens (the first with an
//     unwatched episode, not before the last played one), behind intentSeasonKey from
//     use-bp-anime-detail.ts (a Kitsu entry that is itself a later season, then the caller's hint).
//   - bp-anime-season-chip.tsx seasonYears + meta line, bp-anime-seasons.tsx shortOrderLabel,
//     hasSeasonChips and the extras-last chip order with its divider.
// The watched sets from AniList / MAL that upstream feeds the preferred season are not loaded
// here; Harbor's manual marks and the local resume store are (lib/episode-progress).
import { t } from "@/lib/i18n";
import { getEpisodeProgress } from "@/lib/episode-progress";
import { pickLocalizedText } from "@/lib/localized-text";
import { manualWatchedState } from "@/lib/manual-watched";
import { kitsuToTvdb } from "@/lib/providers/anime-mapping";
import { harborImdbEpisodesCached } from "@/lib/providers/harbor-imdb";
import { parseKitsuId, type KitsuEpisode } from "@/lib/providers/kitsu";
import { tmdbLanguageIso } from "@/lib/providers/tmdb/tmdb-client";
import {
  tvdbLangFromIso1,
  tvdbOrderTypeHasEpisodes,
  tvdbSeasonTypes,
  tvdbSeriesByRemote,
  type TvdbOrderType,
  type TvdbSeasonTypeOption,
} from "@/lib/providers/tvdb";
import { fetchTvdbOrder, fetchTvdbOrderBySeriesId, seasonDateRange, type TvdbOrder } from "@/lib/providers/tvdb-order";
import { lastPlayedEpisode } from "@/lib/resume";
import type { Settings } from "@/lib/settings";
import { effectiveOrderProvider, tvdbPanelEnabled } from "@/lib/settings/episode-order";
import { foreignAnimeProviderSeasons } from "@/lib/streams/anime-identity";
import { splitFranchiseDisplaySeason } from "@/lib/streams/anime-identity-core";
import { buildAnimeOrder } from "@/views/detail/anime-episodes/anime-order-utils";
import { animeSeasonKey } from "@/views/detail/anime-episodes/anime-season-key";
import type { PickerItem } from "@/views/detail/series-episodes/season-arc-picker";

// ------------------------------------------------------------------------ chip copy (pure)

function yearOf(value: string | undefined): string {
  return value && value.length >= 4 ? value.slice(0, 4) : "";
}

/** bp-anime-season-chip.tsx seasonYears: the first and last airdate's years, "2019-2020" for a two cour run. */
export function seasonYears(item: Pick<PickerItem, "from" | "to" | "year">): string {
  const from = yearOf(item.from) || yearOf(item.year);
  const to = yearOf(item.to);
  if (!from) return to;
  return to && to !== from ? `${from}-${to}` : from;
}

/** bp-anime-season-chip.tsx meta: years · "{n} episodes". */
export function seasonMeta(item: PickerItem): string {
  return [seasonYears(item), item.count > 0 ? t("{n} episodes", { n: item.count }) : ""].filter(Boolean).join(" · ");
}

/** bp-anime-seasons.tsx shortOrderLabel: "Aired Order" → "Aired". */
export function shortOrderLabel(label: string): string {
  return label.replace(/\s*Order$/i, "");
}

// ----------------------------------------------------------------- season pick (pure)

/** use-anime-tvdb-panel / use-anime-order activeKey: a touched pick, the intent, the preferred season, the first. */
export function activeSeasonKey(items: PickerItem[], selected: string | null, intent: string | null, preferred: string | null): string {
  if (selected && items.some((i) => i.key === selected)) return selected;
  if (intent && items.some((i) => i.key === intent)) return intent;
  if (preferred && items.some((i) => i.key === preferred)) return preferred;
  return items[0]?.key ?? "";
}

/**
 * use-bp-anime-detail.ts intentSeasonKey: a Kitsu entry whose own episodes all map onto one IMDb
 * season of 2 or more is that season; else the caller's hint when it names season 2 or later.
 */
export function intentSeasonKey(episodes: KitsuEpisode[], hintSeason: number): string | null {
  const counts = new Map<number, number>();
  for (const ep of episodes) {
    if (ep.sourceMetaId != null) continue;
    const s = ep.imdbSeason;
    if (s == null || s < 1) continue;
    counts.set(s, (counts.get(s) ?? 0) + 1);
  }
  if (counts.size === 1) {
    const only = [...counts.keys()][0];
    if (only >= 2) return String(only);
  }
  return hintSeason >= 2 ? String(hintSeason) : null;
}

/** use-anime-preferred-season.ts, with Trakt empty (anime progress never lives there) and no AniList/MAL sets. */
export function preferredSeasonKey(episodes: KitsuEpisode[], metaId: string, trackId?: string): string | null {
  if (episodes.length === 0) return null;
  const traktWatched = new Set<string>();
  const partScoped =
    splitFranchiseDisplaySeason(parseKitsuId(metaId)) != null ||
    (trackId ? splitFranchiseDisplaySeason(parseKitsuId(trackId)) != null : false);
  const played = lastPlayedEpisode(metaId) ?? (trackId ? lastPlayedEpisode(trackId) : null);
  const playedEp = played != null ? episodes.find((e) => e.number === played.episode) : undefined;
  const playedSeason = partScoped
    ? (playedEp?.seasonNumber ?? playedEp?.imdbSeason ?? null)
    : (playedEp?.imdbSeason ?? playedEp?.seasonNumber ?? null);
  let maxSeason = 1;
  for (const ep of episodes) {
    const isCurrent = ep.sourceMetaId == null;
    let progress = getEpisodeProgress(ep.sourceMetaId ?? metaId, animeSeasonKey(ep), ep.number, ep.length ?? null, ep.imdbId ?? null, traktWatched,
      undefined, undefined, undefined, undefined, ep.imdbSeason, ep.imdbEpisode);
    if (isCurrent && !progress.watched && trackId && trackId !== metaId && manualWatchedState(metaId, animeSeasonKey(ep), ep.number) !== false) {
      const alt = getEpisodeProgress(trackId, animeSeasonKey(ep), ep.number, ep.length ?? null, ep.imdbId ?? null, traktWatched,
        undefined, undefined, undefined, undefined, ep.imdbSeason, ep.imdbEpisode);
      if (alt.watched) progress = alt;
    }
    const seasonNo = partScoped ? (ep.seasonNumber ?? ep.imdbSeason ?? 1) : (ep.imdbSeason ?? ep.seasonNumber ?? 1);
    if (seasonNo > maxSeason) maxSeason = seasonNo;
    if (!progress.watched) {
      if (playedSeason != null && seasonNo < playedSeason) continue;
      return String(seasonNo);
    }
  }
  if (playedSeason != null) return String(playedSeason);
  return String(maxSeason);
}

// ------------------------------------------------------------- the TVDB panel (pure)

export type SeasonBuild = { items: PickerItem[]; subset: Map<string, KitsuEpisode[]>; pool: KitsuEpisode[] };

/**
 * use-anime-tvdb-panel.ts `built`, for Big Picture's call (no franchise pool, no franchise entries):
 * every TVDB season of the order becomes a chip, its episodes matched onto the Kitsu list by TVDB
 * episode id, season:episode pair or absolute number (a Kitsu episode is claimed once); what TVDB
 * has and Kitsu lacks is shown as a TVDB episode (negative id). Kitsu episodes no season claimed
 * land under "Extras". Seasons the anime-identity layer calls foreign are skipped.
 */
export function buildTvdbPanel(
  ordering: TvdbOrder,
  episodes: KitsuEpisode[],
  imdbId: string | null,
  foreignSeasons: Set<number> | null,
  extrasLabel: string,
  lang: string,
): SeasonBuild | null {
  const pool = episodes;
  const byPair = new Map<string, KitsuEpisode>();
  const byAbs = new Map<number, KitsuEpisode>();
  const byTvdbId = new Map<number, KitsuEpisode>();
  const currentByPair = new Map<string, KitsuEpisode>();
  const currentByAbs = new Map<number, KitsuEpisode>();
  const currentByTvdbId = new Map<number, KitsuEpisode>();
  for (const ep of episodes) {
    const abs = ep.absoluteNumber ?? ep.number;
    if (abs != null && !currentByAbs.has(abs)) currentByAbs.set(abs, ep);
    if (ep.tvdbEpisodeId != null && !currentByTvdbId.has(ep.tvdbEpisodeId)) currentByTvdbId.set(ep.tvdbEpisodeId, ep);
    if (ep.imdbSeason != null && ep.imdbSeason >= 1 && ep.imdbEpisode != null) {
      const key = `${ep.imdbSeason}:${ep.imdbEpisode}`;
      if (!currentByPair.has(key)) currentByPair.set(key, ep);
    }
  }
  for (const ep of pool) {
    const abs = ep.absoluteNumber ?? ep.number;
    if (abs != null && !byAbs.has(abs)) byAbs.set(abs, ep);
    if (ep.tvdbEpisodeId != null && !byTvdbId.has(ep.tvdbEpisodeId)) byTvdbId.set(ep.tvdbEpisodeId, ep);
    if (ep.imdbSeason != null && ep.imdbSeason >= 0 && ep.imdbEpisode != null) {
      const k = `${ep.imdbSeason}:${ep.imdbEpisode}`;
      if (!byPair.has(k)) byPair.set(k, ep);
    }
  }
  const items: PickerItem[] = [];
  const subset = new Map<string, KitsuEpisode[]>();
  const claimed = new Set<number>();
  const imdbMap = imdbId ? harborImdbEpisodesCached(imdbId) : undefined;
  for (const s of ordering.seasons) {
    if (s.seasonNumber < 0) continue;
    if (foreignSeasons?.has(s.seasonNumber)) continue;
    const bucket = ordering.bySeason.get(s.seasonNumber) ?? [];
    if (bucket.length === 0) continue;
    const seenId = new Set<number>();
    const eps: KitsuEpisode[] = [];
    for (const e of bucket) {
      const abs = ordering.absByEpId.get(e.id);
      const img = e.stillUrl ?? e.stillPath ?? (abs != null ? ordering.imageByAbs.get(abs) : undefined);
      let match: KitsuEpisode | undefined;
      if (e.seasonNumber > 0) {
        match = byTvdbId.get(e.id) ?? byPair.get(`${e.seasonNumber}:${e.episodeNumber}`);
        if (!match && abs != null) match = byAbs.get(abs);
      }
      const currentMatch =
        currentByTvdbId.get(e.id) ?? currentByPair.get(`${e.seasonNumber}:${e.episodeNumber}`) ?? (abs != null ? currentByAbs.get(abs) : undefined);
      let title: string | undefined;
      let synopsis: string | undefined;
      if (match && currentMatch && match !== currentMatch) {
        title = pickLocalizedText([{ text: match?.title }, { text: currentMatch?.title }], { forName: true, lang });
        synopsis = pickLocalizedText([{ text: match?.synopsis }, { text: currentMatch?.synopsis }], { lang });
      }
      if (match && claimed.has(match.id)) match = undefined;
      const imdbRating = imdbMap?.get(`${e.seasonNumber}:${e.episodeNumber}`) ?? (abs != null ? imdbMap?.get(`1:${abs}`) : undefined);
      const ep: KitsuEpisode = match
        ? {
            ...match,
            thumbnail: !match.thumbnail && img ? img : match.thumbnail,
            ...(title != null ? { title } : {}),
            ...(synopsis != null ? { synopsis } : {}),
            ...(match.rating == null && imdbRating != null ? { rating: imdbRating, ratingIsImdb: true } : {}),
          }
        : {
            id: -e.id,
            number: e.episodeNumber,
            seasonNumber: e.seasonNumber,
            title: pickLocalizedText([{ text: e.name }, { text: e.nameEn ?? "" }, { text: currentMatch?.title ?? "" }], { forName: true, lang }) ?? e.name,
            synopsis: pickLocalizedText([{ text: e.overview }, { text: e.overviewEn ?? "" }, { text: currentMatch?.synopsis ?? "" }], { lang }) ?? e.overview,
            thumbnail: img ?? null,
            airdate: e.airDate ?? null,
            length: e.runtime ?? null,
            imdbSeason: e.seasonNumber,
            imdbEpisode: e.episodeNumber,
            absoluteNumber: abs ?? undefined,
            tvdbEpisodeId: e.id > 0 ? e.id : undefined,
            rating: imdbRating,
            ratingIsImdb: imdbRating != null ? true : undefined,
          };
      if (seenId.has(ep.id)) continue;
      seenId.add(ep.id);
      if (match) claimed.add(match.id);
      eps.push(ep);
    }
    const key = String(s.seasonNumber);
    const { from, to } = seasonDateRange(bucket);
    items.push({ key, name: s.name, count: eps.length, year: s.airDate?.slice(0, 4), from, to, extra: s.seasonNumber === 0 });
    subset.set(key, eps);
  }
  const matchedIds = new Set<number>();
  for (const eps of subset.values()) for (const e of eps) matchedIds.add(e.id);
  const leftovers = pool.filter((e) => e.id > 0 && e.sourceMetaId == null && !matchedIds.has(e.id));
  if (leftovers.length > 0) {
    items.push({ key: "specials", name: extrasLabel, count: leftovers.length, extra: true });
    subset.set("specials", leftovers);
  }
  if (items.length === 0) return null;
  return { items, subset, pool };
}

/** use-anime-order.ts filteredBuilt: drop foreign provider seasons unless that would drop them all. */
export function dropForeignSeasons(built: SeasonBuild, foreign: Set<number> | null): SeasonBuild {
  if (!foreign || foreign.size === 0) return built;
  const items = built.items.filter((i) => !(Number.isFinite(Number(i.key)) && foreign.has(Number(i.key))));
  if (items.length === built.items.length || items.length === 0) return built;
  const subset = new Map(built.subset);
  for (const s of foreign) subset.delete(String(s));
  return { ...built, items, subset };
}

/** use-anime-tvdb-panel.ts: the order types that have episodes, and which one is active. */
export function effectiveOrderType(nonEmpty: TvdbSeasonTypeOption[], seasonType: string): TvdbOrderType {
  const norm = (seasonType === "official" ? "aired" : seasonType) as TvdbOrderType;
  const values = new Set(nonEmpty.map((c) => c.value));
  return values.has(norm) ? norm : values.has("aired") ? "aired" : nonEmpty[0].value;
}

// ----------------------------------------------------------------------- the view

export type SeasonChip = {
  key: string; name: string; count: number; years: string; meta: string; extra: boolean; badge: string | null;
  /** bp-anime-seasons.tsx: a BpChipDivider goes before the first extra that follows a regular season. */
  divider: boolean;
};
export type OrderChip = { value: TvdbOrderType; label: string; short: string };
export type SeasonsView<E> = {
  /** "panel": the TVDB panel with its order toggle; "order": buildAnimeOrder; "none": neither resolved. */
  source: "panel" | "order" | "none";
  seasons: SeasonChip[];
  seasonKey: string;
  orderTypes: OrderChip[];
  orderType: TvdbOrderType;
  /** bp-anime-seasons.tsx hasSeasonChips: more than one season or more than one order. */
  hasChips: boolean;
  groups: Array<{ key: string; showSeason: boolean; episodes: E[] }>;
};

/** bp-anime-seasons.tsx BpAnimeSeasonChips: specials and extras sort to the back behind a divider. */
export function chipsFor(items: PickerItem[]): SeasonChip[] {
  const ordered = [...items].sort((a, b) => Number(!!a.extra) - Number(!!b.extra));
  return ordered.map((s, i) => ({
    key: s.key,
    name: s.name,
    count: s.count,
    years: seasonYears(s),
    meta: seasonMeta(s),
    extra: !!s.extra,
    badge: s.badge ?? null,
    divider: i > 0 && !!s.extra && !ordered[i - 1].extra,
  }));
}

export function viewOf<E>(
  source: SeasonsView<E>["source"],
  built: SeasonBuild | null,
  orderTypes: TvdbSeasonTypeOption[],
  orderType: TvdbOrderType,
  seasonKey: string,
  toEpisode: (ep: KitsuEpisode) => E,
): SeasonsView<E> {
  const items = built?.items ?? [];
  const groups = items.map((i) => {
    const eps = built!.subset.get(i.key) ?? [];
    // use-bp-anime-detail.ts showSeason: the strip's episodes span more than one season.
    const showSeason = new Set(eps.map((e) => e.imdbSeason ?? e.seasonNumber ?? 1)).size > 1;
    return { key: i.key, showSeason, episodes: eps.map(toEpisode) };
  });
  return {
    source,
    seasons: chipsFor(items),
    seasonKey,
    orderTypes: orderTypes.map((o) => ({ value: o.value, label: o.label, short: shortOrderLabel(o.label) })),
    orderType,
    hasChips: items.length > 1 || orderTypes.length > 1,
    groups,
  };
}

// ------------------------------------------------------------------- the network half

export type SeasonsInput = {
  /** The id the page was opened with; watched marks and local resume live under it. */
  metaId: string;
  kitsuId: number | null;
  imdbId: string | null;
  /** kitsu:<id> from the provider chain (use-bp-anime-detail canonicalId). */
  canonicalId: string;
  episodes: KitsuEpisode[];
};

type PanelResult = { build: SeasonBuild; orderTypes: TvdbSeasonTypeOption[]; activeType: TvdbOrderType } | null;

/** use-anime-tvdb-panel.ts's three effects in sequence: series id, order types, the order itself. */
async function tvdbPanel(input: SeasonsInput, settings: Settings): Promise<PanelResult> {
  const tvdbKey = settings.tvdbKey ?? "";
  let sid = input.kitsuId != null ? await kitsuToTvdb(input.kitsuId).catch(() => null) : null;
  if (sid == null && input.imdbId?.startsWith("tt")) sid = await tvdbSeriesByRemote(tvdbKey, input.imdbId).catch(() => null);
  if (sid == null) return null;
  const base = await tvdbSeasonTypes(tvdbKey, sid).catch(() => [] as TvdbSeasonTypeOption[]);
  const candidates: TvdbSeasonTypeOption[] = base.some((c) => c.value === "aired") ? base : [{ value: "aired", label: "Aired Order" }, ...base];
  const checks = await Promise.all(candidates.map((c) => tvdbOrderTypeHasEpisodes(tvdbKey, sid!, c.value).catch(() => false)));
  const nonEmpty = candidates.filter((_, i) => checks[i]);
  if (nonEmpty.length === 0) return null;
  const activeType = effectiveOrderType(nonEmpty, settings.tvdbSeasonType);
  const lang = tmdbLanguageIso();
  const [ordering, foreign] = await Promise.all([
    fetchTvdbOrderBySeriesId(tvdbKey, sid, activeType, tvdbLangFromIso1(lang)).catch(() => null),
    // use-anime-tvdb-panel identitySource: Big Picture passes no metaId, so the kitsu id.
    input.kitsuId != null ? foreignAnimeProviderSeasons(`kitsu:${input.kitsuId}`, input.imdbId).catch(() => null) : Promise.resolve(null),
  ]);
  if (!ordering) return null;
  const build = buildTvdbPanel(ordering, input.episodes, input.imdbId, foreign, t("Extras"), lang);
  return build ? { build, orderTypes: nonEmpty, activeType } : null;
}

/** use-anime-order.ts over use-episode-order.ts, not solo: buildAnimeOrder on the TVDB order. */
async function animeOrder(input: SeasonsInput, settings: Settings): Promise<SeasonBuild | null> {
  const provider = effectiveOrderProvider(settings);
  const seasonType = settings.tvdbSeasonType;
  const metaId = input.canonicalId;
  const remoteId = input.imdbId && input.imdbId.startsWith("tt") ? input.imdbId : metaId.startsWith("tmdb:tv:") ? metaId.slice(8) : null;
  const kitsuId = /^(kitsu|mal|anilist|anidb):/.test(metaId) ? parseKitsuId(metaId) : null;
  if (provider !== "tvdb" || seasonType === "tmdb" || (!remoteId && kitsuId == null)) return null;
  const tvdbKey = settings.tvdbKey ?? "";
  const lang = tmdbLanguageIso();
  const tvdbLang = tvdbLangFromIso1(lang);
  let ordering: TvdbOrder | null = null;
  if (kitsuId != null) {
    const sid = await kitsuToTvdb(kitsuId).catch(() => null);
    if (sid != null) ordering = await fetchTvdbOrderBySeriesId(tvdbKey, sid, seasonType, tvdbLang).catch(() => null);
  }
  if (!ordering && remoteId) ordering = await fetchTvdbOrder(tvdbKey, remoteId, seasonType, tvdbLang).catch(() => null);
  const built = buildAnimeOrder(ordering, input.episodes, t("Specials"), lang);
  if (!built) return null;
  const foreign = await foreignAnimeProviderSeasons(metaId, input.imdbId).catch(() => null);
  return dropForeignSeasons({ items: built.items, subset: built.subsetByKey, pool: input.episodes }, foreign);
}

/**
 * use-bp-anime-detail.ts seasons / seasonKey / orderTypes / orderType: the panel when it is on
 * (tvdbOrderPanel with the TVDB provider) and resolves, else buildAnimeOrder, else nothing (the
 * caller keeps its own grouping). `selected` is the chip the viewer picked, kept while it exists.
 */
export async function resolve<E>(
  input: SeasonsInput,
  settings: Settings,
  selected: string | null,
  hintSeason: number,
  toEpisode: (ep: KitsuEpisode) => E,
): Promise<SeasonsView<E>> {
  const eps = input.episodes;
  const trackId = input.canonicalId === input.metaId ? undefined : input.canonicalId;
  const pick = (items: PickerItem[]) =>
    activeSeasonKey(items, selected, intentSeasonKey(eps, hintSeason), preferredSeasonKey(eps, input.metaId, trackId));
  if (eps.length > 0 && tvdbPanelEnabled(settings)) {
    const panel = await tvdbPanel(input, settings).catch(() => null);
    if (panel) return viewOf("panel", panel.build, panel.orderTypes, panel.activeType, pick(panel.build.items), toEpisode);
  }
  if (eps.length > 0) {
    const order = await animeOrder(input, settings).catch(() => null);
    if (order) return viewOf("order", order, [], "aired", pick(order.items), toEpisode);
  }
  return viewOf("none", null, [], "aired", "", toEpisode);
}
