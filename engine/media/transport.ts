// Replaces lib/media-server/transport.ts inside the bundle: upstream routes home-server HTTP
// through a Tauri command (self-signed certs, CORS); on tvOS NSURLSession does it through
// the host fetch. The two URL helpers stay upstream's (imported from the real file, whose
// Tauri import is stubbed and only used inside the function we replace).
import { normalizeServerOrigin, candidateServerOrigins, type MediaServerResponse } from "../../reference/harbor/src/lib/media-server/transport";

export { normalizeServerOrigin, candidateServerOrigins };
export type { MediaServerResponse };

export async function mediaServerRequest<T>(
  origin: string,
  path: string,
  init: { method?: string; headers?: Record<string, string>; body?: unknown; timeoutMs?: number } = {},
): Promise<MediaServerResponse<T>> {
  const normalized = normalizeServerOrigin(origin);
  const url = new URL(path.replace(/^\/+/, ""), `${normalized}/`);
  if (url.origin !== new URL(normalized).origin) throw new Error("Media server request escaped its configured origin");
  const headers: Record<string, string> = { Accept: "application/json", ...(init.headers ?? {}) };
  if (init.body != null && !headers["Content-Type"]) headers["Content-Type"] = "application/json";
  const response = await fetch(url.toString(), {
    method: init.method ?? "GET",
    headers,
    body: init.body == null ? undefined : JSON.stringify(init.body),
    signal: AbortSignal.timeout(init.timeoutMs ?? 20_000),
  });
  const text = await response.text();
  let body: unknown = text;
  try { body = text ? JSON.parse(text) : null; } catch { /* non-JSON response */ }
  const outHeaders: Record<string, string> = {};
  response.headers.forEach((v, k) => { outHeaders[k] = v; });
  if (response.status < 200 || response.status >= 300) throw new Error(`Media server request failed (${response.status})`);
  return { status: response.status, headers: outHeaders, body: body as T };
}
