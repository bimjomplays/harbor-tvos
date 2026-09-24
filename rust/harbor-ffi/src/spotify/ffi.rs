//! C ABI over the Spotify player (declared in include/harbor_ffi.h), the torrent pattern: JSON
//! out, strings the caller releases with `harbor_string_free`, `{"error": "..."}` on failure, and
//! no panic crosses the boundary.
//!
//! `harbor_spotify_connect` and `harbor_spotify_session_token` block on the network (call them
//! off the main thread). The transport calls only queue a player command and return at once.
//! `harbor_spotify_pcm_read` is for the real-time audio thread: no locks, no allocation.
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

use serde::Serialize;

use super::ConnectRequest;

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

fn done(r: Result<(), String>) -> String {
    match r {
        Ok(()) => ok_json(),
        Err(e) => error_json(e),
    }
}

/// Runs `f`, turning a panic into `{"error": "Spotify panicked: ..."}`.
fn guarded(f: impl FnOnce() -> String) -> *mut c_char {
    let out = catch_unwind(AssertUnwindSafe(f)).unwrap_or_else(|panic| {
        let why = panic
            .downcast_ref::<&str>()
            .map(|s| s.to_string())
            .or_else(|| panic.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "unknown".to_string());
        error_json(format!("Spotify panicked: {why}"))
    });
    to_c(out)
}

/// Signs in and starts the player. `request_json`: `{"cacheDir": String, "deviceId"?: String,
/// "accessToken"?: String, "credentials"?: String}` (saved credentials win over a token).
/// Returns the status (`{"connected", "username", "country", "premium", "accountType", "error",
/// "credentials"?}`); `credentials` is the reusable sign-in to keep in the Keychain.
#[no_mangle]
pub unsafe extern "C" fn harbor_spotify_connect(request_json: *const c_char) -> *mut c_char {
    let raw = from_c(request_json).map(str::to_owned);
    guarded(move || {
        let request: Result<ConnectRequest, String> = raw
            .ok_or_else(|| "request_json missing".to_string())
            .and_then(|s| serde_json::from_str(&s).map_err(|e| e.to_string()));
        payload(request.and_then(|r| super::runtime()?.block_on(super::connect(r))))
    })
}

/// `{"connected", "username", "country", "premium", "accountType", "error"}`.
#[no_mangle]
pub extern "C" fn harbor_spotify_status() -> *mut c_char {
    guarded(|| payload(Ok::<_, String>(super::status())))
}

/// Drains the player events: `{"events": [{"event": "loading" | "playing" | "paused" |
/// "position" | "end" | "failure", "position"?: seconds, "reason"?: String}], "connected": bool}`.
#[no_mangle]
pub extern "C" fn harbor_spotify_events() -> *mut c_char {
    guarded(|| super::events().to_string())
}

/// Plays one track (`spotify:track:<id>`) from the start at `volume` (0...1). Returns `{"ok": true}`.
#[no_mangle]
pub unsafe extern "C" fn harbor_spotify_play(uri: *const c_char, volume: f64) -> *mut c_char {
    let uri = from_c(uri).map(str::to_owned);
    guarded(move || done(super::play(uri.as_deref().unwrap_or(""), volume)))
}

/// Pauses or resumes the current track. Returns `{"ok": true}`.
#[no_mangle]
pub extern "C" fn harbor_spotify_pause(paused: bool) -> *mut c_char {
    guarded(move || {
        super::set_paused(paused);
        ok_json()
    })
}

/// Seeks the current track to `seconds`. Returns `{"ok": true}`.
#[no_mangle]
pub extern "C" fn harbor_spotify_seek(seconds: f64) -> *mut c_char {
    guarded(move || done(super::seek(seconds)))
}

/// Sets the soft volume (0...1). Returns `{"ok": true}`.
#[no_mangle]
pub extern "C" fn harbor_spotify_set_volume(volume: f64) -> *mut c_char {
    guarded(move || {
        super::set_volume(volume);
        ok_json()
    })
}

/// Stops the current track (another source takes over). Returns `{"ok": true}`.
#[no_mangle]
pub extern "C" fn harbor_spotify_stop() -> *mut c_char {
    guarded(|| {
        super::stop();
        ok_json()
    })
}

/// Stops and shuts the session down and clears the audio cache. Safe when never connected.
/// Returns `{"ok": true}`.
#[no_mangle]
pub extern "C" fn harbor_spotify_disconnect() -> *mut c_char {
    guarded(|| {
        super::disconnect();
        ok_json()
    })
}

/// A Web API token from the session (login5). Returns `{"accessToken", "expiresAt" (unix s),
/// "scopes"}`.
#[no_mangle]
pub extern "C" fn harbor_spotify_session_token() -> *mut c_char {
    guarded(|| payload(super::runtime().and_then(|rt| rt.block_on(super::session_token()))))
}

/// Real-time audio thread: copies up to `frames` frames of 44.1 kHz stereo float PCM into `left`
/// and `right` (each at least `frames` long) and pads the rest with silence. Returns the frames
/// that were audio. Never blocks, locks or allocates. NULL buffers read nothing.
#[no_mangle]
pub unsafe extern "C" fn harbor_spotify_pcm_read(left: *mut f32, right: *mut f32, frames: usize) -> usize {
    if left.is_null() || right.is_null() || frames == 0 {
        return 0;
    }
    let left = std::slice::from_raw_parts_mut(left, frames);
    let right = std::slice::from_raw_parts_mut(right, frames);
    catch_unwind(AssertUnwindSafe(|| super::ring().read_planar(left, right))).unwrap_or(0)
}
