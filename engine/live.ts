// Live TV (Stage 8 slice): playlists in upstream's store, M3U parsed by upstream's scanner.
import { readPlaylists, writePlaylists, type StoredPlaylist } from "@/lib/iptv/playlists-store";
import { parseM3u, groupChannels } from "@/lib/iptv/m3u";
import type { IptvChannel } from "@/lib/iptv/types";

export type LiveGroup = { name: string; channels: Array<Pick<IptvChannel, "id" | "name" | "logo" | "url" | "group" | "tvgId">> };

export function playlists(): StoredPlaylist[] {
  return readPlaylists();
}

export function addPlaylist(name: string, url: string): StoredPlaylist {
  const trimmed = url.trim();
  const entry: StoredPlaylist = { id: `pl_${Date.now().toString(36)}`, name: name.trim() || trimmed, url: trimmed, kind: "m3u" };
  writePlaylists([...readPlaylists().filter((p) => p.url !== trimmed), entry]);
  return entry;
}

export function removePlaylist(id: string): void {
  writePlaylists(readPlaylists().filter((p) => p.id !== id));
}

const MAX_CHANNELS = 4000;

/** Fetches and parses one playlist into groups (group-title order of first appearance). */
export async function channels(playlistId: string): Promise<{ groups: LiveGroup[]; total: number; truncated: boolean }> {
  const pl = readPlaylists().find((p) => p.id === playlistId);
  if (!pl) throw new Error("playlist not found");
  const res = await fetch(pl.url, { headers: { Accept: "*/*" } });
  if (!res.ok) throw new Error(`playlist ${res.status}`);
  const text = await res.text();
  const all = parseM3u(text, pl.id);
  const kept = all.slice(0, MAX_CHANNELS);
  const grouped = groupChannels(kept);
  const groups: LiveGroup[] = [];
  for (const [name, list] of grouped) {
    groups.push({ name, channels: list.map((c) => ({ id: c.id, name: c.name, logo: c.logo, url: c.url, group: c.group, tvgId: c.tvgId })) });
  }
  return { groups, total: all.length, truncated: all.length > kept.length };
}
