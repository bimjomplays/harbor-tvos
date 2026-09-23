// Harbor account session, owned by the bundle (upstream lib/theme-auth + lib/account).
//
// The session lives in upstream's own localStorage keys (`harbor.theme-session.<profile>`),
// which the Swift KeyValueStore routes to the Keychain. Swift only mirrors what this module
// reports and never refreshes a token itself: two refreshers racing on one rotating refresh
// token is how a device signs itself out.
import {
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

export async function login(username: string, password: string): Promise<SessionView> {
  await loginIdentity(username, password);
  return session();
}

export async function register(username: string, password: string): Promise<{ recoveryCode: string; session: SessionView }> {
  const { recoveryCode } = await registerIdentity(username, password);
  return { recoveryCode, session: session() };
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
