#ifndef HARBOR_FFI_H
#define HARBOR_FFI_H

#include <stdbool.h>
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

#endif
