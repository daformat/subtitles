//! Interleaved f32 at the input's rate → 16 kHz mono f32.
//!
//! Spike 0B confirmed the tap always hands us 48 kHz / 2 ch / f32 packed, and
//! the models want 16 kHz mono — an exact 3:1 decimation, which keeps its own
//! path below. A microphone is not always 48 kHz: AirPods' is 24 kHz, many
//! USB microphones are 44.1 kHz, and an input at either used to abort the
//! app on the assert this replaced. Those go through a fractional path.
//!
//! Decimation without a low-pass first would fold everything above 8 kHz back
//! into the speech band as aliasing, which is exactly where the ASR features
//! live. So: downmix, then a windowed-sinc FIR evaluated only at output
//! positions (1/3 the multiply-accumulates of filtering then discarding).
//! The fractional path evaluates the same kind of filter between input
//! samples, from a table of it at `PHASES` offsets, interpolated.

const TAPS: usize = 96;
const HALF: usize = TAPS / 2;
const CUTOFF_HZ: f32 = 7200.0; // below the 8 kHz Nyquist of 16 kHz, with margin
/// Offsets between two input samples the fractional filter is tabled at.
const PHASES: usize = 256;

pub struct Resampler {
    taps: [f32; TAPS],
    hist: [f32; TAPS],
    pos: usize,   // next write index in the circular history
    phase: usize, // input samples seen, mod `decim`
    decim: usize,
    /// Set for a rate that is not a whole multiple of the output's.
    fractional: Option<Fractional>,
}

/// Where the next output falls between input samples, and the filter to
/// weigh them by there: `(PHASES + 1)` rows of `TAPS`, each summing to one.
struct Fractional {
    table: Vec<f32>,
    /// Input samples per output sample.
    step: f64,
    /// The next output's position, in input samples since the start.
    next: f64,
    /// Input samples seen.
    count: u64,
}

impl Resampler {
    pub fn new(input_rate: u32, output_rate: u32) -> Self {
        assert!(input_rate > 0 && output_rate > 0, "sample rates must be positive");
        if input_rate % output_rate == 0 {
            return Self::decimating(input_rate, output_rate);
        }
        // The cutoff sits under the lower of the two Nyquists, so an input
        // slower than the output (an old 8 kHz headset) is not asked for what
        // it does not have.
        let nyquist = input_rate.min(output_rate) as f32 / 2.0;
        let fc = CUTOFF_HZ.min(nyquist * 0.9) / input_rate as f32;
        let mut table = vec![0.0f32; (PHASES + 1) * TAPS];
        for j in 0..=PHASES {
            let frac = j as f32 / PHASES as f32;
            let row = &mut table[j * TAPS..(j + 1) * TAPS];
            let mut sum = 0.0;
            for (k, t) in row.iter_mut().enumerate() {
                // The distance from the output's position, `frac` past sample
                // `base`, to the input sample this tap weighs: tap 0 is the
                // newest, `base + HALF`, and each tap after it one older.
                let x = frac - HALF as f32 + k as f32;
                *t = windowed_sinc(x, fc);
                sum += *t;
            }
            for t in row.iter_mut() {
                *t /= sum; // unity DC gain at every offset
            }
        }
        Resampler {
            taps: [0.0; TAPS],
            hist: [0.0; TAPS],
            pos: 0,
            phase: 0,
            decim: 1,
            fractional: Some(Fractional {
                table,
                step: input_rate as f64 / output_rate as f64,
                next: 0.0,
                count: 0,
            }),
        }
    }

    fn decimating(input_rate: u32, output_rate: u32) -> Self {
        let decim = (input_rate / output_rate) as usize;

        // Windowed sinc low-pass, Blackman window.
        let fc = CUTOFF_HZ / input_rate as f32; // normalised cutoff (cycles/sample)
        let mut taps = [0.0f32; TAPS];
        let mid = (TAPS - 1) as f32 / 2.0;
        let mut sum = 0.0;
        for (i, t) in taps.iter_mut().enumerate() {
            let x = i as f32 - mid;
            let sinc = if x.abs() < 1e-6 {
                2.0 * fc
            } else {
                (2.0 * std::f32::consts::PI * fc * x).sin() / (std::f32::consts::PI * x)
            };
            let n = i as f32 / (TAPS - 1) as f32;
            let w = 0.42 - 0.5 * (2.0 * std::f32::consts::PI * n).cos()
                + 0.08 * (4.0 * std::f32::consts::PI * n).cos();
            *t = sinc * w;
            sum += *t;
        }
        for t in taps.iter_mut() {
            *t /= sum; // unity DC gain
        }

        Resampler {
            taps,
            hist: [0.0; TAPS],
            pos: 0,
            phase: 0,
            decim,
            fractional: None,
        }
    }

    /// Feed interleaved input, append mono 16 kHz samples to `out`.
    ///
    /// Channel count is handled here so the caller never has to care whether the
    /// tap gave us mono or stereo.
    pub fn process(&mut self, input: &[f32], channels: usize, out: &mut Vec<f32>) {
        debug_assert!(channels >= 1);
        for frame in input.chunks_exact(channels) {
            let mono = frame.iter().sum::<f32>() / channels as f32;

            self.hist[self.pos] = mono;
            self.pos = (self.pos + 1) % TAPS;

            if let Some(f) = self.fractional.as_mut() {
                f.count += 1;
                // An output is due once HALF samples past its position are in:
                // the history then holds every sample the filter reaches.
                while f.next.floor() as u64 + HALF as u64 <= f.count - 1 {
                    let base = f.next.floor();
                    let at = (f.next - base) * PHASES as f64;
                    let j = (at as usize).min(PHASES - 1);
                    let blend = (at - j as f64) as f32;
                    // The newest sample the filter reaches, x[base + HALF], is
                    // this many behind the newest in the history.
                    let lag = (f.count - 1 - (base as u64 + HALF as u64)) as usize;
                    let mut idx = (self.pos + 2 * TAPS - 1 - lag) % TAPS;
                    let (lo, hi) = (&f.table[j * TAPS..], &f.table[(j + 1) * TAPS..]);
                    let mut acc = 0.0;
                    for k in 0..TAPS {
                        let w = lo[k] + (hi[k] - lo[k]) * blend;
                        acc += w * self.hist[idx];
                        idx = (idx + TAPS - 1) % TAPS;
                    }
                    out.push(acc);
                    f.next += f.step;
                }
                continue;
            }

            self.phase += 1;
            if self.phase == self.decim {
                self.phase = 0;
                let mut acc = 0.0;
                // hist[pos-1] is the newest sample; walk backwards through the taps
                let mut idx = (self.pos + TAPS - 1) % TAPS;
                for &t in self.taps.iter() {
                    acc += t * self.hist[idx];
                    idx = (idx + TAPS - 1) % TAPS;
                }
                out.push(acc);
            }
        }
    }
}

/// A low-pass at `fc` (cycles per input sample), `x` samples from its centre,
/// under a Blackman window spanning the filter's `TAPS`.
fn windowed_sinc(x: f32, fc: f32) -> f32 {
    use std::f32::consts::PI;
    if x.abs() >= HALF as f32 {
        return 0.0;
    }
    let sinc = if x.abs() < 1e-6 { 2.0 * fc } else { (2.0 * PI * fc * x).sin() / (PI * x) };
    let u = x / HALF as f32; // -1 ..= 1 across the window
    let w = 0.42 + 0.5 * (PI * u).cos() + 0.08 * (2.0 * PI * u).cos();
    sinc * w
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn output_rate_is_one_third() {
        let mut r = Resampler::new(48000, 16000);
        let mut out = Vec::new();
        let input = vec![0.0f32; 4800 * 2]; // 100 ms of stereo
        r.process(&input, 2, &mut out);
        assert_eq!(out.len(), 1600); // 100 ms at 16 kHz
    }

    #[test]
    fn passes_low_frequencies_at_unity() {
        // 440 Hz should survive decimation essentially untouched.
        let mut r = Resampler::new(48000, 16000);
        let mut out = Vec::new();
        let input: Vec<f32> = (0..48000 * 2)
            .map(|i| {
                let t = (i / 2) as f32 / 48000.0;
                (2.0 * std::f32::consts::PI * 440.0 * t).sin()
            })
            .collect();
        r.process(&input, 2, &mut out);

        // skip the filter warm-up, then check the amplitude survived
        let peak = out[TAPS..].iter().fold(0.0f32, |m, v| m.max(v.abs()));
        assert!(peak > 0.9, "440 Hz was attenuated to {peak}");
    }

    #[test]
    fn rejects_content_above_nyquist() {
        // 12 kHz is above the 8 kHz Nyquist of the output. Without the low-pass
        // it would alias down to 4 kHz — right in the middle of the speech band.
        let mut r = Resampler::new(48000, 16000);
        let mut out = Vec::new();
        let input: Vec<f32> = (0..48000 * 2)
            .map(|i| {
                let t = (i / 2) as f32 / 48000.0;
                (2.0 * std::f32::consts::PI * 12000.0 * t).sin()
            })
            .collect();
        r.process(&input, 2, &mut out);

        let peak = out[TAPS..].iter().fold(0.0f32, |m, v| m.max(v.abs()));
        assert!(peak < 0.02, "12 kHz aliased through at {peak}");
    }

    #[test]
    fn downmixes_stereo() {
        let mut r = Resampler::new(48000, 16000);
        let mut out = Vec::new();
        // L = +1, R = -1 must cancel to silence
        let input: Vec<f32> = (0..4800 * 2)
            .map(|i| if i % 2 == 0 { 1.0 } else { -1.0 })
            .collect();
        r.process(&input, 2, &mut out);
        assert!(out.iter().all(|v| v.abs() < 1e-6));
    }

    /// A tone at `hz`, `seconds` long, interleaved over `channels`.
    fn tone(hz: f32, rate: u32, channels: usize, seconds: f32) -> Vec<f32> {
        let frames = (rate as f32 * seconds) as usize;
        (0..frames * channels)
            .map(|i| {
                let t = (i / channels) as f32 / rate as f32;
                (2.0 * std::f32::consts::PI * hz * t).sin()
            })
            .collect()
    }

    #[test]
    fn airpods_and_usb_rates_resample_without_aborting() {
        // AirPods' microphone is 24 kHz; many USB ones are 44.1 kHz. Both used
        // to hit an assert and take the app down.
        for (rate, channels) in [(24000u32, 1usize), (44100, 1), (44100, 2), (22050, 1), (8000, 1)] {
            let mut r = Resampler::new(rate, 16000);
            let mut out = Vec::new();
            let input = tone(440.0, rate, channels, 1.0);
            // In uneven pieces, the way a device delivers them.
            for piece in input.chunks(channels * 471) {
                r.process(piece, channels, &mut out);
            }
            let expected = 16000 - HALF as i64 * 16000 / rate as i64;
            assert!((out.len() as i64 - expected).abs() <= 2,
                    "{rate} Hz gave {} samples for 1 s, expected about {expected}", out.len());
            let peak = out[TAPS..].iter().fold(0.0f32, |m, v| m.max(v.abs()));
            assert!(peak > 0.9 && peak < 1.05, "440 Hz at {rate} Hz came out at {peak}");
        }
    }

    #[test]
    fn fractional_path_rejects_content_above_nyquist() {
        let mut r = Resampler::new(44100, 16000);
        let mut out = Vec::new();
        r.process(&tone(12000.0, 44100, 1, 1.0), 1, &mut out);
        let peak = out[TAPS..].iter().fold(0.0f32, |m, v| m.max(v.abs()));
        assert!(peak < 0.02, "12 kHz aliased through at {peak}");
    }

    #[test]
    fn fractional_path_is_smooth_between_samples() {
        // A 1 kHz tone at 24 kHz, resampled, against the tone itself at 16 kHz:
        // a table row or a history index off by one shows up as a phase jump.
        let mut r = Resampler::new(24000, 16000);
        let mut out = Vec::new();
        r.process(&tone(1000.0, 24000, 1, 0.5), 1, &mut out);
        // Each output is the signal at its own position, n / 16 kHz: the
        // latency is in when it is emitted, not in what it is.
        let delay = 0.0;
        let worst = out.iter().enumerate().skip(TAPS).take(4000)
            .map(|(n, v)| {
                let t = n as f32 / 16000.0 - delay;
                (v - (2.0 * std::f32::consts::PI * 1000.0 * t).sin()).abs()
            })
            .fold(0.0f32, f32::max);
        assert!(worst < 0.02, "resampled 1 kHz strays {worst} from the tone");
    }
}
