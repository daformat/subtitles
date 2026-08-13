//! subs-core — the portable audio front end.
//!
//! Capture → ring buffer → resample → voice gate → pre-roll, then hand 16 kHz
//! mono frames to whoever transcribes them. The core deliberately does *not*
//! transcribe: the only supported engine is FluidAudio, which runs Parakeet on
//! the Apple Neural Engine from Swift and cannot be driven from Rust.
//!
//! What is left here is the part that is platform-portable and was worth
//! measuring: the realtime-safe capture path, the resampler, and the gating that
//! keeps a day of mostly-silence cheap. Porting to Windows means replacing the
//! tap and the renderer, not this crate.
//!
//! Naming follows C conventions (`subs_event_t`, not `SubsEvent`) so the
//! generated header reads naturally from Swift.
//!
//! Threading contract:
//!   * `subs_push_audio` is called from the realtime audio thread. It copies into
//!     the ring and returns. Nothing else.
//!   * everything else runs on the worker thread started by `subs_start`.
//!   * both callbacks fire on the *worker* thread, never the audio thread and
//!     never the main thread. Callers must marshal to their UI thread themselves.

#![allow(non_camel_case_types)] // C ABI naming, intentional

mod resample;
mod ring;

use std::ffi::{c_void, CString};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

const OUT_RATE: u32 = 16000;

// Voice activity thresholds. Gating during silence is where the CPU saving is:
// most of a day's system audio is nothing at all.
//
// Two *separate* timeouts, deliberately:
//
//   GATE_HANGOVER    — stop forwarding audio. Cheap and reversible; forwarding
//                      resumes the instant speech returns and no engine state is
//                      lost.
//   ENDPOINT_SILENCE — declare the utterance finished, which makes the engine
//                      flush and reset. Destructive, so it must be confident.
//                      Speakers routinely pause ~1 s mid-sentence, and resetting
//                      on those pauses chops one sentence into several.
const GATE_OPEN_DBFS: f32 = -60.0;
const GATE_HANGOVER: Duration = Duration::from_millis(400);
const ENDPOINT_SILENCE: Duration = Duration::from_millis(1600);

#[repr(C)]
#[derive(Clone, Copy)]
pub struct subs_config_t {
    pub input_sample_rate: u32,
    pub input_channels: u16,
}

/// Speech stopped briefly. Display-only — the engine keeps its context, so this
/// costs no accuracy. Emitted at GATE_HANGOVER, long before the destructive
/// ENDPOINT, so the renderer can break a page at a natural pause instead of
/// wherever the text happens to overflow.
pub const SUBS_EVENT_PAUSE: i32 = 0;
/// Long enough silence to call the utterance over: flush and reset the engine.
pub const SUBS_EVENT_ENDPOINT: i32 = 1;
/// Once a second: gate state, peak level, and the health counters.
pub const SUBS_EVENT_STATUS: i32 = 2;

#[repr(C)]
pub struct subs_event_t {
    pub kind: i32,
    /// UTF-8, valid only for the duration of the callback.
    pub text: *const std::ffi::c_char,
    /// Seconds of audio consumed so far.
    pub audio_time: f64,
    /// Peak level of the last second, dBFS. -120 means digital silence.
    pub peak_dbfs: f32,
    /// Consecutive seconds of *exactly zero* samples — the signature of a missing
    /// audio-capture grant, which Core Audio reports no other way.
    pub silent_seconds: f32,
    /// Samples the ring dropped because the worker fell behind. Should stay 0.
    pub dropped: u64,
}

pub type subs_event_cb = Option<unsafe extern "C" fn(*const subs_event_t, *mut c_void)>;

/// Receives gated, pre-rolled 16 kHz mono frames on the worker thread.
pub type subs_audio_cb = Option<unsafe extern "C" fn(*const f32, usize, *mut c_void)>;

struct Callback {
    cb: subs_event_cb,
    ctx: *mut c_void,
}
unsafe impl Send for Callback {}

struct AudioSink {
    cb: subs_audio_cb,
    ctx: *mut c_void,
}
unsafe impl Send for AudioSink {}

impl Callback {
    fn emit(&self, kind: i32, text: &str, audio_time: f64, peak: f32, silent: f32, dropped: u64) {
        let Some(f) = self.cb else { return };
        let Ok(c) = CString::new(text) else { return };
        let ev = subs_event_t {
            kind,
            text: c.as_ptr(),
            audio_time,
            peak_dbfs: peak,
            silent_seconds: silent,
            dropped,
        };
        unsafe { f(&ev, self.ctx) }
    }
}

pub struct Engine {
    ring: Arc<ring::Ring>,
    running: Arc<AtomicBool>,
    worker: Option<std::thread::JoinHandle<()>>,
    cb: Option<Callback>,
    audio_sink: Option<AudioSink>,
    input_rate: u32,
    channels: u16,
}

// ── C ABI ────────────────────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn subs_create(cfg: *const subs_config_t) -> *mut Engine {
    if cfg.is_null() {
        return std::ptr::null_mut();
    }
    let cfg = unsafe { &*cfg };
    if cfg.input_sample_rate == 0 || cfg.input_channels == 0 {
        return std::ptr::null_mut();
    }

    // ~4 seconds of stereo 48 kHz. Large enough that a scheduling hiccup never
    // costs audio; small enough that a stall shows up as latency rather than
    // being silently absorbed.
    let ring = Arc::new(ring::Ring::new(
        (cfg.input_sample_rate as usize) * (cfg.input_channels as usize) * 4,
    ));

    Box::into_raw(Box::new(Engine {
        ring,
        running: Arc::new(AtomicBool::new(false)),
        worker: None,
        cb: None,
        audio_sink: None,
        input_rate: cfg.input_sample_rate,
        channels: cfg.input_channels,
    }))
}

#[no_mangle]
pub extern "C" fn subs_set_callback(e: *mut Engine, cb: subs_event_cb, ctx: *mut c_void) {
    let Some(e) = (unsafe { e.as_mut() }) else { return };
    e.cb = Some(Callback { cb, ctx });
}

/// Must be set before `subs_start`.
#[no_mangle]
pub extern "C" fn subs_set_audio_callback(e: *mut Engine, cb: subs_audio_cb, ctx: *mut c_void) {
    let Some(e) = (unsafe { e.as_mut() }) else { return };
    e.audio_sink = Some(AudioSink { cb, ctx });
}

/// Realtime-safe: copies into the ring and returns. Called from the audio thread.
#[no_mangle]
pub extern "C" fn subs_push_audio(e: *mut Engine, samples: *const f32, count: usize) {
    let Some(e) = (unsafe { e.as_ref() }) else { return };
    if samples.is_null() || count == 0 {
        return;
    }
    let slice = unsafe { std::slice::from_raw_parts(samples, count) };
    e.ring.push(slice);
}

/// Starts the worker. Returns 0 on success.
#[no_mangle]
pub extern "C" fn subs_start(e: *mut Engine) -> i32 {
    let Some(e) = (unsafe { e.as_mut() }) else { return -1 };
    if e.running.load(Ordering::SeqCst) {
        return 0;
    }
    let Some(cb) = e.cb.take() else { return -2 };
    let sink = e.audio_sink.take();

    e.running.store(true, Ordering::SeqCst);
    let running = e.running.clone();
    let ring = e.ring.clone();
    let input_rate = e.input_rate;
    let channels = e.channels;

    e.worker = Some(std::thread::spawn(move || {
        let mut resampler = resample::Resampler::new(input_rate, OUT_RATE);

        let mut raw = vec![0.0f32; 16384];
        let mut mono: Vec<f32> = Vec::with_capacity(4096);

        let mut audio_time = 0.0f64;
        let mut zero_run = 0.0f32;
        let mut last_voice: Option<Instant> = None;
        let mut endpointed = true;
        let mut peak_dbfs = -120.0f32;
        let mut was_gated = false;
        let mut last_status = Instant::now();

        // ~1 s of recent audio, replayed when the engine's context is empty so no
        // word starts cold.
        let preroll_cap = OUT_RATE as usize;
        let mut preroll: std::collections::VecDeque<f32> =
            std::collections::VecDeque::with_capacity(preroll_cap + 8192);
        // Only prime after a reset. The engine keeps its own rolling buffer across
        // gate cycles, so replaying on every gate open feeds it the same audio
        // twice and it stutters.
        let mut needs_preroll = true;

        // Bound the backlog. If the worker falls behind, the ring would otherwise
        // stay full and every subtitle would run permanently late, since a live
        // stream can never be caught up. Discarding stale audio costs a few words
        // once; carrying the backlog costs latency forever. Done consumer-side:
        // it owns the read index, so skipping forward is race-free and keeps
        // `push` a plain memcpy.
        let max_backlog = (input_rate as usize) * (channels as usize) * 3 / 2; // 1.5 s

        while running.load(Ordering::SeqCst) {
            if ring.available() > max_backlog {
                let mut discard = ring.available() - max_backlog;
                while discard > 0 {
                    let take = discard.min(raw.len());
                    let got = ring.pop(&mut raw[..take]);
                    if got == 0 {
                        break;
                    }
                    discard -= got;
                }
            }

            let n = ring.pop(&mut raw);
            if n == 0 {
                std::thread::sleep(Duration::from_millis(5));
                continue;
            }
            let block = &raw[..n];

            // Watchdog. Without the TCC audio grant the tap delivers
            // perfectly-timed, correctly-sized, *all-zero* buffers and reports no
            // error anywhere. Exact-zero is the signature; real silence from a
            // running output device carries at least dither. The app correlates
            // this with "is any process actually playing" before blaming the user.
            let block_secs = n as f64 / (input_rate as f64 * channels as f64);
            if block.iter().all(|s| *s == 0.0) {
                zero_run += block_secs as f32;
            } else {
                zero_run = 0.0;
            }

            mono.clear();
            resampler.process(block, channels as usize, &mut mono);
            audio_time += block_secs;

            let rms = if mono.is_empty() {
                0.0
            } else {
                (mono.iter().map(|s| s * s).sum::<f32>() / mono.len() as f32).sqrt()
            };
            let dbfs = if rms > 0.0 {
                20.0 * rms.log10()
            } else {
                -120.0
            };
            let now = Instant::now();
            if dbfs > peak_dbfs {
                peak_dbfs = dbfs;
            }
            if dbfs > GATE_OPEN_DBFS {
                last_voice = Some(now);
                endpointed = false;
            }
            let since_voice = last_voice.map(|t| now.duration_since(t));
            let gated_on = since_voice.map(|d| d < GATE_HANGOVER).unwrap_or(false);
            let should_endpoint =
                !endpointed && since_voice.map(|d| d >= ENDPOINT_SILENCE).unwrap_or(false);

            if gated_on {
                if let Some(sink) = sink.as_ref() {
                    if let Some(f) = sink.cb {
                        if needs_preroll {
                            needs_preroll = false;
                            let history: Vec<f32> = preroll.iter().copied().collect();
                            if !history.is_empty() {
                                unsafe { f(history.as_ptr(), history.len(), sink.ctx) }
                            }
                        }
                        unsafe { f(mono.as_ptr(), mono.len(), sink.ctx) }
                    }
                }
            }

            if was_gated && !gated_on {
                cb.emit(SUBS_EVENT_PAUSE, "", audio_time, peak_dbfs, zero_run, 0);
            }

            // Keep the pre-roll current regardless of gate state — its whole
            // purpose is to hold the audio from *before* the gate opened.
            for &sample in mono.iter() {
                if preroll.len() == preroll_cap {
                    preroll.pop_front();
                }
                preroll.push_back(sample);
            }
            was_gated = gated_on;

            if should_endpoint {
                endpointed = true;
                needs_preroll = true;
                cb.emit(SUBS_EVENT_ENDPOINT, "", audio_time, peak_dbfs, zero_run, 0);
            }

            if last_status.elapsed() >= Duration::from_secs(1) {
                last_status = now;
                let label = if gated_on { "listening" } else { "idle" };
                cb.emit(
                    SUBS_EVENT_STATUS,
                    label,
                    audio_time,
                    peak_dbfs,
                    zero_run,
                    ring.dropped() as u64,
                );
                peak_dbfs = -120.0;
            }
        }
    }));
    0
}

#[no_mangle]
pub extern "C" fn subs_stop(e: *mut Engine) {
    let Some(e) = (unsafe { e.as_mut() }) else { return };
    e.running.store(false, Ordering::SeqCst);
    if let Some(h) = e.worker.take() {
        let _ = h.join();
    }
}

#[no_mangle]
pub extern "C" fn subs_destroy(e: *mut Engine) {
    if e.is_null() {
        return;
    }
    subs_stop(e);
    drop(unsafe { Box::from_raw(e) });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn null_inputs_are_survivable() {
        assert!(subs_create(std::ptr::null()).is_null());
        subs_push_audio(std::ptr::null_mut(), std::ptr::null(), 0);
        subs_stop(std::ptr::null_mut());
        subs_destroy(std::ptr::null_mut());
    }

    #[test]
    fn create_rejects_nonsense_format() {
        let bad = subs_config_t {
            input_sample_rate: 0,
            input_channels: 2,
        };
        assert!(subs_create(&bad).is_null());
    }

    #[test]
    fn start_requires_an_event_callback() {
        let cfg = subs_config_t {
            input_sample_rate: 48000,
            input_channels: 2,
        };
        let e = subs_create(&cfg);
        assert!(!e.is_null());
        assert_eq!(subs_start(e), -2, "start must fail without a callback");
        subs_destroy(e);
    }

    #[test]
    fn push_before_start_is_buffered_not_lost() {
        let cfg = subs_config_t {
            input_sample_rate: 48000,
            input_channels: 2,
        };
        let e = subs_create(&cfg);
        let samples = vec![0.5f32; 960];
        subs_push_audio(e, samples.as_ptr(), samples.len());
        let eng = unsafe { &*e };
        assert_eq!(eng.ring.available(), 960);
        subs_destroy(e);
    }
}
