#ifndef HARBOR_FFI_H
#define HARBOR_FFI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Every char * returned here is owned by the caller and must be released with
 * harbor_string_free. */

/* harbor-core: parse -> trust -> score -> rank. */
char *harbor_core_version(void);
char *harbor_run_pipeline(const char *streams_json, const char *trust_json, const char *score_json);
void harbor_string_free(char *p);

/* Torrent engine (librqbit, Stage 6; rust/harbor-ffi/src/torrent). Every call blocks until the
 * engine answers, so call them off the main thread. Each returns JSON: the payload on success,
 * {"error": "..."} on failure. */

/* config_json: {"dir": "<download root>", "retentionHours"?: n, "maxGb"?: n, "dht"?: bool,
 * "listen"?: bool, "upnp"?: bool}. Returns the status (see harbor_torrent_status). */
char *harbor_torrent_start(const char *config_json);
/* {"ready", "port", "active_torrents", "last_error", "dht_tier", "dht_nodes"} */
char *harbor_torrent_status(void);
/* request_json: {"magnet"?: s, "infoHash"?: s, "torrentPath"?: s, "trackers"?: [s], "fileIdx"?: n}.
 * Waits for metadata. Returns {"info_hash", "files": [{"idx", "name", "length"}], "stream_base",
 * "already_managed", "file_idx", "stream_url"}. */
char *harbor_torrent_add(const char *request_json);
/* Narrows the torrent to one file. Returns {"ok": true}. */
char *harbor_torrent_select(const char *info_hash, int64_t file_idx);
/* file_idx < 0: whole torrent. Returns {"peers", "unchoked", "downloaded", "downloadSpeed",
 * "streamProgress", "streamLen", "peerSearchRunning", "finished", "state"}. */
char *harbor_torrent_stats(const char *info_hash, int64_t file_idx);
/* Drops a torrent; delete_files also deletes its data. Returns {"ok": true}. */
char *harbor_torrent_remove(const char *info_hash, bool delete_files);
/* Stops the engine and every torrent (deleting their data when delete_files). Returns {"ok": true}. */
char *harbor_torrent_shutdown(bool delete_files);

/* Spotify Premium playback (librespot 0.8, Stage 12; rust/harbor-ffi/src/spotify). JSON out like
 * the torrent calls: the payload on success, {"error": "..."} on failure. connect and
 * session_token block on the network, so call them off the main thread; the others return at once.
 * One track plays at a time; the queue is the app's. */

/* request_json: {"cacheDir": "<private folder under Caches>", "deviceId"?: s, "accessToken"?: s,
 * "credentials"?: "<saved reusable sign-in JSON>"} (saved credentials win over a token).
 * Returns the status plus "credentials": the reusable sign-in to keep in the Keychain. */
char *harbor_spotify_connect(const char *request_json);
/* {"connected", "username", "country", "premium", "accountType", "error"}; accountType is null
 * while the tier is unknown. */
char *harbor_spotify_status(void);
/* Drains the player events: {"events": [{"event": "loading" | "playing" | "paused" | "position" |
 * "end" | "failure", "position"?: seconds heard, "reason"?: s}], "connected": bool}. */
char *harbor_spotify_events(void);
/* uri: "spotify:track:<id>", volume 0...1. Returns {"ok": true}. */
char *harbor_spotify_play(const char *uri, double volume);
char *harbor_spotify_pause(bool paused);
char *harbor_spotify_seek(double seconds);
char *harbor_spotify_set_volume(double volume);
/* Another source takes over. */
char *harbor_spotify_stop(void);
/* Shuts the session down and clears the audio cache; safe when never connected. */
char *harbor_spotify_disconnect(void);
/* A Web API token from the session (login5): {"accessToken", "expiresAt" (unix s), "scopes"}. */
char *harbor_spotify_session_token(void);

/* Decoded Spotify audio: 44.1 kHz stereo float32. For the real-time audio thread (never blocks,
 * locks or allocates): copies up to `frames` frames into left and right (each >= frames floats),
 * pads the rest with silence and returns the frames that were audio. */
#define HARBOR_SPOTIFY_SAMPLE_RATE 44100
size_t harbor_spotify_pcm_read(float *left, float *right, size_t frames);

#endif
