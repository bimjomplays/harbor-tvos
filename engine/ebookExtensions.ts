// lib/ebook/extensions.ts for the TV bundle (see bundle-config.mjs): upstream keeps eBook extension
// repositories and plugins in IndexedDB and runs each plugin in a Worker. JavaScriptCore on tvOS
// has neither, so the TV lists no repositories and no plugins; the functions that would add one
// fail loudly instead of pretending to succeed.
import type { InstalledPlugin } from "@/lib/manga/plugins/types";

export type EBookPluginManifest = {
  id: string;
  name: string;
  version: string;
  lang: string;
  nsfw: boolean;
  icon?: string;
  entry: string;
};

export type EBookPluginRepo = { name: string; url: string; plugins: EBookPluginManifest[] };

const listeners = new Set<() => void>();
const unsupported = () => new Error("HarborEngine: eBook extensions need a Worker and IndexedDB, which tvOS does not have");

export async function browseEBookRepo(_url: string): Promise<EBookPluginRepo> {
  throw unsupported();
}

/** Resolves at once: there is nothing stored to load on a TV. */
export async function loadEBookExtensions(): Promise<void> {}

export function ebookRepoUrls(): string[] {
  return [];
}

export function installedEBookPlugins(): InstalledPlugin[] {
  return [];
}

export function subscribeEBookExtensions(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export async function addEBookRepo(_url: string): Promise<void> {
  throw unsupported();
}

export async function removeEBookRepo(_url: string): Promise<void> {}

export async function installEBookPlugin(..._args: unknown[]): Promise<void> {
  throw unsupported();
}

export async function setEBookPluginEnabled(_id: string, _enabled: boolean): Promise<void> {}

export async function removeEBookPlugin(_id: string): Promise<void> {}
