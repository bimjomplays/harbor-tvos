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
const inflight = new Map<string, Promise<{ kind: PollResult["kind"]; message?: string; username?: string | null }>>();

/** One poll step; the native side owns the cadence. Concurrent calls for one code share a request. */
export function poll(deviceCode: string): Promise<{ kind: PollResult["kind"]; message?: string; username?: string | null }> {
  const running = inflight.get(deviceCode);
  if (running) return running;
  const device = codes.get(deviceCode) ?? { deviceCode, userCode: "", verificationUrl: "", expiresIn: 60, pollIntervalSec: 5 };
  const p = new Promise<{ kind: PollResult["kind"]; message?: string; username?: string | null }>((resolve) => {
    let settled = false;
    const done = (v: { kind: PollResult["kind"]; message?: string; username?: string | null }) => { if (!settled) { settled = true; resolve(v); } };
    // pollForToken only reports non-pending results; a silent 8 s means "ask again later".
    const timer = setTimeout(() => { handle.cancel(); done({ kind: "pending" }); }, 8000);
    const handle = pollForToken({ ...device, expiresIn: 30, pollIntervalSec: 9999 }, (r) => {
      clearTimeout(timer);
      handle.cancel();
      if (r.kind === "authorized") {
        completeAuthorization(r.session).then((s) => done({ kind: "authorized", username: s.username })).catch(() => done({ kind: "authorized", username: null }));
      } else if (r.kind === "error") done({ kind: "error", message: r.message });
      else done({ kind: r.kind });
    });
  }).finally(() => inflight.delete(deviceCode));
  inflight.set(deviceCode, p);
  return p;
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
