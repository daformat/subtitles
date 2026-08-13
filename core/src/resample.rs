//! 48 kHz interleaved stereo f32 → 16 kHz mono f32.
//!
//! Spike 0B confirmed the tap always hands us 48 kHz / 2 ch / f32 packed, and
//! the models want 16 kHz mono — an exact 3:1 decimation.
//!
//! Decimation without a low-pass first would fold everything above 8 kHz back
//! into the speech band as aliasing, which is exactly where the ASR features
//! live. So: downmix, then a windowed-sinc FIR evaluated only at output
//! positions (1/3 the multiply-accumulates of filtering then discarding).

const TAPS: usize = 96;
const CUTOFF_HZ: f32 = 7200.0; // below the 8 kHz Nyquist of 16 kHz, with margin

pub struct Resampler {
    taps: [f32; TAPS],
    hist: [f32; TAPS],
    pos: usize,   // next write index in the circular history
    phase: usize, // input samples seen, mod `decim`
    decim: usize,
}

impl Resampler {
    pub fn new(input_rate: u32, output_rate: u32) -> Self {
        assert!(
            input_rate % output_rate == 0,
            "only integer decimation supported ({input_rate} -> {output_rate})"
        );
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
}
