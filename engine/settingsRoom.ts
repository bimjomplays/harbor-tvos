// Big Picture settings (bp-settings-catalog.ts + bp-settings-commit.ts) as data: categories with
// summaries, controls per category, and one commit function. Swift renders rows generically.
import { bpSettingsCategories, bpSettingsControls, bpConnectedNames, type BpCatId, type BpControl } from "@/views/big-picture/bp-settings-catalog";
import { LANGUAGES, setUiLanguage, type UiLanguage } from "@/lib/i18n";
import { serviceBadge } from "@/lib/providers/streaming";
import type { StreamingService } from "@/lib/settings";
import type { Settings } from "@/lib/settings/types";
import { loadEffective, persistEffective } from "@/lib/settings/profile-store";
import { currentAuthor } from "@/lib/theme-auth";
import { declineSportsConsent, getSportsConsentSnapshot, resetSportsConsent } from "@/lib/sports/consent";
import { markSettingsPatched } from "./sync";

const t = (key: string, vars?: Record<string, string | number>) => key.replace(/\{(\w+)\}/g, (_, k) => String(vars?.[k] ?? `{${k}}`));

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
  const playlists = (s.iptvPlaylists ?? []).length;
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
