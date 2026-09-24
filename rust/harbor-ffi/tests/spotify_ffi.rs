//! Drives the Spotify C ABI the way the app does, with no network: everything before a sign-in,
//! the connect failure paths that never reach Spotify, and the PCM read the audio thread makes.
//! One test so the global player state is never shared between parallel test threads.
#![cfg(feature = "spotify")]
use std::ffi::{c_char, CStr, CString};

use harbor_ffi::harbor_string_free;
use harbor_ffi::spotify::ffi::*;
use serde_json::Value;

fn take(p: *mut c_char) -> Value {
    assert!(!p.is_null());
    let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_owned();
    unsafe { harbor_string_free(p) };
    serde_json::from_str(&s).unwrap_or_else(|e| panic!("not JSON ({e}): {s}"))
}

fn cstr(s: &str) -> CString {
    CString::new(s).unwrap()
}

fn error(v: &Value) -> String {
    v["error"].as_str().unwrap_or_else(|| panic!("expected an error: {v}")).to_string()
}

fn connect(json: &str) -> Value {
    let request = cstr(json);
    take(unsafe { harbor_spotify_connect(request.as_ptr()) })
}

#[test]
fn spotify_ffi_before_and_without_a_session() {
    // Nothing signed in: a disconnected status that never claims Premium (mod.rs snapshot).
    let status = take(harbor_spotify_status());
    assert_eq!(status["connected"], false);
    assert_eq!(status["premium"], false);
    assert!(status["accountType"].is_null());
    assert!(status.get("credentials").is_none());
    let events = take(harbor_spotify_events());
    assert_eq!(events["events"], Value::Array(vec![]));
    assert_eq!(events["connected"], false);

    // Playback without a session asks for a Premium sign-in (control.rs CONNECT_BEFORE_PLAY);
    // a malformed URI is caught before that (player.rs play).
    let uri = cstr("spotify:track:4uLU6hMCjMI75M1A2tKUQC");
    assert_eq!(
        error(&take(unsafe { harbor_spotify_play(uri.as_ptr(), 0.5) })),
        "Connect Spotify Premium before playing this source"
    );
    let bad = cstr("not a uri");
    assert!(error(&take(unsafe { harbor_spotify_play(bad.as_ptr(), 0.5) })).starts_with("Invalid Spotify track URI"));
    assert_eq!(
        error(&take(unsafe { harbor_spotify_play(std::ptr::null(), 0.5) })),
        "Spotify track is missing its URI"
    );

    // Transport calls with nothing loaded are harmless no-ops.
    assert_eq!(take(harbor_spotify_pause(true))["ok"], true);
    assert_eq!(take(harbor_spotify_pause(false))["ok"], true);
    assert_eq!(take(harbor_spotify_seek(12.5))["ok"], true);
    assert_eq!(error(&take(harbor_spotify_seek(f64::NAN))), "Music seek position is invalid");
    assert_eq!(take(harbor_spotify_set_volume(0.3))["ok"], true);
    assert_eq!(take(harbor_spotify_stop())["ok"], true);
    assert_eq!(take(harbor_spotify_disconnect())["ok"], true);
    assert_eq!(error(&take(harbor_spotify_session_token())), "Connect Spotify Premium to use Spotify");

    // Connect failures that never touch the network.
    assert_eq!(error(&take(unsafe { harbor_spotify_connect(std::ptr::null()) })), "request_json missing");
    assert!(!error(&connect("{")).is_empty());
    assert_eq!(error(&connect(r#"{"cacheDir": "  ", "accessToken": "t"}"#)), "Spotify cache folder is missing");
    let dir = std::env::temp_dir().join(format!("harbor-spotify-ffi-{}", std::process::id()));
    let dir_json = serde_json::to_string(dir.to_str().unwrap()).unwrap();
    assert_eq!(
        error(&connect(&format!(r#"{{"cacheDir": {dir_json}}}"#))),
        "Connect Spotify Premium before playing this source"
    );
    assert_eq!(
        error(&connect(&format!(r#"{{"cacheDir": {dir_json}, "credentials": "{{broken", "accessToken": "t"}}"#))),
        "Spotify rejected the saved sign in. Connect Spotify again."
    );
    assert_eq!(take(harbor_spotify_status())["connected"], false);

    // The audio thread's read: silence when nothing plays, NULL buffers read nothing.
    let mut left = [7.0f32; 64];
    let mut right = [7.0f32; 64];
    let got = unsafe { harbor_spotify_pcm_read(left.as_mut_ptr(), right.as_mut_ptr(), 64) };
    assert_eq!(got, 0);
    assert!(left.iter().chain(right.iter()).all(|s| *s == 0.0));
    assert_eq!(unsafe { harbor_spotify_pcm_read(std::ptr::null_mut(), right.as_mut_ptr(), 64) }, 0);
    assert_eq!(unsafe { harbor_spotify_pcm_read(left.as_mut_ptr(), right.as_mut_ptr(), 0) }, 0);

    // Whatever the player thread writes comes out de-interleaved.
    harbor_ffi::spotify::ring().push(&[0.25, -0.25, 0.5, -0.5], harbor_ffi::spotify::sink::STALL).unwrap();
    let got = unsafe { harbor_spotify_pcm_read(left.as_mut_ptr(), right.as_mut_ptr(), 64) };
    assert_eq!(got, 2);
    assert_eq!((left[0], left[1], right[0], right[1]), (0.25, 0.5, -0.25, -0.5));
    assert_eq!(left[2], 0.0);
    let _ = std::fs::remove_dir_all(&dir);
}
