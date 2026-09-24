// Manga room (Stage 13): views/manga.tsx, manga-detail.tsx and manga-reader.tsx without React.
// Sources, caching, chapters, pages and reading progress are upstream's own modules
// (lib/manga/*, lib/manga-progress.ts); this file only lifts the logic the React views and
// hooks hold (resume, chapter complete, favourites toggle, reader order) into plain calls.
//
// tvOS has no Worker, IndexedDB or DOMParser, so upstream's sandboxed source plugins, Mangayomi
// sources and HTML-scraper sources cannot run here: the TV reads from Suwayomi servers (the
// "connect a self-hosted server you run" path), which are plain HTTP through the engine's fetch.
import { activeMangaSourceId, hasAnyMangaSource, listMangaSources, setActiveMangaSource, sourceIconUrl } from "@/lib/manga/sources";
import {
  chapterLanguages,
  chapterPages,
  mangaDetail,
  mangaTags,
  popularManga,
  resumeChapters,
  searchManga,
  searchMangaEverywhere,
  setMangaInLibrary,
  streamChapters,
  type MangaChapter,
  type MangaSummary,
} from "@/lib/manga/api";
import {
  listMangaProgress,
  listReadMangaChapters,
  recordMangaChapterRead,
  recordMangaProgress,
  removeMangaProgressEntry,
  resumePageForChapter,
  type MangaProgressEntry,
} from "@/lib/manga-progress";
import { clearMangaReading, setMangaReading } from "@/lib/manga-reading-state";
import { chapterGroupKey, chapterNumberKey, resolveReaderChapters } from "@/lib/manga/chapter-identity";
import { pageHeadersFor } from "@/lib/manga/plugins/adapter";
import { decodeMangaId, makeServer } from "@/lib/manga/sources/suwayomi/model";
import { suwayomiAuthFor, suwayomiBaseForSource } from "@/lib/manga/sources/suwayomi/auth-registry";
import { reconcileSuwayomiServers } from "@/lib/manga/sources/suwayomi/server-link";
import { flushSuwayomiProgress } from "@/lib/manga/sources/suwayomi/progress-bridge";
import { loadSources, pickTransport } from "@/lib/manga/sources/suwayomi/transport";
import { makeClient } from "@/lib/manga/sources/suwayomi/model";
import { notifyMangaLibraryChanged } from "@/lib/manga/library-events";
import { resolveMangaIdByTitle } from "@/lib/search-manga-resolve";
import { isAgnosticLang } from "@/lib/manga/lang-filter";
import { cachedSuwayomiSources } from "@/views/manga/manga-browse/langs";
import { resolveAnimeSourceReading } from "@/lib/manga/anime-adaptation";
import { persistCritical } from "@/lib/storage-recovery";
import { addServer as upstreamAddServer, listServers, removeServer as upstreamRemoveServer } from "@/views/manga/manga-sources-panel/suwayomi/servers-store";
import { DEFAULT_PREFS, loadPrefs, PREFS_KEY } from "@/views/manga/manga-reader/reader-prefs";
import type { ReaderPrefs } from "@/views/manga/manga-reader/reader-types";

type MangaMeta = { id: string; title: string; cover?: string };

// ------------------------------------------------------------------------------ sources

let inited = false;
/**
 * views/manga.tsx initMangaSource(), minus the plugin, Mangayomi and repo loaders (IndexedDB +
 * Worker, unavailable in JavaScriptCore) and the legacy community-catalog migration (a TV
 * install never had that data). Servers saved by the sources panel are linked as sources.
 */
function ensureInit(): void {
  if (inited) return;
  inited = true;
  try {
    reconcileSuwayomiServers();
  } catch {
    /* a malformed stored list leaves the TV with no sources, which the room explains */
  }
}

function hostOf(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
}

/** Authorization headers per server base, so the TV's image loader can fetch covers and pages. */
function imageAuth(): Array<{ base: string; header: string }> {
  const out: Array<{ base: string; header: string }> = [];
  for (const s of listMangaSources()) {
    if (s.kind !== "suwayomi" || !s.baseUrl) continue;
    const server = makeServer(s.baseUrl);
    if (server.authHeader) out.push({ base: server.base, header: server.authHeader });
  }
  return out;
}

/** What the room needs to draw its shell: sources, the active one, servers and image auth. */
export function state() {
  ensureInit();
  return {
    hasSource: hasAnyMangaSource(),
    activeId: activeMangaSourceId(),
    // Credential-free: a base URL can carry user:pass, which never goes to the UI.
    sources: listMangaSources().map((s) => ({ id: s.id, name: s.name, kind: s.kind ?? null, host: s.baseUrl ? hostOf(s.baseUrl) : "", iconUrl: sourceIconUrl(s) ?? null })),
    servers: listServers().map((s) => ({ id: s.id, name: s.name, host: hostOf(s.baseUrl), hasAuth: !!s.auth })),
    auth: imageAuth(),
  };
}

/** suwayomi/server-form.tsx submit: servers-store addServer, which links and activates the source. */
export function addServer(name: string, baseUrl: string, username: string | null, password: string | null) {
  ensureInit();
  const user = (username ?? "").trim();
  const auth = user || password ? { username: user, password: password ?? "" } : undefined;
  const server = upstreamAddServer(name ?? "", baseUrl ?? "", auth);
  return server ? { ok: true, id: server.id } : { ok: false, id: null };
}

/** Checks a server the way the sources panel does before trusting it: the source list answers. */
export async function testServer(baseUrl: string, username: string | null, password: string | null) {
  const user = (username ?? "").trim();
  const server = makeServer(baseUrl, user ? `${user}:${password ?? ""}` : undefined);
  const client = makeClient(server);
  try {
    const t = await pickTransport(client);
    const sources = await loadSources(client, t);
    return { ok: sources.length > 0, sources: sources.length };
  } catch {
    return { ok: false, sources: 0 };
  }
}

export function removeServer(id: string) {
  upstreamRemoveServer(id);
  return state();
}

export function setActive(id: string) {
  setActiveMangaSource(id);
  return state();
}

// ------------------------------------------------------------------------------ browse

export function popular(offset: number, tagId: string | null): Promise<MangaSummary[]> {
  ensureInit();
  return popularManga(offset ?? 0, tagId || undefined);
}

/** manga-browse.tsx fetchPage: a query or a tag searches, otherwise popular. */
export function search(query: string, offset: number, tagId: string | null): Promise<MangaSummary[]> {
  ensureInit();
  const q = (query ?? "").trim();
  return q || tagId ? searchManga(q, offset ?? 0, tagId || undefined) : popularManga(offset ?? 0, undefined);
}

/** manga-browse extensionsSearchMode: a query with no source picked asks every extension. */
export function searchEverywhere(query: string): Promise<MangaSummary[]> {
  ensureInit();
  return searchMangaEverywhere((query ?? "").trim());
}

export function tags() {
  ensureInit();
  return mangaTags().catch(() => []);
}

// ------------------------------------------------------------------------------ detail

/** manga-detail.tsx load: the summary, every chapter chunk, the language list and default. */
export async function detail(mangaId: string) {
  ensureInit();
  const [summary, chapters] = await Promise.all([
    mangaDetail(mangaId).catch(() => null),
    (async () => {
      const all: MangaChapter[] = [];
      await streamChapters(mangaId, (chunk) => {
        all.push(...chunk);
      }).catch(() => {});
      return all;
    })(),
  ]);
  const langs = chapterLanguages(chapters);
  // manga-detail: English when present, else the first language of the first chunk.
  const defaultLang = langs.find((l) => l.code === "en")?.code ?? langs[0]?.code ?? "en";
  return { detail: summary, chapters, langs, defaultLang, extName: await extensionName(mangaId) };
}

/** manga-detail extInfo: the Suwayomi extension a title comes from, named as all-extensions.tsx
 *  sourceDisplayName does ("Name · All languages", "Name (FR)", or the bare name for English). */
async function extensionName(mangaId: string): Promise<string | null> {
  const parsed = decodeMangaId(mangaId);
  if (!parsed) return null;
  const base = suwayomiBaseForSource(parsed.sourceId);
  if (!base) return null;
  const list = await cachedSuwayomiSources({ baseUrl: base }).catch(() => []);
  const source = list.find((s) => s.id === parsed.sourceId);
  if (!source) return null;
  if (isAgnosticLang(source.lang)) return `${source.name} · All languages`;
  return source.lang && source.lang !== "en" ? `${source.name} (${source.lang.toUpperCase()})` : source.name;
}

/** manga-reader.tsx chapterLabel. */
export function chapterLabel(c: MangaChapter): string {
  if (c.chapter) return `Chapter ${c.chapter}`;
  return c.title || "Oneshot";
}

/** A reading-progress entry for one title (use-manga-progress useMangaProgressEntry). */
export function progressFor(pid: string, id: string, title: string | null): MangaProgressEntry | null {
  const items = listMangaProgress(pid);
  const byId = items.find((e) => e.id === id);
  if (byId) return byId;
  const norm = (t: string) => t.toLowerCase().replace(/[^a-z0-9]+/g, "");
  const key = title ? norm(title) : "";
  return key ? (items.find((e) => norm(e.title) === key) ?? null) : null;
}

/** manga-detail handleResume (and manga.tsx resume): the entry's chapter in a list, or -1. */
export function matchChapter(entry: MangaProgressEntry, pool: MangaChapter[]): number {
  let i = pool.findIndex((c) => c.id === entry.chapterId);
  if (i < 0) {
    const want = chapterNumberKey(entry.chapterNumber) ?? chapterNumberKey(entry.chapterLabel);
    if (want != null) i = pool.findIndex((c) => chapterNumberKey(c.chapter ?? c.title ?? "") === want);
  }
  if (i < 0 && entry.chapterNumber != null) {
    i = pool.findIndex((c) => c.chapter != null && c.chapter === entry.chapterNumber);
  }
  return i;
}

/**
 * views/manga.tsx resume(): switch to the entry's source, fetch the owning copy's chapters and
 * open the reader on the saved chapter (or the first when the chapter is gone). null sends the
 * viewer to the detail page instead.
 */
export async function resume(entry: MangaProgressEntry) {
  ensureInit();
  const target = entry.sourceId || activeMangaSourceId();
  if (target && activeMangaSourceId() !== target) setActiveMangaSource(target);
  try {
    const chs = await resumeChapters(entry.id);
    const i = matchChapter(entry, chs);
    if (i >= 0 || chs.length > 0) {
      return {
        manga: { id: entry.id, title: entry.title, cover: entry.cover },
        chapters: chs,
        index: i >= 0 ? i : 0,
        startPage: Math.max(0, entry.page - 1),
      };
    }
  } catch {
    /* noop */
  }
  return null;
}

/** views/manga.tsx openMangaByTitle: exact title, then a punctuation-free retry, then progress. */
export async function openByTitle(title: string, pid: string): Promise<string | null> {
  ensureInit();
  const norm = (s: string) => s.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "");
  const key = norm(title);
  const pick = (hits: MangaSummary[]) =>
    hits.find((h) => norm(h.title) === key || (h.altTitle != null && norm(h.altTitle) === key)) ?? hits[0] ?? null;
  try {
    const hit = pick(await searchManga(title, 0));
    if (hit) return hit.id;
    const alt = title.replace(/[^\p{L}\p{N}]+/gu, " ").trim();
    if (alt && alt !== title) {
      const hit2 = pick(await searchManga(alt, 0));
      if (hit2) return hit2.id;
    }
  } catch {
    /* fall through to reading progress */
  }
  return listMangaProgress(pid).find((e) => norm(e.title) === key)?.id ?? null;
}

/** search-manga-resolve: a franchise (AniList) manga opened by title through every extension. */
export async function resolveTitle(title: string): Promise<string | null> {
  ensureInit();
  return (await resolveMangaIdByTitle(title).catch(() => undefined)) ?? null;
}

/** bp-hero-manga / hero-manga-adaptation open(): the first source hit for the AniList title. */
export async function firstByTitle(title: string): Promise<string | null> {
  ensureInit();
  const found = (await searchManga(title, 0).catch(() => [] as MangaSummary[]))[0];
  return found?.id ?? null;
}

/** hero-manga-adaptation: the manga (or light novel) an anime adapts, from AniList relations. */
export async function animeSource(id: string, name: string) {
  const src = await resolveAnimeSourceReading(id, null, name ?? "").catch(() => null);
  if (!src) return null;
  return { kind: src.kind, title: src.node.title, poster: src.node.poster ?? null, anilistId: src.node.anilistId };
}

// ------------------------------------------------------------------------------ reader

/** Page URLs for a chapter, each with the headers its host needs (plugins/adapter pageHeadersFor). */
export async function pages(chapterId: string) {
  ensureInit();
  const urls = await chapterPages(chapterId);
  return urls.map((url) => {
    const h = pageHeadersFor(url);
    if (h) return { url, headers: h };
    const auth = suwayomiAuthFor(url);
    return auth ? { url, headers: { authorization: auth } } : { url };
  });
}

/**
 * manga-reader.tsx: the reader collapses provider copies itself and walks one representative per
 * chapter group; the scanlator group picked when it opened is kept for the session. Returns the
 * reading order (indices into `chapters`) and every chapter's group key so the TV can find its
 * position after an index change without another call.
 */
export function readerOrder(chapters: MangaChapter[], index: number) {
  const pickedGroup = index >= 0 && index < chapters.length ? (chapters[index]?.group ?? undefined) : undefined;
  const collapsed = resolveReaderChapters(chapters, { group: pickedGroup });
  const idToIdx = new Map(chapters.map((c, i) => [c.id, i]));
  const order = collapsed.map((c) => idToIdx.get(c.id)).filter((i): i is number => i != null);
  return { order, keys: chapters.map((c) => chapterGroupKey(c)) };
}

/**
 * manga-reader.tsx page load: where a chapter opens. Local progress and the server's own
 * lastPageRead (when the chapter is not already read there), the later wins; an explicit start
 * page (resume) is a floor. null opens at the top.
 */
export function startPage(pid: string, manga: MangaMeta, chapter: MangaChapter, requested: number | null): number | null {
  const localResume = resumePageForChapter(pid, manga.id, manga.title, chapter.id, chapter.chapter) ?? null;
  const serverResume =
    typeof chapter.serverPage === "number" && chapter.serverPage > 0 && !chapter.serverRead ? chapter.serverPage : null;
  const synced = serverResume != null && (localResume == null || serverResume > localResume) ? serverResume : localResume;
  if (requested != null && synced != null) return Math.max(requested, synced);
  return requested ?? synced;
}

/** use-reader-progress: the page the viewer is on (1-based), saved and shown as "now reading". */
export function recordPage(pid: string, manga: MangaMeta, chapter: MangaChapter, page: number, total: number, scroll: number | null) {
  if (!manga.title || total <= 0) return false;
  const p = Math.min(Math.max(1, page), total);
  setMangaReading({ mangaId: manga.id, title: manga.title, cover: manga.cover, chapter: chapter.chapter, chapterLabel: chapterLabel(chapter), page: p, totalPages: total });
  recordMangaProgress(pid, {
    id: manga.id,
    title: manga.title,
    cover: manga.cover,
    sourceId: activeMangaSourceId(),
    chapterId: chapter.id,
    chapterNumber: chapter.chapter,
    chapterLabel: chapterLabel(chapter),
    page: p,
    totalPages: total,
    scroll: scroll ?? undefined,
    updatedAt: Date.now(),
  });
  return true;
}

/**
 * manga-reader.tsx markChapterComplete: the chapter is saved as completed and read, and the next
 * chapter becomes the "up next" entry Continue Reading resumes into.
 */
export function markComplete(pid: string, manga: MangaMeta, chapters: MangaChapter[], index: number, nextIndex: number | null, total: number) {
  const chapter = chapters[index];
  if (!chapter || !manga.title) return false;
  recordMangaProgress(pid, {
    id: manga.id,
    title: manga.title,
    cover: manga.cover,
    sourceId: activeMangaSourceId(),
    chapterId: chapter.id,
    chapterNumber: chapter.chapter,
    chapterLabel: chapterLabel(chapter),
    page: total,
    totalPages: total,
    completed: true,
    updatedAt: Date.now(),
  });
  recordMangaChapterRead(pid, manga.id, chapter.id);
  if (nextIndex == null) return true;
  const n = chapters[nextIndex];
  if (!n) return true;
  const existing = listMangaProgress(pid).find((e) => e.id === manga.id);
  if (existing?.upNext && existing.chapterId === n.id) return true;
  recordMangaProgress(pid, {
    id: manga.id,
    title: manga.title,
    cover: manga.cover,
    sourceId: activeMangaSourceId(),
    chapterId: n.id,
    chapterNumber: n.chapter,
    chapterLabel: chapterLabel(n),
    page: 0,
    totalPages: 0,
    upNext: true,
    updatedAt: Date.now(),
  });
  return true;
}

/** The reader closed: clear "now reading" and push any queued server progress straight away. */
export function closeReader() {
  clearMangaReading();
  flushSuwayomiProgress();
  return true;
}

/** reader-prefs.ts loadPrefs (the same key, so every other field upstream keeps survives). */
export function prefs(): ReaderPrefs {
  return loadPrefs(PREFS_KEY);
}

/** manga-reader patchPrefs / zoomBy: merge, clamp the zoom (0.5-3, book 1-3), persist. */
export function savePrefs(patch: Partial<ReaderPrefs>): ReaderPrefs {
  const next = { ...DEFAULT_PREFS, ...loadPrefs(PREFS_KEY), ...patch };
  const lo = next.mode === "book" ? 1 : 0.5;
  next.zoom = Math.max(lo, Math.min(3, Math.round((Number(next.zoom) || 1) * 100) / 100));
  try {
    localStorage.setItem(PREFS_KEY, JSON.stringify(next));
  } catch {
    /* noop */
  }
  return next;
}

// ------------------------------------------------------------------------------ progress

export function progress(pid: string): MangaProgressEntry[] {
  return listMangaProgress(pid);
}

export function removeProgress(pid: string, id: string) {
  removeMangaProgressEntry(pid, id);
  return listMangaProgress(pid);
}

export function readChapters(pid: string, mangaId: string): string[] {
  return listReadMangaChapters(pid, mangaId);
}

// ------------------------------------------------------------------------------ favourites
// lib/manga-favorites.tsx: the provider's map, key and Suwayomi library sync, without React.

export type MangaFavEntry = { id: string; title: string; cover?: string; addedAt: number };

const FAV_PREFIX = "harbor.mangafav.v1.";
const librarySync = new Map<string, Promise<void>>();

function syncLibrary(id: string, inLibrary: boolean): void {
  const pending = librarySync.get(id) ?? Promise.resolve();
  const next = pending
    .catch(() => {})
    .then(async () => {
      await setMangaInLibrary(id, inLibrary);
      notifyMangaLibraryChanged();
    });
  librarySync.set(id, next);
  void next
    .catch((error) => console.warn("[manga-favorites] Suwayomi library sync failed", error))
    .finally(() => {
      if (librarySync.get(id) === next) librarySync.delete(id);
    });
}

function readFavs(pid: string): Map<string, MangaFavEntry> {
  const map = new Map<string, MangaFavEntry>();
  try {
    const raw = localStorage.getItem(FAV_PREFIX + pid);
    if (!raw) return map;
    const arr = JSON.parse(raw);
    if (!Array.isArray(arr)) return map;
    for (const el of arr) {
      if (el && typeof el.id === "string") {
        map.set(el.id, {
          id: el.id,
          title: typeof el.title === "string" ? el.title : "",
          cover: typeof el.cover === "string" ? el.cover : undefined,
          addedAt: typeof el.addedAt === "number" ? el.addedAt : 0,
        });
      }
    }
  } catch {
    return new Map();
  }
  return map;
}

/** Newest first (views/manga.tsx LibraryCta order). */
export function favorites(pid: string): MangaFavEntry[] {
  return [...readFavs(pid).values()].sort((a, b) => b.addedAt - a.addedAt);
}

export function isFavorite(pid: string, id: string): boolean {
  return readFavs(pid).has(id);
}

/** MangaFavoritesProvider toggle: returns whether the title is a favourite afterwards. */
export function toggleFavorite(pid: string, input: { id: string; title?: string; cover?: string }): boolean {
  ensureInit();
  const next = readFavs(pid);
  let on: boolean;
  if (next.has(input.id)) {
    next.delete(input.id);
    syncLibrary(input.id, false);
    on = false;
  } else {
    next.set(input.id, { id: input.id, title: input.title ?? "", cover: input.cover, addedAt: Date.now() });
    syncLibrary(input.id, true);
    on = true;
  }
  persistCritical(FAV_PREFIX + pid, JSON.stringify([...next.values()]));
  return on;
}
