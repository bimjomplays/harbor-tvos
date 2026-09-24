//! Drives the torrent C ABI the way the app does, with no network: start (DHT and inbound off),
//! add a local .torrent whose data is already on disk, read a byte range from the loopback
//! stream server, stats, remove with data, shutdown. One test so the global engine is never
//! shared between parallel test threads.
use std::ffi::{c_char, CStr, CString};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use harbor_ffi::harbor_string_free;
use harbor_ffi::torrent::ffi::*;
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

fn temp_dir(tag: &str) -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("harbor-torrent-{tag}-{}-{nanos}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A plain HTTP/1.1 request to the loopback server; returns (status, headers, body).
fn http(port: u16, method: &str, path: &str, range: Option<&str>) -> (u16, String, Vec<u8>) {
    let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let mut req = format!("{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n");
    if let Some(r) = range {
        req.push_str(&format!("Range: {r}\r\n"));
    }
    req.push_str("\r\n");
    s.write_all(req.as_bytes()).unwrap();
    let mut raw = Vec::new();
    s.read_to_end(&mut raw).unwrap();
    let split = raw.windows(4).position(|w| w == b"\r\n\r\n").expect("no header end");
    let head = String::from_utf8_lossy(&raw[..split]).to_string();
    let body = raw[split + 4..].to_vec();
    let status: u16 = head.split_whitespace().nth(1).unwrap().parse().unwrap();
    (status, head.to_ascii_lowercase(), body)
}

fn make_torrent(content: &Path) -> (Vec<u8>, String) {
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    rt.block_on(async {
        let t = librqbit::create_torrent(
            content,
            librqbit::CreateTorrentOptions { name: None, piece_length: Some(16384) },
        )
        .await
        .unwrap();
        (t.as_bytes().unwrap().to_vec(), t.info_hash().as_string())
    })
}

#[test]
fn torrent_engine_start_add_stream_stop_shutdown() {
    // Nothing running yet: shutdown is a no-op, everything else says the engine is not ready.
    assert_eq!(take(harbor_torrent_shutdown(true))["ok"], true);
    assert_eq!(take(harbor_torrent_status())["ready"], false);
    let hash0 = cstr("0123456789abcdef0123456789abcdef01234567");
    assert!(take(unsafe { harbor_torrent_stats(hash0.as_ptr(), -1) })["error"].is_string());
    assert!(take(unsafe { harbor_torrent_select(hash0.as_ptr(), 0) })["error"].is_string());
    let bad = cstr("{\"infoHash\": \"0123456789abcdef0123456789abcdef01234567\"}");
    assert!(take(unsafe { harbor_torrent_add(bad.as_ptr()) })["error"].is_string());
    assert!(take(unsafe { harbor_torrent_start(std::ptr::null()) })["error"].is_string());
    let not_json = cstr("{");
    assert!(take(unsafe { harbor_torrent_start(not_json.as_ptr()) })["error"].is_string());

    // Start offline; a leftover from an "earlier run" is swept.
    let dir = temp_dir("cache");
    std::fs::write(dir.join("leftover.bin"), b"stale").unwrap();
    let config = cstr(&serde_json::json!({ "dir": dir, "dht": false, "listen": false, "retentionHours": 12, "maxGb": 10 }).to_string());
    let status = take(unsafe { harbor_torrent_start(config.as_ptr()) });
    assert_eq!(status["ready"], true, "{status}");
    let port = status["port"].as_u64().unwrap() as u16;
    assert!(port > 0);
    assert!(!dir.join("leftover.bin").exists(), "startup sweep keeps leftovers");
    // Starting again returns the running engine.
    let again = take(unsafe { harbor_torrent_start(config.as_ptr()) });
    assert_eq!(again["port"].as_u64(), Some(port as u64));
    let (code, _, body) = http(port, "GET", "/health", None);
    assert_eq!((code, body.as_slice()), (200, &b"ok"[..]));

    // A two-file torrent whose data is already where the engine will look for it.
    let src = temp_dir("src");
    let content = src.join("Show");
    std::fs::create_dir_all(&content).unwrap();
    let video: Vec<u8> = (0..300_000u32).map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8).collect();
    std::fs::write(content.join("Show.S01E02.mkv"), &video).unwrap();
    std::fs::write(content.join("sample.txt"), b"not the video").unwrap();
    let (torrent, hash) = make_torrent(&content);
    let torrent_path = src.join("show.torrent");
    std::fs::write(&torrent_path, &torrent).unwrap();
    // An explicit output folder holds the files directly (no torrent-name subfolder).
    let placed = dir.join(&hash);
    std::fs::create_dir_all(&placed).unwrap();
    std::fs::write(placed.join("Show.S01E02.mkv"), &video).unwrap();
    std::fs::write(placed.join("sample.txt"), b"not the video").unwrap();

    // No fileIdx: the engine narrows to the largest file, like upstream.
    let req = cstr(&serde_json::json!({ "torrentPath": torrent_path, "trackers": [] }).to_string());
    let added = take(unsafe { harbor_torrent_add(req.as_ptr()) });
    assert!(added["error"].is_null(), "{added}");
    assert_eq!(added["info_hash"], hash.as_str());
    assert_eq!(added["already_managed"], false);
    let files = added["files"].as_array().unwrap();
    assert_eq!(files.len(), 2);
    let idx = added["file_idx"].as_u64().unwrap() as usize;
    assert_eq!(files[idx]["name"], "Show.S01E02.mkv");
    assert_eq!(files[idx]["length"], video.len() as u64);
    let url = added["stream_url"].as_str().unwrap();
    assert_eq!(url, format!("http://127.0.0.1:{port}/stream/{hash}/{idx}"));

    // Adding the same torrent again reports it as already managed.
    let again = take(unsafe { harbor_torrent_add(req.as_ptr()) });
    assert_eq!(again["already_managed"], true, "{again}");
    let chash = cstr(&hash);
    assert_eq!(take(unsafe { harbor_torrent_select(chash.as_ptr(), idx as i64) })["ok"], true);

    // mpv's requests: HEAD, then byte ranges.
    let path = format!("/stream/{hash}/{idx}");
    let (code, head, body) = http(port, "GET", &path, Some("bytes=100000-100999"));
    assert_eq!(code, 206, "{head}");
    assert!(head.contains(&format!("content-range: bytes 100000-100999/{}", video.len())), "{head}");
    assert_eq!(body, video[100_000..101_000]);
    let (code, head, _) = http(port, "HEAD", &path, None);
    assert_eq!(code, 200);
    assert!(head.contains(&format!("content-length: {}", video.len())), "{head}");
    assert!(head.contains("content-type: video/x-matroska"), "{head}");
    let (code, _, body) = http(port, "GET", &path, Some(&format!("bytes={}-", video.len() - 10)));
    assert_eq!((code, body.as_slice()), (206, &video[video.len() - 10..]));
    let (code, _, _) = http(port, "GET", &path, Some(&format!("bytes={}-", video.len())));
    assert_eq!(code, 416);
    let (code, _, _) = http(port, "GET", "/stream/0123456789abcdef0123456789abcdef01234567/0", None);
    assert_eq!(code, 404);

    let stats = take(unsafe { harbor_torrent_stats(chash.as_ptr(), idx as i64) });
    assert!(stats["error"].is_null(), "{stats}");
    assert_eq!(stats["streamLen"], video.len() as u64);
    assert_eq!(stats["streamProgress"], video.len() as u64);
    assert_eq!(stats["peers"], 0);
    assert_eq!(take(harbor_torrent_status())["active_torrents"], 1);

    // Stop: the torrent and its data go.
    assert_eq!(take(unsafe { harbor_torrent_remove(chash.as_ptr(), true) })["ok"], true);
    assert!(!dir.join(&hash).exists(), "torrent data survives removal");
    assert_eq!(take(harbor_torrent_status())["active_torrents"], 0);
    assert!(take(unsafe { harbor_torrent_stats(chash.as_ptr(), -1) })["error"].is_string());

    // Shutdown, then the engine can start again on the same folder.
    assert_eq!(take(harbor_torrent_shutdown(true))["ok"], true);
    assert_eq!(take(harbor_torrent_status())["ready"], false);
    let restarted = take(unsafe { harbor_torrent_start(config.as_ptr()) });
    assert_eq!(restarted["ready"], true, "{restarted}");
    assert_eq!(take(harbor_torrent_shutdown(true))["ok"], true);

    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_dir_all(&src);
}
