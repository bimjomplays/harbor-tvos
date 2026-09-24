// Harbor tvOS patch of librqbit-sha1-wrapper 4.1.0: same public interface (`ISha1`, `Sha1`),
// backed by the pure-Rust `sha1` crate whichever feature librqbit selects. See Cargo.toml.

pub trait ISha1 {
    fn new() -> Self;
    fn update(&mut self, buf: &[u8]);
    fn finish(self) -> [u8; 20];
}

pub struct Sha1Rust {
    inner: sha1::Sha1,
}

impl ISha1 for Sha1Rust {
    fn new() -> Self {
        use sha1::Digest;
        Self { inner: sha1::Sha1::new() }
    }

    fn update(&mut self, buf: &[u8]) {
        use sha1::Digest;
        self.inner.update(buf);
    }

    fn finish(self) -> [u8; 20] {
        use sha1::Digest;
        self.inner.finalize().into()
    }
}

pub type Sha1 = Sha1Rust;

#[cfg(test)]
mod tests {
    use super::{ISha1, Sha1};

    #[test]
    fn matches_the_known_sha1_of_abc() {
        let mut h = Sha1::new();
        h.update(b"abc");
        let hex: String = h.finish().iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, "a9993e364706816aba3e25717850c26c9cd0d89d");
    }
}
