// Card marks for browse tiles (bp-card-marks.tsx + bp-card-state-marks.tsx), computed in one
// pass per row so a Swift tile never asks the engine per card. Score chips are deliberately
// absent: upstream's TV tile surface carries none ("a ten-foot card carries no score plate",
// use-bp-card-badges.ts badgeGates), and the hero shows the score of the focused title.
import { CR_CATEGORY_SHORT, shortCategory } from "@/lib/anime-award-labels";
import { findTopAward, parseAwardYear, type AwardWin } from "@/lib/anime-awards";
import { ensureAwardMaster } from "@/lib/anime-awards-source";
import { mergeBundledAwards } from "@/lib/awards-history";
import { awardSummary, type AwardType } from "@/lib/providers/wikidata";
import { animeHasDub, dubSetReady, ensureDubSet } from "@/lib/providers/anime-dub-sub";
import { isTop10, setTop10Metas } from "@/lib/top10-set";
import { isWatchedFlagged } from "@/lib/watched-flag";
import { isMovieWatchedLocal } from "@/lib/movie-watched";
import { setWatchlistAggregate, watchlistHas } from "@/lib/watchlist";
import { library } from "@/lib/stremio";
import { loadEffective } from "@/lib/settings/profile-store";
import type { Settings } from "@/lib/settings/types";
import { BP_ANIME_ID } from "@/views/big-picture/use-bp-card-badges";
import { tmdbImdbCached, tmdbImdbId } from "@/lib/providers/tmdb/tmdb-imdb-resolve";

export type CardMeta = {
  id: string;
  type: string;
  name: string;
  releaseInfo?: string | null;
  releaseDate?: string | null;
  inTheaters?: boolean | null;
};

export type Zone = "topStart" | "topEnd" | "bottomEnd" | "bottomStart";

export type CardMarks = {
  id: string;
  /** Top-start identity chip: "2023 Winner", "3 Oscars", "DUB", "New", "Rerun · 2015", "In Cinema". */
  chip: string | null;
  bookmark: Zone | null;
  watched: "topEnd" | "bottomEnd" | null;
  top10: "left" | "right" | null;
};

// bp-award-mark.tsx NOUN table.
const NOUN: Record<string, string> = {
  oscar: "Oscar", emmy: "Emmy", golden_globe: "Globe", bafta: "BAFTA", sag: "SAG", critics_choice: "Critics",
  cannes: "Cannes", venice: "Venice", berlin: "Berlin", annie: "Annie", spirit: "Spirit", saturn: "Saturn",
  bafta_tv: "BAFTA", cesar: "Cesar", goya: "Goya", blue_dragon: "Blue Dragon", baeksang: "Baeksang", bifa: "BIFA", other: "Award",
};

function classicLabel(type: AwardType, wins: number): string {
  const noun = NOUN[type] ?? NOUN.other;
  if (wins <= 1) return noun;
  return noun.endsWith("s") ? `${wins} ${noun}` : `${wins} ${noun}s`;
}

function animeAwardLabel(win: AwardWin): string {
  const known = CR_CATEGORY_SHORT[win.categoryKey];
  return `${win.year} ${known ?? shortCategory(win)}`;
}

function isInCinema(m: CardMeta): boolean {
  return m.type === "movie" && m.inTheaters === true;
}

function isRerun(m: CardMeta): boolean {
  if (m.type !== "movie" || !m.releaseDate) return false;
  const released = Date.parse(m.releaseDate);
  if (Number.isNaN(released)) return false;
  return (Date.now() - released) / (1000 * 60 * 60 * 24 * 30.44) > 9;
}

function chipFor(m: CardMeta, s: Settings): string | null {
  if (!s.showCardBadges) return null;
  const isAnime = BP_ANIME_ID.test(m.id);
  const year = parseAwardYear(m.releaseInfo);
  if (isAnime) {
    const win = findTopAward(m.name ?? "", year, m.id);
    if (win) return animeAwardLabel(win);
  } else {
    const won = awardSummary(mergeBundledAwards(null, m.name, year)).find((x) => x.wins > 0);
    if (won) return classicLabel(won.type, won.wins);
  }
  if (s.showDubBadge && isAnime && dubSetReady() && animeHasDub(m.id)) return "DUB";
  const cinema = isInCinema(m);
  if (!cinema && !!m.releaseInfo && m.releaseInfo === String(new Date().getFullYear())) return "New";
  if (cinema) return isRerun(m) ? `Rerun${m.releaseInfo ? ` · ${m.releaseInfo}` : ""}` : "In Cinema";
  return null;
}

let primed = false;
function prime(anime: boolean): void {
  if (primed) return;
  primed = true;
  // Both are network feeds; a first row renders without them and the next call sees them.
  void ensureAwardMaster().catch(() => {});
  if (anime) ensureDubSet();
}

/**
 * Marks for one screenful of cards, using the profile's effective settings. A watchlist entry
 * or watched flag is often stored under the imdb id while a TMDB-built row carries a tmdb one
 * (useTmdbImdbId in the tiles); the resolver's cache makes the alt lookup free after the first.
 */
export function marks(metas: CardMeta[], profileId: string, linked: boolean): CardMarks[] {
  const s = loadEffective(profileId, linked);
  prime(metas.some((m) => BP_ANIME_ID.test(m.id)));
  // useTmdbImdbId: the cache answers now; a miss resolves in the background for the next pass.
  const alts = metas.map((m) => {
    if (!m.id.startsWith("tmdb:")) return null;
    const hit = tmdbImdbCached(m.id);
    if (hit === undefined && s.tmdbKey) void tmdbImdbId(s.tmdbKey, m.id).catch(() => null);
    return hit ?? null;
  });
  const has = (i: number, test: (id: string) => boolean) => test(metas[i].id) || (!!alts[i] && test(alts[i] as string));
  // bpCardZones: scores take topEnd when badgePlacement is "top", else bottomEnd; the watched
  // check always takes the other end. The TV tile has no scores, but the corner stays theirs.
  const scoresZone = s.badgePlacement === "top" ? "topEnd" : "bottomEnd";
  const watchedZone = scoresZone === "bottomEnd" ? "topEnd" : "bottomEnd";
  const bookmarkZone = s.watchlistBadge === "off" ? null : (s.watchlistBadge as Zone);
  const ribbonSide = s.top10RibbonSide === "left" ? "left" : "right";
  return metas.map((m, i) => ({
    id: m.id,
    chip: chipFor(m, s),
    bookmark: bookmarkZone && has(i, watchlistHas) ? bookmarkZone : null,
    watched: s.showWatchedBadge && (has(i, isWatchedFlagged) || (m.type === "movie" && has(i, isMovieWatchedLocal))) ? watchedZone : null,
    // On a television the ribbon is the mark, not a preference (bp-card-state-marks.tsx).
    top10: isTop10(m.id, m.name) ? ribbonSide : null,
  }));
}

/** The room's Top 10 (bp-top10-feed.ts): one set at a time, the shell's rows are the floor. */
export function setTop10(metas: Array<{ id: string; name: string }>): void {
  setTop10Metas(metas);
}

/**
 * watchlist-sync.tsx: the Stremio library (minus removed/temp) feeds the aggregate the
 * bookmark mark reads. Trakt/Simkl lists join when those trackers land.
 */
export async function refreshWatchlist(authKey: string | null): Promise<number> {
  if (!authKey) {
    setWatchlistAggregate([]);
    return 0;
  }
  const items = await library(authKey);
  const ids = items.filter((it) => !it.removed && !it.temp).map((it) => it._id);
  setWatchlistAggregate(ids);
  return ids.length;
}
