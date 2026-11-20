//! A high-quality sample-rate converter: a Kaiser-windowed sinc, one filter per fractional
//! position (polyphase), the same on every system. Output sample k sits at input time k × from/to.

/// Greatest common divisor.
fn gcd(a: u64, b: u64) -> u64 {
    if b == 0 { a } else { gcd(b, a % b) }
}

/// The modified Bessel function I₀.
fn bessel0(x: f64) -> f64 {
    let (mut sum, mut term, q) = (1.0, 1.0, x * x / 4.0);
    for k in 1..200 {
        term *= q / (k as f64 * k as f64);
        sum += term;
        if term < sum * 1e-17 {
            break;
        }
    }
    sum
}

/// How steep and how deep: the pass band's edge as a share of the lower Nyquist, and the stop
/// band's attenuation in dB.
pub const PASS: f64 = 0.95;
pub const ATTENUATION: f64 = 150.0;

pub struct Resampler {
    up: usize,
    down: usize,
    half: usize,
    /// `up` filters of 2 × half taps each, one after another.
    filters: Vec<f32>,
    /// Input not yet used up, starting `half` samples before `position`'s time.
    history: Vec<f32>,
    /// Where the next output sits, in input samples × `up`, from history's start.
    position: usize,
    /// Output so far, input so far: to end at the right length.
    produced: u64,
    consumed: u64,
}

impl Resampler {
    pub fn new(from: u32, to: u32) -> Resampler {
        let d = gcd(u64::from(from), u64::from(to));
        let (up, down) = ((u64::from(to) / d) as usize, (u64::from(from) / d) as usize);
        // Against the lower of the two Nyquists, the band from PASS to 1 + (1 − PASS) is the
        // transition, so what folds back over Nyquist is only what's above PASS.
        let lower = (up as f64 / down as f64).min(1.0);
        let width = (1.0 - PASS) * lower; // half the transition, in units of the input's Nyquist
        let beta = 0.1102 * (ATTENUATION - 8.7);
        let half = ((ATTENUATION - 7.95) / (14.36 * (2.0 * width) / 2.0) / 2.0).ceil() as usize;
        let mut filters = vec![0f32; up * 2 * half];
        let norm = bessel0(beta);
        for phase in 0..up {
            let fraction = phase as f64 / up as f64;
            let mut taps = vec![0f64; 2 * half];
            for (i, tap) in taps.iter_mut().enumerate() {
                // The tap's input sample, relative to the output's time.
                let t = i as f64 - (half as f64 - 1.0) - fraction;
                let x = t / half as f64;
                let window = if x.abs() >= 1.0 {
                    0.0
                } else {
                    bessel0(beta * (1.0 - x * x).sqrt()) / norm
                };
                let a = std::f64::consts::PI * t * lower;
                *tap = window * if a == 0.0 { lower } else { lower * a.sin() / a };
            }
            let sum: f64 = taps.iter().sum();
            for (i, tap) in taps.iter().enumerate() {
                filters[phase * 2 * half + i] = (tap / sum) as f32;
            }
        }
        Resampler {
            up,
            down,
            half,
            filters,
            // Silence before the start.
            history: vec![0.0; half - 1],
            position: 0,
            produced: 0,
            consumed: 0,
        }
    }

    /// Adds input; appends the output it makes possible.
    pub fn process(&mut self, input: &[f32], out: &mut Vec<f32>) {
        self.history.extend_from_slice(input);
        self.consumed += input.len() as u64;
        self.run(out, None);
    }

    fn run(&mut self, out: &mut Vec<f32>, limit: Option<u64>) {
        let taps = 2 * self.half;
        loop {
            if limit.is_some_and(|l| self.produced >= l) {
                break;
            }
            let start = self.position / self.up;
            if start + taps > self.history.len() {
                break;
            }
            let phase = self.position % self.up;
            let filter = &self.filters[phase * taps..(phase + 1) * taps];
            let window = &self.history[start..start + taps];
            let mut sum = 0f32;
            for (a, b) in filter.iter().zip(window) {
                sum += a * b;
            }
            out.push(sum);
            self.produced += 1;
            self.position += self.down;
        }
        let used = self.position / self.up;
        if used > 1 << 16 {
            self.history.drain(..used);
            self.position -= used * self.up;
        }
    }

    /// The end: what's left, up to the length the input's duration gives (whole samples, as
    /// Apple's converter).
    pub fn finish(&mut self, out: &mut Vec<f32>) {
        let total = self.consumed * self.up as u64 / self.down as u64;
        self.history.extend(std::iter::repeat_n(0.0, 2 * self.half));
        self.run(out, Some(total));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(hz: f64, rate: f64, n: usize) -> Vec<f32> {
        (0..n)
            .map(|i| (2.0 * std::f64::consts::PI * hz * i as f64 / rate).sin() as f32)
            .collect()
    }

    fn convert(input: &[f32], from: u32, to: u32) -> Vec<f32> {
        let mut r = Resampler::new(from, to);
        let mut out = Vec::new();
        for block in input.chunks(4096) {
            r.process(block, &mut out);
        }
        r.finish(&mut out);
        out
    }

    #[test]
    fn a_tone_keeps_its_pitch_place_and_level() {
        for (from, to) in [
            (44100, 48000),
            (96000, 48000),
            (48000, 44100),
            (22050, 48000),
        ] {
            let (f, t) = (f64::from(from), f64::from(to));
            let input = sine(1000.0, f, from as usize);
            let got = convert(&input, from, to);
            assert_eq!(got.len(), to as usize, "{from} → {to}");
            let expected = sine(1000.0, t, to as usize);
            // Away from the ends, where the filter reaches past the audio.
            let margin = to as usize / 10;
            let worst = got[margin..got.len() - margin]
                .iter()
                .zip(&expected[margin..])
                .map(|(a, b)| (a - b).abs())
                .fold(0f32, f32::max);
            assert!(worst < 1e-4, "{from} → {to}: {worst}");
        }
    }

    #[test]
    fn what_cant_be_kept_is_removed() {
        // 30 kHz can't exist at 48 kHz.
        let input = sine(30000.0, 96000.0, 96000);
        let got = convert(&input, 96000, 48000);
        let peak = got[4800..43200].iter().fold(0f32, |m, x| m.max(x.abs()));
        assert!(peak < 1e-6, "{peak}");
    }

    #[test]
    fn blocks_dont_change_the_result() {
        let input = sine(440.0, 44100.0, 30000);
        let whole = {
            let mut r = Resampler::new(44100, 48000);
            let mut out = Vec::new();
            r.process(&input, &mut out);
            r.finish(&mut out);
            out
        };
        assert_eq!(whole, convert(&input, 44100, 48000));
    }
}
