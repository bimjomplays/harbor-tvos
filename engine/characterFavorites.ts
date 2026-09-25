// lib/character-favorites.tsx without React: the provider's per-profile map under
// `harbor.charfavorites.v1.<profile>` (the same key and entry shape, so the desktop Favorites tab
// and profile export read what the TV writes). bp-anime-characters.tsx toggles it on Select.

export type CharacterEntry = { id: string; name: string; image?: string; addedAt: number };
type CharacterInput = { id: string; name?: string; image?: string };

const PREFIX = "harbor.charfavorites.v1.";
const keyFor = (pid: string) => PREFIX + pid;

function readMap(key: string): Map<string, CharacterEntry> {
  const map = new Map<string, CharacterEntry>();
  try {
    const raw = localStorage.getItem(key);
    if (!raw) return map;
    const arr = JSON.parse(raw);
    if (!Array.isArray(arr)) return map;
    for (const el of arr) {
      if (el && typeof el.id === "string") {
        map.set(el.id, {
          id: el.id,
          name: typeof el.name === "string" ? el.name : "",
          image: typeof el.image === "string" ? el.image : undefined,
          addedAt: typeof el.addedAt === "number" ? el.addedAt : 0,
        });
      }
    }
  } catch {
    return new Map();
  }
  return map;
}

function writeMap(key: string, map: Map<string, CharacterEntry>): void {
  try {
    localStorage.setItem(key, JSON.stringify([...map.values()]));
  } catch {
    return;
  }
}

/** CharacterFavoritesProvider `pid = activeId ?? "default"`. */
function pidOf(profileId: string | null | undefined): string {
  return profileId || "default";
}

/** The favourited character ids (store.ids). */
export function ids(profileId: string | null): string[] {
  return [...readMap(keyFor(pidOf(profileId))).keys()];
}

/** store.count: what the Library's Favorites tab says lives on the desktop. */
export function count(profileId: string | null): number {
  return readMap(keyFor(pidOf(profileId))).size;
}

/** store.toggle: adds (stamped now) or removes; answers whether the character is a favourite now. */
export function toggle(profileId: string | null, input: CharacterInput): boolean {
  if (!input || typeof input.id !== "string" || !input.id) return false;
  const key = keyFor(pidOf(profileId));
  const next = readMap(key);
  let on: boolean;
  if (next.has(input.id)) {
    next.delete(input.id);
    on = false;
  } else {
    next.set(input.id, { id: input.id, name: input.name ?? "", image: input.image, addedAt: Date.now() });
    on = true;
  }
  writeMap(key, next);
  return on;
}
