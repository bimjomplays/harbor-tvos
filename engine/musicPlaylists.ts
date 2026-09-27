// Harbor's own playlists (Stage 12 leftovers batch). Upstream keeps these in the Rust music
// database (src-tauri/src/music/library.rs: list_playlists / create_playlist / rename_playlist /
// delete_playlist / add_tracks_to_playlist / reorder_playlist / remove_from_playlist) behind Tauri
// commands (src/lib/music/library.ts), read everywhere through music-playlist-picker.tsx's "Add to
// playlist" and shown in components/music/music-library.tsx's "Playlists" view. tvOS has no SQLite
// database for this (as it has none for liked tracks or recents either, engine/music.ts LIKED_KEY /
// RECENTS_KEY), so the TV keeps the same playlists, with their tracks, in engine storage. Not
// ported: M3U import/export (music-library.tsx importMusicM3u/exportMusicM3u), which needs a file
// picker tvOS has no user-visible file system for.
import type { MusicTrack } from "@/lib/music/types";
import * as src from "./musicSources";

const PLAYLISTS_KEY = "harbor.music.playlists.v1";
const NAME_MAX = 100;
const NOT_FOUND = "Music playlist was not found";

export type MusicPlaylist = { id: string; name: string; createdAt: string; updatedAt: string; tracks: MusicTrack[] };

/** A track as it is stored: artwork without Subsonic / Plex credentials (music.ts atRest). */
function atRest(track: MusicTrack): MusicTrack {
  if (!track.artwork) return track;
  const artwork = src.artworkAtRest(track.artwork);
  return artwork === track.artwork ? track : { ...track, artwork };
}
/** A stored track for the room: its artwork signed again with today's credentials. */
function forDisplay(track: MusicTrack): MusicTrack {
  if (!track.artwork) return track;
  const artwork = src.artworkForDisplay(track.artwork);
  return artwork === track.artwork ? track : { ...track, artwork };
}

function readAll(): MusicPlaylist[] {
  try {
    const parsed = JSON.parse(localStorage.getItem(PLAYLISTS_KEY) ?? "[]") as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed
      .filter((x): x is MusicPlaylist => !!x && typeof x === "object" && typeof (x as MusicPlaylist).id === "string" && typeof (x as MusicPlaylist).name === "string")
      .map((p) => ({ id: p.id, name: p.name, createdAt: p.createdAt ?? "0", updatedAt: p.updatedAt ?? p.createdAt ?? "0", tracks: Array.isArray(p.tracks) ? p.tracks.map(atRest) : [] }));
  } catch {
    return [];
  }
}
function writeAll(list: MusicPlaylist[]): void {
  try {
    localStorage.setItem(PLAYLISTS_KEY, JSON.stringify(list.map((p) => ({ ...p, tracks: p.tracks.map(atRest) }))));
  } catch {
    /* a full store must not stop playback */
  }
}
function forRoom(p: MusicPlaylist): MusicPlaylist {
  return { ...p, tracks: p.tracks.map(forDisplay) };
}
/** library.rs valid_playlist_name */
function validName(name: string): string {
  const trimmed = name.trim();
  if (!trimmed || trimmed.length > NAME_MAX) throw new Error(`Playlist name must be between 1 and ${NAME_MAX} characters`);
  return trimmed;
}
function require_(list: MusicPlaylist[], id: string): MusicPlaylist {
  const found = list.find((p) => p.id === id);
  if (!found) throw new Error(NOT_FOUND);
  return found;
}

/** library.rs list_playlists: newest activity first, then name. */
export function listPlaylists(): MusicPlaylist[] {
  return readAll()
    .slice()
    .sort((a, b) => Number(b.updatedAt) - Number(a.updatedAt) || a.name.localeCompare(b.name))
    .map(forRoom);
}

/** library.rs create_playlist */
export function createPlaylist(name: string): MusicPlaylist {
  const trimmed = validName(name);
  const now = Date.now().toString();
  const playlist: MusicPlaylist = { id: crypto.randomUUID(), name: trimmed, createdAt: now, updatedAt: now, tracks: [] };
  const list = readAll();
  list.push(playlist);
  writeAll(list);
  return forRoom(playlist);
}

/** library.rs rename_playlist */
export function renamePlaylist(playlistId: string, name: string): MusicPlaylist {
  const trimmed = validName(name);
  const list = readAll();
  const playlist = require_(list, playlistId);
  playlist.name = trimmed;
  playlist.updatedAt = Date.now().toString();
  writeAll(list);
  return forRoom(playlist);
}

/** library.rs delete_playlist */
export function deletePlaylist(playlistId: string): void {
  const list = readAll();
  require_(list, playlistId);
  writeAll(list.filter((p) => p.id !== playlistId));
}

/** library.rs add_tracks_to_playlist: INSERT OR IGNORE, a track already in the playlist is skipped. */
export function addTracksToPlaylist(playlistId: string, tracks: MusicTrack[]): MusicPlaylist {
  const list = readAll();
  const playlist = require_(list, playlistId);
  const already = new Set(playlist.tracks.map((t) => t.id));
  for (const track of tracks) {
    if (already.has(track.id)) continue;
    already.add(track.id);
    playlist.tracks.push(atRest(track));
  }
  playlist.updatedAt = Date.now().toString();
  writeAll(list);
  return forRoom(playlist);
}
/** library.rs add_to_playlist */
export function addToPlaylist(playlistId: string, track: MusicTrack): MusicPlaylist {
  return addTracksToPlaylist(playlistId, [track]);
}

/** library.rs remove_from_playlist */
export function removeFromPlaylist(playlistId: string, trackId: string): MusicPlaylist {
  const list = readAll();
  const playlist = require_(list, playlistId);
  playlist.tracks = playlist.tracks.filter((t) => t.id !== trackId);
  playlist.updatedAt = Date.now().toString();
  writeAll(list);
  return forRoom(playlist);
}

/**
 * library.rs reordered: the order after moving one track to a new index. Pulled out on its own so
 * the index arithmetic (the part that is easy to get wrong) can be tested without a playlist.
 */
export function reorderedTracks(tracks: MusicTrack[], trackId: string, toIndex: number): MusicTrack[] {
  const from = tracks.findIndex((t) => t.id === trackId);
  if (from < 0) return tracks;
  const next = tracks.slice();
  const [moved] = next.splice(from, 1);
  const to = Math.max(0, Math.min(toIndex, next.length));
  next.splice(to, 0, moved);
  return next;
}

/** library.rs reorder_playlist */
export function reorderPlaylist(playlistId: string, trackId: string, toIndex: number): MusicPlaylist {
  const list = readAll();
  const playlist = require_(list, playlistId);
  playlist.tracks = reorderedTracks(playlist.tracks, trackId, toIndex);
  playlist.updatedAt = Date.now().toString();
  writeAll(list);
  return forRoom(playlist);
}
