// Stats / Wrapped (Stage 10): views/wrapped.tsx without React. `load` is the view's effect
// (collectWatchEvents → aggregateWrapped for this year, all time when this year is empty);
// `enrich` is its second phase (enrichTopTitles: posters, genres, people). The card helpers that
// live in views/wrapped/cards.tsx (prettyDate, the heatmap grid and heatColor) are ported here so
// the Swift cards only draw.
import { aggregateWrapped } from "@/lib/wrapped/aggregate";
import { collectWatchEvents } from "@/lib/wrapped/collect";
import { enrichTopTitles } from "@/lib/wrapped/enrich";
import type { TopTitle, WrappedStats } from "@/lib/wrapped/types";
import { isAuthenticated as traktConnected } from "@/lib/trakt/session";
import { loadEffective } from "@/lib/settings/profile-store";

/** cards.tsx prettyDate: "Mar 4". */
function prettyDate(iso: string): string {
  const d = new Date(`${iso}T00:00:00`);
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

/** cards.tsx heatColor as a level: 0 empty, then accent/25, /45, /70, full. */
function heatLevel(count: number, max: number): number {
  if (count === 0) return 0;
  const r = count / (max || 1);
  if (r > 0.75) return 4;
  if (r > 0.5) return 3;
  if (r > 0.25) return 2;
  return 1;
}

export type HeatDay = { key: string; count: number; level: number };
export type WrappedView = WrappedStats & {
  /** HeatmapCard: the last 364 days in weeks of seven, oldest first. Empty when there is no heatmap. */
  heatWeeks: HeatDay[][];
  /** HighlightsCard "Longest binge" body date. */
  bingeDate: string;
};

function heatWeeks(stats: WrappedStats): HeatDay[][] {
  if (stats.heatmap.length === 0) return [];
  const map = new Map(stats.heatmap.map((c) => [c.date, c.count]));
  const max = Math.max(...stats.heatmap.map((c) => c.count));
  const end = new Date();
  const cells: HeatDay[] = [];
  for (let i = 363; i >= 0; i--) {
    const d = new Date(end);
    d.setDate(d.getDate() - i);
    const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
    const count = map.get(key) ?? 0;
    cells.push({ key, count, level: heatLevel(count, max) });
  }
  const weeks: HeatDay[][] = [];
  for (let i = 0; i < cells.length; i += 7) weeks.push(cells.slice(i, i + 7));
  return weeks;
}

/** wrapped.tsx effect, first phase. Null when collecting failed (the view shows WrappedEmpty). */
export async function load(): Promise<WrappedView | null> {
  try {
    const { events, source } = await collectWatchEvents({ traktConnected: traktConnected() });
    const year = new Date().getFullYear();
    const yearStats = aggregateWrapped(events, source, year);
    const stats = yearStats.totalPlays === 0 && events.length > 0 ? aggregateWrapped(events, source, null) : yearStats;
    return { ...stats, heatWeeks: heatWeeks(stats), bingeDate: stats.longestBinge.date ? prettyDate(stats.longestBinge.date) : "" };
  } catch {
    return null;
  }
}

/** Second phase: enrichTopTitles with the profile's TMDB key. The view merges it as wrapped.tsx does. */
export async function enrich(
  topTitles: TopTitle[],
  profileId = "default",
  linked = true,
): Promise<{ genres: Array<{ genre: string; count: number }>; posters: Record<string, string>; actors: Array<{ name: string; count: number }> }> {
  const tmdbKey = loadEffective(profileId || "default", linked !== false).tmdbKey ?? "";
  try {
    return await enrichTopTitles(Array.isArray(topTitles) ? topTitles : [], tmdbKey);
  } catch {
    return { genres: [], posters: {}, actors: [] };
  }
}

/** settings.wrappedButton: whether the Library shows its "Stats" entry. */
export function enabled(profileId = "default", linked = true): boolean {
  return loadEffective(profileId || "default", linked !== false).wrappedButton !== false;
}
