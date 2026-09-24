# Upstream re-sync, 2026-09-24

`reference/harbor` moved from `1bfcfb6` to `f289f8f3` (beta-branch, 28 commits). Engine bundle
3835 KB after the bump alone, 3866 KB after this batch (+27 KB of `chrome/nav-items.tsx` and its
nav icons; its lottie-web player and ~200 KB of Lottie JSON are stubbed in
`engine/bundle-config.mjs`, as are Vite `?raw` SVG imports). Offline smoke: 497 checks.

## What the port did, per upstream commit

| Commit | Upstream change | Port |
|---|---|---|
| `7fd95389` | search: remove stray focus rings, trap Tab inside the overlay | Not applicable (web focus rings / Tab key) |
| `d8a55fd7` | nav: never borrow page-level border radius on focus restore | Not applicable (DOM focus restore) |
| `eee14245` | nav: swallow F6 (WebView2 pane focus) | Not applicable (Windows only) |
| `2ba8331e` | chrome: in-place sidebar editing (hide, reorder, hidden tray) | **Ported** as TV tab editing: `engine/navEdit.ts` (upstream `applyNavCustomization`, `effectiveNavOrder`, `moveNavItem`, `toggleNavHidden`, `resetNavCustomization` over `settings.navCustomization`), top bar follows the order and hides (`Room.shellTabs` / `Room.arranged`), long-press menu on a tab (Hide this tab / Show all tabs / Reset layout, as context-menu.tsx `kind: "nav"`), Settings → Tabs (`TabsPanel.swift`: rows in bar order, Move up / Move down, Hide/Show this tab, Nothing hidden., Show all tabs, Reset layout). TV-only: Home is pinned first and shown (Back lands there) and Search (no NavItemId) keeps its slot. An untouched layout keeps the Big Picture order; a TV move is written back into the shared order in the slots the TV's tabs hold, so desktop-only items do not shift. Drag, edit mode and rename: not applicable (no pointer; the TV bar is icon-only) |
| `2eb97fc0` | linux: native power inhibition for Cinnamon/GNOME | Not applicable (Linux) |
| `c28d8b0d` | theme: MinUI Dark preset, token-driven dock | **Ported** by the re-bundle: `engine/themes.ts` lists upstream's library, so ThemeStore / Appearance now offer 13 presets; smoke checks MinUI Dark resolves dark with MinUI card/button styles and General Sans. Dock tokens: not applicable (no dock chrome) |
| `6c8aaec5` | poster dock clipping at row edges, header overlap | Not applicable (pointer magnification dock; tvOS focus scaling is native) |
| `3a10cec2` | settings: retire manga and liveTv hide toggles into sidebar editing | **Ported.** `settings/load.ts` `_navHideMigrateV1` runs in the bundled loader, so an existing "Hide manga" / "Hide Live TV" becomes a hidden `manga` / `live` entry, which now hides the TV's Manga / Live TV tab. `engine/parental.ts` copies only anime/sports/adult from a profile (profile-identity-sync.tsx), `engine/search.ts` asks manga sources whenever `mangaEnabled` (search-context / use-bp-search gates), `SettingsBridge.mangaOn` is `mangaEnabled` alone (Search, "Read the Manga") and the Manga tab also honours the tab hide |
| `cee434e3` | linux: mpv render context before loadfile | Not applicable (Linux mpv render ctx) |
| `ec6a696d` | watchlist: same-name collisions, twin ghosts, anime detail hijack | **Ported where the port mirrors it.** `mergeWatchlist` (identity slots, year-aware keys) and `toggleWatchlist` / `setWatchlistAggregate` fixes arrive by re-bundling (the Library feed already calls `mergeWatchlist`). `cards.refreshWatchlist` now uses `refreshWatchlistAggregates` (Stremio + Trakt + Simkl ids). New `cards.removeFromWatchlist` removes every cloud form (tt / tmdb / anime id) and evicts them from the aggregate; Detail's remove uses it with the resolved IMDb id. Not applicable: `noteLocalImdbId` (the TV writes no local watchlist entries), the watchlist-tab removal guards (the TV Library has no remove-from-card), and the detail.tsx Kitsu title-search fallback (the port's detail never flips a title to anime by name) |
| `5aff59fe` | cache-clear confirmation reset | Not applicable (desktop storage panel) |
| `193d7cc6`, `f8b56b7a`, `0c76fa89`, `39f7d2bd`, `84f25351`, `368ad337`, `6a56b24c`, `29caed61`, `ece91461`, `c8d1eea8`, `cc6c2ec9`, `22ae4308`, `f289f8f3` | merges | Covered by the rows for their commits |
| `83652fe7` | sidebar menus measurable and immediately dismissible | Not applicable (DOM menu measuring); the TV menu is the system context menu |
| `1b03acd8` | tv-cards: real anime backdrops instead of blurred posters | Not applicable: the port does not mirror the desktop `tv` card style (tv-card.tsx); Big Picture tiles are posters |
| `ac4aaa48` | rows: re-measure cards after a card-style switch | Not applicable (DOM row measuring; SwiftUI re-lays out) |
| `f07ad3af` | settings: detect metadata addons installed via the Stremio account | Not applicable yet: `hasCustomMetaAddonAsync` is bundled, but the TV has no Providers tab reading `hasCustomMetaAddon` |

Also carried by the bump: upstream's new UI strings ("Hide this tab", "Show this tab",
"Nothing hidden.", "Show all tabs", the reworded content-filter copy) reach the catalogs through
`tools/build_locales.mjs` (English fallback and Arabic so far).
