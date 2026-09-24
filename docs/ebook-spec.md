# eBooks on Apple TV (Stage 13) — feasibility and design

Upstream: `src/views/ebook.tsx`, `src/views/ebook/*` (sources panel, setup, reader, wheel menu),
`src/lib/ebook/*` (sources, providers, gutendex, api, library, reader-state, chapter-locations,
narration, epub), `src/lib/unzip.ts`, and the "Read the eBook" entry in
`components/anime-hero/hero-manga-adaptation.tsx` / `views/big-picture/bp-hero-manga.tsx`.

## 1. Sources: what runs in JavaScriptCore

`lib/ebook/providers.ts providers()` builds one provider per stored source plus one per
installed extension. JavaScriptCore on tvOS has no DOMParser, no Worker, no IndexedDB, no
DecompressionStream and no Tauri.

| Upstream source | Needs | On the TV |
|---|---|---|
| `gutendex` (Project Gutenberg, `gutendex.ts`) | JSON over fetch for the catalog; EPUB bytes + `parseEpub` for chapters | **Works.** Catalog, search, detail through the engine unchanged; the EPUB is read natively (section 2). |
| `local` folders | `@tauri-apps/plugin-fs` readDir/readFile | Not possible: no Tauri, and a TV has no user-visible file system. |
| `html` scraper sources | `DOMParser` + CSS selectors | Not ported: needs a DOM and `querySelector`; a selector engine over the native tree is possible later. |
| Extensions (`extensions.ts`) | IndexedDB for repos/plugins, `PluginWorker` (Worker) | Not possible in JSC. The bundle swaps the module for `engine/ebookExtensions.ts` (no repos, no plugins), because upstream's loader would reject and take `providers()` down with it. |
| Metadata (`api.ts`: AniList, Google Books, Open Library, Wikidata) | fetch + JSON | Works unchanged (`fetchEBookMetadata`, `mergeEBookMetadata`, `dedupeEBooks`, `eBooksMatch`). |
| Translation (`translation.ts`, DeepSeek) | fetch; IndexedDB cache is optional (`cache.ts` checks `typeof indexedDB`) | Bundled (its `?raw` prompt is loaded as text) but not surfaced: no key UI on the TV. |
| NYT bestsellers, collections, awards, universes rails | fetch + localStorage | Not surfaced yet (see 6). `booksBySameAuthor` from `universes.ts` is used for "More by". |

So the TV reads Project Gutenberg, which upstream's own sources panel offers as a one-click add
("GutenbergQuickAdd"). Everything that keys data (source ids, routes, chapter ids, progress
keys, the shelf, favourites, bookmarks, reader prefs) is upstream's module, so a book read on the
TV and on the desktop write the same keys.

## 2. EPUB without WebKit

Upstream reads an EPUB as: `lib/unzip.ts` (central directory walk + `DecompressionStream
("deflate-raw")`) → `epub.ts parseEpub` (DOMParser on `container.xml`, the OPF, the nav/NCX and
each XHTML) → chapters split at the table-of-contents targets → **plain text** per chapter
(`documentSections` / `readEpubChapter`: block elements separated by blank lines) →
`cleanSourceText` → paragraphs (`ebookParagraphs`). The web reader renders those paragraphs; it
never renders the book's own XHTML/CSS. That makes a native port straightforward and exact:

- **ZIP** — `App/Sources/EBook/EPUBBook.swift EPUBZip`: the same EOCD / central-directory walk,
  stored and DEFLATE entries; DEFLATE through the Compression framework
  (`compression_decode_buffer` with `COMPRESSION_ZLIB`, which is raw RFC 1951 DEFLATE), sized by
  the central directory's uncompressed size.
- **Markup** — `EPUBMarkup`: a forgiving XML/HTML tree builder (elements with lowercased local
  names, attributes, text/CDATA; comments, PIs and doctypes skipped; character references decoded;
  void elements; stray end tags ignored; a new block closes an open `<p>`). It stands in for
  DOMParser's XML parse *and* its HTML fallback, so a malformed chapter still reads.
- **parseEpub / readEpubChapter** — `EPUBBook.parse` / `text(for:)` port them line for line:
  manifest, spine (`linear="no"` skipped, nav excluded), readable documents (> 24 characters),
  headings as titles, EPUB 3 toc nav then NCX navPoints, `targetNode` (lifted to the heading),
  `documentSections` splitting at the targets, chapter paths `path#encodeURIComponent(fragment)`.
  Cover, title and authors are not parsed: the TV takes them from the source.
- **Cleaning and paragraphs stay upstream's**: the raw chapter text goes to
  `engine/ebook.ts openChapter`, which runs upstream's `cleanSourceText` (copied; not exported),
  `ebookParagraphs` and `ebookTextIdentity`, and returns the saved line. Chapter ids are built by
  the engine (`JSON.stringify([bookId, path])`, gutendexProvider.chapters), so they are
  byte-identical to the desktop's.
- **NSAttributedString `.html` import** is not used: it relies on WebKit, which tvOS does not
  ship, and upstream shows plain paragraphs anyway.
- **Pagination** — TextKit 1 (`NSTextStorage` / `NSLayoutManager` / one `NSTextContainer` per
  page), typeset off the main thread; each page is drawn by `drawGlyphs(forGlyphRange:at:)` into a
  plain `UIView`. This is upstream's "book" mode (`book-pages.ts` renders paragraph pages and keeps
  `paragraphStarts`); the TV keeps the same mapping: a page's line is the first paragraph that
  starts on it, and a saved line opens the page it starts on.
- Downloads: `EPUBLibrary` fetches the EPUB once (60 s, as `gutendexEpub`), keeps it in Caches
  (16 files) and the last 3 parsed books in memory (upstream keeps 6 packages).

## 3. Reader, progress and settings (harbor-reader.tsx)

- Left / Right turn pages (swapped for right-to-left text), crossing into the next / previous
  chapter at the ends; Up/Down also page. Select opens the reader bar; Back closes a panel, the
  bar, then the reader.
- Position: `persistReadingPosition` is ported (`engine/ebook.ts savePosition`):
  `harbor.ebook.progress.v1.<profile>.<book>.<chapterId>:harbor` = paragraph line, and the resume
  (`chapterProgress`, `bookProgress`, `chapterIndex`, `totalChapters`, `textIdentity`). Opening a
  chapter saves the resume first, as EBookDetails `readChapter` does.
- Settings panel from upstream's reader settings: Paper (dark / dim / light, upstream's
  colours), Type (literary / arabic / classic → Georgia / Geeza Pro / Palatino, system serif
  fallback), Text size 15–34, Line height 1.25–2.4, Page width 520–1080, Brightness 55–120,
  Direction auto / LTR / RTL, narration voice. Stored through `saveEBookReaderPrefs`
  (`harbor.ebook.reader.v1`), merged so the fields the TV does not show survive.
- Chapter list, bookmarks (`addEBookBookmark`, the 140-character preview), previous / next
  chapter. Annotations, search inside a chapter, translation, custom fonts, the mouse line
  tracker and focus mode are not ported (mouse/keyboard-only or not yet surfaced).

## 4. Narration

Upstream narrates with Microsoft Edge voices through a Tauri command (desktop only) and falls
back to the device voice (`speakWithDevice`: one `SpeechSynthesisUtterance` per paragraph from
the current line, rate 0.95, the page following the voice). The TV does the fallback with
`AVSpeechSynthesizer`: the same paragraph-by-paragraph walk, the page follows each utterance, the
spoken paragraph is tinted, Play/Pause pauses and resumes. The Edge voice list is kept for the
choice; the TV picks the installed system voice with that voice's locale and gender (best quality
first). Narration stops at the chapter's end, as upstream's does.

## 5. Room, detail, gating

- `EBookView` (views/ebook.tsx): EBookSetup until a source exists; then the hero, Favorites,
  "Continue your bookmarks" (opens straight into the reader: readIntent), Popular eBooks, the
  Shelf page, and "Browse eBooks" (search after 2 characters with a 300 ms debounce, catalog
  picker when several providers exist, paging with loadMore's stale-page streak, each page's
  metadata pass folded in when it lands).
- `EBookDetailView` (EBookDetails): the book, Start / Continue Reading (the wheel menu's action),
  Bookmark (the shelf, `toggleEBookLibrary`), favourite, the Source picker, description, chapters,
  "More by …" and "Recommended eBooks" (same logic as upstream, in `engine/ebook.ts`).
- Sources page: Project Gutenberg's quick add and removal of stored sources.
- "Read the eBook": `MangaHeroEntry` now handles a light-novel adaptation (`kind: "ebook"`):
  `ebookDetail("anilist:<id>")` then the detail page, which searches the sources for the book.
- Gating: upstream's desktop sidebar always lists eBooks (parentalKey "anime") and gates the room
  behind its setup screen. On the TV the tab is hidden by default like Manga and turned on in
  Settings → eBooks (a device choice, `EBookGate`); the parental "anime" lock hides it too
  (`engine/parental.ts`).

## 6. Not done (and why)

- Local folders, HTML sources and extensions: see section 1.
- NYT bestsellers rail/hero, Collections (series, catalog, awards), AniList list tracking and the
  browse filters (type, genre, status, language, sort): pure data, portable later; left out to
  keep this batch to reading.
- Offline export/download, translation, annotations, in-chapter search: desktop surfaces.
- Legacy chapter-location migration (`restoreSourceEBookChapters`): needs upstream's EPUB parse
  in JS; TV-read books never have legacy chapter ids.
