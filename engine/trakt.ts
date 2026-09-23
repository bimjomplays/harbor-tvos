// Trakt (Stage 5 slice): device-code sign-in through Harbor's token proxy, session in the
// secret store (Keychain on tvOS), scrobbles from the player.
import { requestDeviceCode, pollForToken, completeAuthorization, type PollResult } from "@/lib/trakt/device-auth";
import { getSession, setSession, isAuthenticated } from "@/lib/trakt/session";
import { stremioIdToTraktTarget } from "@/lib/trakt/ids";
import { scrobbleStart, scrobblePause, scrobbleStop } from "@/lib/trakt/scrobble";
import type { DeviceCode, TraktSession } from "@/lib/trakt/types";

const codes = new Map<string, DeviceCode>();

export async function deviceCode(): Promise<DeviceCode> {
  const c = await requestDeviceCode();
  codes.set(c.deviceCode, c);
  return c;
}

/** One poll step; the native side owns the cadence. */
export function poll(deviceCode: string): Promise<{ kind: PollResult["kind"]; message?: string; username?: string | null }> {
  const device = codes.get(deviceCode) ?? { deviceCode, userCode: "", verificationUrl: "", expiresIn: 60, pollIntervalSec: 5 };
  return new Promise((resolve) => {
    const handle = pollForToken({ ...device, expiresIn: 30, pollIntervalSec: 9999 }, (r) => {
      handle.cancel();
      if (r.kind === "authorized") {
        completeAuthorization(r.session).then((s) => resolve({ kind: "authorized", username: s.username })).catch(() => resolve({ kind: "authorized", username: null }));
      } else if (r.kind === "error") resolve({ kind: "error", message: r.message });
      else resolve({ kind: r.kind });
    });
    // pollForToken only reports non-pending results; a pending answer means "ask again later".
    setTimeout(() => { handle.cancel(); resolve({ kind: "pending" }); }, 8000);
  });
}

export function status(): { authenticated: boolean; username: string | null } {
  const s: TraktSession | null = getSession();
  return { authenticated: isAuthenticated(), username: s?.username ?? null };
}

export function disconnect(): void {
  setSession(null);
}

export type EpisodeRef = { season: number; episode: number; imdbId?: string | null; imdbSeason?: number | null; imdbEpisode?: number | null; tvdbEpisodeId?: number | null };

/** start / pause / stop with progress 0-100; silently skipped when not connected or unmappable. */
export async function scrobble(action: "start" | "pause" | "stop", metaId: string, episode: EpisodeRef | null, progress: number): Promise<{ sent: boolean; reason?: string }> {
  if (!isAuthenticated()) return { sent: false, reason: "not-connected" };
  const res = stremioIdToTraktTarget(metaId, episode ? {
    season: episode.season, episode: episode.episode,
    imdbId: episode.imdbId ?? undefined, imdbSeason: episode.imdbSeason ?? undefined, imdbEpisode: episode.imdbEpisode ?? undefined,
    tvdbEpisodeId: episode.tvdbEpisodeId ?? undefined,
  } as never : undefined);
  if (!res.ok) return { sent: false, reason: res.reason };
  const p = Math.max(0, Math.min(100, progress));
  try {
    if (action === "start") await scrobbleStart(res.target, p);
    else if (action === "pause") await scrobblePause(res.target, p);
    else await scrobbleStop(res.target, p);
    return { sent: true };
  } catch (e) {
    return { sent: false, reason: (e as Error).message };
  }
}
