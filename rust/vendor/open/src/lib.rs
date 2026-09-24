//! Harbor tvOS stub of `open` 5.4.4 (see Cargo.toml). Only the entry points librespot-oauth 0.8
//! can reach are kept, with upstream's signatures; each one fails with `Unsupported`.
use std::{ffi::OsStr, io, thread};

fn unsupported() -> io::Error {
    io::Error::new(io::ErrorKind::Unsupported, "there is no browser to open on this device")
}

/// Upstream opens `path` with the default application.
pub fn that(path: impl AsRef<OsStr>) -> io::Result<()> {
    let _ = path.as_ref();
    Err(unsupported())
}

/// Upstream opens `path` on a new thread; librespot-oauth ignores the handle.
pub fn that_in_background(path: impl AsRef<OsStr>) -> thread::JoinHandle<io::Result<()>> {
    let path = path.as_ref().to_os_string();
    thread::spawn(move || that(path))
}

/// Upstream opens `path` with a named application.
pub fn with(path: impl AsRef<OsStr>, app: impl Into<String>) -> io::Result<()> {
    let _ = (path.as_ref(), app.into());
    Err(unsupported())
}
