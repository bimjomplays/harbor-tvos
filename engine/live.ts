// Live TV on upstream's IPTV stack: sources (M3U, Xtream, middleware probing), the 6-hour
// playlist cache, favorites/pins/stats ordering (bp-guide-order), and an XMLTV guide with
// upstream's channel↔EPG resolver. Swift gets flat channel lists plus now/next per channel.
import { readPlaylists, writePlaylists, type StoredPlaylist } from "@/lib/iptv/playlists-store";
import { detectProviderShape } from "@/lib/iptv/ingest/detect";
import { loadPlaylist, clearPlaylistCache } from "@/lib/iptv/store";
import { deriveEpgUrls } from "@/lib/iptv/m3u";
import { parseXmltv, indexProgramsByChannel, findCurrent } from "@/lib/iptv/xmltv";
import { computeTvgIdCounts, epgProgramsForChannel } from "@/lib/iptv/epg-resolver";
import { epgOffsetHoursPref } from "@/lib/iptv/settings-bridge";
import { recordChannelPlay, removeStatsForSource } from "@/lib/iptv/channel-stats";
import { removePinsForSource, togglePin as togglePinUpstream, isPinned } from "@/lib/iptv/pins";
import { toggleGroupHidden as toggleGroupHiddenUpstream } from "@/lib/iptv/group-order";
import { removeEpgOverridesForSource, getEpgOverride, setEpgOverride } from "@/lib/iptv/epg-map";
import { recentChannels } from "@/lib/iptv/channel-stats";
import { detectCountryFromGroup, flagUrl, indexChannelsByCountry, stripCountryPrefix } from "@/lib/iptv/country-detect";
import { isLiveChannel } from "@/lib/iptv/vod-classify";
import { sortChannelsByGroupRelevance } from "@/lib/iptv/group-relevance";
import { headersFromChannel } from "@/lib/iptv/channel-headers";
import { buildCatchupUrl, channelHasCatchup } from "@/lib/iptv/catchup";
import { hydrateShortEpg } from "@/lib/iptv/xtream-short-epg";
import { rankBpLive } from "@/views/big-picture/bp-live-rank";
import { materializePlaylistEntry, newPlaylistId } from "@/lib/iptv/playlist-entry";
import { buildBpGuide } from "@/views/big-picture/use-bp-live";
import { bpChannelLabel, bpGroupLabel } from "@/views/big-picture/bp-guide-title";
import { bpGuideOrder } from "@/views/big-picture/bp-guide-order";
import type { EpgChannelMeta, EpgIndex, EpgProgram, IptvChannel, XmltvParseResult } from "@/lib/iptv/types";
import { loadStoredSettings } from "@/lib/settings/load";
import { Gunzip } from "fflate";
import { clearVodCache } from "./liveVod";

export type LiveChannel = {
  id: string;
  name: string;
  pinned?: boolean;
  label: string;
  badge: string | null;
  groupLabel: string | null;
  logo: string | null;
  url: string;
  group: string | null;
  tvgId: string | null;
  /** Referer / User-Agent the playlist asked for (channel-headers.ts). */
  headers: Record<string, string> | null;
  favorite: boolean;
  /** epg-map.ts: the guide channel the viewer matched by hand (null = automatic tvg-id / name match). */
  epgMatch: string | null;
};

export type LiveGroup = { name: string; count: number; hidden?: boolean };

export type LivePlaylistView = {
  id: string;
  name: string;
  kind: "m3u" | "xtream" | "epg";
  /** Channels in guide order for the "All" category (favorites, pins, most watched, region networks, rest). */
  channels: LiveChannel[];
  groups: LiveGroup[];
  hiddenGroups?: string[];
  /** bp-live.tsx chips after Favorites and All (recent, pinned groups, themes or countries, top groups). */
  categories: LiveCategory[];
  total: number;
  epgUrl: string | null;
};

export type NowNext = {
  id: string;
  now: ProgramView | null;
  next: ProgramView | null;
  /** False when the guide holds nothing for this channel (no match), so the row can say "Live". */
  known: boolean;
};

export type ProgramView = { title: string; description: string | null; startMs: number; endMs: number; category: string | null; iconUrl: string | null };

// ------------------------------------------------------------------------------ sources

export function playlists(): StoredPlaylist[] {
  return readPlaylists();
}

/** use-bp-live.ts sources: every playlist but the "Guide data only" ones. */
function channelSources(): StoredPlaylist[] {
  return readPlaylists().filter((p) => (p.kind ?? "m3u") !== "epg");
}

// use-bp-live.ts readActiveId / writeActiveId: the source Live TV (and the Home live row) opens on.
const ACTIVE_KEY = "harbor.iptv.active";

function readActiveSource(): string | null {
  try { return localStorage.getItem(ACTIVE_KEY); } catch { return null; }
}

/** use-bp-live activeSource: the remembered source when it still has channels, else the first. */
export function activeSource(): string | null {
  const list = channelSources();
  const stored = readActiveSource();
  return list.find((p) => p.id === stored)?.id ?? list[0]?.id ?? null;
}

/** use-bp-live setActiveId (a guide-only source is not a channel source and is ignored). */
export function setActiveSource(id: string): string | null {
  if (channelSources().some((p) => p.id === id)) {
    try { localStorage.setItem(ACTIVE_KEY, id); } catch { /* ignore */ }
  }
  return activeSource();
}

/**
 * Add any source upstream accepts: an M3U/M3U8 URL, a middleware host (probed for
 * /iptv/m3u etc.), or an Xtream `get.php` / `player_api.php` login URL. The EPG URL is taken
 * from the argument, else derived for Xtream logins.
 */
export function addPlaylist(name: string, url: string, epgUrl?: string | null): StoredPlaylist {
  const trimmed = url.trim();
  const id = `pl_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 6)}`;
  const probe = detectProviderShape({ id, name: name.trim() || trimmed, url: trimmed });
  if (probe.kind === "invalid") throw new Error(probe.reason);
  const entry: StoredPlaylist = { id, name: name.trim() || trimmed, url: trimmed, kind: probe.kind === "xtream" ? "xtream" : probe.kind === "epg" ? "epg" : "m3u" };
  if (probe.kind === "xtream") entry.xtream = { server: probe.creds.base, username: probe.creds.username, password: probe.creds.password };
  const epg = (epgUrl ?? "").trim() || (probe.kind === "xtream" ? deriveEpgUrls(trimmed)[0] ?? null : null);
  if (epg) entry.epgUrl = epg;
  writePlaylists([...readPlaylists().filter((p) => p.url !== trimmed), entry]);
  return entry;
}

/**
 * bp-live-setup: the structured form. "m3u" takes a playlist URL, "xtream" a server + login
 * (Harbor builds the get.php and xmltv.php addresses), "epg" a guide address only.
 */
export function addStructured(kind: "m3u" | "xtream" | "epg", name: string, url: string, epgUrl: string, server: string, username: string, password: string): StoredPlaylist {
  const id = newPlaylistId();
  const entry = materializePlaylistEntry(id, {
    kind, name: name.trim() || "My playlist", url: url.trim(), epgUrl: epgUrl.trim(),
    xtream: { server: server.trim(), username: username.trim(), password: password.trim() },
  } as Parameters<typeof materializePlaylistEntry>[1]);
  const list = readPlaylists();
  writePlaylists([...list, entry]);
  return entry;
}

export function setEpgUrl(id: string, epgUrl: string | null): void {
  writePlaylists(readPlaylists().map((p) => (p.id === id ? { ...p, epgUrl: (epgUrl ?? "").trim() || undefined } : p)));
  epgCache.delete(id);
}

export function removePlaylist(id: string): void {
  writePlaylists(readPlaylists().filter((p) => p.id !== id));
  clearPlaylistCache(id);
  epgCache.delete(id);
  loaded.delete(id);
  removeFavoritesForSource(id);
  removePinsForSource(id);
  removeStatsForSource(id);
  removeEpgOverridesForSource(id);
  // use-vod-sources removePlaylist: clearXtreamVodLibraryCache(id).
  clearVodCache(id);
}

// ---------------------------------------------------------------------------- favorites
// lib/iptv/favorites.tsx storage, without the React provider.
const FAV_KEY = "harbor.iptv.favorites.v2";
type StoredFavorite = { id: string; name: string; logo: string | null; group: string | null; url: string; tvgId: string | null; sourceId: string };

function readFavorites(): Map<string, StoredFavorite> {
  const map = new Map<string, StoredFavorite>();
  try {
    const parsed = JSON.parse(localStorage.getItem(FAV_KEY) ?? "[]");
    if (Array.isArray(parsed)) for (const e of parsed) if (e && typeof e.id === "string") map.set(e.id, e as StoredFavorite);
  } catch { /* ignore */ }
  return map;
}

function writeFavorites(map: Map<string, StoredFavorite>): void {
  localStorage.setItem(FAV_KEY, JSON.stringify(Array.from(map.values())));
}

export function favorites(): StoredFavorite[] {
  return Array.from(readFavorites().values());
}

export function toggleFavorite(channel: { id: string; name: string; logo?: string | null; group?: string | null; url: string; tvgId?: string | null }): boolean {
  const map = readFavorites();
  if (map.has(channel.id)) {
    map.delete(channel.id);
    writeFavorites(map);
    return false;
  }
  map.set(channel.id, { id: channel.id, name: channel.name, logo: channel.logo ?? null, group: channel.group ?? null, url: channel.url, tvgId: channel.tvgId ?? null, sourceId: channel.id.split("::")[0] ?? "" });
  writeFavorites(map);
  return true;
}

function removeFavoritesForSource(sourceId: string): void {
  const map = readFavorites();
  let changed = false;
  for (const [id, f] of map) {
    if (f.sourceId === sourceId || id.startsWith(`${sourceId}::`)) { map.delete(id); changed = true; }
  }
  if (changed) writeFavorites(map);
}

// lib/iptv/group-order: per-source group prefs (hidden / pinned groups), read straight from the store.
function readHiddenGroups(sourceId: string): string[] {
  try {
    const all = JSON.parse(localStorage.getItem("harbor.iptv.groupPrefs.v1") ?? "{}") as Record<string, { hidden?: string[] }>;
    return all?.[sourceId]?.hidden ?? [];
  } catch { return []; }
}

/** useGroupPrefs toggleGroupHidden: hide (or show again) a whole channel group of one source. */
export function toggleGroupHidden(playlistId: string, group: string): string[] {
  toggleGroupHiddenUpstream(playlistId, group);
  return readHiddenGroups(playlistId);
}

/** usePinnedOrder togglePin: pinned channels sit in guide-order tier 2. */
export function toggleChannelPin(channelId: string): boolean {
  togglePinUpstream(channelId);
  return isPinned(channelId);
}

function readPins(): string[] {
  try {
    const parsed = JSON.parse(localStorage.getItem("harbor.iptv.pins.v1") ?? "[]");
    return Array.isArray(parsed) ? parsed.filter((x): x is string => typeof x === "string") : [];
  } catch {
    return [];
  }
}

// ----------------------------------------------------------------------------- channels

const MAX_CHANNELS = 6000;
const loaded = new Map<string, IptvChannel[]>();

function toView(ch: IptvChannel, favs: Map<string, StoredFavorite>): LiveChannel {
  // bp-guide-title: "##ESPN HD RAW##" → label "ESPN", badge "HD"; a group that repeats the name is dropped.
  const l = bpChannelLabel(ch.name);
  return { id: ch.id, name: ch.name, label: l.name, badge: l.badge, groupLabel: bpGroupLabel(ch.group, l.name), logo: ch.logo, url: ch.url, group: ch.group, tvgId: ch.tvgId, headers: headersFromChannel(ch) ?? null, favorite: favs.has(ch.id), epgMatch: getEpgOverride(ch.id) };
}

/** Loads (or serves from upstream's cache) one playlist, ordered like the Big Picture guide. */
export async function channels(playlistId: string, force = false): Promise<LivePlaylistView> {
  const pl = readPlaylists().find((p) => p.id === playlistId);
  if (!pl) throw new Error("playlist not found");
  const playlist = await loadPlaylist(pl, { force });
  const settings = loadStoredSettings();
  const region = String(settings.region ?? "US");
  const languages = Array.isArray(settings.preferredLanguages) ? (settings.preferredLanguages as string[]) : [];
  // use-bp-live.ts: VOD lines (Xtream movie/series entries) are not channels, and the groups
  // the viewer's region and languages care about come first.
  const all = sortChannelsByGroupRelevance(playlist.channels.filter(isLiveChannel), region, languages).slice(0, MAX_CHANNELS);
  loaded.set(playlistId, all);
  const favs = readFavorites();
  const hidden = readHiddenGroups(pl.id);
  const ordered = bpGuideOrder({ channels: all, favoriteIds: new Set(favs.keys()), pinnedOrder: readPins(), hiddenGroups: hidden, region, promoteNetworks: true });
  const counts = new Map<string, number>();
  for (const ch of all) {
    const g = ch.group ?? "Uncategorized";
    counts.set(g, (counts.get(g) ?? 0) + 1);
  }
  const pins = new Set(readPins());
  return {
    id: pl.id,
    name: pl.name,
    kind: pl.kind ?? "m3u",
    channels: ordered.map((ch) => ({ ...toView(ch, favs), pinned: pins.has(ch.id) })),
    groups: Array.from(counts, ([name, count]) => ({ name, count, hidden: hidden.includes(name) })),
    hiddenGroups: hidden,
    categories: liveCategories(pl.id, all, new Set(favs.keys()), hidden, region),
    total: playlist.channels.length,
    epgUrl: pl.epgUrl ?? null,
  };
}

// ---------------------------------------------------------------------------- categories
// bp-live.tsx builds its filter chips from use-live-home's rails: Favorites, All, then
// "Continue watching", pinned groups, and either the viewer's countries' groups or the theme
// rails followed by the biggest groups, 30 chips at most. use-live-home.ts keeps THEMES,
// JUNK_RE and railFor private, so they are reproduced here verbatim.
export type LiveCategory = {
  key: string;
  label: string;
  count: number;
  /** A group rail: Swift filters the channel list by this group. */
  group: string | null;
  /** bp-live-filters FilterFlag: the flagcdn image for a country group. */
  flag: string | null;
  /** A rail that is not one group (recent, themes): its channels in guide order. */
  ids?: string[];
};

const UNCATEGORIZED = "Uncategorized";
const MIN_GROUP = 4;
const MAX_RAILS = 120;
const THEME_CAP = 60;
const MAX_CATEGORIES = 30;
const JUNK_RE = /\b(xxx|adult|adults|porn|ppv|vip|sex|hardcore|nsfw)\b|18\s*\+|\+\s*18|^[\s#*\-=._|~>]+$/i;
const THEMES: Array<{ key: string; title: string; re: RegExp }> = [
  { key: "sports", title: "Sports", re: /\b(sports?|espn|bein|sky\s?sport|nfl|nba|mlb|nhl|ufc|wwe|boxing|football|soccer|dazn|fubo|golf|tennis|nascar|motogp|formula)\b/i },
  { key: "news", title: "News", re: /\b(news|cnn|bbc|msnbc|cnbc|bloomberg|newsmax|gb\s?news|al\s?jazeera|sky\s?news|fox\s?news)\b/i },
  { key: "movies", title: "Movies", re: /\b(movies?|cinema|film|films|hbo|cinemax|starz|showtime|tcm|mgm|paramount)\b/i },
  { key: "kids", title: "Kids & Family", re: /\b(kids?|cartoon|disney|nick|nickelodeon|junior|baby|boomerang|cbeebies|pbs\s?kids)\b/i },
  { key: "entertainment", title: "Entertainment", re: /\b(entertain\w*|comedy|drama|lifestyle|reality|bravo|tlc|usa\s?network|tnt|fx|amc)\b/i },
  { key: "docs", title: "Documentary", re: /\b(document\w*|discovery|history|nat\s?geo|national\s?geographic|science|animal|smithsonian)\b/i },
  { key: "music", title: "Music", re: /\b(music|mtv|vevo|vh1|kerrang|stingray|trace|hits)\b/i },
];

type Rail = { key: string; title: string; group: string | null; flagCode?: string; channels: IptvChannel[] };

function railFor(g: string, chs: IptvChannel[], code?: string): Rail {
  return { key: code ? `co:${code}:${g}` : `cat:${g}`, title: stripCountryPrefix(g), group: g, flagCode: code ?? detectCountryFromGroup(g)?.code, channels: chs.slice(0, 30) };
}

function readGroupPins(sourceId: string): string[] {
  try {
    const all = JSON.parse(localStorage.getItem("harbor.iptv.groupPrefs.v1") ?? "{}") as Record<string, { pinned?: string[] }>;
    return all?.[sourceId]?.pinned ?? [];
  } catch { return []; }
}

// lib/iptv/country-prefs: the countries picked for this source (desktop's country filter).
function readCountries(sourceId: string): string[] {
  try {
    const all = JSON.parse(localStorage.getItem("harbor.iptv.countryPrefs.v1") ?? "{}") as Record<string, { selected?: string[] }>;
    return all?.[sourceId]?.selected ?? [];
  } catch { return []; }
}

function liveCategories(sourceId: string, channels: IptvChannel[], favoriteIds: Set<string>, hiddenGroups: string[], region: string): LiveCategory[] {
  // use-live-home index: channels by id and by group, theme matches (60 each), the big groups.
  const byId = new Map<string, IptvChannel>();
  const byGroup = new Map<string, IptvChannel[]>();
  const themeCh: Record<string, IptvChannel[]> = {};
  for (const t of THEMES) themeCh[t.key] = [];
  for (const ch of channels) {
    byId.set(ch.id, ch);
    const g = ch.group ?? UNCATEGORIZED;
    const arr = byGroup.get(g);
    if (arr) arr.push(ch); else byGroup.set(g, [ch]);
    for (const t of THEMES) {
      const tc = themeCh[t.key];
      if (tc.length < THEME_CAP && (t.re.test(g) || t.re.test(ch.name))) tc.push(ch);
    }
  }
  const topGroups = [...byGroup.entries()].filter(([g, a]) => !JUNK_RE.test(g) && a.length >= MIN_GROUP).sort((a, b) => b[1].length - a[1].length).map(([g]) => g);

  const rails: Rail[] = [];
  const used = new Set<string>();
  // A stat for a channel the playlist no longer lists cannot be tuned from this list: dropped.
  const recent = recentChannels(20, sourceId).map((s) => byId.get(s.id)).filter((c): c is IptvChannel => !!c);
  if (recent.length) rails.push({ key: "recent", title: "Continue watching", group: null, channels: recent });
  for (const g of readGroupPins(sourceId)) {
    if (used.has(g) || !byGroup.has(g)) continue;
    rails.push(railFor(g, byGroup.get(g) ?? []));
    used.add(g);
  }
  const categoryRails: Rail[] = [];
  const { channelsByCountry } = indexChannelsByCountry(channels);
  const selected = readCountries(sourceId).filter((c) => channelsByCountry.has(c));
  if (selected.length) {
    for (const code of selected.slice(0, 6)) {
      const inCountry = new Map<string, IptvChannel[]>();
      for (const ch of channelsByCountry.get(code) ?? []) {
        const g = ch.group ?? UNCATEGORIZED;
        const arr = inCountry.get(g);
        if (arr) arr.push(ch); else inCountry.set(g, [ch]);
      }
      const byCount = [...inCountry.entries()].filter(([g]) => !JUNK_RE.test(g)).sort((a, b) => b[1].length - a[1].length);
      for (const [g, chs] of byCount) {
        if (categoryRails.length >= MAX_RAILS) break;
        categoryRails.push(railFor(g, chs, code));
      }
      if (categoryRails.length >= MAX_RAILS) break;
    }
  } else {
    for (const theme of THEMES) {
      const chs = themeCh[theme.key];
      if (chs.length >= 3) categoryRails.push({ key: `theme:${theme.key}`, title: theme.title, group: null, channels: chs.slice(0, 30) });
    }
    for (const g of topGroups) {
      if (categoryRails.length >= MAX_RAILS) break;
      if (used.has(g)) continue;
      categoryRails.push(railFor(g, byGroup.get(g) ?? []));
    }
  }

  // bp-live.tsx: hidden groups skipped, group rails re-derived from the full list (railFor caps
  // at 30), empty rails dropped, 30 chips counting Favorites and All.
  const hidden = new Set(hiddenGroups);
  const pinnedOrder = readPins();
  const out: LiveCategory[] = [];
  for (const rail of [...rails, ...categoryRails]) {
    if (out.length + 2 >= MAX_CATEGORIES) break;
    if (rail.group != null) {
      if (hidden.has(rail.group)) continue;
      const count = byGroup.get(rail.group)?.length ?? 0;
      if (count === 0) continue;
      out.push({ key: rail.key, label: rail.title, count, group: rail.group, flag: rail.flagCode ? flagUrl(rail.flagCode) : null });
      continue;
    }
    const ids = bpGuideOrder({ channels: rail.channels, favoriteIds, pinnedOrder, hiddenGroups, region, promoteNetworks: false }).map((c) => c.id);
    if (ids.length === 0) continue;
    out.push({ key: rail.key, label: rail.title, count: ids.length, group: null, flag: null, ids });
  }
  return out;
}

/** Tell the stats store a channel was tuned (feeds the "most watched" band). */
export function recordPlay(playlistId: string, channelId: string): void {
  const ch = loaded.get(playlistId)?.find((c) => c.id === channelId);
  if (ch) recordChannelPlay(ch);
}

// ---------------------------------------------------------------------------------- EPG

const EPG_TTL_MS = 60 * 60 * 1000;
/** xmltv.ts MAX_BYTES: a guide bigger than this (as downloaded) is refused. */
const EPG_MAX_BYTES = 200 * 1024 * 1024;
/** How much of the download is inflated / decoded / parsed at a time. */
const EPG_PIECE_BYTES = 1 << 20;
/** `url` is the guide addresses joined with "|" (epg-store.ts sourceSignature). */
const epgCache = new Map<string, { index: EpgIndex; url: string; loading: Promise<EpgIndex> | null }>();

/**
 * xmltv.ts fetchAndParseXmltv reads the guide as a stream: drainBlocks runs on each network
 * chunk, so its buffer is never more than a chunk. The host hands the engine whole bodies, and
 * drainBlocks over a whole guide looks for the next `<channel ` in everything that is left after
 * every programme (quadratic: a 4 MB guide took 25 s, a normal 50 MB one never finished and held
 * the engine thread). This walks the text once with the same block rules and hands each block to
 * upstream's parseXmltv, so every programme and channel is read by upstream's own code.
 */
class XmltvReader {
  readonly programs: EpgProgram[] = [];
  readonly channelMeta = new Map<string, EpgChannelMeta>();
  private rest = "";

  push(text: string, final: boolean): void {
    const buf = this.rest + text;
    let pos = 0;
    let ch = buf.indexOf("<channel ");
    let pr = buf.indexOf("<programme");
    for (;;) {
      if (ch >= 0 && ch < pos) ch = buf.indexOf("<channel ", pos);
      if (pr >= 0 && pr < pos) pr = buf.indexOf("<programme", pos);
      // drainBlocks/trimLeftover: no block starts here; keep a tail a split tag could begin in.
      if (ch < 0 && pr < 0) { pos = Math.max(pos, buf.length - 64); break; }
      const channelFirst = ch >= 0 && (pr < 0 || ch < pr);
      const start = channelFirst ? ch : pr;
      const closeTag = channelFirst ? "</channel>" : "</programme>";
      const close = buf.indexOf(closeTag, start);
      if (close < 0) { pos = start; break; }
      const end = close + closeTag.length;
      this.take(buf.slice(start, end));
      pos = end;
    }
    this.rest = final ? "" : buf.slice(pos);
  }

  private take(block: string): void {
    const one = parseXmltv(block);
    for (const p of one.programs) this.programs.push(p);
    // parseChannel: a repeated channel without a name or icon keeps the first one's.
    for (const [id, meta] of one.channelMeta) {
      if (this.channelMeta.has(id) && !meta.displayName && !meta.icon) continue;
      this.channelMeta.set(id, meta);
    }
  }
}

/** The end of the last whole UTF-8 character in b[0..<end] (a split one waits for the next piece). */
function utf8Cut(b: Uint8Array, end: number): number {
  let i = end;
  let tail = 0;
  while (i > 0 && tail < 4 && (b[i - 1] & 0xc0) === 0x80) { i--; tail++; }
  if (i === 0) return end;
  const lead = b[i - 1];
  const need = lead >= 0xf0 ? 4 : lead >= 0xe0 ? 3 : lead >= 0xc0 ? 2 : 1;
  return tail + 1 >= need ? end : i - 1;
}

/** Inflates (gzip or not), decodes and parses a downloaded guide a piece at a time. */
export function parseXmltvBytes(raw: Uint8Array): XmltvParseResult {
  const reader = new XmltvReader();
  const decoder = new TextDecoder("utf-8");
  let carry: Uint8Array | null = null;
  const feed = (chunk: Uint8Array) => {
    let bytes = chunk;
    if (carry) {
      const joined = new Uint8Array(carry.length + chunk.length);
      joined.set(carry);
      joined.set(chunk, carry.length);
      bytes = joined;
      carry = null;
    }
    let at = 0;
    while (at < bytes.length) {
      const end = Math.min(bytes.length, at + EPG_PIECE_BYTES);
      const cut = utf8Cut(bytes, end);
      const stop = cut > at ? cut : end;
      reader.push(decoder.decode(bytes.subarray(at, stop)), false);
      // A character split at the end of this chunk waits for the next one.
      if (end === bytes.length && stop < end) { carry = bytes.slice(stop, end); break; }
      at = stop;
    }
  };
  if (raw.length > 1 && raw[0] === 0x1f && raw[1] === 0x8b) {
    const gz = new Gunzip((data) => feed(data));
    for (let at = 0; at < raw.length; at += EPG_PIECE_BYTES) {
      const end = Math.min(raw.length, at + EPG_PIECE_BYTES);
      gz.push(raw.subarray(at, end), end === raw.length);
    }
  } else {
    feed(raw);
  }
  const left: Uint8Array | null = carry;
  reader.push(left ? decoder.decode(left) : "", true);
  return { programs: reader.programs, channelMeta: reader.channelMeta };
}

async function fetchXmltv(url: string): Promise<XmltvParseResult> {
  // Bytes, not text: a .xml.gz guide served without Content-Encoding is binary, and the host's
  // text path decodes as (lossy) UTF-8, which wrecked the gzip header and every guide behind it.
  const res = await fetch(url, {
    headers: { "User-Agent": "VLC/3.0.20 LibVLC/3.0.20", Accept: "application/xml, text/xml, application/octet-stream, */*" },
    harborResponseType: "base64",
  } as RequestInit);
  if (!res.ok) throw new Error(`EPG fetch failed: ${res.status} ${res.statusText}`);
  const bytes = new Uint8Array(await res.arrayBuffer());
  if (bytes.length > EPG_MAX_BYTES) throw new Error("EPG exceeds 200MB limit");
  return parseXmltvBytes(bytes);
}

/**
 * epg-store.ts doFetchWithFallback: each address in turn; one that fails or lists no programmes
 * passes to the next; if none has programmes, the channel list of the last one that had any.
 */
async function fetchEpgWithFallback(urls: string[]): Promise<EpgIndex> {
  if (urls.length === 0) throw new Error("No EPG URL available for this playlist");
  let lastErr: unknown = null;
  let lastMeta: Map<string, EpgChannelMeta> | undefined;
  for (const url of urls) {
    try {
      const { programs, channelMeta } = await fetchXmltv(url);
      if (channelMeta.size > 0) lastMeta = channelMeta;
      if (programs.length === 0) {
        lastErr = new Error("EPG endpoint returned no programs");
        continue;
      }
      return { byChannel: indexProgramsByChannel(programs), channelMeta, fetchedAt: Date.now() };
    } catch (e) {
      lastErr = e;
    }
  }
  if (lastMeta && lastMeta.size > 0) return { byChannel: new Map(), channelMeta: lastMeta, fetchedAt: Date.now() };
  throw lastErr instanceof Error ? lastErr : new Error(String(lastErr));
}

/**
 * use-epg.ts + use-bp-live.ts: the source's own guide (its EPG URL, else the two Xtream
 * addresses deriveEpgUrls builds), then every "Guide data only" source's address.
 */
export function epgUrlsFor(pl: StoredPlaylist): string[] {
  const own = pl.epgUrl ? [pl.epgUrl] : deriveEpgUrls(pl.url);
  const epgOnly = readPlaylists().filter((s) => s.kind === "epg").map((s) => s.epgUrl || s.url);
  return [...new Set([...own, ...epgOnly].filter(Boolean))];
}

/** Loads the playlist's guide (once an hour); returns how many channels it covers. */
export async function loadEpg(playlistId: string, force = false): Promise<{ channels: number; programs: number; url: string | null }> {
  const pl = readPlaylists().find((p) => p.id === playlistId);
  if (!pl) throw new Error("playlist not found");
  const urls = epgUrlsFor(pl);
  if (urls.length === 0) return { channels: 0, programs: 0, url: null };
  const url = urls[0];
  const signature = urls.join("|");
  const held = epgCache.get(playlistId);
  if (held && held.url === signature && !force && Date.now() - held.index.fetchedAt < EPG_TTL_MS) return summarize(held.index, url);
  if (held?.loading && held.url === signature) return summarize(await held.loading, url);
  const loading = fetchEpgWithFallback(urls);
  const previous = held?.index ?? { byChannel: new Map(), fetchedAt: 0 };
  epgCache.set(playlistId, { index: previous, url: signature, loading });
  // A newer load (another address list, or a forced refresh) owns the entry once it starts.
  const mine = () => epgCache.get(playlistId)?.loading === loading;
  try {
    const index = await loading;
    if (mine()) epgCache.set(playlistId, { index, url: signature, loading: null });
    return summarize(index, url);
  } catch (e) {
    if (mine()) epgCache.set(playlistId, { index: previous, url: signature, loading: null });
    throw e;
  }
}

/**
 * views/live/hooks/use-xtream-epg-fallback: an Xtream source with no usable XMLTV answers
 * get_short_epg per visible channel (cap 120), merged into the guide index.
 */
const SHORT_EPG_CAP = 120;
export async function loadShortEpg(playlistId: string, channelIds: string[]): Promise<{ hydrated: number }> {
  const pl = readPlaylists().find((p) => p.id === playlistId);
  if (!pl?.xtream) return { hydrated: 0 };
  const all = loaded.get(playlistId) ?? [];
  const held = epgCache.get(playlistId);
  const base = held?.index ?? null;
  const byId = new Map(all.map((c) => [c.id, c]));
  const subset = channelIds.map((id) => byId.get(id)).filter((c): c is IptvChannel => !!c).slice(0, SHORT_EPG_CAP);
  const before = base ? base.byChannel.size : 0;
  const creds = { base: pl.xtream.server, username: pl.xtream.username, password: pl.xtream.password };
  const next = await hydrateShortEpg(creds, subset, base);
  if (!next || next === base) return { hydrated: 0 };
  epgCache.set(playlistId, { index: next, url: held?.url ?? "", loading: null });
  return { hydrated: next.byChannel.size - before };
}

function summarize(index: EpgIndex, url: string) {
  let programs = 0;
  for (const list of index.byChannel.values()) programs += list.length;
  return { channels: index.byChannel.size, programs, url };
}

function view(p: EpgProgram): ProgramView {
  return { title: p.title, description: p.description, startMs: p.startMs, endMs: p.endMs, category: p.category, iconUrl: p.iconUrl ?? null };
}

// The guide asks per screenful (and the grid per 40 rows): the id map and tvg-id counts over a
// 6,000-channel list are built once per loaded list, not on every ask.
const channelIndexes = new WeakMap<IptvChannel[], { byId: Map<string, IptvChannel>; counts: ReturnType<typeof computeTvgIdCounts> }>();
function channelIndex(all: IptvChannel[]): { byId: Map<string, IptvChannel>; counts: ReturnType<typeof computeTvgIdCounts> } {
  const held = channelIndexes.get(all);
  if (held) return held;
  const built = { byId: new Map(all.map((c) => [c.id, c] as [string, IptvChannel])), counts: computeTvgIdCounts(all) };
  channelIndexes.set(all, built);
  return built;
}

/** Now/next for a screenful of channels (epg-resolver matching, tvg-shift + offset applied). */
export function nowNext(playlistId: string, channelIds: string[], nowMs = Date.now()): NowNext[] {
  const all = loaded.get(playlistId) ?? [];
  const epg = epgCache.get(playlistId)?.index ?? null;
  const { byId, counts } = channelIndex(all);
  const offset = epgOffsetHoursPref();
  return channelIds.map((id) => {
    const ch = byId.get(id);
    const programs = ch && epg && epg.byChannel.size > 0 ? epgProgramsForChannel(ch, epg, counts, offset) : undefined;
    if (!programs || programs.length === 0) return { id, now: null, next: null, known: false };
    const { current, next } = findCurrent(programs, nowMs);
    return { id, now: current ? view(current) : null, next: next ? view(next) : null, known: true };
  });
}

export type LaneCell = { startMs: number; endMs: number; program: ProgramView | null };

const SLOT_MS = 30 * 60_000;
const MIN_GAP_MS = 1000;

// use-bp-guide-data.ts buildLane/closeGap (not exported upstream): a lane is contiguous and
// gapless across the window, empty stretches sliced on half-hour boundaries.
function closeGap(out: LaneCell[], from: number, to: number): void {
  if (to <= from) return;
  if (to - from < MIN_GAP_MS && out.length > 0) { out[out.length - 1].endMs = to; return; }
  let cur = from;
  while (cur < to) {
    const next = Math.min(to, Math.floor(cur / SLOT_MS) * SLOT_MS + SLOT_MS);
    out.push({ startMs: cur, endMs: next, program: null });
    cur = next;
  }
}

function buildLane(programs: readonly EpgProgram[], windowStart: number, windowEnd: number): LaneCell[] {
  const inWindow = programs.filter((p) => p.endMs > windowStart && p.startMs < windowEnd).sort((a, b) => a.startMs - b.startMs);
  const out: LaneCell[] = [];
  let cursor = windowStart;
  for (const program of inWindow) {
    const endMs = Math.min(program.endMs, windowEnd);
    if (endMs <= cursor) continue;
    const startMs = Math.max(program.startMs, cursor);
    closeGap(out, cursor, startMs);
    out.push({ startMs, endMs, program: view(program) });
    cursor = endMs;
  }
  closeGap(out, cursor, windowEnd);
  return out;
}

/** Guide lanes for a screenful of channels: gapless cells over [windowStart, windowEnd). */
export function lanes(playlistId: string, channelIds: string[], windowStart: number, windowEnd: number): Array<{ id: string; catchup: boolean; cells: LaneCell[] }> {
  const all = loaded.get(playlistId) ?? [];
  const epg = epgCache.get(playlistId)?.index ?? null;
  const { byId, counts } = channelIndex(all);
  const offset = epgOffsetHoursPref();
  return channelIds.map((id) => {
    const ch = byId.get(id);
    const programs = ch && epg && epg.byChannel.size > 0 ? epgProgramsForChannel(ch, epg, counts, offset) ?? [] : [];
    return { id, catchup: !!ch && channelHasCatchup(ch), cells: buildLane(programs, windowStart, windowEnd) };
  });
}

/**
 * Replay URL for a past programme (lib/iptv/catchup.ts: flussonic / xtream timeshift /
 * append / shift / catchup-source templates), or null when the channel offers none. Desktop's
 * guide does this (use-live-actions.ts handlePlayCatchup); Big Picture never wired it.
 */
export function catchupUrl(playlistId: string, channelId: string, startMs: number, endMs: number): { url: string; headers: Record<string, string> | null } | null {
  const ch = (loaded.get(playlistId) ?? []).find((c) => c.id === channelId);
  if (!ch) return null;
  const url = buildCatchupUrl(ch, startMs, endMs);
  return url ? { url, headers: headersFromChannel(ch) ?? null } : null;
}

/** One channel's programmes inside a window (the guide lane / "what's on later"). */
export function schedule(playlistId: string, channelId: string, fromMs: number, toMs: number): ProgramView[] {
  const all = loaded.get(playlistId) ?? [];
  const epg = epgCache.get(playlistId)?.index ?? null;
  const ch = all.find((c) => c.id === channelId);
  if (!ch || !epg) return [];
  const programs = epgProgramsForChannel(ch, epg, computeTvgIdCounts(all), epgOffsetHoursPref()) ?? [];
  return programs.filter((p) => p.endMs > fromMs && p.startMs < toMs).map(view);
}

// ------------------------------------------------------------------ manual EPG matching
// views/live/guide/epg-match-modal.tsx: when a channel's tvg-id is wrong the viewer picks the
// guide channel by hand; lib/iptv/epg-map.ts stores it and epg-resolver.ts honours it first, so
// nowNext, lanes, schedule and the Home row all follow the match.
export type EpgMatchEntry = { id: string; sample: string };
export type EpgMatchList = { channelId: string; channelName: string; query: string; total: number; current: string | null; entries: EpgMatchEntry[] };

const EPG_MATCH_CAP = 120;
const matchEntriesCache = new WeakMap<EpgIndex, EpgMatchEntry[]>();

function matchEntries(epg: EpgIndex): EpgMatchEntry[] {
  const cached = matchEntriesCache.get(epg);
  if (cached) return cached;
  const out: EpgMatchEntry[] = [];
  for (const [id, programs] of epg.byChannel) out.push({ id, sample: programs[0]?.title ?? "" });
  out.sort((a, b) => a.id.localeCompare(b.id));
  matchEntriesCache.set(epg, out);
  return out;
}

/**
 * The guide channels a playlist channel can be matched to, filtered like the modal: any query
 * word found in "<tvg id> <first programme title>", 120 at most. A null query starts from the
 * channel's own name (the modal's initial search).
 */
export function epgCandidates(playlistId: string, channelId: string, query?: string | null): EpgMatchList {
  const ch = (loaded.get(playlistId) ?? []).find((c) => c.id === channelId);
  const epg = epgCache.get(playlistId)?.index ?? null;
  const q = query ?? ch?.name ?? "";
  const entries = epg ? matchEntries(epg) : [];
  const tokens = q.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const visible = (tokens.length === 0 ? entries : entries.filter((e) => {
    const hay = `${e.id} ${e.sample}`.toLowerCase();
    return tokens.some((t) => hay.includes(t));
  })).slice(0, EPG_MATCH_CAP);
  return { channelId, channelName: ch?.name ?? "", query: q, total: entries.length, current: getEpgOverride(channelId), entries: visible };
}

/** epg-match-modal assign: a guide channel id, or null to clear the match. Returns the match now in force. */
export function setEpgMatch(channelId: string, tvgId?: string | null): string | null {
  setEpgOverride(channelId, tvgId || null);
  return getEpgOverride(channelId);
}


// ------------------------------------------------------------------------- Home live row
// bp-live-row + bp-live-rank: the active playlist's best sixteen channels right now (favourites
// first, junk names penalised, most-watched and network channels boosted), with now/next.
export type HomeLiveCell = { playlistId: string; channel: LiveChannel; now: ProgramView | null; next: ProgramView | null; progress: number | null };

export async function homeRow(): Promise<{ playlistId: string | null; cells: HomeLiveCell[] }> {
  // use-bp-live.ts sources: a "Guide data only" entry has no channels (it feeds the guide).
  const lists = channelSources();
  if (lists.length === 0) return { playlistId: null, cells: [] };
  const activeId = readActiveSource();
  const pl = lists.find((p) => p.id === activeId) ?? lists[0];
  if (!loaded.has(pl.id)) await Promise.race([channels(pl.id).catch(() => undefined), new Promise((r) => setTimeout(r, 12000))]);
  const all = loaded.get(pl.id) ?? [];
  if (all.length === 0) return { playlistId: pl.id, cells: [] };
  if (!epgCache.has(pl.id)) await Promise.race([loadEpg(pl.id).catch(() => undefined), new Promise((r) => setTimeout(r, 8000))]);
  const epg = epgCache.get(pl.id)?.index ?? null;
  const favs = readFavorites();
  const region = String(loadStoredSettings().region ?? "US");
  const tvgCounts = computeTvgIdCounts(all);
  const ranked = rankBpLive({ channels: all, guide: [], epg: epg && epg.byChannel.size > 0 ? epg : null, tvgCounts, nowMs: Date.now(), region, favoriteIds: new Set(favs.keys()) });
  return {
    playlistId: pl.id,
    cells: ranked.map((it) => ({ playlistId: pl.id, channel: toView(it.channel, favs), now: it.current ? view(it.current) : null, next: it.next ? view(it.next) : null, progress: it.progress })),
  };
}

// ---------------------------------------------------------------------------- Multiview
// lib/multiview/store.ts: the layout is remembered (harbor.multiview.layout, default "2x2"), the
// slots are not (the view resets them when it closes). store.ts imports React and bridge.ts
// Tauri, so the pure parts are reproduced here. The info banner's dismissal is multiview.tsx's
// harbor.multiview.banner-dismissed. The split positions are desktop drag handles and stay out.
export type MultiviewLayout = "1" | "2" | "2v" | "3" | "2x2";
const MV_LAYOUT_KEY = "harbor.multiview.layout";
const MV_BANNER_KEY = "harbor.multiview.banner-dismissed";
/** bridge.ts MAX_SLOTS. */
export const MULTIVIEW_MAX_SLOTS = 4;

function isLayout(v: unknown): v is MultiviewLayout {
  return v === "1" || v === "2" || v === "2v" || v === "3" || v === "2x2";
}

/** store.ts layoutSlotCount. */
export function layoutSlotCount(l: MultiviewLayout): number {
  if (l === "1") return 1;
  if (l === "2" || l === "2v") return 2;
  if (l === "3") return 3;
  return 4;
}

export function multiviewPrefs(): { layout: MultiviewLayout; slotCount: number; maxSlots: number; bannerDismissed: boolean } {
  let layout: MultiviewLayout = "2x2";
  let dismissed = false;
  try {
    const v = localStorage.getItem(MV_LAYOUT_KEY);
    if (isLayout(v)) layout = v;
    dismissed = localStorage.getItem(MV_BANNER_KEY) === "1";
  } catch { /* defaults */ }
  return { layout, slotCount: layoutSlotCount(layout), maxSlots: MULTIVIEW_MAX_SLOTS, bannerDismissed: dismissed };
}

/** store.ts setLayout: an unknown value keeps the current layout. */
export function setMultiviewLayout(layout: string): { layout: MultiviewLayout; slotCount: number } {
  if (isLayout(layout)) {
    try { localStorage.setItem(MV_LAYOUT_KEY, layout); } catch { /* ignore */ }
  }
  const now = multiviewPrefs().layout;
  return { layout: now, slotCount: layoutSlotCount(now) };
}

/** multiview.tsx dismissBanner. */
export function dismissMultiviewBanner(): boolean {
  try { localStorage.setItem(MV_BANNER_KEY, "1"); } catch { /* ignore */ }
  return true;
}
