//! Preparing decoded audio for the embedding models, as Phase 0 did, so vectors match the ones
//! Phase 0 measured: mono 48 kHz (at most the first 10 minutes), silence trimmed (-60 dB),
//! peak-normalised to 0.9, up to six evenly spread 10 s windows. Then each model's input: CLAP's
//! log-mel features, PE-AV's reflect padding. Port of `ClapFeatures.swift`.

use std::f64::consts::PI;
use std::sync::OnceLock;

pub const SAMPLE_RATE: usize = 48_000;
pub const WINDOW_SAMPLES: usize = 480_000;
pub const MAX_WINDOWS: usize = 6;
/// Phase 0 decodes at most the first 10 minutes of a file.
pub const MAX_SECONDS: f64 = 600.0;

fn peak(x: &[f32]) -> Option<f32> {
    x.iter().map(|v| v.abs()).reduce(f32::max)
}

/// Trimmed and peak-normalised audio, or None if silent or shorter than 20 ms.
pub fn prepare(x: &[f32]) -> Option<Vec<f32>> {
    let trimmed = trim_silence(x, -60.0, 0.01);
    if trimmed.len() < (0.02 * SAMPLE_RATE as f64) as usize
        || peak(trimmed).is_none_or(|p| p < 1e-6)
    {
        return None;
    }
    Some(peak_normalize(trimmed, 0.9))
}

/// Cuts leading and trailing parts quieter than `threshold_db` relative to the peak (5 ms
/// frames, `pad_seconds` of padding).
pub fn trim_silence(x: &[f32], threshold_db: f64, pad_seconds: f64) -> &[f32] {
    let Some(p) = peak(x).filter(|&p| p > 0.0) else {
        return x;
    };
    let hop = ((SAMPLE_RATE as f64 * 0.005) as usize).max(1);
    let n = x.len() / hop;
    if n < 2 {
        return x;
    }
    let threshold = p * 10f64.powf(threshold_db / 20.0) as f32;
    let (mut first, mut last) = (None, 0);
    for f in 0..n {
        let m = x[f * hop..(f + 1) * hop]
            .iter()
            .fold(0f32, |m, v| m.max(v.abs()));
        if m >= threshold {
            first.get_or_insert(f);
            last = f;
        }
    }
    let Some(first) = first else { return x };
    let pad = (pad_seconds * SAMPLE_RATE as f64) as usize;
    &x[(first * hop).saturating_sub(pad)..x.len().min((last + 1) * hop + pad)]
}

pub fn peak_normalize(x: &[f32], target: f32) -> Vec<f32> {
    match peak(x) {
        Some(p) if p > 1e-9 => {
            let gain = target / p;
            x.iter().map(|v| v * gain).collect()
        }
        _ => x.to_vec(),
    }
}

/// Up to six evenly spread 10 s windows, skipping near-silent ones; short audio comes back whole.
pub fn windows(x: &[f32]) -> Vec<Vec<f32>> {
    let win = WINDOW_SAMPLES;
    if x.len() <= win {
        return vec![x.to_vec()];
    }
    let count = MAX_WINDOWS.min((x.len() as f64 / win as f64).ceil() as usize);
    let span = (x.len() - win) as f64;
    // numpy.linspace: start + i × step, the last exactly at the end.
    let starts: Vec<usize> = (0..count)
        .map(|i| {
            if i == count - 1 {
                x.len() - win
            } else {
                (i as f64 * (span / (count - 1) as f64)) as usize
            }
        })
        .collect();
    let windows: Vec<Vec<f32>> = starts.iter().map(|&s| x[s..s + win].to_vec()).collect();
    let rms: Vec<f64> = windows.iter().map(|w| rms(w)).collect();
    let loudest = rms.iter().copied().fold(0.0, f64::max);
    let kept: Vec<Vec<f32>> = windows
        .iter()
        .zip(&rms)
        .filter(|(_, r)| **r >= 0.05 * loudest)
        .map(|(w, _)| w.clone())
        .collect();
    if kept.is_empty() { windows } else { kept }
}

/// Root mean square, summed in double precision in order.
pub fn rms(w: &[f32]) -> f64 {
    (w.iter().fold(0.0, |s, &v| s + v as f64 * v as f64) / w.len() as f64).sqrt()
}

/// PE-AV's input: the window reflect-padded at the end to a multiple of 1920 samples
/// (PeAudioFeatureExtractor), as numpy's "reflect" pads.
pub fn peav_input(window: &[f32]) -> Vec<f32> {
    const HOP: usize = 1920;
    let n = window.len();
    if n <= 1 || n.is_multiple_of(HOP) {
        return window.to_vec();
    }
    let pad = HOP - n % HOP;
    // numpy "reflect" keeps mirroring for long pads: a periodic mirror of period 2(n-1).
    let period = 2 * (n - 1);
    let mut out = Vec::with_capacity(n + pad);
    out.extend_from_slice(window);
    for j in 0..pad {
        let mut m = (n + j) % period;
        if m >= n {
            m = period - m;
        }
        out.push(window[m]);
    }
    out
}

// MARK: CLAP's log-mel features ("repeatpad", Slaney mel, dB)

pub const CLAP_FRAMES: usize = 1001;
pub const CLAP_MELS: usize = 64;
const N_FFT: usize = 1024;
const HOP: usize = 480;

struct Band {
    first: usize,
    weights: Vec<f64>,
}

/// transformers.mel_filter_bank(norm="slaney", mel_scale="slaney"), each band as its nonzero range.
fn mel_filters() -> &'static [Band] {
    static FILTERS: OnceLock<Vec<Band>> = OnceLock::new();
    FILTERS.get_or_init(|| {
        let to_mel = |hz: f64| {
            if hz >= 1000.0 {
                15.0 + (hz / 1000.0).ln() * (27.0 / 6.4f64.ln())
            } else {
                3.0 * hz / 200.0
            }
        };
        let to_hz = |mel: f64| {
            if mel >= 15.0 {
                1000.0 * (6.4f64.ln() / 27.0 * (mel - 15.0)).exp()
            } else {
                200.0 * mel / 3.0
            }
        };
        let bins = N_FFT / 2 + 1;
        let (lo, hi) = (to_mel(50.0), to_mel(14000.0));
        let step = (hi - lo) / (CLAP_MELS + 1) as f64;
        let edges: Vec<f64> = (0..CLAP_MELS + 2)
            .map(|i| {
                if i == CLAP_MELS + 1 {
                    hi
                } else {
                    lo + i as f64 * step
                }
            })
            .map(to_hz)
            .collect();
        let nyquist = (SAMPLE_RATE / 2) as f64;
        let bin_width = nyquist / (bins - 1) as f64;
        let freqs: Vec<f64> = (0..bins)
            .map(|i| {
                if i == bins - 1 {
                    nyquist
                } else {
                    i as f64 * bin_width
                }
            })
            .collect();
        (0..CLAP_MELS)
            .map(|m| {
                let enorm = 2.0 / (edges[m + 2] - edges[m]);
                let weights: Vec<f64> = freqs
                    .iter()
                    .map(|&f| {
                        let down = (f - edges[m]) / (edges[m + 1] - edges[m]);
                        let up = (edges[m + 2] - f) / (edges[m + 2] - edges[m + 1]);
                        0f64.max(down.min(up)) * enorm
                    })
                    .collect();
                let first = weights.iter().position(|&w| w > 0.0).unwrap_or(0);
                let last = weights.iter().rposition(|&w| w > 0.0).unwrap_or(0);
                Band {
                    first,
                    weights: weights[first..=last].to_vec(),
                }
            })
            .collect()
    })
}

/// The periodic Hann window.
fn hann() -> &'static [f64] {
    static HANN: OnceLock<Vec<f64>> = OnceLock::new();
    HANN.get_or_init(|| {
        (0..N_FFT)
            .map(|i| 0.5 - 0.5 * (2.0 * PI * i as f64 / N_FFT as f64).cos())
            .collect()
    })
}

fn fft() -> &'static RadixTwoFft {
    static FFT: OnceLock<RadixTwoFft> = OnceLock::new();
    FFT.get_or_init(|| RadixTwoFft::new(N_FFT))
}

/// The log-mel features of one ≤10 s window: `CLAP_FRAMES` × `CLAP_MELS` values, row-major, as
/// the model takes them.
pub fn clap_features(window: &[f32]) -> Vec<f32> {
    let mut x = window.to_vec();
    if x.len() < WINDOW_SAMPLES && !x.is_empty() {
        let repeats = WINDOW_SAMPLES / x.len();
        x = x.repeat(repeats);
        x.resize(WINDOW_SAMPLES, 0.0);
    } else if x.len() > WINDOW_SAMPLES {
        x.truncate(WINDOW_SAMPLES);
    }
    // Centre the frames: reflect-pad N_FFT/2 on both sides (numpy "reflect" skips the edge sample).
    let pad = N_FFT / 2;
    let mut padded = vec![0.0f64; x.len() + 2 * pad];
    for (i, &v) in x.iter().enumerate() {
        padded[pad + i] = v as f64;
    }
    for i in 0..pad {
        padded[pad - 1 - i] = x[i + 1] as f64;
        padded[pad + x.len() + i] = x[x.len() - 2 - i] as f64;
    }
    let (fft, filters, hann) = (fft(), mel_filters(), hann());
    let mut out = vec![0f32; CLAP_FRAMES * CLAP_MELS];
    let (mut re, mut im) = (vec![0.0; N_FFT], vec![0.0; N_FFT]);
    let mut power = vec![0.0; N_FFT / 2 + 1];
    for f in 0..CLAP_FRAMES {
        let start = f * HOP;
        for i in 0..N_FFT {
            re[i] = padded[start + i] * hann[i];
            im[i] = 0.0;
        }
        fft.transform(&mut re, &mut im);
        for k in 0..=N_FFT / 2 {
            // Stored as complex64 in transformers before taking the magnitude.
            let (r, j) = (re[k] as f32 as f64, im[k] as f32 as f64);
            power[k] = r * r + j * j;
        }
        for (m, band) in filters.iter().enumerate() {
            let mut sum = 0.0;
            for (i, w) in band.weights.iter().enumerate() {
                sum += w * power[band.first + i];
            }
            out[f * CLAP_MELS + m] = (10.0 * 1e-10f64.max(sum).log10()) as f32;
        }
    }
    out
}

/// An in-place iterative radix-2 complex FFT (forward, no scaling), in double precision.
pub struct RadixTwoFft {
    size: usize,
    cos: Vec<f64>,
    sin: Vec<f64>,
    reversed: Vec<usize>,
}

impl RadixTwoFft {
    pub fn new(size: usize) -> RadixTwoFft {
        assert!(
            size > 1 && size.is_power_of_two(),
            "size must be a power of two"
        );
        let bits = size.trailing_zeros();
        RadixTwoFft {
            size,
            cos: (0..size / 2)
                .map(|i| (-2.0 * PI * i as f64 / size as f64).cos())
                .collect(),
            sin: (0..size / 2)
                .map(|i| (-2.0 * PI * i as f64 / size as f64).sin())
                .collect(),
            reversed: (0..size)
                .map(|i| i.reverse_bits() >> (usize::BITS - bits))
                .collect(),
        }
    }

    pub fn transform(&self, re: &mut [f64], im: &mut [f64]) {
        for i in 0..self.size {
            let r = self.reversed[i];
            if i < r {
                re.swap(i, r);
                im.swap(i, r);
            }
        }
        let mut len = 2;
        while len <= self.size {
            let (half, step) = (len / 2, self.size / len);
            let mut start = 0;
            while start < self.size {
                for k in 0..half {
                    let (c, s) = (self.cos[k * step], self.sin[k * step]);
                    let (a, b) = (start + k, start + k + half);
                    let tr = re[b] * c - im[b] * s;
                    let ti = re[b] * s + im[b] * c;
                    re[b] = re[a] - tr;
                    im[b] = im[a] - ti;
                    re[a] += tr;
                    im[a] += ti;
                }
                start += len;
            }
            len <<= 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    #[derive(Deserialize)]
    struct Window {
        length: usize,
        first: f32,
        rms: f64,
    }
    #[derive(Deserialize)]
    struct Features {
        shape: Vec<usize>,
        index: Vec<usize>,
        values: Vec<f32>,
        mean: f64,
    }
    #[derive(Deserialize)]
    struct Fixture {
        prepared_length: usize,
        prepared_peak: f32,
        windows: Vec<Window>,
        long: Features,
        short: Features,
    }

    /// Values from Python (models/parity_clap.py --fixture), shared with the Swift tests.
    fn fixture() -> Fixture {
        serde_json::from_str(include_str!(
            "../../../../../app/Tests/EarmarkCoreTests/Fixtures/clap_features.json"
        ))
        .unwrap()
    }

    /// The same formula as parity_clap.fixture_signal().
    fn signal() -> Vec<f32> {
        let sr = SAMPLE_RATE as f64;
        let mut body: Vec<f64> = (0..23 * SAMPLE_RATE)
            .map(|i| {
                let t = i as f64 / sr;
                let mut v = 0.4 * (2.0 * PI * (200.0 * t + 40.0 * t * t)).sin()
                    + 0.2 * (2.0 * PI * 3000.0 * t).sin() * (-0.1 * t).exp();
                v += 0.5 * (-200.0 * (t % 2.0)).exp() * (2.0 * PI * 800.0 * t).sin();
                v
            })
            .collect();
        for v in &mut body[..3 * SAMPLE_RATE] {
            *v *= 0.01;
        }
        let mut x = vec![0.0; SAMPLE_RATE / 2];
        x.extend(body);
        x.extend(vec![0.0; SAMPLE_RATE]);
        x.into_iter().map(|v| v as f32).collect()
    }

    #[test]
    fn prepare_and_windows_match_phase0() {
        let f = fixture();
        let prepared = prepare(&signal()).unwrap();
        assert_eq!(prepared.len(), f.prepared_length);
        assert!((peak(&prepared).unwrap() - f.prepared_peak).abs() < 1e-6);
        let w = windows(&prepared);
        assert_eq!(w.len(), f.windows.len());
        for (w, r) in w.iter().zip(&f.windows) {
            assert_eq!(w.len(), r.length);
            assert!((w[0] - r.first).abs() < 1e-5);
            assert!((rms(w) - r.rms).abs() < 1e-5);
        }
    }

    #[test]
    fn features_match_the_clap_feature_extractor() {
        let f = fixture();
        let prepared = prepare(&signal()).unwrap();
        for (input, r) in [
            (windows(&prepared)[0].clone(), &f.long),
            (
                prepared[..(3.3 * SAMPLE_RATE as f64) as usize].to_vec(),
                &f.short,
            ),
        ] {
            let feats = clap_features(&input);
            assert_eq!(feats.len(), r.shape[0] * r.shape[1]);
            let worst = r
                .index
                .iter()
                .zip(&r.values)
                .map(|(&i, v)| (feats[i] - v).abs())
                .fold(0f32, f32::max);
            assert!(worst < 0.01, "largest difference {worst} dB");
            let mean = feats.iter().map(|&v| v as f64).sum::<f64>() / feats.len() as f64;
            assert!((mean - r.mean).abs() < 0.001);
        }
    }

    #[test]
    fn fft_matches_a_direct_dft() {
        let n = 16;
        let x: Vec<f64> = (0..n)
            .map(|i| (i as f64 * 0.7).sin() + 0.3 * (i as f64 * 2.1).cos())
            .collect();
        let (mut re, mut im) = (x.clone(), vec![0.0; n]);
        RadixTwoFft::new(n).transform(&mut re, &mut im);
        for k in 0..n {
            let (mut r, mut j) = (0.0, 0.0);
            for (t, v) in x.iter().enumerate() {
                let a = -2.0 * PI * (k * t) as f64 / n as f64;
                r += v * a.cos();
                j += v * a.sin();
            }
            assert!((re[k] - r).abs() < 1e-9 && (im[k] - j).abs() < 1e-9);
        }
    }

    #[test]
    fn peav_padding_matches_pe_audio_feature_extractor() {
        #[derive(Deserialize)]
        struct W {
            length: usize,
            padded: usize,
            tail: Vec<f32>,
            around_end: Vec<f32>,
        }
        #[derive(Deserialize)]
        struct F {
            windows: Vec<W>,
        }
        let f: F = serde_json::from_str(include_str!(
            "../../../../../app/Tests/EarmarkCoreTests/Fixtures/peav_padding.json"
        ))
        .unwrap();
        for w in f.windows {
            let x: Vec<f32> = (0..w.length)
                .map(|i| ((i as f64 * 0.01).sin() * 0.5) as f32)
                .collect();
            let p = peav_input(&x);
            assert_eq!(p.len(), w.padded, "length {}", w.length);
            for (a, b) in p[p.len() - 8..].iter().zip(&w.tail) {
                assert!((a - b).abs() < 1e-6);
            }
            let around = &p[w.length.saturating_sub(4)..p.len().min(w.length + 4)];
            for (a, b) in around.iter().zip(&w.around_end) {
                assert!((a - b).abs() < 1e-6);
            }
        }
    }
}
