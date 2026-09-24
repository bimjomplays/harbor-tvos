//! C ABI over harbor-core, the librqbit torrent engine (`torrent`, Stage 6) and the librespot
//! Spotify player (`spotify`, Stage 12, the default `spotify` feature). Every function
//! that returns a `*mut c_char` hands ownership to the caller, who must release it with
//! `harbor_string_free`.
use std::ffi::{c_char, CStr, CString};

use harbor_core::{parser, scoring, trust, ParsedStream, ScoreOptions, ScoredStream, Stream, TrustOptions};

pub mod torrent;
#[cfg(feature = "spotify")]
pub mod spotify;

fn to_c(s: String) -> *mut c_char {
    CString::new(s).unwrap_or_default().into_raw()
}

unsafe fn from_c<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    CStr::from_ptr(p).to_str().ok()
}

#[no_mangle]
pub extern "C" fn harbor_core_version() -> *mut c_char {
    to_c(harbor_core::harbor_core_version())
}

/// Runs parse → trust → score → rank on a JSON `Stream[]`.
/// `trust_json` and `score_json` may be NULL for defaults.
/// Returns JSON `{ "picker": RankedPicker, "rejected": Rejection[] }`, or `{ "error": "..." }`.
#[no_mangle]
pub unsafe extern "C" fn harbor_run_pipeline(
    streams_json: *const c_char,
    trust_json: *const c_char,
    score_json: *const c_char,
) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let raw: Vec<Stream> =
            serde_json::from_str(from_c(streams_json).ok_or("streams_json missing")?).map_err(|e| e.to_string())?;
        let trust_opts: TrustOptions = match from_c(trust_json) {
            Some(s) if !s.is_empty() => serde_json::from_str(s).map_err(|e| e.to_string())?,
            _ => TrustOptions::default(),
        };
        let score_opts: ScoreOptions = match from_c(score_json) {
            Some(s) if !s.is_empty() => serde_json::from_str(s).map_err(|e| e.to_string())?,
            _ => ScoreOptions::default(),
        };
        let parsed: Vec<ParsedStream> = raw.into_iter().map(parser::parse_stream).collect();
        let trusted = trust::apply_trust(parsed, &trust_opts);
        let corpus = scoring::compute_corpus_stats(&trusted.keep, &score_opts);
        let scored: Vec<ScoredStream> = trusted
            .keep
            .into_iter()
            .map(|p| scoring::score_stream(p, &score_opts, &corpus))
            .collect();
        let picker = scoring::rank_and_pick(scored, &score_opts.active_debrids, score_opts.respect_addon_order);
        serde_json::to_string(&serde_json::json!({ "picker": picker, "rejected": trusted.rejected }))
            .map_err(|e| e.to_string())
    })();
    match result {
        Ok(s) => to_c(s),
        Err(e) => to_c(serde_json::json!({ "error": e }).to_string()),
    }
}

#[no_mangle]
pub unsafe extern "C" fn harbor_string_free(p: *mut c_char) {
    if !p.is_null() {
        drop(CString::from_raw(p));
    }
}
