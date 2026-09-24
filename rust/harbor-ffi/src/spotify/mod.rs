//! Spotify Premium playback through librespot 0.8, as upstream does it
//! (reference/harbor/src-tauri/src/music/spotify/{mod,session,player,control}.rs), minus what the
//! TV does elsewhere:
//!
//! - OAuth (auth.rs) runs in the engine (engine/musicSpotify.ts): the TV cannot finish upstream's
//!   loopback redirect itself, so the phone signs in and the viewer pastes the final address back.
//!   The engine hands the access token (or the saved reusable credentials) to `connect`.
//! - The secrets store (keystore.rs) is the engine's Keychain tier (`harbor.spotify.v1.*`). librespot
//!   writes its reusable credentials to `<cacheDir>/session/credentials.json`; `connect` reads them
//!   back, deletes the file and returns them, as keystore::capture/harvest do.
//! - Browse/search/token refresh (api.rs, browse.rs, tokens.rs) are engine TypeScript over the Web
//!   API; `session_token` is tokens.rs `session_token` (login5) for when there is no OAuth token.
//! - The queue, scrobbles and Now Playing are Swift's MusicPlayer (player.ts upstream); this module
//!   plays one track at a time and reports upstream's music://event stream as polled JSON events.
//! - Audio goes to `sink::RingSink`, drained by Swift, instead of rodio/cpal.
//!
//! Own tokio runtime (librespot's Session needs one), one global session, a std Mutex that is never
//! held across an await.
pub mod ffi;
pub mod sink;

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use librespot_core::authentication::Credentials;
use librespot_core::cache::Cache;
use librespot_core::config::SessionConfig;
use librespot_core::session::Session;
use librespot_core::SpotifyUri;
use librespot_playback::config::{Bitrate, PlayerConfig};
use librespot_playback::mixer::softmixer::SoftMixer;
use librespot_playback::mixer::{Mixer, MixerConfig};
use librespot_playback::player::{Player, PlayerEvent};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::runtime::Runtime;

use sink::{PcmRing, RingSink, RING_SAMPLES};

// Upstream copy (session.rs, control.rs, player.rs).
pub const FREE_ACCOUNT: &str =
    "Spotify Free cannot stream through third party apps. Connect a Spotify Premium account.";
pub const SIGN_IN_AGAIN: &str = "Spotify rejected the saved sign in. Connect Spotify again.";
pub const CONNECT_BEFORE_PLAY: &str = "Connect Spotify Premium before playing this source";
pub const UNAVAILABLE: &str = "Spotify track is unavailable";
const CLOSED_EARLY: &str = "Spotify closed the session before it was ready.";

const AUDIO_DIR: &str = "audio";
/// Where librespot writes the reusable credentials before `connect` harvests them.
const SESSION_DIR: &str = "session";
/// Upstream allows 2 GB of cached audio on a desktop. tvOS gives apps no guaranteed disk and this
/// lives in the purgeable Caches folder (PLAN decision 5), so the TV keeps a quarter of that.
const AUDIO_CACHE_LIMIT: u64 = 512 * 1024 * 1024;
const PRODUCT_INFO_TIMEOUT: Duration = Duration::from_secs(8);
const PRODUCT_INFO_POLL: Duration = Duration::from_millis(100);
const ACCOUNT_ATTRIBUTE: &str = "type";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(45);
const EVENT_LIMIT: usize = 256;
const DEFAULT_VOLUME: f64 = 0.82;

/// session.rs AccountTier
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AccountTier {
    Premium,
    Free,
    Unknown,
}

impl AccountTier {
    pub fn from_attribute(value: &str) -> Self {
        match value.trim().to_ascii_lowercase().as_str() {
            "premium" => Self::Premium,
            "" => Self::Unknown,
            _ => Self::Free,
        }
    }

    pub fn label(self) -> Option<&'static str> {
        match self {
            Self::Premium => Some("Premium"),
            Self::Free => Some("Spotify Free"),
            Self::Unknown => None,
        }
    }

    pub fn premium(self) -> bool {
        matches!(self, Self::Premium)
    }
}

/// mod.rs SpotifyStatus, plus the harvested reusable credentials on a fresh connect.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SpotifyStatus {
    pub connected: bool,
    pub username: Option<String>,
    pub country: Option<String>,
    pub premium: bool,
    /// None while connected means the tier is not known yet; the engine asks the Web API
    /// (tokens.rs probe_tier) and disconnects a Free account.
    pub account_type: Option<String>,
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub credentials: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectRequest {
    /// A private folder under Caches for librespot's audio cache and credential hand-off.
    pub cache_dir: String,
    /// keystore.rs device_id (a UUID the engine keeps).
    #[serde(default)]
    pub device_id: Option<String>,
    /// The OAuth access token from the phone sign-in (connect_interactive).
    #[serde(default)]
    pub access_token: Option<String>,
    /// The saved reusable credentials, as JSON (initialize / keystore::load).
    #[serde(default)]
    pub credentials: Option<String>,
}

struct Live {
    session: Session,
    player: Arc<Player>,
    mixer: Arc<dyn Mixer>,
    cache_dir: PathBuf,
}

struct Current {
    uri: String,
    request_id: Option<u64>,
}

struct State {
    live: Option<Live>,
    username: String,
    country: String,
    tier: AccountTier,
    current: Option<Current>,
    events: VecDeque<Value>,
}

impl State {
    const fn empty() -> Self {
        Self {
            live: None,
            username: String::new(),
            country: String::new(),
            tier: AccountTier::Unknown,
            current: None,
            events: VecDeque::new(),
        }
    }

    fn connected(&self) -> bool {
        self.live
            .as_ref()
            .is_some_and(|live| !live.session.is_invalid())
    }

    fn push(&mut self, event: Value) {
        if self.events.len() >= EVENT_LIMIT {
            self.events.pop_front();
        }
        self.events.push_back(event);
    }
}

static STATE: Mutex<State> = Mutex::new(State::empty());

fn state() -> MutexGuard<'static, State> {
    // A panic while holding the lock must not brick Spotify for the rest of the run.
    STATE.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

pub(crate) fn runtime() -> Result<&'static Runtime, String> {
    static RT: OnceLock<Option<Runtime>> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("harbor-spotify")
            .enable_all()
            .build()
            .map_err(|e| eprintln!("[spotify] runtime unavailable: {e}"))
            .ok()
    })
    .as_ref()
    .ok_or_else(|| "Spotify runtime unavailable".to_string())
}

/// The ring every player writes into and `harbor_spotify_pcm_read` drains. One for the process:
/// the audio callback reads it without touching the state lock.
pub fn ring() -> &'static Arc<PcmRing> {
    static RING: OnceLock<Arc<PcmRing>> = OnceLock::new();
    RING.get_or_init(|| Arc::new(PcmRing::new(RING_SAMPLES)))
}

fn text(value: &str) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

fn unix_seconds(at: SystemTime) -> u64 {
    at.duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()
}

/// mod.rs snapshot()
pub fn status() -> SpotifyStatus {
    let state = state();
    if !state.connected() {
        return SpotifyStatus {
            connected: false,
            username: None,
            country: None,
            premium: false,
            account_type: None,
            error: None,
            credentials: None,
        };
    }
    SpotifyStatus {
        connected: true,
        username: text(&state.username),
        country: text(&state.country),
        premium: state.tier.premium(),
        account_type: state.tier.label().map(str::to_string),
        error: None,
        credentials: None,
    }
}

/// session.rs make_cache, with the credentials in their own folder so they can be harvested.
fn make_cache(root: &Path) -> Result<Cache, String> {
    let audio = root.join(AUDIO_DIR);
    let session = root.join(SESSION_DIR);
    for dir in [&audio, &session] {
        std::fs::create_dir_all(dir)
            .map_err(|error| format!("create Spotify cache {}: {error}", dir.display()))?;
    }
    Cache::new(Some(session), None, Some(audio), Some(AUDIO_CACHE_LIMIT))
        .map_err(|error| format!("open Spotify cache {}: {error}", root.display()))
}

/// keystore::capture: the reusable credentials librespot just wrote, as JSON, and the file gone.
fn harvest(root: &Path) -> Option<String> {
    let path = root.join(SESSION_DIR).join("credentials.json");
    let stored = std::fs::read_to_string(&path).ok();
    let _ = std::fs::remove_file(&path);
    let stored = stored?;
    serde_json::from_str::<Credentials>(&stored).ok()?;
    Some(stored.trim().to_string())
}

/// session.rs clear_audio_cache (and any credentials file left behind).
fn clear_cache(root: &Path) {
    for dir in [AUDIO_DIR, SESSION_DIR] {
        let path = root.join(dir);
        if path.is_dir() {
            let _ = std::fs::remove_dir_all(&path);
        }
    }
}

/// session.rs describe_connect
fn describe_connect(error: librespot_core::Error) -> String {
    let text = error.to_string();
    let marker = text.to_ascii_lowercase();
    if marker.contains("badcredentials")
        || marker.contains("bad credentials")
        || marker.contains("invalid credentials")
        || marker.contains("unauthenticated")
    {
        return SIGN_IN_AGAIN.to_string();
    }
    format!("Spotify session connection failed: {text}")
}

/// session.rs await_account_tier
async fn await_account_tier(session: &Session) -> AccountTier {
    let deadline = tokio::time::Instant::now() + PRODUCT_INFO_TIMEOUT;
    loop {
        if let Some(value) = session.get_user_attribute(ACCOUNT_ATTRIBUTE) {
            return AccountTier::from_attribute(&value);
        }
        if session.is_invalid() || tokio::time::Instant::now() >= deadline {
            return AccountTier::Unknown;
        }
        tokio::time::sleep(PRODUCT_INFO_POLL).await;
    }
}

fn credentials_for(request: &ConnectRequest) -> Result<Credentials, String> {
    if let Some(saved) = request.credentials.as_deref().and_then(text) {
        return serde_json::from_str::<Credentials>(&saved).map_err(|_| SIGN_IN_AGAIN.to_string());
    }
    if let Some(token) = request.access_token.as_deref().and_then(text) {
        return Ok(Credentials::with_access_token(token));
    }
    Err(CONNECT_BEFORE_PLAY.to_string())
}

/// mod.rs connect_with + session.rs build/connect + player.rs start, for one request.
pub async fn connect(request: ConnectRequest) -> Result<SpotifyStatus, String> {
    let root = text(&request.cache_dir)
        .map(PathBuf::from)
        .ok_or_else(|| "Spotify cache folder is missing".to_string())?;
    let credentials = credentials_for(&request)?;
    let cache = make_cache(&root)?;
    let mut config = SessionConfig::default();
    if let Some(device) = request.device_id.as_deref().and_then(text) {
        config.device_id = device;
    }
    let session = Session::new(config, Some(cache));
    let connected = tokio::time::timeout(CONNECT_TIMEOUT, async {
        session
            .connect(credentials, true)
            .await
            .map_err(describe_connect)?;
        Ok::<_, String>(await_account_tier(&session).await)
    })
    .await;
    let tier = match connected {
        Ok(Ok(tier)) => tier,
        Ok(Err(error)) => {
            session.shutdown();
            let _ = harvest(&root);
            return Err(error);
        }
        Err(_) => {
            session.shutdown();
            let _ = harvest(&root);
            return Err(format!(
                "Spotify session connection failed: timed out after {} seconds",
                CONNECT_TIMEOUT.as_secs()
            ));
        }
    };
    let credentials = harvest(&root);
    if tier == AccountTier::Free {
        session.shutdown();
        return Err(FREE_ACCOUNT.to_string());
    }
    if session.is_invalid() {
        return Err(CLOSED_EARLY.to_string());
    }
    let (player, mixer) = start_player(session.clone())?;
    let previous = {
        let mut state = state();
        let previous = state.live.replace(Live {
            session: session.clone(),
            player,
            mixer,
            cache_dir: root,
        });
        state.username = session.username();
        state.country = session.country();
        state.tier = tier;
        state.current = None;
        state.events.clear();
        previous
    };
    retire(previous);
    let mut status = status();
    status.credentials = credentials;
    Ok(status)
}

/// Stops a replaced or disconnected session. Dropping a Player joins its thread, so it happens
/// off the caller's thread, as upstream does.
fn retire(live: Option<Live>) {
    if let Some(live) = live {
        // Nothing the old player buffered is heard after it (the next sink claims the ring too).
        ring().request_flush();
        live.player.stop();
        live.session.shutdown();
        std::thread::spawn(move || drop(live));
    }
}

/// player.rs start: 320 kbps, gapless, position every 250 ms, soft volume, the ring sink.
fn start_player(session: Session) -> Result<(Arc<Player>, Arc<dyn Mixer>), String> {
    let mixer: Arc<dyn Mixer> = Arc::new(
        SoftMixer::open(MixerConfig::default())
            .map_err(|error| format!("open Spotify volume mixer: {error}"))?,
    );
    let config = PlayerConfig {
        bitrate: Bitrate::Bitrate320,
        gapless: true,
        position_update_interval: Some(Duration::from_millis(250)),
        ..Default::default()
    };
    let ring = ring().clone();
    // Upstream builds its sink with AudioFormat::F32; the ring stores f32 too.
    let player = Player::new(config, session, mixer.get_soft_volume(), move || {
        Box::new(RingSink::new(ring))
    });
    spawn_events(player.clone())?;
    Ok((player, mixer))
}

/// The heard position: librespot reports what it decoded; the ring still holds up to half a second.
fn heard(position_ms: u32) -> f64 {
    (position_ms as f64 / 1000.0 - ring().buffered_seconds()).max(0.0)
}

/// player.rs spawn_events, with upstream's request-id guards (bind_request, record_position,
/// finish_context) and its music://event payloads as queued JSON.
fn spawn_events(player: Arc<Player>) -> Result<(), String> {
    let mut events = player.get_player_event_channel();
    runtime()?.spawn(async move {
        while let Some(event) = events.recv().await {
            handle_event(event);
        }
    });
    Ok(())
}

fn handle_event(event: PlayerEvent) {
    let mut state = state();
    match event {
        PlayerEvent::Loading {
            play_request_id,
            track_id,
            ..
        } => {
            let Ok(uri) = track_id.to_uri() else { return };
            if let Some(current) = state.current.as_mut().filter(|c| c.uri == uri) {
                current.request_id = Some(play_request_id);
                state.push(json!({ "event": "loading" }));
            }
        }
        PlayerEvent::Playing {
            play_request_id,
            position_ms,
            ..
        } => {
            if bound(&state, play_request_id) {
                state.push(json!({ "event": "playing", "position": heard(position_ms) }));
            }
        }
        PlayerEvent::Paused {
            play_request_id,
            position_ms,
            ..
        } => {
            if bound(&state, play_request_id) {
                state.push(json!({ "event": "paused", "position": heard(position_ms) }));
            }
        }
        PlayerEvent::PositionChanged {
            play_request_id,
            position_ms,
            ..
        }
        | PlayerEvent::PositionCorrection {
            play_request_id,
            position_ms,
            ..
        }
        | PlayerEvent::Seeked {
            play_request_id,
            position_ms,
            ..
        } => {
            if bound(&state, play_request_id) {
                state.push(json!({ "event": "position", "position": heard(position_ms) }));
            }
        }
        PlayerEvent::EndOfTrack {
            play_request_id, ..
        } => {
            if bound(&state, play_request_id) {
                state.current = None;
                state.push(json!({ "event": "end", "reason": "eof" }));
            }
        }
        PlayerEvent::Unavailable {
            play_request_id, ..
        } => {
            if bound(&state, play_request_id) {
                state.current = None;
                state.push(json!({ "event": "failure", "reason": UNAVAILABLE }));
            }
        }
        _ => {}
    }
}

fn bound(state: &State, request_id: u64) -> bool {
    state
        .current
        .as_ref()
        .is_some_and(|current| current.request_id == Some(request_id))
}

/// Drains the queued events. `connected` goes false when Spotify drops the session.
pub fn events() -> Value {
    let mut state = state();
    let drained: Vec<Value> = state.events.drain(..).collect();
    json!({ "events": drained, "connected": state.connected() })
}

/// control.rs volume_to_u16
pub fn volume_to_u16(volume: f64) -> u16 {
    let clamped = if volume.is_finite() {
        volume.clamp(0.0, 1.0)
    } else {
        DEFAULT_VOLUME
    };
    (clamped * u16::MAX as f64).round() as u16
}

/// control.rs play + player.rs play: one track, from the start.
pub fn play(uri: &str, volume: f64) -> Result<(), String> {
    let uri = uri.trim();
    if uri.is_empty() {
        return Err("Spotify track is missing its URI".to_string());
    }
    let parsed =
        SpotifyUri::from_uri(uri).map_err(|error| format!("Invalid Spotify track URI: {error}"))?;
    let mut state = state();
    if !state.connected() {
        return Err(CONNECT_BEFORE_PLAY.to_string());
    }
    // A track still going is being skipped: drop its buffered tail. After a natural end the tail
    // plays out ahead of the new track (upstream's gapless hand-off).
    if state.current.is_some() {
        ring().request_flush();
    }
    ring().keep_next_stop();
    state.current = Some(Current {
        uri: uri.to_string(),
        request_id: None,
    });
    state.events.clear();
    let live = state.live.as_ref().ok_or_else(|| CONNECT_BEFORE_PLAY.to_string())?;
    live.mixer.set_volume(volume_to_u16(volume));
    live.player.load(parsed, true, 0);
    Ok(())
}

/// control.rs set_paused. A pause the viewer asked for is heard at once (the ring is dropped).
pub fn set_paused(paused: bool) {
    let state = state();
    let Some(live) = state.live.as_ref() else { return };
    if state.current.is_none() {
        return;
    }
    if paused {
        ring().discard_next_stop();
        live.player.pause();
    } else {
        live.player.play();
    }
}

/// control.rs seek
pub fn seek(position: f64) -> Result<(), String> {
    if !position.is_finite() {
        return Err("Music seek position is invalid".to_string());
    }
    let state = state();
    if let Some(live) = state.live.as_ref() {
        live.player
            .seek((position.max(0.0) * 1000.0).min(u32::MAX as f64) as u32);
        ring().request_flush();
    }
    Ok(())
}

/// control.rs set_volume
pub fn set_volume(volume: f64) {
    if let Some(live) = state().live.as_ref() {
        live.mixer.set_volume(volume_to_u16(volume));
    }
}

/// control.rs stop(false): another source is taking over. A track still going is cut off; after
/// a natural end the buffered tail is still heard.
pub fn stop() {
    let mut state = state();
    let playing = state.current.is_some();
    if let Some(live) = state.live.as_ref() {
        if playing {
            ring().discard_next_stop();
        }
        live.player.stop();
    }
    if playing {
        ring().request_flush();
    }
    state.current = None;
    state.events.clear();
}

/// mod.rs disconnect: stop, shut the session down, clear the audio cache. The engine forgets the
/// saved credentials and web token (keystore::forget).
pub fn disconnect() {
    let previous = {
        let mut state = state();
        let previous = state.live.take();
        state.username.clear();
        state.country.clear();
        state.tier = AccountTier::Unknown;
        state.current = None;
        state.events.clear();
        previous
    };
    ring().request_flush();
    if let Some(live) = previous.as_ref() {
        clear_cache(&live.cache_dir);
    }
    retire(previous);
}

/// tokens.rs session_token: a login5 token for the Web API when there is no OAuth token.
pub async fn session_token() -> Result<Value, String> {
    let session = state()
        .live
        .as_ref()
        .map(|live| live.session.clone())
        .filter(|session| !session.is_invalid())
        .ok_or_else(|| "Connect Spotify Premium to use Spotify".to_string())?;
    let token = session
        .login5()
        .auth_token()
        .await
        .map_err(|error| format!("Spotify authorization failed: {error}"))?;
    let expires_at = unix_seconds(token.timestamp).saturating_add(token.expires_in.as_secs());
    Ok(json!({ "accessToken": token.access_token, "expiresAt": expires_at, "scopes": token.scopes }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn account_tiers_read_the_product_info_attribute() {
        assert_eq!(AccountTier::from_attribute("premium"), AccountTier::Premium);
        assert_eq!(AccountTier::from_attribute(" Premium "), AccountTier::Premium);
        assert_eq!(AccountTier::from_attribute("free"), AccountTier::Free);
        assert_eq!(AccountTier::from_attribute("open"), AccountTier::Free);
        assert_eq!(AccountTier::from_attribute("  "), AccountTier::Unknown);
        assert!(!AccountTier::Unknown.premium());
        assert_eq!(AccountTier::Free.label(), Some("Spotify Free"));
    }

    #[test]
    fn spotify_volume_is_bounded() {
        assert_eq!(volume_to_u16(-1.0), 0);
        assert_eq!(volume_to_u16(1.0), u16::MAX);
        assert_eq!(volume_to_u16(f64::NAN), 53_739);
    }

    #[test]
    fn saved_credentials_win_over_a_token_and_bad_ones_ask_for_a_new_sign_in() {
        let request = |credentials: Option<&str>, token: Option<&str>| ConnectRequest {
            cache_dir: "/tmp".to_string(),
            device_id: None,
            access_token: token.map(str::to_string),
            credentials: credentials.map(str::to_string),
        };
        assert_eq!(credentials_for(&request(None, None)).unwrap_err(), CONNECT_BEFORE_PLAY);
        assert_eq!(credentials_for(&request(None, Some("  "))).unwrap_err(), CONNECT_BEFORE_PLAY);
        assert_eq!(credentials_for(&request(Some("{"), Some("token"))).unwrap_err(), SIGN_IN_AGAIN);
        let token = credentials_for(&request(None, Some("abc"))).unwrap();
        assert_eq!(token.auth_data, b"abc".to_vec());
        let saved = serde_json::to_string(&Credentials::with_access_token("saved")).unwrap();
        let chosen = credentials_for(&request(Some(&saved), Some("abc"))).unwrap();
        assert_eq!(chosen.auth_data, b"saved".to_vec());
    }

    #[test]
    fn harvested_credentials_leave_no_file_behind() {
        let root = std::env::temp_dir().join(format!("harbor-spotify-harvest-{}", std::process::id()));
        std::fs::create_dir_all(root.join(SESSION_DIR)).unwrap();
        let file = root.join(SESSION_DIR).join("credentials.json");
        let saved = serde_json::to_string(&Credentials::with_access_token("x")).unwrap();
        std::fs::write(&file, &saved).unwrap();
        assert_eq!(harvest(&root).as_deref(), Some(saved.as_str()));
        assert!(!file.exists());
        std::fs::write(&file, b"not json").unwrap();
        assert_eq!(harvest(&root), None);
        assert!(!file.exists(), "unreadable credentials are removed too");
        std::fs::create_dir_all(root.join(AUDIO_DIR)).unwrap();
        clear_cache(&root);
        assert!(!root.join(AUDIO_DIR).exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn describe_connect_names_a_rejected_sign_in() {
        let rejected = librespot_core::Error::unauthenticated("BadCredentials");
        assert_eq!(describe_connect(rejected), SIGN_IN_AGAIN);
        let other = librespot_core::Error::unavailable("no access point");
        assert!(describe_connect(other).starts_with("Spotify session connection failed"));
    }
}
