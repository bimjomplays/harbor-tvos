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
import { dedupeEBooks, eBooksMatch, ebookDetail, mergeEBookMetadata, searchEBooks, type EBook } from "@/lib/ebook/api";
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
import { getEBookTracking } from "@/lib/ebook/tracking";
import { booksBySameAuthor } from "@/lib/ebook/universes";

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
  return {
    paragraphs: ebookParagraphs(text),
    line: loadEBookProgress(pid, bookId, `${chapter.id}:harbor`),
    identity: ebookTextIdentity(text),
  };
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
) {
  if (!count || (!chapter.legacy && chapterIndex < 0) || !totalChapters) return null;
  const safeLine = Math.max(0, Math.min(count - 1, line));
  const chapterProgress = count <= 1 ? 100 : Math.round((safeLine / (count - 1)) * 100);
  const bookProgress = Math.round(((chapterIndex + chapterProgress / 100) / totalChapters) * 100);
  saveEBookProgress(pid, bookId, `${chapter.id}:harbor`, safeLine);
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
