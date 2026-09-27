// eBook room (Stage 13): views/ebook.tsx, ebook-sources-panel.tsx and ebook/harbor-reader.tsx
// without React. Sources, catalog paging, metadata, the shelf, favourites, reading position,
// bookmarks and reader prefs are upstream's own modules (lib/ebook/*); this file only lifts the
// logic the React views hold (source resolution, "more by", recommendations, the position save)
// into plain calls.
//
// What tvOS cannot run (docs/ebook-spec.md): local folders (Tauri fs), HTML-scraper sources
// (DOMParser), extensions (Worker + IndexedDB) and upstream's EPUB reader (DOMParser +
// DecompressionStream). The TV reads Project Gutenberg through upstream's Gutendex source; the
// EPUB itself is downloaded, unzipped and parsed natively (App/Sources/EBook/EPUBBook.swift), and
// the chapter ids, text cleaning, paragraphs and progress keys stay upstream's (below).
import {
  listEBookProviders,
  loadSourceEBookPage,
  searchSourceEBookCatalog,
  sourceEBookDetail,
  type EBookChapter,
  type EBookCursor,
} from "@/lib/ebook/providers";
import { addEBookGutendex, hasEBookGutendex, listEBookSources, removeEBookSource } from "@/lib/ebook/sources";
import { gutendexDetail } from "@/lib/ebook/gutendex";
import {
  dedupeEBooks,
  eBooksMatch,
  ebookDetail,
  EBOOK_CATEGORIES,
  mergeEBookMetadata,
  searchEBooks,
  type EBook,
  type EBookCategoryGroup,
} from "@/lib/ebook/api";
import {
  applyEBookBrowseFilters,
  EBOOK_FILTER_GENRES,
  ebookMatchesGenre,
  type EBookBrowseLanguage,
  type EBookBrowseSort,
  type EBookBrowseStatus,
} from "@/lib/ebook/browse-filters";
import {
  buildSourceEBookCollections,
  eBookCollectionCacheScope,
  markSourceEBookAwardsResolved,
  readSourceEBookCollections,
  sourceEBookAwardsAreFresh,
  streamSourceEBookAwardMatches,
  writeSourceEBookCollections,
  type EBookSourceCollection,
} from "@/lib/ebook/collections";
import { NYT_ATTRIBUTION, NYT_PRIMARY_LIST, loadNytBestsellers, nytList, readNytSnapshot } from "@/lib/ebook/nyt";
import { nytRailItems, nytRankFor as nytRankInList } from "@/lib/ebook/nyt-rail";
import { nytBestsellerFor } from "@/lib/ebook/nyt-match";
import { resolveNytBooks } from "@/lib/ebook/nyt-availability";
import {
  ebookInLibrary,
  ebookIsFavorite,
  ebookLibrary,
  favoriteEBooks,
  toggleEBookFavorite,
  toggleEBookLibrary,
} from "@/lib/ebook/library";
import {
  addEBookBookmark,
  loadEBookBookmarks,
  loadEBookProgress,
  loadEBookReaderPrefs,
  loadEBookResume,
  removeEBookBookmark,
  saveEBookProgress,
  saveEBookReaderPrefs,
  saveEBookResume,
  type EBookReaderPrefs,
  type EBookResume,
} from "@/lib/ebook/reader-state";
import { ebookParagraphs, ebookTextIdentity } from "@/lib/ebook/chapter-locations";
import {
  fetchEBookListCollection,
  flushPendingEBookTracking,
  getEBookTracking,
  saveEBookTracking,
} from "@/lib/ebook/tracking";
import { booksBySameAuthor } from "@/lib/ebook/universes";
// AniList list tracking (lib/ebook/tracking.ts) reuses the session engine/trackers.ts signs in
// (anilist.status/authorizeUrl/complete): there is no separate eBook sign-in, upstream or here.
import * as anilistSession from "@/lib/anilist/session";

// ------------------------------------------------------------------------------ sources

function routeParts(id: string): { providerId: string; itemId: string } | null {
  // providers.ts routeParts (not exported): `source:<providerId>:<itemId>`, both URI-encoded.
  if (!id.startsWith("source:")) return null;
  const rest = id.slice(7);
  const split = rest.indexOf(":");
  if (split < 1) return null;
  try {
    return { providerId: decodeURIComponent(rest.slice(0, split)), itemId: decodeURIComponent(rest.slice(split + 1)) };
  } catch {
    return null;
  }
}

/** What the room draws its shell from: the providers (with "All Sources" when several) and the
 *  stored sources, marked readable when the TV can open their books. */
export async function state() {
  const providers = await listEBookProviders().catch(() => []);
  return {
    providers: providers.map((p) => ({ id: p.id, name: p.name })),
    sources: listEBookSources().map((s) => ({ id: s.id, name: s.name, kind: s.kind, readable: s.kind === "gutendex" })),
    hasGutendex: hasEBookGutendex(),
  };
}

/** ebook-sources-panel GutenbergQuickAdd. */
export function addGutendex() {
  addEBookGutendex();
  return state();
}

export function removeSource(id: string) {
  removeEBookSource(id);
  return state();
}

// ------------------------------------------------------------------------------ catalog

/** views/ebook.tsx updateSourceItems: flatten, keep (or replace) by id, collapse duplicates. */
export function merge(current: EBook[] | null, incoming: EBook[], replace: boolean): EBook[] {
  const byId = new Map<string, EBook>();
  for (const ebook of [...(current ?? []), ...(incoming ?? [])].flatMap((item) => item.books ?? [item])) {
    if (!replace && byId.has(ebook.id)) continue;
    byId.set(ebook.id, ebook);
  }
  return dedupeEBooks([...byId.values()]);
}

// page.enriched promises by token, so a second call can wait for the metadata pass.
const enrichments = new Map<number, Promise<EBook[]>>();
let enrichSeq = 0;

/**
 * views/ebook.tsx loadSources / search / loadMore: one page from the selected provider ("all" or
 * one id), a query searching instead of browsing. Returns the merged list, how many ids were new
 * (loadMore's stale-page streak), the next cursor and a token whose metadata pass `enriched` awaits.
 */
export async function page(
  query: string | null,
  providerId: string | null,
  cursor: EBookCursor | null,
  tagId: string | null,
  current: EBook[] | null,
) {
  const term = (query ?? "").trim();
  const result = await loadSourceEBookPage(term.length >= 2 ? term : undefined, providerId || undefined, cursor ?? {}, undefined, tagId || undefined);
  const known = new Set((current ?? []).flatMap((ebook) => ebook.books ?? [ebook]).map((ebook) => ebook.id));
  const fresh = result.items.filter((ebook) => !known.has(ebook.id)).length;
  const token = ++enrichSeq;
  enrichments.set(token, result.enriched);
  result.enriched.catch(() => {});
  while (enrichments.size > 8) enrichments.delete(enrichments.keys().next().value!);
  // onSource / loadMore show the bare page as mergeEBookMetadata(items, []) does (series grouped,
  // a localized title picked) until the metadata pass lands.
  return { items: merge(current, mergeEBookMetadata(result.items, []), false), fresh, cursor: result.cursor, hasMore: result.hasMore, token };
}

/** page.enriched: the page again with book metadata (covers, authors, descriptions). The room
 *  folds it into whatever list it holds by then with merge(current, items, true), as the view's
 *  functional state updates do. */
export async function enriched(token: number): Promise<EBook[] | null> {
  const pending = enrichments.get(token);
  if (!pending) return null;
  enrichments.delete(token);
  return (await pending.catch(() => null)) ?? null;
}

// ------------------------------------------------------------------------------ detail

/** views/ebook.tsx: a source route reads the provider, anything else the metadata catalog. */
export async function detail(id: string): Promise<EBook | null> {
  return (await (id.startsWith("source:") ? sourceEBookDetail(id) : ebookDetail(id)).catch(() => null)) ?? null;
}

/**
 * EBookDetails source resolution: the title (and its aliases) searched in every source, the
 * promising hits hydrated, and every copy that eBooksMatch keeps offered as a "Source".
 */
export async function resolveSources(ebook: EBook, sourceCandidates: EBook[] | null) {
  const existing = (ebook.books ?? [ebook]).filter((book) => book.source === "source");
  const queries = [ebook.title, ...(ebook.sourceAliases ?? []), ...(ebook.verifiedAliases ?? []), ...(ebook.altTitle?.split("|") ?? [])]
    .map((title) => title.trim())
    .filter(Boolean);
  const normalizedAuthors = new Set(ebook.authors.map((author) => author.normalize("NFKD").toLocaleLowerCase().trim()).filter(Boolean));
  const hasArabic = (value: string) => /\p{Script=Arabic}/u.test(value);
  const ebookIsArabic = hasArabic(ebook.title);
  try {
    const results = await Promise.all([...new Set(queries)].slice(0, 6).map((query) => searchSourceEBookCatalog(query, "all")));
    const searched = results.flat().flatMap((item) => item.books ?? [item]);
    const candidates = [...existing, ...searched, ...(sourceCandidates ?? [])];
    const uniqueCandidates = [...new Map(candidates.map((item) => [item.id, item])).values()];
    const promising = uniqueCandidates
      .filter((candidate) => {
        if (existing.some((book) => book.id === candidate.id) || eBooksMatch(candidate, ebook)) return true;
        const sharesAuthor = candidate.authors.some((author) => normalizedAuthors.has(author.normalize("NFKD").toLocaleLowerCase().trim()));
        return sharesAuthor || hasArabic(candidate.title) !== ebookIsArabic;
      })
      .slice(0, 32);
    const hydrated = await Promise.all(
      promising.map((candidate) => sourceEBookDetail(candidate.id).then((d) => d ?? candidate).catch(() => candidate)),
    );
    const matches = dedupeEBooks([...uniqueCandidates, ...hydrated])
      .filter((item) => eBooksMatch(item, ebook) || item.books?.some((book) => eBooksMatch(book, ebook)))
      .flatMap((item) => item.books ?? [item]);
    return [...new Map(matches.map((item) => [item.id, item])).values()];
  } catch {
    return existing;
  }
}

/** EBookDetails "More by {author}": the source catalogs first, then book metadata. */
export async function moreByAuthor(ebook: EBook): Promise<EBook[]> {
  if (!ebook.authors.length) return [];
  const authors = ebook.authors.slice(0, 2);
  try {
    const sourceResults = (await Promise.all(authors.map((author) => searchSourceEBookCatalog(author, "all")))).flat();
    const sourceMatches = booksBySameAuthor(ebook, sourceResults);
    if (sourceMatches.length) return sourceMatches.slice(0, 18);
    const metadataResults = (await Promise.all(authors.map((author) => searchEBooks(author).catch(() => [])))).flat();
    return booksBySameAuthor(ebook, metadataResults).slice(0, 18);
  } catch {
    return [];
  }
}

/** EBookDetails "Recommended eBooks": same-genre picks from the installed sources' first page. */
export async function recommended(ebook: EBook): Promise<{ items: EBook[]; failed: boolean }> {
  const normalize = (value: string) =>
    value
      .normalize("NFKD")
      .toLocaleLowerCase()
      .replace(/[^\p{L}\p{N}]+/gu, " ")
      .trim();
  const currentTitles = new Set(
    [ebook.title, ebook.altTitle, ...(ebook.books ?? []).flatMap((book) => [book.title, book.altTitle])]
      .filter((title): title is string => Boolean(title))
      .map(normalize),
  );
  const currentGenres = ebook.genres.map(normalize).filter(Boolean);
  const genreScore = (item: EBook) => {
    const candidateGenres = item.genres.map(normalize).filter(Boolean);
    return currentGenres.reduce(
      (score, genre) =>
        score + Number(candidateGenres.some((candidate) => candidate === genre || candidate.includes(genre) || genre.includes(candidate))),
      0,
    );
  };
  const pick = (items: EBook[]) => {
    const seen = new Set<string>();
    return items
      .filter((item) => {
        if (item.id === ebook.id || currentTitles.has(normalize(item.title))) return false;
        const key = `${item.source}:${item.id}`;
        if (seen.has(key)) return false;
        seen.add(key);
        return true;
      })
      .map((item) => ({ item, score: genreScore(item) }))
      .filter(({ score }) => score > 0)
      .sort((left, right) => right.score - left.score)
      .map(({ item }) => item)
      .slice(0, 18);
  };
  try {
    const result = await loadSourceEBookPage(undefined, "all");
    const enrichedItems = await result.enriched.catch(() => result.items);
    return { items: pick(enrichedItems), failed: false };
  } catch {
    return { items: [], failed: true };
  }
}

/** bp-hero-manga "Read the eBook": the light novel's AniList entry, opened by its id. */
export async function anilistEBookId(anilistId: number): Promise<string> {
  const ebook = await ebookDetail(`anilist:${anilistId}`).catch(() => null);
  return ebook?.id ?? `anilist:${anilistId}`;
}

// ------------------------------------------------------------------------------ reading a book

/**
 * The EPUB behind a source route, for the TV's native reader: only Gutendex books have one the
 * TV can open (gutendex.ts pickEpub). null when the route is some other kind of source.
 */
export async function epub(route: string): Promise<{ bookId: string; url: string } | null> {
  const parts = routeParts(route);
  if (!parts) return null;
  const source = listEBookSources().find((s) => s.id === parts.providerId);
  if (source?.kind !== "gutendex") return null;
  const book = await gutendexDetail(parts.itemId).catch(() => null);
  return book?.epubUrl ? { bookId: parts.itemId, url: book.epubUrl } : null;
}

/** providers.ts gutendexProvider.chapters: `[bookId, chapter path]` as JSON, and the position. */
export function chapters(bookId: string, list: Array<{ path: string; title: string }>): EBookChapter[] {
  return (list ?? []).map((chapter, index) => ({ id: JSON.stringify([bookId, chapter.path]), title: chapter.title, position: index }));
}

/** providers.ts cleanSourceText (not exported): cut CSS / script debris a page leaked, drop
 *  text with no letters or digits. Upstream runs it over every chapter it reads. */
export function cleanSourceText(value: string): string {
  const text = value.replace(/\r/g, "").trim();
  const boundary = [
    /(?:^|\s)(?:background|border|color|cursor|display|font-size|line-height|opacity|position)\s*:\s*[^;{}]+;\s*(?:[\w-]+\s*:|})/i,
    /\b(?:document\.(?:getElementById|querySelector)|function\s+[\w$]+\s*\(|querySelectorAll\s*\(|classList\.(?:add|remove)\s*\()/i,
    /(?:^|\s)[.#][\w-]+(?::[\w-]+)?\s*\{(?=[^}]{0,400}\b(?:background|border|color|display|position)\s*:)/i,
  ].reduce((cut, pattern) => {
    const index = text.search(pattern);
    return index < 0 ? cut : Math.min(cut, index);
  }, text.length);
  const cleaned = text.slice(0, boundary).trim();
  return /[\p{L}\p{N}]/u.test(cleaned) ? cleaned : "";
}

function volumeLabel(chapter: EBookChapter): string | undefined {
  return chapter.volumeTitle || (chapter.volume ? `Volume ${chapter.volume}` : undefined);
}

/**
 * EBookDetails readChapter + the reader's first render: the resume points at the chapter, and
 * the chapter's cleaned text comes back as paragraphs (harbor-reader `paragraphs`), with the line
 * saved for it and the text identity every position save carries.
 */
export function openChapter(pid: string, bookId: string, chapter: EBookChapter, raw: string) {
  saveEBookResume(pid, bookId, { chapterId: chapter.id, chapterTitle: chapter.title, chapterLabel: chapter.chapter, volumeLabel: volumeLabel(chapter) });
  const text = cleanSourceText(raw ?? "");
  const line = loadEBookProgress(pid, bookId, `${chapter.id}:harbor`);
  const identity = ebookTextIdentity(text);
  return {
    paragraphs: ebookParagraphs(text),
    line,
    identity,
    offset: loadPageAnchor(pid, bookId, chapter.id, line, identity),
  };
}

/**
 * (bug pass) TV-only page anchor beside upstream's paragraph line: where the saved page began, in
 * characters from the saved paragraph's start (negative when the page opens on the tail of the
 * paragraph before it). A paragraph longer than a screen page spans several pages, and the line
 * alone reopened the book on the first of them. Stored under upstream's progress prefix (durable on
 * the TV) with a suffix upstream's savedEBookChapters skips (it only reads ids ending in
 * ":harbor"); used only while the saved line and the chapter's text identity still match.
 */
function pageAnchorKey(pid: string, bookId: string, chapterId: string): string {
  const safe = (value: string) => encodeURIComponent(value);
  return `harbor.ebook.progress.v1.${safe(pid)}.${safe(bookId)}.${safe(`${chapterId}:harbor:tv-anchor`)}`;
}

function loadPageAnchor(pid: string, bookId: string, chapterId: string, line: number, identity: string): number | null {
  try {
    const stored = JSON.parse(localStorage.getItem(pageAnchorKey(pid, bookId, chapterId)) || "null") as
      | { line?: unknown; offset?: unknown; identity?: unknown }
      | null;
    if (!stored || stored.line !== line || stored.identity !== identity) return null;
    return typeof stored.offset === "number" && Number.isInteger(stored.offset) ? stored.offset : null;
  } catch {
    return null;
  }
}

/** harbor-reader persistReadingPosition. */
export function savePosition(
  pid: string,
  bookId: string,
  chapter: EBookChapter,
  line: number,
  count: number,
  chapterIndex: number,
  totalChapters: number,
  identity: string,
  offset?: number | null,
) {
  if (!count || (!chapter.legacy && chapterIndex < 0) || !totalChapters) return null;
  const safeLine = Math.max(0, Math.min(count - 1, line));
  const chapterProgress = count <= 1 ? 100 : Math.round((safeLine / (count - 1)) * 100);
  const bookProgress = Math.round(((chapterIndex + chapterProgress / 100) / totalChapters) * 100);
  saveEBookProgress(pid, bookId, `${chapter.id}:harbor`, safeLine);
  try {
    const key = pageAnchorKey(pid, bookId, chapter.id);
    if (typeof offset === "number" && Number.isFinite(offset)) {
      localStorage.setItem(key, JSON.stringify({ line: safeLine, offset: Math.round(offset), identity }));
    } else {
      localStorage.removeItem(key);
    }
  } catch {
    /* the line alone still restores the paragraph */
  }
  return saveEBookResume(pid, bookId, {
    chapterId: chapter.id,
    chapterTitle: chapter.title,
    chapterLabel: chapter.chapter,
    volumeLabel: volumeLabel(chapter),
    chapterProgress,
    ...(!chapter.legacy ? { bookProgress, chapterIndex, totalChapters } : {}),
    textIdentity: identity,
  });
}

export function resume(pid: string, bookId: string): EBookResume | null {
  return loadEBookResume(pid, bookId);
}

/** useEBookReadStatus for several books at once: "read", "partial" or absent. */
export function statuses(pid: string, ids: string[]): Record<string, "read" | "partial"> {
  const out: Record<string, "read" | "partial"> = {};
  for (const id of ids ?? []) {
    const r = loadEBookResume(pid, id);
    const tracking = getEBookTracking(id);
    const savedLine = r ? loadEBookProgress(pid, id, `${r.chapterId}:harbor`) : 0;
    const read =
      tracking.status === "COMPLETED" ||
      (r?.chapterIndex !== undefined && r.totalChapters !== undefined && r.chapterIndex === r.totalChapters - 1 && (r.chapterProgress ?? 0) >= 100);
    const partial = tracking.progress > 0 || savedLine > 0 || (r?.chapterProgress ?? 0) > 0 || (r?.bookProgress ?? 0) > 0;
    if (read) out[id] = "read";
    else if (partial) out[id] = "partial";
  }
  return out;
}

// ------------------------------------------------------------------------------ AniList tracking

/** getEBookTracking, exposed directly: the wheel menu's own read/unread toggle state
 *  (status === "COMPLETED"), kept separate from the merged read/partial badge `statuses()`
 *  computes from resume too — upstream keeps the two apart (a book can be resume-complete
 *  without ever being marked read on AniList, or marked read without a saved position at all). */
export function trackingFor(id: string) {
  return getEBookTracking(id);
}

/**
 * ebook-wheel-menu.tsx markCompleted: the desktop's only AniList list action for an eBook is this
 * one toggle (there is no in-between "Reading"/"Paused" picker in the eBook UI, unlike the anime
 * tracker panel) — Completed sets progress to the book's full chapter/volume count, PLANNING
 * clears it back to 0. `saveEBookTracking` (lib/ebook/tracking.ts) persists locally at once and,
 * when the book has an `anilistId` and the AniList session from engine/trackers.ts is signed in,
 * pushes the same mutation upstream's `SaveMediaListEntry` uses; it throws on a failed push so the
 * caller can fall back to "saved locally" copy, exactly as the wheel menu's try/catch does.
 */
export async function toggleRead(ebook: EBook) {
  const next = getEBookTracking(ebook.id).status !== "COMPLETED";
  return saveEBookTracking(ebook, {
    status: next ? "COMPLETED" : "PLANNING",
    progress: next ? (ebook.chapters ?? getEBookTracking(ebook.id).progress) : 0,
    progressVolumes: next ? (ebook.volumes ?? getEBookTracking(ebook.id).progressVolumes) : 0,
  });
}

/**
 * views/ebook.tsx loadAnilistLibrary, run once when the room opens: flush anything saved while
 * signed out, then pull the AniList list collection so `statuses()` picks up ranks set from the
 * AniList site itself (mediaListEntry.progress) without a per-book round trip. A no-op when the
 * shared AniList session (engine/trackers.ts `anilist.*`) isn't signed in.
 */
export async function refreshAnilistLibrary(): Promise<void> {
  const session = anilistSession.getSession();
  if (!session || !anilistSession.isAuthenticated()) return;
  await flushPendingEBookTracking().catch(() => {});
  await fetchEBookListCollection(session.userId).catch(() => {});
}

/** views/ebook.tsx continueBookmarks: every known book with a resume, newest first. */
export function continueList(pid: string, candidates: EBook[] | null) {
  const byId = new Map<string, EBook>();
  for (const ebook of [...(candidates ?? []), ...ebookLibrary(), ...favoriteEBooks()]) if (!byId.has(ebook.id)) byId.set(ebook.id, ebook);
  return [...byId.values()]
    .map((ebook) => ({ ebook, resume: loadEBookResume(pid, ebook.id) }))
    .filter((item): item is { ebook: EBook; resume: EBookResume } => item.resume !== null)
    .sort((left, right) => right.resume.updatedAt - left.resume.updatedAt);
}

// ------------------------------------------------------------------------------ shelf

export function library() {
  return { shelf: ebookLibrary(), favorites: favoriteEBooks() };
}

export function flags(id: string) {
  return { shelf: ebookInLibrary(id), favorite: ebookIsFavorite(id) };
}

export function toggleShelf(ebook: EBook): boolean {
  return toggleEBookLibrary(ebook);
}

export function toggleFavorite(ebook: EBook): boolean {
  return toggleEBookFavorite(ebook);
}

// ------------------------------------------------------------------------------ reader

export function prefs(): EBookReaderPrefs {
  return loadEBookReaderPrefs();
}

/** harbor-reader patch(): merge into the stored prefs (every field the TV never shows survives). */
export function savePrefs(patch: Partial<EBookReaderPrefs>): EBookReaderPrefs {
  const next = { ...loadEBookReaderPrefs(), ...(patch ?? {}) };
  saveEBookReaderPrefs(next);
  return next;
}

export function bookmarks(pid: string, bookId: string) {
  return loadEBookBookmarks(pid, bookId);
}

/** harbor-reader addBookmark: the passage's first 140 characters are its preview. */
export function addBookmark(pid: string, bookId: string, chapter: EBookChapter, line: number, preview: string) {
  return addEBookBookmark(pid, {
    bookId,
    chapterId: chapter.id,
    chapterTitle: chapter.title || `Chapter ${chapter.chapter ?? ""}`.trim(),
    chapterLabel: chapter.chapter ? `Chapter ${chapter.chapter}` : chapter.title || "Chapter",
    volumeLabel: volumeLabel(chapter) ?? "Chapters",
    line,
    preview: (preview ?? "").slice(0, 140),
  });
}

export function removeBookmark(pid: string, bookId: string, id: string) {
  return removeEBookBookmark(pid, bookId, id);
}

// ------------------------------------------------------------------------------ NYT bestsellers
//
// (docs/ebook-spec.md §6 "Not done"): views/ebook.tsx's bestseller rail and hero, lib/ebook/nyt.ts
// + nyt-rail.ts + nyt-match.ts + nyt-availability.ts unchanged. Placeholders (no source copy yet:
// nyt-rail.ts PREFIX "nyt:") are told apart in Swift by that same id prefix; opening one shows a
// toast instead (views/ebook.tsx isNytPlaceholder → emitListToast).

/**
 * views/ebook.tsx `const bestsellerList = useNytList(); useResolveNytBooks(bestsellerList, 15);`:
 * the primary list ("combined-print-and-e-book-fiction") resolved against the installed sources,
 * as the room's "New York Times Bestsellers" rail (and its hero, once 3+ have a cover) show it.
 * Cheap to call every time the room opens without a key, or between weekly refreshes: nyt.ts
 * loadNytBestsellers only fetches once the cached snapshot is 7 days old, and does nothing at all
 * beyond reading that cache when apiKey is empty (refreshNytBestsellers's own early return).
 */
export async function nytRail(apiKey: string): Promise<{ attribution: string; items: EBook[] }> {
  const snapshot = await loadNytBestsellers(apiKey ?? "").catch(() => null);
  const list = nytList(snapshot, NYT_PRIMARY_LIST);
  if (!list) return { attribution: NYT_ATTRIBUTION, items: [] };
  await resolveNytBooks(list.books.slice(0, 15)).catch(() => {});
  return { attribution: NYT_ATTRIBUTION, items: nytRailItems(list) ?? [] };
}

/**
 * views/ebook.tsx EBookLibraryHero / EBookDetails: `nytRankFor(list, ebook) ?? nytBestsellerFor(
 * snapshot, ebook)?.book`, read from whatever NYT snapshot nytRail above has cached (no network:
 * this never fetches, so the detail page and the hero can call it for every book on screen).
 */
export function nytBestsellerRank(ebook: EBook): { rank: number; weeksOnList: number } | null {
  const snapshot = readNytSnapshot();
  const list = nytList(snapshot, NYT_PRIMARY_LIST);
  const best = nytRankInList(list, ebook) ?? nytBestsellerFor(snapshot, ebook)?.book ?? null;
  return best ? { rank: best.rank, weeksOnList: best.weeksOnList } : null;
}

// ------------------------------------------------------------------------------ browse filters
//
// views/ebook.tsx Type / Genre / Status / Language / Sort dropdowns (browseStatus, browseLanguage,
// browseSort, categoryGroup, category), applied together the way the view's own matchesCategory +
// applyEBookBrowseFilters(filteredSourceItems, ...).filter(matchesCategory) does. The TV turns the
// dropdowns into chips that cycle their value and apply at once (no separate Apply/Reset step,
// like the stream picker's own facet chips, App/Sources/Streams/PlayPickerView.swift).

export type EBookBrowseCategories = { order: EBookCategoryGroup[]; groups: Record<string, string[]>; genres: readonly string[] };

/** EBOOK_CATEGORIES's own key order, so the Swift "All" case can flatten it the way
 *  `Object.values(EBOOK_CATEGORIES)` does (Fiction, then Non-fiction). */
export function browseCategories(): EBookBrowseCategories {
  return { order: Object.keys(EBOOK_CATEGORIES) as EBookCategoryGroup[], groups: EBOOK_CATEGORIES, genres: EBOOK_FILTER_GENRES };
}

export type EBookBrowseFiltersArg = {
  type: EBookCategoryGroup | "All";
  genre: string;
  status: EBookBrowseStatus;
  language: EBookBrowseLanguage;
  sort: EBookBrowseSort;
};

/** applyEBookBrowseFilters (status, language, then sort) followed by the view's own
 *  matchesCategory (Type / Genre, ebookMatchesGenre): the Browse eBooks grid's five chips. */
export function applyBrowseFilters(items: EBook[], filters: EBookBrowseFiltersArg): EBook[] {
  const base = applyEBookBrowseFilters(items, { status: filters.status, language: filters.language, sort: filters.sort });
  const wanted = filters.genre || (filters.type === "All" ? "" : filters.type);
  if (!wanted) return base;
  const categories = filters.genre
    ? [filters.genre]
    : [filters.type, ...(EBOOK_CATEGORIES[filters.type as EBookCategoryGroup] ?? [])];
  return base.filter((ebook) => categories.some((item) => ebookMatchesGenre(ebook.genres, item)));
}

// ------------------------------------------------------------------------------ collections
//
// views/ebook.tsx screen "collections" (lib/ebook/collections.ts unchanged): series, the
// installed source's own catalog, and award-winner shelves built from books the source already
// has. Data-only and portable (docs/ebook-spec.md §6): no AniList list tracking, no offline
// export, no annotations here, just the collections the view itself builds from source items.

/** eBookCollectionCacheScope(providerId, providerIds): the collections screen's cache key. */
export function collectionScope(providerId: string, providerIds: string[]): string {
  return eBookCollectionCacheScope(providerId, providerIds);
}

const collectionJobs = new Map<number, Promise<EBookSourceCollection[]>>();
let collectionSeq = 0;

/**
 * The collections screen's instant state: the cached collections (readSourceEBookCollections)
 * folded with whatever buildSourceEBookCollections finds among the catalog items the room hands
 * over (it pages the source ahead of what the browse grid has loaded first, like the view's own
 * loadCatalog effect). Returns that at once, and a token when the scope's award search isn't
 * fresh yet (sourceEBookAwardsAreFresh): collectionsResolved awaits it, the way the view's own
 * effect streams new award matches in as streamSourceEBookAwardMatches finds them.
 */
export function collections(
  scope: string,
  providerId: string,
  items: EBook[],
): { collections: EBookSourceCollection[]; token: number | null } {
  const cached = readSourceEBookCollections(scope);
  const cachedAwardBooks = cached.filter((c) => c.kind === "award").flatMap((c) => c.books);
  const live = buildSourceEBookCollections([...items, ...cachedAwardBooks]);
  if (live.length) writeSourceEBookCollections(scope, live);
  const merged = new Map(cached.map((c) => [c.id, c] as const));
  for (const c of live) merged.set(c.id, c);
  const resolved = [...merged.values()];
  if (!scope || sourceEBookAwardsAreFresh(scope)) return { collections: resolved, token: null };
  const token = ++collectionSeq;
  const job = (async () => {
    const found = await streamSourceEBookAwardMatches(
      [...items, ...cachedAwardBooks],
      (title) => searchSourceEBookCatalog(title, providerId),
      () => {},
    );
    markSourceEBookAwardsResolved(scope);
    const withAwards = buildSourceEBookCollections([...items, ...cachedAwardBooks, ...found]);
    if (withAwards.length) writeSourceEBookCollections(scope, withAwards);
    const finalMerged = new Map(cached.map((c) => [c.id, c] as const));
    for (const c of withAwards) finalMerged.set(c.id, c);
    return [...finalMerged.values()];
  })();
  collectionJobs.set(token, job);
  job.catch(() => {});
  while (collectionJobs.size > 4) collectionJobs.delete(collectionJobs.keys().next().value!);
  return { collections: resolved, token };
}

/** collections()'s background award search, once it lands. */
export async function collectionsResolved(token: number): Promise<EBookSourceCollection[] | null> {
  const pending = collectionJobs.get(token);
  if (!pending) return null;
  collectionJobs.delete(token);
  return (await pending.catch(() => null)) ?? null;
}
