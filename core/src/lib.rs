//! subs-core — the portable half of the pipeline.
//!
//! Owns everything from the ring buffer through the stabilizer (PLAN.md §4).
//! The platform layer supplies audio and renders events; it knows nothing about
//! resampling, ASR, or stabilisation. Porting to Windows means replacing the tap
//! and the renderer, not this crate.
//!
//! Naming below deliberately follows C conventions (`subs_event_t`, not
//! `SubsEvent`) so the generated header reads naturally from Swift and C.
//!
//! Threading contract:
//!   * `subs_push_audio` is called from the realtime audio thread. It copies into
//!     the ring and returns. Nothing else.
//!   * everything expensive runs on the worker thread started by `subs_start`.
//!   * the event callback fires on the *worker* thread, not the audio thread and
//!     not the main thread. Callers must marshal to their UI thread themselves.

#![allow(non_camel_case_types)] // C ABI naming, intentional

mod asr;
mod resample;
mod ring;
mod stabilize;
mod textcase;

use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

const OUT_RATE: u32 = 16000;

// Voice activity thresholds. Gating the recognizer off during silence is where
// the real CPU saving is — Spike 0A Finding 2 showed RTF headroom is the scarce
// resource, and most of a day's system audio is silence.
//
// Two *separate* timeouts, deliberately:
//
//   GATE_HANGOVER    — stop feeding the recognizer, purely to save CPU. Cheap and
//                      reversible; feeding resumes the instant speech returns and
//                      no recognizer state is lost.
//   ENDPOINT_SILENCE — declare the utterance finished: flush the line and reset.
//                      Destructive, so it must be confident. Speakers routinely
//                      pause ~1 s mid-sentence, and resetting on those pauses
//                      chops a single sentence into several lines.
const GATE_OPEN_DBFS: f32 = -60.0;
const GATE_HANGOVER: Duration = Duration::from_millis(400);
const ENDPOINT_SILENCE: Duration = Duration::from_millis(1600);

#[repr(C)]
#[derive(Clone, Copy)]
pub struct subs_config_t {
    pub model_dir: *const c_char,
    pub num_threads: i32,
    pub input_sample_rate: u32,
    pub input_channels: u16,
    pub int8: i32,
}

pub const SUBS_EVENT_COMMITTED: i32 = 0;
pub const SUBS_EVENT_TENTATIVE: i32 = 1;
pub const SUBS_EVENT_STATUS: i32 = 2;
pub const SUBS_EVENT_ENDPOINT: i32 = 3;
/// Speech stopped briefly. Display-only: the recognizer keeps its context, so
/// this costs no accuracy. Emitted at GATE_HANGOVER, long before the far more
/// destructive ENDPOINT, so the renderer can start a fresh page at a natural
/// break instead of clearing mid-phrase when the text happens to overflow.
pub const SUBS_EVENT_PAUSE: i32 = 4;

#[repr(C)]
pub struct subs_event_t {
    pub kind: i32,
    /// UTF-8, valid only for the duration of the callback.
    pub text: *const c_char,
    /// Seconds of audio consumed so far.
    pub audio_time: f64,
    /// Rolling decode-CPU ÷ audio-duration. Sustained > 0.8 means trouble.
    pub rtf: f32,
    /// Consecutive seconds of *exactly zero* samples. See the watchdog note below.
    pub silent_seconds: f32,
    /// Samples the ring dropped because the worker fell behind. Should stay 0.
    pub dropped: u64,
}

pub type subs_event_cb = Option<unsafe extern "C" fn(*const subs_event_t, *mut c_void)>;

struct Callback {
    cb: subs_event_cb,
    ctx: *mut c_void,
}
// Safety: the pointer is opaque to us; the caller guarantees it stays valid
// between subs_set_callback and subs_destroy.
unsafe impl Send for Callback {}

impl Callback {
    fn emit(&self, kind: i32, text: &str, audio_time: f64, rtf: f32, silent: f32, dropped: u64) {
        let Some(f) = self.cb else { return };
        let Ok(c) = CString::new(text) else { return };
        let ev = subs_event_t {
            kind,
            text: c.as_ptr(),
            audio_time,
            rtf,
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
    cfg: OwnedConfig,
}

#[derive(Clone)]
struct OwnedConfig {
    model_dir: String,
    num_threads: i32,
    input_rate: u32,
    channels: u16,
    int8: bool,
}

// ── C ABI ────────────────────────────────────────────────────────────────────

/// Returns null on failure. The model directory must exist and contain
/// encoder/decoder/joiner .onnx files plus tokens.txt.
#[no_mangle]
pub extern "C" fn subs_create(cfg: *const subs_config_t) -> *mut Engine {
    if cfg.is_null() {
        return std::ptr::null_mut();
    }
    let cfg = unsafe { &*cfg };
    let Ok(model_dir) = (unsafe { CStr::from_ptr(cfg.model_dir) }).to_str() else {
        return std::ptr::null_mut();
    };

    // ~4 seconds of stereo 48 kHz. Large enough that a scheduling hiccup on the
    // worker never costs audio; small enough that a stall is visible as latency.
    let ring = Arc::new(ring::Ring::new(
        (cfg.input_sample_rate as usize) * (cfg.input_channels as usize) * 4,
    ));

    Box::into_raw(Box::new(Engine {
        ring,
        running: Arc::new(AtomicBool::new(false)),
        worker: None,
        cb: None,
        cfg: OwnedConfig {
            model_dir: model_dir.to_string(),
            num_threads: cfg.num_threads,
            input_rate: cfg.input_sample_rate,
            channels: cfg.input_channels,
            int8: cfg.int8 != 0,
        },
    }))
}

#[no_mangle]
pub extern "C" fn subs_set_callback(e: *mut Engine, cb: subs_event_cb, ctx: *mut c_void) {
    let Some(e) = (unsafe { e.as_mut() }) else { return };
    e.cb = Some(Callback { cb, ctx });
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

/// Starts the worker. Returns 0 on success, non-zero on failure (bad model path).
#[no_mangle]
pub extern "C" fn subs_start(e: *mut Engine) -> i32 {
    let Some(e) = (unsafe { e.as_mut() }) else { return -1 };
    if e.running.load(Ordering::SeqCst) {
        return 0;
    }
    let Some(cb) = e.cb.take() else { return -2 };

    let mut recognizer = match asr::Recognizer::new(&e.cfg.model_dir, e.cfg.num_threads, e.cfg.int8)
    {
        Ok(r) => r,
        Err(msg) => {
            cb.emit(SUBS_EVENT_STATUS, &format!("error: {msg}"), 0.0, 0.0, 0.0, 0);
            e.cb = Some(cb);
            return -3;
        }
    };

    e.running.store(true, Ordering::SeqCst);
    let running = e.running.clone();
    let ring = e.ring.clone();
    let cfg = e.cfg.clone();

    e.worker = Some(std::thread::spawn(move || {
        let mut resampler = resample::Resampler::new(cfg.input_rate, OUT_RATE);
        let mut stab = stabilize::Stabilizer::new();

        let mut raw = vec![0.0f32; 16384];
        let mut mono: Vec<f32> = Vec::with_capacity(4096);

        let mut audio_time = 0.0f64;
        let mut decode_cpu = 0.0f64;
        let mut audio_seen = 0.0f64;
        let mut zero_run = 0.0f32;
        let mut last_voice: Option<Instant> = None;
        let mut endpointed = true;
        let mut peak_dbfs = -120.0f32;
        let mut was_gated = false;
        // ~1 s of recent 16 kHz mono, replayed into the recognizer whenever the
        // gate opens so it never starts a word cold.
        let preroll_cap = OUT_RATE as usize;
        let mut preroll: std::collections::VecDeque<f32> =
            std::collections::VecDeque::with_capacity(preroll_cap + 8192);
        let mut last_status = Instant::now();
        let mut last_tentative = String::new();
        // True until the first word of an utterance is committed; drives capitalisation.
        let mut sentence_start = true;

        // Bound the backlog. If the worker ever falls behind — a burst of system
        // load, a slow decode — the ring would otherwise stay full and every
        // subtitle would run permanently seconds late, since a live stream can
        // never be caught up. Discarding stale audio costs a few dropped words
        // once; carrying the backlog costs latency forever.
        //
        // Done here rather than in the producer: the consumer owns the read index,
        // so skipping forward is race-free and keeps `push` a plain memcpy.
        let max_backlog =
            (cfg.input_rate as usize) * (cfg.channels as usize) * 3 / 2; // 1.5 s

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

            // ── watchdog ──
            // Spike 0B Finding 1: without the TCC audio grant the tap delivers
            // perfectly-timed, correctly-sized, *all-zero* buffers and reports no
            // error anywhere. Exact-zero is the signature — real silence from a
            // running output device carries at least dither. The app correlates
            // this with "is any process actually playing" before accusing the user.
            let block_secs = n as f64 / (cfg.input_rate as f64 * cfg.channels as f64);
            if block.iter().all(|s| *s == 0.0) {
                zero_run += block_secs as f32;
            } else {
                zero_run = 0.0;
            }

            mono.clear();
            resampler.process(block, cfg.channels as usize, &mut mono);
            audio_time += block_secs;
            audio_seen += block_secs;

            // ── energy gate ──
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
                let t0 = Instant::now();
                // Pre-roll on every gate opening.
                //
                // Two problems, one fix. (1) The gate only opens once a block
                // exceeds the threshold, so the quiet onset of a word is
                // discarded. (2) A streaming Zipformer needs left context; after
                // an endpoint reset it starts cold and emits nothing for a second
                // or more. Measured: without this the second utterance lost its
                // first six words, while the same model decoding the same clip
                // offline (one continuous stream, never reset) got them all.
                if !was_gated {
                    let history: Vec<f32> = preroll.iter().copied().collect();
                    if !history.is_empty() {
                        recognizer.accept(&history, OUT_RATE as i32);
                    }
                }
                recognizer.accept(&mono, OUT_RATE as i32);
                recognizer.decode();
                decode_cpu += t0.elapsed().as_secs_f64();

                let update = stab.push(&recognizer.tokens());
                let rtf = if audio_seen > 0.0 {
                    (decode_cpu / audio_seen) as f32
                } else {
                    0.0
                };
                // A COMMITTED event moves text out of the tentative tail, so the
                // tail must be republished even when its *string* is unchanged —
                // otherwise the renderer keeps drawing the old tail alongside the
                // text it just committed, and the word appears twice for a frame.
                let committed_now = !update.newly_committed.is_empty();
                let cased_committed = textcase::natural_case(&update.newly_committed, sentence_start);
                // The tail is only sentence-initial while nothing has been
                // committed yet this utterance.
                let cased_tentative = textcase::natural_case(
                    &update.tentative,
                    sentence_start && !committed_now,
                );
                if committed_now {
                    sentence_start = false;
                    cb.emit(
                        SUBS_EVENT_COMMITTED,
                        &cased_committed,
                        audio_time,
                        rtf,
                        zero_run,
                        ring.dropped() as u64,
                    );
                }
                if committed_now || update.tentative != last_tentative {
                    last_tentative = update.tentative.clone();
                    cb.emit(
                        SUBS_EVENT_TENTATIVE,
                        &cased_tentative,
                        audio_time,
                        rtf,
                        zero_run,
                        ring.dropped() as u64,
                    );
                }
            }

            if was_gated && !gated_on {
                cb.emit(SUBS_EVENT_PAUSE, "", audio_time, 0.0, zero_run, 0);
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
                // Flush before resetting. Anything still tentative has been shown
                // to the reader but never confirmed; dropping it on reset silently
                // loses the tail of every utterance the model was unsure about.
                let tail = textcase::natural_case(&stab.flush(), sentence_start);
                if !tail.is_empty() {
                    cb.emit(
                        SUBS_EVENT_COMMITTED,
                        &tail,
                        audio_time,
                        0.0,
                        zero_run,
                        ring.dropped() as u64,
                    );
                }
                recognizer.reset();
                stab.reset();
                last_tentative.clear();
                sentence_start = true;
                cb.emit(SUBS_EVENT_ENDPOINT, "", audio_time, 0.0, zero_run, 0);
            }

            if last_status.elapsed() >= Duration::from_secs(1) {
                last_status = now;
                let rtf = if audio_seen > 0.0 {
                    (decode_cpu / audio_seen) as f32
                } else {
                    0.0
                };
                let label = format!(
                    "{} {:.0}dB",
                    if gated_on { "listening" } else { "idle" },
                    peak_dbfs
                );
                peak_dbfs = -120.0;
                cb.emit(
                    SUBS_EVENT_STATUS,
                    &label,
                    audio_time,
                    rtf,
                    zero_run,
                    ring.dropped() as u64,
                );
                // rolling window, so a bad minute does not haunt the average
                decode_cpu = 0.0;
                audio_seen = 0.0;
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
    fn create_rejects_missing_model_dir() {
        let dir = CString::new("/nonexistent/model/dir").unwrap();
        let cfg = subs_config_t {
            model_dir: dir.as_ptr(),
            num_threads: 2,
            input_sample_rate: 48000,
            input_channels: 2,
            int8: 0,
        };
        // creation succeeds (it is just bookkeeping); start is where the model loads
        let e = subs_create(&cfg);
        assert!(!e.is_null());
        unsafe extern "C" fn noop(_: *const subs_event_t, _: *mut c_void) {}
        subs_set_callback(e, Some(noop), std::ptr::null_mut());
        assert_ne!(subs_start(e), 0, "start must fail on a bad model dir");
        subs_destroy(e);
    }

    #[test]
    fn push_before_start_is_buffered_not_lost() {
        let dir = CString::new("/tmp").unwrap();
        let cfg = subs_config_t {
            model_dir: dir.as_ptr(),
            num_threads: 1,
            input_sample_rate: 48000,
            input_channels: 2,
            int8: 0,
        };
        let e = subs_create(&cfg);
        let samples = vec![0.5f32; 960];
        subs_push_audio(e, samples.as_ptr(), samples.len());
        let eng = unsafe { &*e };
        assert_eq!(eng.ring.available(), 960);
        subs_destroy(e);
    }
}
