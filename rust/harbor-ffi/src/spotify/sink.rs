//! The audio output for librespot on tvOS.
//!
//! Upstream (src-tauri/src/music/spotify/player.rs) opens librespot's default backend
//! (`audio_backend::find(None)`, rodio over cpal) with `AudioFormat::F32`. cpal/rodio have no tvOS
//! output, so the TV gives the player this sink instead: every decoded packet (44.1 kHz,
//! interleaved stereo, already scaled by the soft mixer) goes into a lock-free single-producer /
//! single-consumer ring, and Swift drains it from an `AVAudioSourceNode` render callback
//! (`harbor_spotify_pcm_read`, App/Sources/Music/SpotifyPlayback.swift).
//!
//! - Producer: librespot's player thread (`Sink::write`). It blocks while the ring is full, which
//!   paces decoding to real time the way a hardware sink does. If the consumer does not read for
//!   `STALL` while the ring is full (the audio engine is not running), the write fails and the
//!   player pauses itself (`handle_pause`), rather than hanging its command loop.
//! - Consumer: the real-time audio thread. `read_planar` never blocks, locks or allocates; what the
//!   ring cannot supply is silence.
//! - Upstream's rodio sink drains on `stop` (sleep_until_end), so the end of a track is heard. The
//!   TV does the same, except after a pause or skip the host asked for (`discard_on_stop` /
//!   `request_flush`), when the buffered half second is dropped so the button responds at once.
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use librespot_playback::audio_backend::{Sink, SinkError, SinkResult};
use librespot_playback::convert::Converter;
use librespot_playback::decoder::AudioPacket;
use librespot_playback::{NUM_CHANNELS, SAMPLE_RATE};

/// Half a second of interleaved stereo at 44.1 kHz: enough to ride out a late decode, short enough
/// that the reported position is close to what is heard.
pub const RING_SAMPLES: usize = (SAMPLE_RATE as usize) * (NUM_CHANNELS as usize) / 2;
/// How long a full ring may go unread before the write gives up.
pub const STALL: Duration = Duration::from_secs(2);
const WAIT_STEP: Duration = Duration::from_millis(3);

pub struct PcmRing {
    /// f32 bit patterns; atomics keep the SPSC hand-off free of `unsafe`.
    samples: Box<[AtomicU32]>,
    /// Total samples ever written / read. Only the producer stores `written`; only the consumer
    /// stores `read`. Both only grow, so `written - read` is the fill.
    written: AtomicUsize,
    read: AtomicUsize,
    /// Asked from any thread; the consumer drops everything buffered on its next read.
    flush: AtomicBool,
    /// The next `Sink::stop` (a pause the host asked for) flushes instead of draining.
    discard_on_stop: AtomicBool,
}

impl PcmRing {
    pub fn new(capacity: usize) -> Self {
        let capacity = capacity.max(NUM_CHANNELS as usize * 64);
        Self {
            samples: (0..capacity).map(|_| AtomicU32::new(0)).collect(),
            written: AtomicUsize::new(0),
            read: AtomicUsize::new(0),
            flush: AtomicBool::new(false),
            discard_on_stop: AtomicBool::new(false),
        }
    }

    pub fn capacity(&self) -> usize {
        self.samples.len()
    }

    /// Samples waiting to be heard (both channels counted).
    pub fn buffered(&self) -> usize {
        self.written
            .load(Ordering::Acquire)
            .saturating_sub(self.read.load(Ordering::Acquire))
    }

    /// Seconds of audio waiting in the ring, for the heard position.
    pub fn buffered_seconds(&self) -> f64 {
        self.buffered() as f64 / (SAMPLE_RATE as f64 * NUM_CHANNELS as f64)
    }

    pub fn request_flush(&self) {
        self.flush.store(true, Ordering::Release);
    }

    pub fn discard_next_stop(&self) {
        self.discard_on_stop.store(true, Ordering::Release);
    }

    /// A new track starts: a discard asked for while the sink was already stopped must not cut
    /// the end of this one.
    pub fn keep_next_stop(&self) {
        self.discard_on_stop.store(false, Ordering::Release);
    }

    /// Producer: copies `data` in, waiting for room. Fails when the consumer stops reading for
    /// `stall` while the ring is full.
    pub fn push(&self, data: &[f32], stall: Duration) -> Result<(), String> {
        let capacity = self.capacity();
        let mut offset = 0;
        let mut waiting: Option<(usize, Instant)> = None;
        while offset < data.len() {
            let written = self.written.load(Ordering::Relaxed);
            let read = self.read.load(Ordering::Acquire);
            let free = capacity.saturating_sub(written.saturating_sub(read));
            if free == 0 {
                match waiting {
                    Some((mark, since)) if mark == read => {
                        if since.elapsed() >= stall {
                            return Err("the audio output stopped reading".to_string());
                        }
                    }
                    _ => waiting = Some((read, Instant::now())),
                }
                std::thread::sleep(WAIT_STEP);
                continue;
            }
            waiting = None;
            let count = free.min(data.len() - offset);
            for (i, sample) in data[offset..offset + count].iter().enumerate() {
                self.samples[(written + i) % capacity].store(sample.to_bits(), Ordering::Relaxed);
            }
            self.written.store(written + count, Ordering::Release);
            offset += count;
        }
        Ok(())
    }

    /// Consumer (real-time thread): de-interleaves up to `min(left.len(), right.len())` frames and
    /// fills the rest with silence. Returns the frames that came from the ring.
    pub fn read_planar(&self, left: &mut [f32], right: &mut [f32]) -> usize {
        let frames = left.len().min(right.len());
        let capacity = self.capacity();
        let written = self.written.load(Ordering::Acquire);
        let mut read = self.read.load(Ordering::Relaxed);
        if self.flush.swap(false, Ordering::AcqRel) {
            // Keep the frame alignment: `written` is always a whole number of frames.
            read = written;
        }
        let available = written.saturating_sub(read) / NUM_CHANNELS as usize;
        let count = available.min(frames);
        for i in 0..count {
            let at = read + i * NUM_CHANNELS as usize;
            left[i] = f32::from_bits(self.samples[at % capacity].load(Ordering::Relaxed));
            right[i] = f32::from_bits(self.samples[(at + 1) % capacity].load(Ordering::Relaxed));
        }
        for sample in left[count..frames].iter_mut() {
            *sample = 0.0;
        }
        for sample in right[count..frames].iter_mut() {
            *sample = 0.0;
        }
        self.read
            .store(read + count * NUM_CHANNELS as usize, Ordering::Release);
        count
    }

    /// Waits until the consumer has played everything written, it stops reading for `stall`, or
    /// a flush empties the ring.
    pub fn wait_drained(&self, stall: Duration) {
        let mut mark = (self.read.load(Ordering::Acquire), Instant::now());
        loop {
            if self.buffered() == 0 || self.flush.load(Ordering::Acquire) {
                return;
            }
            let read = self.read.load(Ordering::Acquire);
            if read != mark.0 {
                mark = (read, Instant::now());
            } else if mark.1.elapsed() >= stall {
                return;
            }
            std::thread::sleep(WAIT_STEP);
        }
    }
}

/// librespot `Sink` over a shared `PcmRing`.
pub struct RingSink {
    ring: Arc<PcmRing>,
}

impl RingSink {
    pub fn new(ring: Arc<PcmRing>) -> Self {
        Self { ring }
    }
}

impl Sink for RingSink {
    fn start(&mut self) -> SinkResult<()> {
        Ok(())
    }

    fn stop(&mut self) -> SinkResult<()> {
        if self.ring.discard_on_stop.swap(false, Ordering::AcqRel) {
            self.ring.request_flush();
        } else {
            self.ring.wait_drained(STALL);
        }
        Ok(())
    }

    fn write(&mut self, packet: AudioPacket, converter: &mut Converter) -> SinkResult<()> {
        match packet {
            AudioPacket::Samples(samples) => {
                let converted = converter.f64_to_f32(&samples);
                self.ring.push(&converted, STALL).map_err(SinkError::OnWrite)
            }
            // Only the passthrough decoder yields raw Ogg pages, and the TV never enables it.
            AudioPacket::Raw(_) => Err(SinkError::InvalidParams(
                "the tvOS sink takes decoded samples only".to_string(),
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frames(ring: &PcmRing, count: usize) -> (Vec<f32>, Vec<f32>, usize) {
        let mut left = vec![9.0; count];
        let mut right = vec![9.0; count];
        let got = ring.read_planar(&mut left, &mut right);
        (left, right, got)
    }

    #[test]
    fn interleaved_samples_come_out_as_left_and_right() {
        let ring = PcmRing::new(256);
        ring.push(&[0.1, -0.1, 0.2, -0.2, 0.3, -0.3], STALL).unwrap();
        assert_eq!(ring.buffered(), 6);
        let (left, right, got) = frames(&ring, 5);
        assert_eq!(got, 3);
        assert_eq!(&left[..3], &[0.1, 0.2, 0.3]);
        assert_eq!(&right[..3], &[-0.1, -0.2, -0.3]);
        // What the ring cannot supply is silence, never stale data.
        assert_eq!(&left[3..], &[0.0, 0.0]);
        assert_eq!(&right[3..], &[0.0, 0.0]);
        assert_eq!(ring.buffered(), 0);
    }

    #[test]
    fn the_ring_wraps_around_its_end() {
        let ring = PcmRing::new(128);
        let block: Vec<f32> = (0..100).map(|i| i as f32).collect();
        for _ in 0..5 {
            ring.push(&block, STALL).unwrap();
            let (left, right, got) = frames(&ring, 50);
            assert_eq!(got, 50);
            assert_eq!(left[0], 0.0);
            assert_eq!(right[0], 1.0);
            assert_eq!(left[49], 98.0);
            assert_eq!(right[49], 99.0);
        }
    }

    #[test]
    fn a_full_ring_waits_for_the_reader() {
        let ring = Arc::new(PcmRing::new(128));
        let reader = ring.clone();
        let consumer = std::thread::spawn(move || {
            let mut total = 0;
            let mut left = [0.0f32; 16];
            let mut right = [0.0f32; 16];
            let deadline = Instant::now() + Duration::from_secs(10);
            while total < 500 && Instant::now() < deadline {
                total += reader.read_planar(&mut left, &mut right);
                std::thread::sleep(Duration::from_millis(1));
            }
            total
        });
        let data: Vec<f32> = (0..1000).map(|i| i as f32).collect();
        ring.push(&data, STALL).expect("the reader makes room");
        assert_eq!(consumer.join().unwrap(), 500);
    }

    #[test]
    fn a_full_ring_nobody_reads_fails_instead_of_hanging() {
        let ring = PcmRing::new(128);
        let started = Instant::now();
        let error = ring
            .push(&vec![0.5; 400], Duration::from_millis(60))
            .expect_err("no consumer");
        assert!(error.contains("stopped reading"));
        assert!(started.elapsed() < Duration::from_secs(2));
        assert_eq!(ring.buffered(), 128);
    }

    #[test]
    fn a_flush_drops_what_is_buffered_on_the_next_read() {
        let ring = PcmRing::new(256);
        ring.push(&[1.0; 64], STALL).unwrap();
        ring.request_flush();
        let (left, _, got) = frames(&ring, 8);
        assert_eq!(got, 0);
        assert_eq!(left, vec![0.0; 8]);
        ring.push(&[0.25, 0.75], STALL).unwrap();
        let (left, right, got) = frames(&ring, 1);
        assert_eq!((got, left[0], right[0]), (1, 0.25, 0.75));
    }

    #[test]
    fn stop_drains_unless_the_host_asked_to_discard() {
        let ring = Arc::new(PcmRing::new(256));
        let mut sink = RingSink::new(ring.clone());
        // Nobody reads: stop gives up after the stall instead of waiting forever. Use a short
        // ring fill so the test does not wait the full STALL on the drain.
        ring.push(&[0.5; 8], STALL).unwrap();
        ring.discard_next_stop();
        sink.stop().unwrap();
        assert!(!ring.discard_on_stop.load(Ordering::Acquire));
        let (_, _, got) = frames(&ring, 8);
        assert_eq!(got, 0, "a discarded stop flushes");

        ring.push(&[0.5; 8], STALL).unwrap();
        let reader = ring.clone();
        let consumer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(20));
            let mut left = [0.0f32; 8];
            let mut right = [0.0f32; 8];
            reader.read_planar(&mut left, &mut right)
        });
        sink.stop().unwrap();
        assert_eq!(ring.buffered(), 0, "a plain stop waits until the tail is heard");
        assert_eq!(consumer.join().unwrap(), 4);
    }

    #[test]
    fn half_a_second_of_stereo_fits() {
        assert_eq!(RING_SAMPLES, 44_100);
        let ring = PcmRing::new(RING_SAMPLES);
        ring.push(&vec![0.0; RING_SAMPLES], STALL).unwrap();
        assert!((ring.buffered_seconds() - 0.5).abs() < 1e-9);
    }
}
