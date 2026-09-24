// Harbor account session, owned by the bundle (upstream lib/theme-auth + lib/account).
//
// The session lives in upstream's own localStorage keys (`harbor.theme-session.<profile>`),
// which the Swift KeyValueStore routes to the Keychain. Swift only mirrors what this module
// reports and never refreshes a token itself: two refreshers racing on one rotating refresh
// token is how a device signs itself out.
import {
  applyAuthResult,
  authToken,
  captureSessionScope,
  currentAuthor,
  logoutAuthor,
  refreshToken,
  refreshTokenValue,
  subscribeAuthor,
  type Author,
} from "@/lib/theme-auth";
import { loginIdentity, registerIdentity, fetchMe } from "@/lib/account/identity";
import { startSessionRefresh } from "@/lib/account/session-refresh-runner";
import { safeFetch } from "@/lib/safe-fetch";
import { HARBOR_API_BASE } from "@/lib/config/endpoints";

export type SessionView = {
  user: Author;
  token: string;
  /** False for a legacy theme-author login, which profile sync refuses to arm on. */
  hasRefresh: boolean;
} | null;

export function session(): SessionView {
  // captureSessionScope reloads the session when the active profile changed underneath us.
  captureSessionScope();
  const user = currentAuthor();
  const token = authToken();
  if (!user || !token) return null;
  return { user, token, hasRefresh: !!refreshTokenValue() };
}

/**
 * lib/account/client.ts attaches `.status/.code/.reason` to its errors, but only `.message`
 * survives the bridge. Re-throw with everything in the message, as one JSON line the host parses.
 */
function apiError(e: unknown): Error {
  const err = e as { message?: unknown; status?: unknown; code?: unknown; reason?: unknown } | null;
  const out = new Error(
    "harbor-api:" +
      JSON.stringify({
        status: typeof err?.status === "number" ? err.status : 0,
        code: typeof err?.code === "string" ? err.code : null,
        reason: typeof err?.reason === "string" ? err.reason : null,
        message: typeof err?.message === "string" ? err.message : String(e),
      }),
  );
  return out;
}

export async function login(username: string, password: string): Promise<SessionView> {
  try {
    await loginIdentity(username, password);
  } catch (e) {
    throw apiError(e);
  }
  return session();
}

export async function register(username: string, password: string): Promise<{ recoveryCode: string; session: SessionView }> {
  try {
    const { recoveryCode } = await registerIdentity(username, password);
    return { recoveryCode, session: session() };
  } catch (e) {
    throw apiError(e);
  }
}

export async function logout(): Promise<void> {
  await logoutAuthor();
}

/** A bearer for one native request, refreshed first when upstream says it is due. */
export async function token(): Promise<string | null> {
  if (!session()) return null;
  await refreshIfDue();
  return authToken();
}

/** Ask upstream to rotate the token now (it no-ops unless overdue or a 401 said so). */
export async function refreshIfDue(): Promise<boolean> {
  return refreshToken();
}

/**
 * TV hand-off, Harbor step (big-picture/onboarding/bp-handoff-apply.ts): the phone signed in and
 * delivered `{ session, handle, refresh }`; put it where theme-auth reads it. Upstream applies a
 * provisional record with an empty user id and then calls fetchMe, but applyServerUser refuses a
 * user whose id differs from the record's, so the id never fills in and that step always fails.
 * Asking /identity/api/me with the delivered token first and applying the real user is what that
 * code intends. Throws (the phone sees `applyFailed`) when the token does not resolve to a user,
 * and never keeps a session with no user id, which is upstream's own rule.
 */
export async function adopt(token: string, handle: string, refresh: string | null): Promise<SessionView> {
  let res: Response;
  try {
    res = await safeFetch(`${HARBOR_API_BASE}/themes/api/identity/api/me`, {
      headers: { Authorization: `Bearer ${token}` },
    });
  } catch (e) {
    throw apiError(e);
  }
  const d = (await res.json().catch(() => null)) as { user?: { id?: unknown } } | null;
  if (!res.ok || !d?.user || typeof d.user.id !== "string" || !d.user.id) {
    throw apiError({ status: res.status, message: "harbor session did not hydrate" });
  }
  const user = d.user as Parameters<typeof applyAuthResult>[0]["user"];
  applyAuthResult({ token, refresh: refresh || null, user });
  const s = session();
  if (!s || !s.user.id) {
    await logoutAuthor().catch(() => {});
    throw new Error("harbor session did not hydrate");
  }
  // The handle the phone read is informational; the server's user record is the truth.
  void handle;
  return s;
}

export async function reloadUser(): Promise<SessionView> {
  await fetchMe();
  return session();
}

let stopRefresh: (() => void) | null = null;
let stopAuthor: (() => void) | null = null;

/**
 * Start upstream's 6-hour refresh runner and forward every session change to the host as a
 * `harbor:account-changed` window event, so Swift can mirror it without polling.
 */
export function start(): void {
  if (stopRefresh) return;
  stopRefresh = startSessionRefresh();
  stopAuthor = subscribeAuthor(() => {
    window.dispatchEvent(new CustomEvent("harbor:account-changed", { detail: session() }));
  });
}

export function stop(): void {
  stopRefresh?.();
  stopAuthor?.();
  stopRefresh = null;
  stopAuthor = null;
}
