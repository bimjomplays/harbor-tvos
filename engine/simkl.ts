// Simkl (Stage 5): PIN sign-in (lib/simkl/device-auth), session in the secret store, scrobbles.
import { requestPin, pollForToken, completeAuthorization } from "@/lib/simkl/device-auth";
import { getSession, setSession, isAuthenticated } from "@/lib/simkl/session";
import { simklScrobble } from "@/lib/simkl/scrobble";
import { loadStoredSettings } from "@/lib/settings/load";
import type { SimklPin } from "@/lib/simkl/types";

const pins = new Map<string, SimklPin>();

/** Same wire shape as trakt.deviceCode so one Swift panel serves both. */
export async function deviceCode(): Promise<{ deviceCode: string; userCode: string; verificationUrl: string; expiresIn: number; pollIntervalSec: number }> {
  const pin = await requestPin();
  pins.set(pin.userCode, pin);
  return { deviceCode: pin.userCode, userCode: pin.userCode, verificationUrl: pin.verificationUrl, expiresIn: pin.expiresIn, pollIntervalSec: pin.pollIntervalSec };
}

type PollOut = { kind: "authorized" | "pending" | "expired" | "error"; message?: string; username?: string | null };
const inflight = new Map<string, Promise<PollOut>>();

/** One poll step; the native side owns the cadence. Concurrent calls for one code share a request. */
export function poll(userCode: string): Promise<PollOut> {
  const running = inflight.get(userCode);
  if (running) return running;
  const pin = pins.get(userCode) ?? { userCode, verificationUrl: "", deepLinkUrl: "", expiresIn: 60, pollIntervalSec: 5 };
  const p = new Promise<PollOut>((resolve) => {
    let settled = false;
    const done = (v: PollOut) => { if (!settled) { settled = true; resolve(v); } };
    const timer = setTimeout(() => { handle.cancel(); done({ kind: "pending" }); }, 8000);
    const handle = pollForToken({ ...pin, expiresIn: 30, pollIntervalSec: 9999 }, (r) => {
      clearTimeout(timer);
      handle.cancel();
      if (r.kind === "authorized") {
        completeAuthorization(r.session).then((s) => done({ kind: "authorized", username: s.username })).catch(() => done({ kind: "authorized", username: null }));
      } else done({ kind: "expired" });
    });
  }).finally(() => inflight.delete(userCode));
  inflight.set(userCode, p);
  return p;
}

export function status(): { authenticated: boolean; username: string | null } {
  return { authenticated: isAuthenticated(), username: getSession()?.username ?? null };
}

export function disconnect(): void {
  setSession(null);
}

export type EpisodeRef = { season: number; episode: number; imdbId?: string | null; imdbSeason?: number | null };

/** start / pause / stop with progress 0-100; honours settings.simklScrobbleEnabled like the hook. */
export async function scrobble(action: "start" | "pause" | "stop", metaId: string, episode: EpisodeRef | null, progress: number, info?: { title?: string; year?: number | null; imdb?: string | null }): Promise<{ sent: boolean; reason?: string }> {
  if (!isAuthenticated()) return { sent: false, reason: "not-connected" };
  if (loadStoredSettings().simklScrobbleEnabled === false) return { sent: false, reason: "disabled" };
  const ep = episode ? { season: episode.season, episode: episode.episode, imdbId: episode.imdbId ?? undefined, imdbSeason: episode.imdbSeason ?? undefined } : undefined;
  const ok = await simklScrobble(action, metaId, ep, Math.max(0, Math.min(100, progress)), { title: info?.title, year: info?.year ?? undefined, imdb: info?.imdb ?? undefined });
  return ok ? { sent: true } : { sent: false, reason: "unmappable-or-failed" };
}
