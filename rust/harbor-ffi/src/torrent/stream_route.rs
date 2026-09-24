// Port of upstream src-tauri/src/torrent_engine/stream_route.rs: the loopback HTTP server mpv
// reads a torrent file from (`GET|HEAD /stream/{hash}/{file_id}` with byte ranges) and `/health`.
// The Stremio-server compatible routes upstream also mounts (`/{hash}/create`, `/{hash}/{file_id}`,
// `/settings`) serve casting and the LAN server, which tvOS does not have, so they are left out.
use std::io::SeekFrom;
use std::path::Path as FsPath;
use std::sync::Arc;

use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use futures_util::StreamExt;
use librqbit::api::TorrentIdOrHash;
use librqbit::Session;
use tokio::io::{AsyncReadExt, AsyncSeekExt};

pub fn router(session: Arc<Session>) -> Router {
    Router::new()
        .route("/stream/{hash}/{file_id}", get(h_stream).head(h_stream))
        .route("/health", get(health))
        .with_state(session)
}

async fn health() -> &'static str {
    "ok"
}

async fn h_stream(
    State(session): State<Arc<Session>>,
    Path((hash, file_id)): Path<(String, usize)>,
    headers: HeaderMap,
) -> Response {
    stream_file(&session, &hash, file_id, &headers).await
}

async fn stream_file(
    session: &Arc<Session>,
    hash: &str,
    file_id: usize,
    headers: &HeaderMap,
) -> Response {
    match super::run_session(session, async {
        Ok(stream_file_inner(session, hash, file_id, headers).await)
    })
    .await
    {
        Ok(response) => response,
        Err(error) => (StatusCode::SERVICE_UNAVAILABLE, error).into_response(),
    }
}

async fn stream_file_inner(
    session: &Arc<Session>,
    hash: &str,
    file_id: usize,
    headers: &HeaderMap,
) -> Response {
    let Ok(id) = TorrentIdOrHash::parse(hash) else {
        return (StatusCode::BAD_REQUEST, "bad hash").into_response();
    };
    let Some(handle) = session.get(id) else {
        return (StatusCode::NOT_FOUND, "no torrent").into_response();
    };
    // Torrent selection resolves metadata only. Peer transfer starts when a
    // player or an intentional download actually asks for stream bytes.
    if handle.is_paused() {
        if let Err(error) = session.unpause(&handle).await {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("could not start torrent: {error:#}"),
            )
                .into_response();
        }
    }
    let ct = handle
        .with_metadata(|m| {
            m.file_infos
                .get(file_id)
                .map(|fi| ct_for(&fi.relative_filename))
        })
        .ok()
        .flatten()
        .unwrap_or("application/octet-stream");
    let mut stream = match handle.stream(file_id) {
        Ok(s) => s,
        Err(e) => return (StatusCode::NOT_FOUND, format!("{e:#}")).into_response(),
    };
    let len = stream.len();
    let requested_range = headers.get(header::RANGE);
    let parsed = requested_range
        .and_then(|value| value.to_str().ok())
        .map(|value| parse_range(value, len));
    let (status, start, end) = match parsed {
        Some(Ok((start, end))) => (StatusCode::PARTIAL_CONTENT, start, end),
        Some(Err(())) => {
            let mut response =
                (StatusCode::RANGE_NOT_SATISFIABLE, "range not satisfiable").into_response();
            if let Ok(value) = HeaderValue::from_str(&format!("bytes */{len}")) {
                response.headers_mut().insert(header::CONTENT_RANGE, value);
            }
            return response;
        }
        None => (StatusCode::OK, 0u64, len),
    };
    if start > 0 && stream.seek(SeekFrom::Start(start)).await.is_err() {
        return (StatusCode::INTERNAL_SERVER_ERROR, "seek failed").into_response();
    }
    let to_take = end - start;
    let mut out = HeaderMap::new();
    out.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
    out.insert(header::CONTENT_TYPE, HeaderValue::from_static(ct));
    if let Ok(value) = HeaderValue::from_str(&to_take.to_string()) {
        out.insert(header::CONTENT_LENGTH, value);
    }
    if status == StatusCode::PARTIAL_CONTENT {
        if let Ok(value) = HeaderValue::from_str(&format!("bytes {}-{}/{}", start, end - 1, len)) {
            out.insert(header::CONTENT_RANGE, value);
        }
    }
    let body = Body::from_stream(
        tokio_util::io::ReaderStream::with_capacity(stream.take(to_take), 65536)
            .take_until(session.cancellation_token().clone().cancelled_owned()),
    );
    (status, out, body).into_response()
}

fn parse_range(raw: &str, len: u64) -> Result<(u64, u64), ()> {
    let spec = raw.trim().strip_prefix("bytes=").ok_or(())?.trim();
    if spec.contains(',') || len == 0 {
        return Err(());
    }
    let (start_raw, end_raw) = spec.split_once('-').ok_or(())?;
    let start_raw = start_raw.trim();
    let end_raw = end_raw.trim();

    if start_raw.is_empty() {
        let suffix_len = end_raw.parse::<u64>().map_err(|_| ())?;
        if suffix_len == 0 {
            return Err(());
        }
        return Ok((len.saturating_sub(suffix_len), len));
    }

    let start = start_raw.parse::<u64>().map_err(|_| ())?;
    if start >= len {
        return Err(());
    }
    if end_raw.is_empty() {
        return Ok((start, len));
    }

    let inclusive_end = end_raw.parse::<u64>().map_err(|_| ())?;
    if inclusive_end < start {
        return Err(());
    }
    Ok((start, inclusive_end.saturating_add(1).min(len)))
}

fn ct_for(path: &FsPath) -> &'static str {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match ext.as_str() {
        "mp4" | "m4v" => "video/mp4",
        "mkv" => "video/x-matroska",
        "webm" => "video/webm",
        "avi" => "video/x-msvideo",
        "mov" => "video/quicktime",
        "ts" | "m2ts" | "mts" => "video/mp2t",
        "ogv" => "video/ogg",
        "mp3" => "audio/mpeg",
        "flac" => "audio/flac",
        "aac" | "m4a" => "audio/aac",
        "srt" => "application/x-subrip",
        "vtt" => "text/vtt",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::parse_range;

    #[test]
    fn parses_http_byte_ranges_used_by_media_players() {
        assert_eq!(parse_range("bytes=0-499", 1_000), Ok((0, 500)));
        assert_eq!(parse_range("bytes=500-", 1_000), Ok((500, 1_000)));
        assert_eq!(parse_range("bytes=-500", 1_000), Ok((500, 1_000)));
        assert_eq!(parse_range("bytes=-1500", 1_000), Ok((0, 1_000)));
        assert_eq!(parse_range("bytes=900-2000", 1_000), Ok((900, 1_000)));
    }

    #[test]
    fn rejects_invalid_or_unsatisfiable_http_byte_ranges() {
        assert_eq!(parse_range("bytes=1000-", 1_000), Err(()));
        assert_eq!(parse_range("bytes=10-9", 1_000), Err(()));
        assert_eq!(parse_range("bytes=-0", 1_000), Err(()));
        assert_eq!(parse_range("bytes=0-1,4-5", 1_000), Err(()));
        assert_eq!(parse_range("not-a-range", 1_000), Err(()));
        assert_eq!(parse_range("bytes=0-", 0), Err(()));
    }
}
