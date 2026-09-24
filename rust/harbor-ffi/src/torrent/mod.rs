//! Stage 6 torrent streaming: upstream's librqbit engine (src-tauri/src/torrent_engine.rs)
//! without Tauri. One librqbit `Session` on its own tokio runtime, a loopback HTTP server that
//! mpv reads `http://127.0.0.1:{port}/stream/{hash}/{file}` from, stats, removal and shutdown.
//! `ffi.rs` wraps this in the C ABI declared in include/harbor_ffi.h.
//!
//! What differs from upstream, and why (tvOS has no durable disk and no background running):
//! - No session persistence (session.json / fastresume) and an in-memory DHT: a stream cache is
//!   deleted when playback ends, so there is nothing to resume, and on start whatever an earlier
//!   run left behind is swept (upstream `cache_sweep` with retention 0).
//! - Each torrent downloads into `<dir>/<infohash>/`, so removing one torrent's data is one
//!   directory and two torrents that share a name never collide.
//! - The tier ladder keeps upstream's order (inbound + DHT, then no inbound, then no DHT) with
//!   UPnP off unless the host asks, and the Android TV tuning from `p2p_android.rs` (100 DHT
//!   queries/s, 512 KB/s upload cap, 4 s/10 s peer timeouts): the Apple TV is the same kind of
//!   device on the same kind of Wi-Fi.
//! - The periodic sweep never touches a torrent that is still in the session and unpaused
//!   (a stream mpv is reading); upstream's retention sweep could release it mid-playback.
//! - No LAN server, casting routes, self-test or runtime enable/disable: the app gates P2P on
//!   upstream's settings (`torrentsDisabled`, `directTorrentStream`) before calling in.

mod cache_sweep;
mod dht_boot;
pub mod ffi;
mod stream_route;
mod trackers;

use std::collections::HashSet;
use std::net::SocketAddr;
use std::num::NonZeroU32;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use librqbit::api::TorrentIdOrHash;
use librqbit::dht::Dht;
use librqbit::limits::LimitsConfig;
use librqbit::{
    AddTorrent, AddTorrentOptions, AddTorrentResponse, ManagedTorrent, PeerConnectionOptions,
    Session, SessionOptions,
};
use serde::{Deserialize, Serialize};
use tokio::net::TcpListener;
use tokio::runtime::Runtime;
use tokio::time::timeout;
use tokio_util::sync::CancellationToken;

pub const STOPPED: &str = "torrent engine stopped";
pub const NOT_READY: &str = "engine not ready";

const CACHE_SWEEP_INITIAL_DELAY_SECS: u64 = 60;
const CACHE_SWEEP_INTERVAL_SECS: u64 = 30 * 60;
const FILE_SELECTION_TIMEOUT_SECS: u64 = 12;
// p2p_android.rs: inbound range identical to desktop; TV-class DHT rate and upload cap.
const LISTEN_PORT_RANGE: std::ops::Range<u16> = 16881..16931;
const DHT_QUERIES_PER_SECOND: &str = "100";
const MAX_UPLOAD_BPS: u32 = 512 * 1024;
const PEER_CONNECT_TIMEOUT: Duration = Duration::from_secs(4);
const PEER_READ_WRITE_TIMEOUT: Duration = Duration::from_secs(10);

static CACHE_SWEEP_RUNNING: AtomicBool = AtomicBool::new(false);

struct CacheSweepGuard;

impl Drop for CacheSweepGuard {
    fn drop(&mut self) {
        CACHE_SWEEP_RUNNING.store(false, Ordering::Release);
    }
}

struct CacheSweeper {
    task: tokio::task::JoinHandle<()>,
    cancelled: Arc<AtomicBool>,
}

impl CacheSweeper {
    fn cancel(self) {
        self.cancelled.store(true, Ordering::Release);
        self.task.abort();
    }
}

/// What the host passes to `harbor_torrent_start`.
#[derive(Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct EngineConfig {
    /// Download root; the app passes a folder under Caches.
    pub dir: String,
    /// settings.streamCacheRetentionHours (upstream default 12).
    #[serde(default)]
    pub retention_hours: Option<u64>,
    /// settings.streamCacheMaxGb, already clamped by the host (0 = no cap).
    #[serde(default)]
    pub max_gb: Option<u64>,
    /// Use the DHT (default true). Tests turn it off to stay off the network.
    #[serde(default)]
    pub dht: Option<bool>,
    /// Accept inbound peer connections on 16881..16931 (default true).
    #[serde(default)]
    pub listen: Option<bool>,
    /// Ask the router for a UPnP port mapping (default false on tvOS).
    #[serde(default)]
    pub upnp: Option<bool>,
}

struct EngineState {
    session: Option<Arc<Session>>,
    side_dht: Option<Dht>,
    port: Option<u16>,
    dht_tier: u8,
    dir: Option<PathBuf>,
    ready: bool,
    last_error: Option<String>,
    server: Option<tokio::task::JoinHandle<()>>,
    sweeper: Option<CacheSweeper>,
}

fn engine() -> &'static Mutex<EngineState> {
    static S: OnceLock<Mutex<EngineState>> = OnceLock::new();
    S.get_or_init(|| {
        Mutex::new(EngineState {
            session: None,
            side_dht: None,
            port: None,
            dht_tier: 0,
            dir: None,
            ready: false,
            last_error: None,
            server: None,
            sweeper: None,
        })
    })
}

fn lock_engine() -> std::sync::MutexGuard<'static, EngineState> {
    // A panic while the lock was held (caught at the FFI boundary) must not wedge the engine.
    engine().lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Serialises start and shutdown, like upstream's lifecycle transition lock.
fn transition() -> &'static tokio::sync::Mutex<()> {
    static T: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();
    T.get_or_init(|| tokio::sync::Mutex::new(()))
}

/// The engine's own multi-threaded tokio runtime. It lives for the rest of the process once
/// created (a runtime cannot be dropped from inside itself, and restarting is cheap without it).
pub(crate) fn runtime() -> Result<&'static Runtime, String> {
    static RT: OnceLock<Option<Runtime>> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(3)
            .thread_name("harbor-torrent")
            .enable_all()
            .build()
            .map_err(|e| eprintln!("[torrent-engine] runtime unavailable: {e}"))
            .ok()
    })
    .as_ref()
    .ok_or_else(|| "torrent runtime unavailable".to_string())
}

pub(crate) fn current_session() -> Option<Arc<Session>> {
    lock_engine()
        .session
        .clone()
        .filter(|session| !session.cancellation_token().is_cancelled())
}

fn current_side_dht() -> Option<Dht> {
    lock_engine()
        .side_dht
        .clone()
        .filter(|dht| !dht.cancellation_token().is_cancelled())
}

fn current_port() -> Option<u16> {
    current_session()?;
    lock_engine().port
}

fn current_dir() -> Option<PathBuf> {
    lock_engine().dir.clone()
}

/// upstream `run_session` + `lifecycle::run`: work on a session that has since been stopped (or
/// replaced) fails with STOPPED instead of acting on a dead engine.
pub(crate) async fn run_session<T>(
    session: &Arc<Session>,
    future: impl std::future::Future<Output = Result<T, String>>,
) -> Result<T, String> {
    let current = current_session().ok_or_else(|| STOPPED.to_string())?;
    if !Arc::ptr_eq(&current, session) {
        return Err(STOPPED.to_string());
    }
    let cancellation = session.cancellation_token().clone();
    tokio::select! {
        biased;
        _ = cancellation.cancelled() => Err(STOPPED.to_string()),
        result = future => {
            if cancellation.is_cancelled() { Err(STOPPED.to_string()) } else { result }
        },
    }
}

#[derive(Serialize)]
pub struct EngineStatusDto {
    ready: bool,
    port: Option<u16>,
    active_torrents: usize,
    last_error: Option<String>,
    dht_tier: u8,
    dht_nodes: usize,
}

#[derive(Serialize, Clone)]
pub struct EngineFile {
    idx: usize,
    name: String,
    length: u64,
}

/// upstream AddResult plus the file it narrowed to and the ready-made stream URL.
#[derive(Serialize)]
pub struct AddResult {
    info_hash: String,
    files: Vec<EngineFile>,
    stream_base: String,
    already_managed: bool,
    file_idx: Option<usize>,
    stream_url: Option<String>,
}

#[derive(Serialize)]
pub struct TorrentEngineStats {
    peers: usize,
    unchoked: usize,
    downloaded: u64,
    #[serde(rename = "downloadSpeed")]
    download_speed: u64,
    #[serde(rename = "streamProgress")]
    stream_progress: u64,
    #[serde(rename = "streamLen")]
    stream_len: u64,
    #[serde(rename = "peerSearchRunning")]
    peer_search_running: bool,
    finished: bool,
    state: String,
}

/// What the host passes to `harbor_torrent_add`: a magnet, a bare info hash, or (tests, local
/// files) a path to a .torrent; per-stream trackers; the addon's fileIdx when it gave one.
#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct AddRequest {
    #[serde(default)]
    pub magnet: Option<String>,
    #[serde(default)]
    pub info_hash: Option<String>,
    #[serde(default)]
    pub torrent_path: Option<String>,
    #[serde(default)]
    pub trackers: Vec<String>,
    #[serde(default)]
    pub file_idx: Option<i64>,
}

fn peer_opts() -> PeerConnectionOptions {
    PeerConnectionOptions {
        connect_timeout: Some(PEER_CONNECT_TIMEOUT),
        read_write_timeout: Some(PEER_READ_WRITE_TIMEOUT),
        keep_alive_interval: None,
    }
}

fn is_info_hash(s: &str) -> bool {
    s.len() == 40 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

fn normalize_hash(s: &str) -> Result<String, String> {
    let h = s.trim().to_ascii_lowercase();
    if is_info_hash(&h) {
        Ok(h)
    } else {
        Err("bad info hash".to_string())
    }
}

fn torrent_dir(dir: &Path, hash: &str) -> PathBuf {
    dir.join(hash)
}

async fn new_session(
    dir: &Path,
    listen: bool,
    upnp: bool,
    dht: bool,
    cancellation: CancellationToken,
) -> Result<Arc<Session>, String> {
    let guard = cancellation.clone().drop_guard();
    let session = Session::new_with_opts(
        dir.to_path_buf(),
        SessionOptions {
            cancellation_token: Some(cancellation),
            fastresume: false,
            persistence: None,
            disable_dht: !dht,
            disable_dht_persistence: true,
            dht_config: None,
            trackers: trackers::as_url_set(),
            listen_port_range: listen.then_some(LISTEN_PORT_RANGE),
            enable_upnp_port_forwarding: listen && upnp,
            peer_opts: Some(peer_opts()),
            ratelimits: LimitsConfig {
                upload_bps: NonZeroU32::new(MAX_UPLOAD_BPS),
                download_bps: None,
            },
            ..Default::default()
        },
    )
    .await
    .map_err(|e| format!("{e:#}"))?;
    let _ = guard.disarm();
    Ok(session)
}

fn sweep_blocking(dir: &Path, retention_hours: u64, max_gb: u64, skip: HashSet<String>) {
    if CACHE_SWEEP_RUNNING
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        eprintln!("[torrent-engine] cache sweep skipped; another sweep is active");
        return;
    }
    let _guard = CacheSweepGuard;
    let cancelled = AtomicBool::new(false);
    let stats = cache_sweep::run_with_cancel(dir, retention_hours, max_gb, &skip, &cancelled);
    if stats.deleted > 0 || stats.errors > 0 {
        eprintln!(
            "[torrent-engine] cache sweep: scanned={} deleted={} reclaimed_bytes={} errors={} first_error={:?}",
            stats.scanned, stats.deleted, stats.reclaimed_bytes, stats.errors, stats.first_error
        );
    }
}

/// Info hashes the session holds; their folders are never swept out from under them.
fn session_hashes(session: &Arc<Session>) -> HashSet<String> {
    session.with_torrents(|torrents| {
        torrents
            .map(|(_id, handle)| handle.info_hash().as_string())
            .collect()
    })
}

fn newest_mtime(paths: &[PathBuf]) -> Option<std::time::SystemTime> {
    paths
        .iter()
        .filter_map(|p| std::fs::metadata(p).and_then(|m| m.modified()).ok())
        .max()
}

/// upstream expire_session_torrents, except that an unpaused torrent (mpv is reading it) stays.
async fn expire_session_torrents(session: &Arc<Session>, dir: &Path, retention_hours: u64) -> u64 {
    let now = std::time::SystemTime::now();
    let max_age = Duration::from_secs(retention_hours.saturating_mul(3600));
    let idle: Vec<(String, Vec<PathBuf>)> = session.with_torrents(|torrents| {
        torrents
            .filter(|(_id, handle)| handle.is_paused())
            .map(|(_id, handle)| {
                let info_hash = handle.info_hash().as_string();
                let root = torrent_dir(dir, &info_hash);
                let paths = handle
                    .with_metadata(|m| {
                        m.file_infos
                            .iter()
                            .map(|fi| root.join(&fi.relative_filename))
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default();
                (info_hash, paths)
            })
            .collect()
    });
    let mut expired = 0_u64;
    for (info_hash, paths) in idle {
        if paths.is_empty() {
            continue;
        }
        let stale = if retention_hours == 0 {
            true
        } else {
            match newest_mtime(&paths) {
                Some(m) => now.duration_since(m).map(|age| age >= max_age).unwrap_or(false),
                None => false,
            }
        };
        if !stale {
            continue;
        }
        let Ok(id) = TorrentIdOrHash::parse(&info_hash) else {
            continue;
        };
        match session.delete(id, true).await {
            Ok(()) => {
                let _ = std::fs::remove_dir_all(torrent_dir(dir, &info_hash));
                expired += 1
            }
            Err(error) => {
                eprintln!("[torrent-engine] cache sweep could not release {info_hash}: {error:#}")
            }
        }
    }
    expired
}

fn spawn_cache_sweeper(
    session: Arc<Session>,
    dir: PathBuf,
    retention_hours: u64,
    max_gb: u64,
) -> CacheSweeper {
    let cancelled = Arc::new(AtomicBool::new(false));
    let cancelled_for_task = cancelled.clone();
    let task = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(CACHE_SWEEP_INITIAL_DELAY_SECS)).await;
        loop {
            if cancelled_for_task.load(Ordering::Acquire) || session.cancellation_token().is_cancelled() {
                break;
            }
            let released = expire_session_torrents(&session, &dir, retention_hours).await;
            if released > 0 {
                eprintln!("[torrent-engine] cache sweep released {released} expired torrent(s)");
            }
            let skip = session_hashes(&session);
            let dir_for_sweep = dir.clone();
            let _ = tokio::task::spawn_blocking(move || {
                sweep_blocking(&dir_for_sweep, retention_hours, max_gb, skip)
            })
            .await;
            tokio::time::sleep(Duration::from_secs(CACHE_SWEEP_INTERVAL_SECS)).await;
        }
    });
    CacheSweeper { task, cancelled }
}

/// upstream `init`: sessions down the tier ladder, the side DHT, the loopback stream server and
/// the cache sweeper. Returns the status once the engine is ready.
pub async fn start(config: EngineConfig) -> Result<EngineStatusDto, String> {
    let _transition = transition().lock().await;
    if current_session().is_some() {
        return Ok(status());
    }
    let dir = PathBuf::from(config.dir.trim());
    if config.dir.trim().is_empty() {
        return Err("download dir missing".to_string());
    }
    std::fs::create_dir_all(&dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
    // No persistence: anything an earlier run left here is unreachable, so it goes now.
    {
        let dir = dir.clone();
        let _ = tokio::task::spawn_blocking(move || sweep_blocking(&dir, 0, 0, HashSet::new())).await;
    }
    std::env::set_var("DHT_QUERIES_PER_SECOND", DHT_QUERIES_PER_SECOND);
    let dht = config.dht.unwrap_or(true);
    let listen = config.listen.unwrap_or(true);
    let upnp = config.upnp.unwrap_or(false);
    let cancellation = CancellationToken::new();
    let guard = cancellation.clone().drop_guard();
    let mut ladder: Vec<(bool, bool, u8)> = Vec::new();
    if listen && dht {
        ladder.push((true, true, 1));
    }
    if dht {
        ladder.push((false, true, 2));
    }
    ladder.push((false, false, 3));
    let mut session = None;
    let mut last_error = String::new();
    for (tier_listen, tier_dht, tier) in ladder {
        match new_session(&dir, tier_listen, upnp, tier_dht, cancellation.child_token()).await {
            Ok(s) => {
                session = Some((s, tier));
                break;
            }
            Err(e) => {
                eprintln!("[torrent-engine] tier{tier} unavailable ({e}); trying the next tier");
                last_error = e;
            }
        }
    }
    let Some((session, dht_tier)) = session else {
        lock_engine().last_error = Some(last_error.clone());
        return Err(last_error);
    };
    let side_dht = if dht {
        dht_boot::build(session.cancellation_token().child_token()).await
    } else {
        None
    };
    let listener = TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], 0)))
        .await
        .map_err(|e| e.to_string())?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let server_cancellation = session.cancellation_token().clone();
    let router = stream_route::router(session.clone());
    let server = tokio::spawn(async move {
        if let Err(e) = axum::serve(listener, router)
            .with_graceful_shutdown(server_cancellation.cancelled_owned())
            .await
        {
            eprintln!("[torrent-engine] server error: {e}");
        }
    });
    let sweeper = spawn_cache_sweeper(
        session.clone(),
        dir.clone(),
        config.retention_hours.unwrap_or(12),
        config.max_gb.unwrap_or(0),
    );
    {
        let mut st = lock_engine();
        if let Some(old) = st.server.take() {
            old.abort();
        }
        if let Some(old) = st.sweeper.take() {
            old.cancel();
        }
        st.session = Some(session);
        st.side_dht = side_dht;
        st.port = Some(port);
        st.dht_tier = dht_tier;
        st.dir = Some(dir);
        st.ready = true;
        st.last_error = None;
        st.server = Some(server);
        st.sweeper = Some(sweeper);
    }
    let _ = guard.disarm();
    eprintln!("[torrent-engine] ready on 127.0.0.1:{port} (dht tier {dht_tier})");
    Ok(status())
}

pub fn status() -> EngineStatusDto {
    let (port, ready, last_error, dht_tier) = {
        let st = lock_engine();
        (st.port, st.ready, st.last_error.clone(), st.dht_tier)
    };
    let session = current_session();
    let ready = ready && session.is_some();
    let port = if ready { port } else { None };
    let active_torrents = session.map(|s| s.with_torrents(|t| t.count())).unwrap_or(0);
    let dht_nodes = current_side_dht().map(|d| dht_boot::node_count(&d)).unwrap_or(0);
    EngineStatusDto { ready, port, active_torrents, last_error, dht_tier, dht_nodes }
}

async fn wait_for_torrent_initialization(
    session: &Arc<Session>,
    handle: &Arc<ManagedTorrent>,
    discard_on_failure: bool,
) -> Result<(), String> {
    let result = match timeout(Duration::from_secs(45), handle.wait_until_initialized()).await {
        Ok(Ok(())) => Ok(()),
        Ok(Err(error)) => Err(format!("{error:#}")),
        Err(_) => Err("torrent init timed out".to_string()),
    };
    if result.is_err() && discard_on_failure {
        if let Err(error) = session
            .delete(TorrentIdOrHash::Hash(handle.info_hash()), true)
            .await
        {
            eprintln!("[torrent-engine] could not discard incomplete torrent: {error:#}");
        }
    }
    result
}

async fn update_only_files_bounded(
    session: &Arc<Session>,
    handle: &Arc<ManagedTorrent>,
    only: &HashSet<usize>,
) -> Result<(), String> {
    timeout(
        Duration::from_secs(FILE_SELECTION_TIMEOUT_SECS),
        session.update_only_files(handle, only),
    )
    .await
    .map_err(|_| "torrent file selection timed out".to_string())?
    .map_err(|error| format!("{error:#}"))
}

fn engine_files(handle: &Arc<ManagedTorrent>) -> Result<Vec<EngineFile>, String> {
    handle
        .with_metadata(|m| {
            m.file_infos
                .iter()
                .enumerate()
                .map(|(idx, fi)| EngineFile {
                    idx,
                    name: fi
                        .relative_filename
                        .file_name()
                        .map(|s| s.to_string_lossy().to_string())
                        .unwrap_or_else(|| fi.relative_filename.to_string_lossy().to_string()),
                    length: fi.len,
                })
                .collect::<Vec<_>>()
        })
        .map_err(|e| format!("{e:#}"))
}

async fn add_result_from_handle(
    session: &Arc<Session>,
    handle: Arc<ManagedTorrent>,
    already_managed: bool,
    file_idx: Option<usize>,
) -> Result<AddResult, String> {
    wait_for_torrent_initialization(session, &handle, !already_managed).await?;
    let files = engine_files(&handle)?;
    let narrow_idx = file_idx
        .filter(|&i| i < files.len())
        .or_else(|| files.iter().max_by_key(|f| f.length).map(|f| f.idx));
    if let Some(idx) = narrow_idx {
        let only: HashSet<usize> = HashSet::from([idx]);
        if let Err(error) = update_only_files_bounded(session, &handle, &only).await {
            eprintln!("[torrent-engine] initial file narrowing failed: {error}");
        }
    }
    let port = current_port().ok_or_else(|| "engine port unavailable".to_string())?;
    let info_hash = handle.info_hash().as_string();
    let stream_base = format!("http://127.0.0.1:{port}/stream");
    Ok(AddResult {
        stream_url: narrow_idx.map(|i| format!("{stream_base}/{info_hash}/{i}")),
        info_hash,
        files,
        stream_base,
        already_managed,
        file_idx: narrow_idx,
    })
}

fn build_magnet(hash: &str) -> String {
    format!("magnet:?xt=urn:btih:{hash}")
}

/// upstream `torrent_engine_add` (and `ensure_added` for a bare hash).
pub async fn add(req: AddRequest) -> Result<AddResult, String> {
    let session = current_session().ok_or_else(|| NOT_READY.to_string())?;
    let dir = current_dir().ok_or_else(|| NOT_READY.to_string())?;
    let file_idx = req.file_idx.filter(|&i| i >= 0).map(|i| i as usize);
    run_session(&session, async {
        // The source: a .torrent on disk, a magnet, or a bare hash turned into one.
        let (source, info_hash): (AddTorrent<'static>, String) = if let Some(path) =
            req.torrent_path.as_deref().filter(|p| !p.trim().is_empty())
        {
            let bytes = std::fs::read(path).map_err(|e| format!("read {path}: {e}"))?;
            let parsed = librqbit::torrent_from_bytes::<librqbit::ByteBuf>(&bytes)
                .map_err(|e| format!("{e:#}"))?;
            let hash = parsed.info_hash.as_string();
            (AddTorrent::from_bytes(bytes), hash)
        } else {
            let magnet = match (req.magnet.as_deref(), req.info_hash.as_deref()) {
                (Some(m), _) if !m.trim().is_empty() => m.trim().to_string(),
                (_, Some(h)) => build_magnet(&normalize_hash(h)?),
                _ => return Err("magnet or info hash missing".to_string()),
            };
            let hash = dht_boot::info_hash_from_magnet(&magnet)
                .map(|id| id.as_string())
                .ok_or_else(|| "magnet has no btih info hash".to_string())?;
            if let Some(handle) = session.get(TorrentIdOrHash::parse(&hash).map_err(|e| e.to_string())?) {
                return add_result_from_handle(&session, handle, true, file_idx).await;
            }
            let seed = match current_side_dht() {
                Some(d) => dht_boot::seed_peers(&d, magnet.as_str(), 40, Duration::from_secs(3)).await,
                None => Vec::new(),
            };
            // librqbit ignores AddTorrentOptions.trackers for magnets, so splice the
            // per-stream trackers directly into the magnet URI to guarantee they announce.
            let magnet = trackers::embed_into_magnet(&magnet, &req.trackers);
            let opts = add_options(&dir, &hash, file_idx, req.trackers.clone(), seed);
            return finish_add(&session, AddTorrent::from_url(magnet), opts, file_idx).await;
        };
        if let Some(handle) = session.get(TorrentIdOrHash::parse(&info_hash).map_err(|e| e.to_string())?) {
            return add_result_from_handle(&session, handle, true, file_idx).await;
        }
        let opts = add_options(&dir, &info_hash, file_idx, req.trackers.clone(), Vec::new());
        finish_add(&session, source, opts, file_idx).await
    })
    .await
}

fn add_options(
    dir: &Path,
    hash: &str,
    file_idx: Option<usize>,
    trackers: Vec<String>,
    seed: Vec<SocketAddr>,
) -> AddTorrentOptions {
    AddTorrentOptions {
        overwrite: true,
        paused: true,
        only_files: file_idx.map(|i| vec![i]),
        output_folder: Some(torrent_dir(dir, hash).to_string_lossy().to_string()),
        trackers: Some(trackers::merge_into(trackers)),
        initial_peers: (!seed.is_empty()).then_some(seed),
        peer_opts: Some(peer_opts()),
        force_tracker_interval: Some(Duration::from_secs(300)),
        ..Default::default()
    }
}

async fn finish_add(
    session: &Arc<Session>,
    source: AddTorrent<'_>,
    opts: AddTorrentOptions,
    file_idx: Option<usize>,
) -> Result<AddResult, String> {
    let added = timeout(Duration::from_secs(60), session.add_torrent(source, Some(opts)))
        .await
        .map_err(|_| "metadata timed out: no peers reached in 60s".to_string())?
        .map_err(|e| format!("{e:#}"))?;
    let (handle, already_managed) = match added {
        AddTorrentResponse::AlreadyManaged(_, handle) => (handle, true),
        AddTorrentResponse::Added(_, handle) => (handle, false),
        AddTorrentResponse::ListOnly(_) => return Err("torrent added as list-only".to_string()),
    };
    add_result_from_handle(session, handle, already_managed, file_idx).await
}

/// upstream `torrent_engine_select`.
pub async fn select(info_hash: &str, file_idx: usize) -> Result<(), String> {
    let session = current_session().ok_or_else(|| NOT_READY.to_string())?;
    let hash = normalize_hash(info_hash)?;
    run_session(&session, async {
        let id = TorrentIdOrHash::parse(&hash).map_err(|e| e.to_string())?;
        let handle = session.get(id).ok_or_else(|| "no torrent".to_string())?;
        let only: HashSet<usize> = HashSet::from([file_idx]);
        update_only_files_bounded(&session, &handle, &only).await
    })
    .await
}

/// upstream `torrent_engine_stats`.
pub fn stats(info_hash: &str, file_idx: Option<usize>) -> Result<TorrentEngineStats, String> {
    let session = current_session().ok_or_else(|| NOT_READY.to_string())?;
    let hash = normalize_hash(info_hash)?;
    let id = TorrentIdOrHash::parse(&hash).map_err(|e| e.to_string())?;
    let handle = session.get(id).ok_or_else(|| "no torrent".to_string())?;
    let s = handle.stats();
    let (peers, download_speed, peer_search_running) = match &s.live {
        Some(live) => (
            live.snapshot.peer_stats.live,
            (live.download_speed.mbps * 1024.0 * 1024.0) as u64,
            true,
        ),
        None => (0, 0, false),
    };
    let stream_progress = match file_idx {
        Some(i) => s.file_progress.get(i).copied().unwrap_or(s.progress_bytes),
        None => s.progress_bytes,
    };
    let stream_len = match file_idx {
        Some(i) => handle
            .with_metadata(|m| m.file_infos.get(i).map(|fi| fi.len))
            .ok()
            .flatten()
            .unwrap_or(s.total_bytes),
        None => s.total_bytes,
    };
    Ok(TorrentEngineStats {
        peers,
        unchoked: peers,
        downloaded: s.progress_bytes,
        download_speed,
        stream_progress,
        stream_len,
        peer_search_running,
        finished: s.finished,
        state: format!("{:?}", s.state),
    })
}

/// upstream `torrent_engine_remove`; with `delete_files` the torrent's folder goes too.
pub async fn remove(info_hash: &str, delete_files: bool) -> Result<(), String> {
    let hash = normalize_hash(info_hash)?;
    let dir = current_dir();
    let result = match current_session() {
        Some(session) => {
            let id = TorrentIdOrHash::parse(&hash).map_err(|e| e.to_string())?;
            if session.get(id).is_some() {
                let id = TorrentIdOrHash::parse(&hash).map_err(|e| e.to_string())?;
                session.delete(id, delete_files).await.map_err(|e| format!("{e:#}"))
            } else {
                Ok(())
            }
        }
        None => Err(NOT_READY.to_string()),
    };
    if delete_files {
        if let Some(dir) = dir {
            let folder = torrent_dir(&dir, &hash);
            if folder.exists() {
                if let Err(e) = std::fs::remove_dir_all(&folder) {
                    eprintln!("[torrent-engine] could not delete {}: {e}", folder.display());
                }
            }
        }
    }
    result
}

/// Stops the engine: every torrent is dropped (and its data deleted when asked), the stream
/// server and the sweeper stop, the session is cancelled. `start` can run again afterwards.
pub async fn shutdown(delete_files: bool) {
    let _transition = transition().lock().await;
    let (session, side_dht, dir) = {
        let mut st = lock_engine();
        if let Some(server) = st.server.take() {
            server.abort();
        }
        if let Some(sweeper) = st.sweeper.take() {
            sweeper.cancel();
        }
        st.port = None;
        st.dht_tier = 0;
        st.ready = false;
        (st.session.take(), st.side_dht.take(), st.dir.take())
    };
    if let Some(dht) = side_dht {
        dht.cancellation_token().cancel();
    }
    if let Some(session) = session {
        let hashes: Vec<String> = session_hashes(&session).into_iter().collect();
        for hash in hashes {
            if let Ok(id) = TorrentIdOrHash::parse(&hash) {
                if let Err(e) = session.delete(id, delete_files).await {
                    eprintln!("[torrent-engine] could not release {hash} on shutdown: {e:#}");
                }
            }
        }
        session.cancellation_token().cancel();
        let _ = timeout(Duration::from_secs(5), session.stop()).await;
    }
    if delete_files {
        if let Some(dir) = dir {
            let _ = tokio::task::spawn_blocking(move || sweep_blocking(&dir, 0, 0, HashSet::new())).await;
        }
    }
}
