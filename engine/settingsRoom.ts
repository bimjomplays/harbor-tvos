// Big Picture settings (bp-settings-catalog.ts + bp-settings-commit.ts) as data: categories with
// summaries, controls per category, and one commit function. Swift renders rows generically.
import { bpSettingsCategories, bpSettingsControls, bpConnectedNames, bpOverscanLabel, bpServiceItems, bpSoundLabel, type BpCatId, type BpControl } from "@/views/big-picture/bp-settings-catalog";
// t() is lib/i18n's: English until the host installs the chosen catalog (installUiCatalog below).
import { LANGUAGES, getUiLanguage, normalizeLanguage, setUiLanguage, t, type UiLanguage } from "@/lib/i18n";
import { registerUiCatalog, uiCatalogLoaded } from "@/lib/i18n/translate";
import { serviceBadge } from "@/lib/providers/streaming";
import type { StreamingService } from "@/lib/settings";
import type { Settings } from "@/lib/settings/types";
import { loadEffective, persistEffective } from "@/lib/settings/profile-store";
import { currentAuthor } from "@/lib/theme-auth";
import { declineSportsConsent, getSportsConsentSnapshot, resetSportsConsent } from "@/lib/sports/consent";
import { markSettingsPatched } from "./sync";
import { readPlaylists } from "@/lib/iptv/playlists-store";

/**
 * bp-settings.tsx counts `settings.iptvPlaylists`, but load.ts moves playlists into their own
 * store (lib/iptv/playlists-store.ts) and drops that field, so upstream's count is always 0 and
 * the row never says "{count} added". The store is where the playlists are; count them there.
 */
function playlistCount(): number {
  try {
    return readPlaylists().length;
  } catch {
    return 0;
  }
}

/** What the TV calls upstream's "html5" engine value: AVPlayer plays it (engine/player.ts pickEngine). */
const NATIVE_ENGINE_LABEL = "AVPlayer";

function stremioName(profileId: string): string | null {
  try {
    const raw = localStorage.getItem(`harbor.auth.${profileId}`);
    const parsed = raw ? (JSON.parse(raw) as { user?: { email?: string; name?: string } }) : null;
    return parsed?.user?.name ?? parsed?.user?.email ?? null;
  } catch {
    return null;
  }
}

function facts(s: Settings, profileId: string) {
  return { tmdbKey: s.tmdbKey ?? "", stremioName: stremioName(profileId), harborName: currentAuthor()?.username ?? null };
}

export function categories(profileId: string, linked: boolean) {
  const s = loadEffective(profileId, linked);
  const connected = bpConnectedNames(facts(s, profileId));
  return {
    // bp-settings-catalog summary: the TV's stand-in for upstream's html5 engine is AVPlayer.
    categories: bpSettingsCategories(s, t, s.bigPictureOverscan ?? 0, connected).map((c) =>
      c.id === "playback" && s.playerEngine === "html5" ? { ...c, summary: NATIVE_ENGINE_LABEL } : c),
    sportsShown: getSportsConsentSnapshot().status !== "declined",
    overscan: s.bigPictureOverscan ?? 0,
  };
}

export function controls(id: BpCatId, profileId: string, linked: boolean): BpControl[] {
  const s = loadEffective(profileId, linked);
  const out = bpSettingsControls(id, s, t, s.bigPictureOverscan ?? 0, getSportsConsentSnapshot().status !== "declined");
  // bp-settings.tsx:193-201: push rows report what is connected / how many playlists were added.
  const connected = bpConnectedNames(facts(s, profileId));
  const playlists = playlistCount();
  return out.map((c) => {
    // Service cells carry their brand tint so the TV can draw a chip without the SVG logo.
    // "Player engine": upstream's "html5" value selects the TV's AVPlayer engine (player.ts pickEngine).
    if (c.kind === "options" && c.id === "engine") return { ...c, options: c.options.map((o) => (o.value === "html5" ? { ...o, label: NATIVE_ENGINE_LABEL } : o)) };
    if (c.kind === "multi" && c.id === "service") return { ...c, items: c.items.map((i) => ({ ...i, tint: serviceBadge(i.value as StreamingService).tint })) };
    if (c.kind === "push" && c.pane === "connect" && connected.length > 0) return { ...c, detail: t("Connected: {list}", { list: connected.join(", ") }) };
    if (c.kind === "push" && c.pane === "live" && playlists > 0) return { ...c, detail: t("{count} added", { count: playlists }) };
    return c;
  });
}

/** bp-settings-commit.ts, without React: writes the settings blob and marks synced sections. */
export function commit(id: string, value: string, profileId: string, linked: boolean): { ok: boolean; sportsShown: boolean } {
  const s = loadEffective(profileId, linked);
  const on = value === "on";
  const patch: Partial<Settings> = {};
  switch (id) {
    case "overscan": patch.bigPictureOverscan = Number(value); break;
    case "quality": patch.posterQuality = value as Settings["posterQuality"]; break;
    case "backdrop": patch.bigPictureMosaic = on; break;
    case "uiLanguage":
      if (LANGUAGES.some((l) => l.code === value)) { setUiLanguage(value as UiLanguage); patch.uiLanguage = value as UiLanguage; }
      break;
    case "subSize": patch.subFontSize = Number(value); break;
    case "subLang": {
      const picked = s.preferredSubLangs;
      patch.preferredSubLangs = picked.includes(value) ? picked.filter((l) => l !== value) : [...picked, value];
      break;
    }
    case "engine": patch.playerEngine = value as Settings["playerEngine"]; break;
    case "playbackSource": patch.playbackSourcePreference = value as Settings["playbackSourcePreference"]; break;
    case "preferredMediaServer": patch.preferredMediaServerId = value || null; break;
    case "hwdec": patch.mpvHwdec = value as Settings["mpvHwdec"]; break;
    case "skipIntro": patch.autoSkipIntro = on; break;
    case "autoNext": patch.autoPlayNextEpisode = on; break;
    case "instantPlay": patch.instantPlay = on; break;
    case "homeMode": patch.homeMode = value as Settings["homeMode"]; break;
    case "hideWatched": patch.hideWatchedInCatalogs = on; break;
    case "service": patch.streaming = { ...s.streaming, [value]: !s.streaming[value as StreamingService] }; break;
    case "sound": patch.bigPictureSound = value as Settings["bigPictureSound"]; break;
    case "controller": patch.tvNavigation = on; break;
    case "autoStart": patch.bigPictureAutoStart = on; break;
    case "sportsTab": if (on) resetSportsConsent(); else declineSportsConsent(); break;
    case "sportsNotice": resetSportsConsent(); break;
    case "leave": break;
    default: return { ok: false, sportsShown: getSportsConsentSnapshot().status !== "declined" };
  }
  if (Object.keys(patch).length > 0) {
    persistEffective({ ...s, ...patch }, profileId, linked);
    markSettingsPatched(Object.keys(patch));
    window.dispatchEvent(new CustomEvent("harbor:settings-updated", { detail: { profileId, fields: Object.keys(patch) } }));
  }
  return { ok: true, sportsShown: getSportsConsentSnapshot().status !== "declined" };
}

// ------------------------------------------------------------------ flags, languages, preview
/**
 * components/flag.tsx FLAG: the language names that have a flag, as the country each SVG draws
 * (flag-eng is the US flag, flag-ara Saudi Arabia). tvOS draws them as emoji flags.
 */
const FLAG_COUNTRY: Record<string, string> = {
  English: "US", Italian: "IT", Russian: "RU", Hindi: "IN", Spanish: "ES", "Spanish (Latin America)": "ES",
  Korean: "KR", Japanese: "JP", Chinese: "CN", "Chinese (Simplified)": "CN", Portuguese: "PT",
  "Portuguese (Brazil)": "BR", German: "DE", French: "FR", Turkish: "TR", Arabic: "SA", Czech: "CZ",
  Danish: "DK", Finnish: "FI", Hebrew: "IL", Hungarian: "HU", Dutch: "NL", Norwegian: "NO", Polish: "PL",
  Romanian: "RO", Swedish: "SE", Thai: "TH", Ukrainian: "UA", Vietnamese: "VN",
};

/** flagSrc(language) as a regional-indicator emoji, or null where upstream has no flag either. */
export function flagEmoji(language: string): string | null {
  const cc = FLAG_COUNTRY[language];
  if (!cc) return null;
  return String.fromCodePoint(...Array.from(cc).map((ch) => 0x1f1e6 + ch.charCodeAt(0) - 65));
}

// onboarding/steps/bp-step-language.tsx PAIRED: one circle split between two flags.
const PAIRED: Record<string, string[]> = { Portuguese: ["Portuguese", "Portuguese (Brazil)"] };

/** bp-step-language.tsx rows: LANGUAGES in order with their flags; `current` is the stored choice. */
export function languages(profileId: string, linked: boolean) {
  const s = loadEffective(profileId, linked);
  return {
    current: normalizeLanguage(s.uiLanguage),
    languages: LANGUAGES.map((l) => ({
      code: l.code,
      label: l.label,
      nativeLabel: l.nativeLabel,
      greeting: l.greeting,
      rtl: l.rtl,
      flags: (PAIRED[l.label] ?? [l.label]).map(flagEmoji).filter((f): f is string => f !== null),
    })),
  };
}

/**
 * store.ts reads uiLanguage once at load; a profile switch or a synced settings blob can carry a
 * different one, so the host re-applies it whenever it reloads settings (lib/settings.tsx does the
 * same on every settings change).
 */
export function applyUiLanguage(profileId: string, linked: boolean): string {
  const lang = normalizeLanguage(loadEffective(profileId, linked).uiLanguage);
  if (lang !== getUiLanguage()) setUiLanguage(lang);
  return lang;
}

/**
 * load-locale.ts, host-fed: the bundle stubs upstream's lazy catalog import (20 MB), so the app
 * hands the chosen language's catalog over as JSON (tools/build_locales.mjs → App/Locales/<lang>.json)
 * and it is registered exactly as ensureUiLocale would. Returns whether that language is loaded.
 */
export function installUiCatalog(lang: string, rawJson: string): boolean {
  const code = normalizeLanguage(lang);
  if (code === "en") return true;
  if (!uiCatalogLoaded(code)) registerUiCatalog(code, JSON.parse(rawJson) as Record<string, string>);
  return uiCatalogLoaded(code);
}
export function uiCatalogInstalled(lang: string): boolean {
  const code = normalizeLanguage(lang);
  return code === "en" || uiCatalogLoaded(code);
}

// bp-settings-pane.tsx constants.
const STILL = "https://image.tmdb.org/t/p/w780/eGX66zonvc4bXg3rM08RUxdYSDx.jpg";
const SUB_PREVIEW_SCALE = 0.55;

/** bp-settings-pane.tsx BpSettingsPane, as data: what the right-hand preview draws per category. */
export function pane(profileId: string, linked: boolean) {
  const s = loadEffective(profileId, linked);
  const connected = bpConnectedNames(facts(s, profileId));
  const overscan = s.bigPictureOverscan ?? 0;
  const language = LANGUAGES.find((l) => l.code === s.uiLanguage) ?? null;
  const source = s.playbackSourcePreference;
  return {
    still: STILL,
    overscan,
    overscanLabel: bpOverscanLabel(t, overscan),
    subtitle: {
      text: t("This is how a subtitle will look."),
      px: Math.round(s.subFontSize * SUB_PREVIEW_SCALE),
      flags: s.preferredSubLangs.map(flagEmoji).filter((f): f is string => f !== null).slice(0, 8),
    },
    homeMode: s.homeMode,
    services: bpServiceItems(s).filter((i) => i.on).slice(0, 18).map((i) => ({ value: i.value, label: i.label, tint: serviceBadge(i.value as StreamingService).tint })),
    servicesEmpty: t("Turn off what you do not have"),
    language: language ? { code: language.code, nativeLabel: language.nativeLabel, greeting: language.greeting, rtl: language.rtl } : null,
    playback: [
      [t("Player engine"), s.playerEngine === "auto" ? t("Auto") : s.playerEngine],
      [t("Play button behavior"), t(source === "ask" ? "Ask every time" : source === "local" ? "Local Library" : source === "online" ? "Online streams" : "Home server")],
      [t("Hardware acceleration"), t(s.mpvHwdec === "auto" ? "Auto" : s.mpvHwdec === "on" ? "On" : "Off")],
      [t("Skip intros"), t(s.autoSkipIntro ? "On" : "Off")],
      [t("Auto-play next episode"), t(s.autoPlayNextEpisode ? "On" : "Off")],
      [t("Instant play"), t(s.instantPlay ? "On" : "Off")],
    ],
    setup: [
      ["TMDB", s.tmdbKey.trim() ? t("On") : t("None")],
      [t("Live TV playlists"), String(playlistCount())],
      [t("Setup"), connected.length > 0 ? connected.join(", ") : t("None")],
    ],
    interface: [
      [t("Interface sounds"), bpSoundLabel(t, s.bigPictureSound)],
      [t("Controller navigation"), t(s.tvNavigation ? "On" : "Off")],
      [t("Open in Big Picture"), t(s.bigPictureAutoStart ? "On" : "Off")],
    ],
  };
}
