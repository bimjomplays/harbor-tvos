// AI search, without React: lib/ai-search.ts (aiSuggest → resolveAiSuggestions) driven the way
// components/search/ai-search/use-ai-suggest.ts drives it, plus the settings that
// views/settings/ai-search-section.tsx edits (provider tab, model, keys, live web context) and the
// model menu of components/search/ai-mode-button.tsx.
//
// Keys: upstream keeps aiSearchKey / aiGroqKey / jinaKey in the settings blob (they never ride
// profile sync, lib/profile-sync/sections.ts is an allowlist). The TV keeps them out of that blob,
// in one JSON value under AI_KEYS_PREFIX, which Swift's KeyValueStore routes to the Keychain
// (secretPrefixes). Provider, model and aiWebSearch stay in the blob exactly as upstream stores them.
import {
  AiSearchError,
  aiSuggest,
  resolveAiSuggestions,
  type AiErrorDescriptor,
  type AiResult,
} from "@/lib/ai-search";
import {
  AI_MODELS,
  DEFAULT_AI_MODEL,
  GROQ_MODELS,
  PROVIDER_NAME,
  migrateModelId,
  modelLabelFor,
  providerForModel,
  providerTabFor,
  type AiModel,
  type AiProviderTab,
} from "@/lib/ai-models";
import { fetchGroqCatalog, fetchOpenRouterCatalog, pruneToCatalog } from "@/lib/ai-live-models";
import { enrichWithContent } from "@/lib/jina-search";
import { releaseText } from "@/lib/release-info";
import { t } from "@/lib/i18n";
import { loadEffective, persistEffective } from "@/lib/settings/profile-store";
import type { Settings } from "@/lib/settings/types";
import type { Meta } from "@/lib/cinemeta";
import { markSettingsPatched } from "./sync";

/** Keychain tier on tvOS: App/Sources/Storage/KeyValueStore.swift secretPrefixes lists this prefix. */
export const AI_KEYS_PREFIX = "harbor.ai-search.keys.v1";

export type KeySlot = "openrouter" | "groq" | "jina";
type Keys = { openrouter: string; groq: string; jina: string };

/** The settings blob the keys belong to: the shared one for a linked profile (profile-store sourceKeyFor). */
function keysKey(profileId: string, linked: boolean): string {
  return `${AI_KEYS_PREFIX}.${linked ? "shared" : profileId}`;
}

function readKeys(profileId: string, linked: boolean): Keys {
  let stored: Partial<Keys> = {};
  try {
    stored = JSON.parse(localStorage.getItem(keysKey(profileId, linked)) || "{}") as Partial<Keys>;
  } catch {
    stored = {};
  }
  const str = (v: unknown) => (typeof v === "string" ? v : "");
  return { openrouter: str(stored.openrouter), groq: str(stored.groq), jina: str(stored.jina) };
}

function writeKeys(keys: Keys, profileId: string, linked: boolean): void {
  const key = keysKey(profileId, linked);
  if (!keys.openrouter && !keys.groq && !keys.jina) localStorage.removeItem(key);
  else localStorage.setItem(key, JSON.stringify(keys));
}

/** lib/settings update(): persist the patch, mark synced sections, tell listeners (settingsRoom.commit does the same). */
function patchSettings(patch: Partial<Settings>, profileId: string, linked: boolean): Settings {
  const s = loadEffective(profileId, linked);
  const next = { ...s, ...patch } as Settings;
  persistEffective(next, profileId, linked);
  markSettingsPatched(Object.keys(patch));
  window.dispatchEvent(new CustomEvent("harbor:settings-updated", { detail: { profileId, fields: Object.keys(patch) } }));
  return next;
}

/**
 * Settings plus the Keychain keys. A blob that still carries a key (a restored backup, a desktop
 * import) hands it to the Keychain once and is saved without it.
 */
function load(profileId: string, linked: boolean): { s: Settings; keys: Keys } {
  let s = loadEffective(profileId, linked);
  const keys = readKeys(profileId, linked);
  const blob = { openrouter: (s.aiSearchKey ?? "").trim(), groq: (s.aiGroqKey ?? "").trim(), jina: (s.jinaKey ?? "").trim() };
  if (blob.openrouter || blob.groq || blob.jina) {
    const merged: Keys = {
      openrouter: keys.openrouter || blob.openrouter,
      groq: keys.groq || blob.groq,
      jina: keys.jina || blob.jina,
    };
    writeKeys(merged, profileId, linked);
    s = { ...s, aiSearchKey: "", aiGroqKey: "", jinaKey: "" };
    persistEffective(s, profileId, linked);
    return { s, keys: merged };
  }
  return { s, keys };
}

/** lib/ai-models aiKey(settings) with the Keychain keys. */
function activeKey(s: Settings, keys: Keys): string {
  return s.aiSearchProvider === "groq" ? keys.groq : keys.openrouter;
}

/** A saved key as the settings row may show it: never the key, only its last four characters. */
function masked(key: string): string | null {
  const k = key.trim();
  if (!k) return null;
  return k.length > 8 ? `••••${k.slice(-4)}` : "••••";
}

function tabOf(s: Settings): AiProviderTab {
  return s.aiSearchProvider === "groq" ? "groq" : "openrouter";
}

type ModelRow = { id: string; label: string; provider: string; providerName: string; free: boolean; recommended: boolean };

function modelRow(m: AiModel): ModelRow {
  return { id: m.id, label: m.label, provider: m.provider, providerName: PROVIDER_NAME[m.provider], free: !!m.free, recommended: !!m.recommended };
}

/**
 * What the Search screen and the settings panel draw: the provider tab, the model on screen
 * (ai-search-section renderedModel), its label and maker (ai-picks-header), and which keys exist.
 */
export function state(profileId: string, linked: boolean) {
  const { s, keys } = load(profileId, linked);
  const tab = tabOf(s);
  const model = s.aiSearchModel ?? "";
  const rendered = migrateModelId(model || (tab === "groq" ? GROQ_MODELS[0].id : DEFAULT_AI_MODEL));
  const provider = providerForModel(model);
  return {
    tab,
    model: rendered,
    // ai-search-section.tsx: modelLabelFor(settings.aiSearchModel) / providerForModel(settings.aiSearchModel).
    label: modelLabelFor(model),
    provider,
    providerName: PROVIDER_NAME[provider],
    /** search-overlay.tsx: the AI button shows when either key is saved. */
    anyKey: !!(keys.openrouter.trim() || keys.groq.trim()),
    /** ai-search-section.tsx hasKey: the chosen provider's key. */
    hasKey: !!activeKey(s, keys).trim(),
    saved: { openrouter: masked(keys.openrouter), groq: masked(keys.groq), jina: masked(keys.jina) },
    webSearch: !!s.aiWebSearch,
  };
}

/**
 * ai-mode-button.tsx allModels (Groq's list only with a Groq key) and ai-search-section.tsx's
 * per-tab lists, each pruned to what the provider still serves (ai-live-models pruneToCatalog).
 */
export async function models(profileId: string, linked: boolean) {
  const { keys } = load(profileId, linked);
  const [or, groq] = await Promise.all([
    fetchOpenRouterCatalog().catch(() => null),
    keys.groq.trim() ? fetchGroqCatalog(keys.groq).catch(() => null) : Promise.resolve(null),
  ]);
  const openrouter = pruneToCatalog(AI_MODELS, or).map(modelRow);
  const groqModels = pruneToCatalog(GROQ_MODELS, groq).map(modelRow);
  return {
    openrouter,
    groq: groqModels,
    menu: [...(keys.groq.trim() ? groqModels : []), ...openrouter],
    defaults: { openrouter: DEFAULT_AI_MODEL, groq: groqModels[0]?.id ?? GROQ_MODELS[0].id },
  };
}

/** ai-search-section.tsx KeyField onSave: `update({ aiSearchKey: draft.trim() })` (or aiGroqKey / jinaKey). */
export function saveKey(slot: KeySlot, value: string, profileId: string, linked: boolean) {
  const { keys } = load(profileId, linked);
  if (slot === "openrouter" || slot === "groq" || slot === "jina") {
    writeKeys({ ...keys, [slot]: (value ?? "").trim() }, profileId, linked);
  }
  return state(profileId, linked);
}

/** ai-search-section.tsx setTab: keep the model when it belongs to the tab, else the tab's default. */
export async function setProvider(tab: AiProviderTab, profileId: string, linked: boolean) {
  const { s, keys } = load(profileId, linked);
  const v: AiProviderTab = tab === "groq" ? "groq" : "openrouter";
  if (v !== tabOf(s)) {
    const model = s.aiSearchModel ?? "";
    let next = model;
    if (providerTabFor(model) !== v) {
      if (v === "groq") {
        const catalog = keys.groq.trim() ? await fetchGroqCatalog(keys.groq).catch(() => null) : null;
        next = pruneToCatalog(GROQ_MODELS, catalog)[0].id;
      } else {
        next = DEFAULT_AI_MODEL;
      }
    }
    patchSettings({ aiSearchProvider: v, aiSearchModel: next }, profileId, linked);
  }
  return state(profileId, linked);
}

/**
 * ai-search-section.tsx setModel (`tab` given: the settings panel keeps its tab) and
 * search-overlay.tsx onSelectModel (`tab` null: the model's own provider, providerTabFor).
 */
export function setModel(id: string, tab: AiProviderTab | null, profileId: string, linked: boolean) {
  const model = (id ?? "").trim();
  if (model) {
    const provider: AiProviderTab = tab === "groq" || tab === "openrouter" ? tab : providerTabFor(model);
    patchSettings({ aiSearchModel: model, aiSearchProvider: provider }, profileId, linked);
  }
  return state(profileId, linked);
}

/** ai-search-section.tsx "Use live web context" (aiWebSearch). */
export function setWebSearch(on: boolean, profileId: string, linked: boolean) {
  patchSettings({ aiWebSearch: !!on }, profileId, linked);
  return state(profileId, linked);
}

type WireMeta = {
  id: string;
  type: string;
  name: string;
  poster?: string;
  background?: string;
  logo?: string;
  description?: string;
  releaseInfo?: string;
  imdbRating?: string;
  genres?: string[];
};

/** The Meta fields ai-result-list.tsx draws, in the shape Swift's Meta decodes. */
function wire(m: Meta): WireMeta {
  const str = (v: unknown) => (typeof v === "string" && v.trim() ? v : undefined);
  const rating = typeof m.imdbRating === "number" ? String(m.imdbRating) : str(m.imdbRating);
  return {
    id: m.id,
    type: m.type,
    name: m.name ?? "",
    poster: str(m.poster),
    background: str(m.background),
    logo: str(m.logo),
    description: str(m.description),
    releaseInfo: str(releaseText(m.releaseInfo)),
    imdbRating: rating,
    genres: Array.isArray(m.genres) ? m.genres.filter((g): g is string => typeof g === "string") : undefined,
  };
}

export type AiRun =
  | { status: "done"; query: string; results: Array<{ meta: WireMeta; season?: number; episode?: number; episodeTitle?: string }> }
  | { status: "error"; query: string; message: string; detail?: string }
  | { status: "nokey"; query: string; message: string };

function errorOf(e: unknown): AiErrorDescriptor {
  if (e instanceof AiSearchError) {
    return { messageKey: e.messageKey, ...(e.values ? { values: e.values } : {}), ...(e.detail ? { detail: e.detail } : {}) };
  }
  const detail = e instanceof Error ? e.message : typeof e === "string" ? e : undefined;
  return { messageKey: "AI search failed.", ...(detail ? { detail } : {}) };
}

/**
 * use-ai-suggest.ts run(): live web context when aiWebSearch is on (Jina Reader, failures
 * ignored), the model's picks, then each pick resolved against Cinemeta (resolveAiSuggestions).
 */
export async function run(query: string, profileId: string, linked: boolean): Promise<AiRun> {
  const q = (query ?? "").trim();
  const { s, keys } = load(profileId, linked);
  const key = activeKey(s, keys);
  if (!key.trim()) {
    // ai-search-section.tsx: no key for the chosen provider.
    return {
      status: "nokey",
      query: q,
      message: s.aiSearchProvider === "groq"
        ? t("Add your Groq API key in Settings, AI search to use this model.")
        : t("Add your OpenRouter API key in Settings, AI search to use this model."),
    };
  }
  if (!q) return { status: "done", query: q, results: [] };
  try {
    let webContext: string | undefined;
    if (s.aiWebSearch) {
      try {
        const { context } = await enrichWithContent(q, keys.jina);
        webContext = context || undefined;
      } catch {
        webContext = undefined;
      }
    }
    const suggestions = await aiSuggest(key, s.aiSearchModel ?? "", s.aiSearchProvider === "groq", q, webContext);
    if (suggestions.length === 0) return { status: "done", query: q, results: [] };
    const resolved: AiResult[] = await resolveAiSuggestions(suggestions);
    return {
      status: "done",
      query: q,
      results: resolved.map((r) => ({
        meta: wire(r.meta),
        ...(r.season != null ? { season: r.season } : {}),
        ...(r.episode != null ? { episode: r.episode } : {}),
        ...(r.episodeTitle ? { episodeTitle: r.episodeTitle } : {}),
      })),
    };
  } catch (e) {
    const err = errorOf(e);
    // ai-search-section.tsx: t(error.messageKey, error.values), then the provider's detail.
    return { status: "error", query: q, message: t(err.messageKey, err.values), ...(err.detail ? { detail: err.detail } : {}) };
  }
}
