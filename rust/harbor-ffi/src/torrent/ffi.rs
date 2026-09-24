//! C ABI over the torrent engine (declared in include/harbor_ffi.h).
//!
//! Every function blocks the calling thread until the engine answers, so the host calls them
//! off its main thread. Each returns a JSON string the caller owns and releases with
//! `harbor_string_free`: the payload on success, `{"error": "..."}` on failure. No panic
//! crosses the boundary: each entry point catches unwinds and reports them as an error.
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use serde::Serialize;

use super::{AddRequest, EngineConfig};

fn to_c(s: String) -> *mut c_char {
    CString::new(s).unwrap_or_default().into_raw()
}

unsafe fn from_c<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    CStr::from_ptr(p).to_str().ok()
}

fn error_json(e: impl Into<String>) -> String {
    serde_json::json!({ "error": e.into() }).to_string()
}

fn ok_json() -> String {
    serde_json::json!({ "ok": true }).to_string()
}

fn payload<T: Serialize>(r: Result<T, String>) -> String {
    match r {
        Ok(v) => serde_json::to_string(&v).unwrap_or_else(|e| error_json(e.to_string())),
        Err(e) => error_json(e),
    }
}

/// Runs `f`, turning a panic into `{"error": "torrent engine panicked: ..."}`.
fn guarded(f: impl FnOnce() -> String) -> *mut c_char {
    let out = catch_unwind(AssertUnwindSafe(f)).unwrap_or_else(|panic| {
        let why = panic
            .downcast_ref::<&str>()
            .map(|s| s.to_string())
            .or_else(|| panic.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "unknown".to_string());
        error_json(format!("torrent engine panicked: {why}"))
    });
    to_c(out)
}

fn block_on<T>(f: impl std::future::Future<Output = Result<T, String>>) -> Result<T, String> {
    super::runtime()?.block_on(f)
}

/// Starts the engine (or returns the running one's status).
/// `config_json`: `{"dir": String, "retentionHours"?: u64, "maxGb"?: u64, "dht"?: bool,
/// "listen"?: bool, "upnp"?: bool}`. Returns the status object.
#[no_mangle]
pub unsafe extern "C" fn harbor_torrent_start(config_json: *const c_char) -> *mut c_char {
    let raw = from_c(config_json).map(str::to_owned);
    guarded(move || {
        let config: Result<EngineConfig, String> = raw
            .ok_or_else(|| "config_json missing".to_string())
            .and_then(|s| serde_json::from_str(&s).map_err(|e| e.to_string()));
        payload(config.and_then(|c| block_on(super::start(c))))
    })
}

/// `{"ready", "port", "active_torrents", "last_error", "dht_tier", "dht_nodes"}`.
#[no_mangle]
pub extern "C" fn harbor_torrent_status() -> *mut c_char {
    guarded(|| payload(Ok::<_, String>(super::status())))
}

/// Adds a torrent and waits for its metadata (up to 60 s) and file check.
/// `request_json`: `{"magnet"?: String, "infoHash"?: String, "torrentPath"?: String,
/// "trackers"?: [String], "fileIdx"?: i64}`. Returns `{"info_hash", "files": [{"idx", "name",
/// "length"}], "stream_base", "already_managed", "file_idx", "stream_url"}`.
#[no_mangle]
pub unsafe extern "C" fn harbor_torrent_add(request_json: *const c_char) -> *mut c_char {
    let raw = from_c(request_json).map(str::to_owned);
    guarded(move || {
        let req: Result<AddRequest, String> = raw
            .ok_or_else(|| "request_json missing".to_string())
            .and_then(|s| serde_json::from_str(&s).map_err(|e| e.to_string()));
        payload(req.and_then(|r| block_on(super::add(r))))
    })
}

/// Narrows the torrent to one file (upstream torrent_engine_select). Returns `{"ok": true}`.
#[no_mangle]
pub unsafe extern "C" fn harbor_torrent_select(info_hash: *const c_char, file_idx: i64) -> *mut c_char {
    let hash = from_c(info_hash).map(str::to_owned);
    guarded(move || {
        let Some(hash) = hash else { return error_json("info_hash missing") };
        if file_idx < 0 {
            return error_json("file_idx must be >= 0");
        }
        match block_on(super::select(&hash, file_idx as usize)) {
            Ok(()) => ok_json(),
            Err(e) => error_json(e),
        }
    })
}

/// Live numbers for the connecting card. `file_idx < 0` means the whole torrent.
/// Returns `{"peers", "unchoked", "downloaded", "downloadSpeed", "streamProgress", "streamLen",
/// "peerSearchRunning", "finished", "state"}`.
#[no_mangle]
pub unsafe extern "C" fn harbor_torrent_stats(info_hash: *const c_char, file_idx: i64) -> *mut c_char {
    let hash = from_c(info_hash).map(str::to_owned);
    guarded(move || {
        let Some(hash) = hash else { return error_json("info_hash missing") };
        let idx = (file_idx >= 0).then_some(file_idx as usize);
        payload(super::stats(&hash, idx))
    })
}

/// Drops a torrent from the session; `delete_files` also deletes its downloaded data.
/// Returns `{"ok": true}`.
#[no_mangle]
pub unsafe extern "C" fn harbor_torrent_remove(info_hash: *const c_char, delete_files: bool) -> *mut c_char {
    let hash = from_c(info_hash).map(str::to_owned);
    guarded(move || {
        let Some(hash) = hash else { return error_json("info_hash missing") };
        match block_on(super::remove(&hash, delete_files)) {
            Ok(()) => ok_json(),
            Err(e) => error_json(e),
        }
    })
}

/// Stops the engine and every torrent in it (deleting their data when `delete_files`).
/// Safe to call when the engine never started. Returns `{"ok": true}`.
#[no_mangle]
pub extern "C" fn harbor_torrent_shutdown(delete_files: bool) -> *mut c_char {
    guarded(move || match block_on(async {
        super::shutdown(delete_files).await;
        Ok(())
    }) {
        Ok(()) => ok_json(),
        Err(e) => error_json(e),
    })
}
