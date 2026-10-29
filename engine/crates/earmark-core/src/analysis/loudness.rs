//! Integrated loudness (ITU-R BS.1770-4 / EBU R128, LUFS) and sample peak (dBFS), fed with
//! decoded audio in chunks so long files are never held in memory. Port of `Loudness.swift`.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct LoudnessResult {
    /// Integrated loudness in LUFS; None for digital silence (everything below the -70 LUFS gate).
    pub integrated: Option<f64>,
    /// The highest sample in dBFS (not oversampled true peak); None for digital silence.
    pub peak: Option<f64>,
}

/// K-weighting: a high shelf then a high pass, per channel (biquad, direct form I).
#[derive(Clone, Copy, Debug)]
struct Biquad {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    x1: f64,
    x2: f64,
    y1: f64,
    y2: f64,
}

impl Biquad {
    fn new(b0: f64, b1: f64, b2: f64, a1: f64, a2: f64) -> Biquad {
        Biquad {
            b0,
            b1,
            b2,
            a1,
            a2,
            x1: 0.0,
            x2: 0.0,
            y1: 0.0,
            y2: 0.0,
        }
    }

    #[inline]
    fn run(&mut self, x: f64) -> f64 {
        let y = self.b0 * x + self.b1 * self.x1 + self.b2 * self.x2
            - self.a1 * self.y1
            - self.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x;
        self.y2 = self.y1;
        self.y1 = y;
        y
    }
}

/// The coefficients for any sample rate (the same derivation as libebur128).
fn k_weighting(fs: f64) -> (Biquad, Biquad) {
    let (mut f0, mut q) = (1681.974450955533, 0.7071752369554196);
    let gain = 3.999843853973347;
    let mut k = (std::f64::consts::PI * f0 / fs).tan();
    let vh = 10f64.powf(gain / 20.0);
    let vb = vh.powf(0.4996667741545416);
    let mut a0 = 1.0 + k / q + k * k;
    let shelf = Biquad::new(
        (vh + vb * k / q + k * k) / a0,
        2.0 * (k * k - vh) / a0,
        (vh - vb * k / q + k * k) / a0,
        2.0 * (k * k - 1.0) / a0,
        (1.0 - k / q + k * k) / a0,
    );
    f0 = 38.13547087602444;
    q = 0.5003270373238773;
    k = (std::f64::consts::PI * f0 / fs).tan();
    a0 = 1.0 + k / q + k * k;
    let high_pass = Biquad::new(
        1.0,
        -2.0,
        1.0,
        2.0 * (k * k - 1.0) / a0,
        (1.0 - k / q + k * k) / a0,
    );
    (shelf, high_pass)
}

fn lufs(mean_square: f64) -> f64 {
    -0.691 + 10.0 * mean_square.log10()
}

pub struct LoudnessMeter {
    pub sample_rate: f64,
    pub channels: usize,
    filters: Vec<(Biquad, Biquad)>,
    weights: Vec<f64>,
    /// Frames per 100 ms step; blocks are 4 steps (400 ms) with 75% overlap.
    step_frames: usize,
    step_fill: usize,
    step_energy: Vec<f64>,
    /// The channel-weighted mean square of each completed 100 ms step.
    steps: Vec<f64>,
    total_frames: usize,
    total_energy: f64,
    peak_sample: f32,
}

impl LoudnessMeter {
    pub fn new(sample_rate: f64, channels: usize) -> LoudnessMeter {
        let count = channels.max(1);
        // 5.1 in WAV order (L R C LFE Ls Rs): LFE ignored, surrounds +1.5 dB.
        let weights = (0..count)
            .map(|c| {
                if count != 6 {
                    1.0
                } else if c == 3 {
                    0.0
                } else if c >= 4 {
                    1.41
                } else {
                    1.0
                }
            })
            .collect();
        LoudnessMeter {
            sample_rate,
            channels: count,
            filters: vec![k_weighting(sample_rate); count],
            weights,
            step_frames: ((sample_rate / 10.0).round() as usize).max(1),
            step_fill: 0,
            step_energy: vec![0.0; count],
            steps: Vec::new(),
            total_frames: 0,
            total_energy: 0.0,
            peak_sample: 0.0,
        }
    }

    /// Feeds `frames` frames of deinterleaved float audio, one slice per channel.
    pub fn process(&mut self, buffers: &[&[f32]], frames: usize) {
        if buffers.len() < self.channels {
            return;
        }
        let mut start = 0;
        while start < frames {
            let n = (frames - start).min(self.step_frames - self.step_fill);
            for (c, input) in buffers.iter().enumerate().take(self.channels) {
                let (mut shelf, mut high_pass) = self.filters[c];
                let mut sum = 0.0;
                let mut peak = self.peak_sample;
                for &x in &input[start..start + n] {
                    peak = peak.max(x.abs());
                    let y = high_pass.run(shelf.run(x as f64));
                    sum += y * y;
                }
                self.filters[c] = (shelf, high_pass);
                self.peak_sample = peak;
                self.step_energy[c] += sum;
            }
            self.step_fill += n;
            self.total_frames += n;
            start += n;
            if self.step_fill == self.step_frames {
                self.close_step();
            }
        }
    }

    fn close_step(&mut self) {
        let mut weighted = 0.0;
        for c in 0..self.channels {
            weighted += self.weights[c] * self.step_energy[c];
        }
        self.steps.push(weighted / self.step_frames as f64);
        self.total_energy += weighted;
        self.step_energy = vec![0.0; self.channels];
        self.step_fill = 0;
    }

    pub fn result(&self) -> LoudnessResult {
        let peak = (self.peak_sample > 0.0).then(|| 20.0 * (self.peak_sample as f64).log10());
        let mut blocks: Vec<f64> = Vec::new();
        if self.steps.len() >= 4 {
            blocks = (0..=self.steps.len() - 4)
                .map(|i| {
                    (self.steps[i] + self.steps[i + 1] + self.steps[i + 2] + self.steps[i + 3])
                        / 4.0
                })
                .collect();
        } else if self.total_frames > 0 {
            // Shorter than one 400 ms block (short effects): the whole sound as one block.
            let mut weighted = self.total_energy;
            for c in 0..self.channels {
                weighted += self.weights[c] * self.step_energy[c];
            }
            blocks = vec![weighted / self.total_frames as f64];
        }
        let absolute: Vec<f64> = blocks
            .into_iter()
            .filter(|&b| b > 0.0 && lufs(b) > -70.0)
            .collect();
        if absolute.is_empty() {
            return LoudnessResult {
                integrated: None,
                peak,
            };
        }
        let relative = lufs(absolute.iter().sum::<f64>() / absolute.len() as f64) - 10.0;
        let gated: Vec<f64> = absolute
            .into_iter()
            .filter(|&b| lufs(b) > relative)
            .collect();
        LoudnessResult {
            integrated: Some(lufs(gated.iter().sum::<f64>() / gated.len() as f64)),
            peak,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(dbfs: f64, seconds: f64, rate: f64) -> Vec<f32> {
        let amp = 10f64.powf(dbfs / 20.0);
        (0..(seconds * rate) as usize)
            .map(|i| (amp * (2.0 * std::f64::consts::PI * 1000.0 * i as f64 / rate).sin()) as f32)
            .collect()
    }

    fn measure(channels: &[Vec<f32>], rate: f64, chunk: usize) -> LoudnessResult {
        let mut meter = LoudnessMeter::new(rate, channels.len());
        let frames = channels[0].len();
        let mut start = 0;
        while start < frames {
            let end = frames.min(start + chunk);
            let slices: Vec<&[f32]> = channels.iter().map(|c| &c[start..end]).collect();
            meter.process(&slices, end - start);
            start = end;
        }
        meter.result()
    }

    /// EBU Tech 3341, cases 1 and 2: a stereo 1 kHz sine at -23 / -33 dBFS reads -23 / -33 LUFS.
    #[test]
    fn stereo_sine() {
        for (level, rate) in [
            (-23.0, 48000.0),
            (-33.0, 48000.0),
            (-23.0, 44100.0),
            (-23.0, 96000.0),
        ] {
            let s = sine(level, 20.0, rate);
            let r = measure(&[s.clone(), s], rate, 4096);
            assert!(
                (r.integrated.unwrap() - level).abs() <= 0.1,
                "{level} at {rate}"
            );
            assert!((r.peak.unwrap() - level).abs() <= 0.01);
        }
    }

    /// EBU Tech 3341, case 3: -36 dB for 10 s, -23 dB for 60 s, -36 dB for 10 s reads -23 LUFS.
    #[test]
    fn relative_gate() {
        let s: Vec<f32> = [
            sine(-36.0, 10.0, 48000.0),
            sine(-23.0, 60.0, 48000.0),
            sine(-36.0, 10.0, 48000.0),
        ]
        .concat();
        let r = measure(&[s.clone(), s], 48000.0, 48000);
        assert!((r.integrated.unwrap() + 23.0).abs() <= 0.1);
    }

    #[test]
    fn short_sounds_and_silence() {
        let blip = sine(-23.0, 0.2, 48000.0);
        let r = measure(&[blip.clone(), blip], 48000.0, 4096);
        assert!((r.integrated.unwrap() + 23.0).abs() <= 0.3);
        let silence = measure(&[vec![0.0; 48000]], 48000.0, 4096);
        assert_eq!(
            silence,
            LoudnessResult {
                integrated: None,
                peak: None
            }
        );
    }
}
