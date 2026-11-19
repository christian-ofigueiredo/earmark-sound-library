//! Tempo and key maths around the models: Beat This!'s input and chunking, the half-rate filter
//! songs are decoded through, beat tracking from the model's logits, and S-KEY's labels. Port of
//! `MusicAnalysis.swift`.

use super::audio::RadixTwoFft;
use crate::music_key::MusicKey;
use std::f64::consts::PI;
use std::sync::OnceLock;

// MARK: Beat This!'s input (beat_this 1.1.0, as Phase 0 ran it)

pub const SAMPLE_RATE: usize = 22_050;
pub const FPS: usize = 50;
pub const MELS: usize = 128;
/// Frames the model takes at a time, and how many at each end of a chunk it isn't trusted on.
pub const CHUNK: usize = 1500;
pub const BORDER: usize = 6;
/// Phase 0 analysed at most the first 20 minutes of a song.
pub const MAX_SECONDS: f64 = 1200.0;
const N_FFT: usize = 1024;
const HOP: usize = 441;

pub fn frame_count(samples: usize) -> usize {
    samples / HOP + 1
}

struct Band {
    first: usize,
    weights: Vec<f64>,
}

/// torchaudio.functional.melscale_fbanks(513, 30, 11000, 128, 22050, norm=None, mel_scale="slaney").
fn mel_filters() -> &'static [Band] {
    static FILTERS: OnceLock<Vec<Band>> = OnceLock::new();
    FILTERS.get_or_init(|| {
        let log_step = 6.4f64.ln() / 27.0;
        let to_mel = |hz: f64| {
            if hz >= 1000.0 {
                15.0 + (hz / 1000.0).ln() / log_step
            } else {
                3.0 * hz / 200.0
            }
        };
        let to_hz = |mel: f64| {
            if mel >= 15.0 {
                1000.0 * (log_step * (mel - 15.0)).exp()
            } else {
                200.0 * mel / 3.0
            }
        };
        let bins = N_FFT / 2 + 1;
        let (lo, hi) = (to_mel(30.0), to_mel(11000.0));
        let edges: Vec<f64> = (0..MELS + 2)
            .map(|i| to_hz(lo + i as f64 * (hi - lo) / (MELS + 1) as f64))
            .collect();
        let nyquist = (SAMPLE_RATE / 2) as f64;
        let freqs: Vec<f64> = (0..bins)
            .map(|i| i as f64 * nyquist / (bins - 1) as f64)
            .collect();
        (0..MELS)
            .map(|m| {
                let weights: Vec<f64> = freqs
                    .iter()
                    .map(|&f| {
                        let down = (f - edges[m]) / (edges[m + 1] - edges[m]);
                        let up = (edges[m + 2] - f) / (edges[m + 2] - edges[m + 1]);
                        0f64.max(down.min(up))
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

fn window() -> &'static [f64] {
    static W: OnceLock<Vec<f64>> = OnceLock::new();
    W.get_or_init(|| {
        (0..N_FFT)
            .map(|i| 0.5 - 0.5 * (2.0 * PI * i as f64 / N_FFT as f64).cos())
            .collect()
    })
}

fn fft() -> &'static RadixTwoFft {
    static F: OnceLock<RadixTwoFft> = OnceLock::new();
    F.get_or_init(|| RadixTwoFft::new(N_FFT))
}

/// The log-mel spectrogram: `frame_count` × `MELS` values, row-major: |STFT| (1024-point periodic
/// Hann, hop 441, centred with reflect padding, scaled by 1/√1024) → 128 Slaney mel bands from
/// 30 Hz to 11 kHz → log(1 + 1000·x). Needs more than 512 samples.
pub fn spectrogram(x: &[f32]) -> Vec<f32> {
    let frames = frame_count(x.len());
    let pad = N_FFT / 2;
    assert!(x.len() > pad, "too short to reflect-pad");
    // torch.stft(center=True, pad_mode="reflect"): the mirror excludes the edge sample.
    let mut padded = vec![0f64; x.len() + 2 * pad];
    for (i, &v) in x.iter().enumerate() {
        padded[pad + i] = v as f64;
    }
    for i in 0..pad {
        padded[pad - 1 - i] = x[i + 1] as f64;
        padded[pad + x.len() + i] = x[x.len() - 2 - i] as f64;
    }
    let (fft, filters, window) = (fft(), mel_filters(), window());
    let scale = 1.0 / (N_FFT as f64).sqrt(); // normalized="frame_length"
    let mut out = vec![0f32; frames * MELS];
    let (mut re, mut im) = (vec![0.0; N_FFT], vec![0.0; N_FFT]);
    let mut magnitude = vec![0.0; N_FFT / 2 + 1];
    for f in 0..frames {
        let start = f * HOP;
        for i in 0..N_FFT {
            re[i] = padded[start + i] * window[i];
            im[i] = 0.0;
        }
        fft.transform(&mut re, &mut im);
        for k in 0..=N_FFT / 2 {
            magnitude[k] = (re[k] * re[k] + im[k] * im[k]).sqrt() * scale;
        }
        for (m, band) in filters.iter().enumerate() {
            let mut sum = 0.0;
            for (i, w) in band.weights.iter().enumerate() {
                sum += w * magnitude[band.first + i];
            }
            out[f * MELS + m] = (1000.0 * sum).ln_1p() as f32;
        }
    }
    out
}

/// Where each chunk starts, in frames: the first at -`BORDER`, overlapping by 2·`BORDER`, the
/// last moved back to end with the song (beat_this's split_piece, avoid_short_end).
pub fn chunk_starts(n: usize) -> Vec<i64> {
    let (n, chunk, border) = (n as i64, CHUNK as i64, BORDER as i64);
    let mut starts: Vec<i64> = (-border..n - border)
        .step_by((chunk - 2 * border) as usize)
        .collect();
    if n > chunk - 2 * border && !starts.is_empty() {
        *starts.last_mut().unwrap() = n - (chunk - border);
    }
    starts
}

/// One chunk of `CHUNK` frames starting at `start`, zero beyond the song.
pub fn chunk(spect: &[f32], n: usize, start: i64) -> Vec<f32> {
    let mut out = vec![0f32; CHUNK * MELS];
    let first = start.max(0) as usize;
    let last = (start + CHUNK as i64).min(n as i64);
    if last <= first as i64 {
        return out;
    }
    let last = last as usize;
    let offset = (first as i64 - start) as usize * MELS;
    out[offset..offset + (last - first) * MELS].copy_from_slice(&spect[first * MELS..last * MELS]);
    out
}

/// The whole song's frames from each chunk's model output, dropping `BORDER` frames at both ends
/// of a chunk; where chunks overlap the earlier one wins. Frames no chunk covers stay at -1000.
pub fn aggregate(outputs: &[Vec<f32>], starts: &[i64], n: usize) -> Vec<f32> {
    let mut piece = vec![-1000f32; n];
    for (start, output) in starts.iter().zip(outputs).rev() {
        let end = output.len().min(CHUNK).saturating_sub(BORDER);
        for i in BORDER..end {
            let t = start + i as i64;
            if t >= 0 && (t as usize) < n {
                piece[t as usize] = output[i];
            }
        }
    }
    piece
}

// MARK: HalfRate

/// Kaiser-windowed sinc, 601 taps, β 22, cut off at 10.54 kHz (fitted to soxr "VHQ", which Phase 0
/// resampled with), normalised to unity gain; zero-padded to a multiple of 8.
fn half_rate_taps() -> &'static [f32] {
    static TAPS: OnceLock<Vec<f32>> = OnceLock::new();
    TAPS.get_or_init(|| {
        let (count, beta, cutoff) = (601usize, 22.0f64, 10_540.0 / 22_050.0);
        let bessel0 = |x: f64| {
            let (mut sum, mut term, mut k) = (1.0f64, 1.0f64, 1.0f64);
            while term > 1e-17 * sum {
                term *= (x / (2.0 * k)) * (x / (2.0 * k));
                sum += term;
                k += 1.0;
            }
            sum
        };
        let mid = (count - 1) as f64 / 2.0;
        let h: Vec<f64> = (0..count)
            .map(|i| {
                let m = i as f64 - mid;
                let sinc = if m == 0.0 {
                    1.0
                } else {
                    (PI * cutoff * m).sin() / (PI * cutoff * m)
                };
                let r = i as f64 / mid - 1.0;
                cutoff * sinc * bessel0(beta * (1.0 - r * r).sqrt()) / bessel0(beta)
            })
            .collect();
        let sum = h.iter().fold(0.0, |s, v| s + v);
        let mut taps: Vec<f32> = h.iter().map(|v| (v / sum) as f32).collect();
        taps.resize(count + (8 - count % 8) % 8, 0.0);
        taps
    })
}

/// Halves the sample rate (44.1 → 22.05 kHz): ⌈n/2⌉ samples, every other sample of the filtered
/// audio, zero beyond the ends. Eight running sums of fused multiply-adds, added up in lane
/// order, as Swift's SIMD8 `addProduct` and `sum()`.
pub fn decimate(x: &[f32]) -> Vec<f32> {
    let taps = half_rate_taps();
    let half = 300; // the filter's centre (601 taps)
    let (n, out) = (x.len(), x.len().div_ceil(2));
    let mut padded = vec![0f32; n + 2 * half + taps.len()];
    padded[half..half + n].copy_from_slice(x);
    let blocks = taps.len() / 8;
    (0..out)
        .map(|m| {
            // The filter is symmetric, so it lines up with the input as it is.
            let base = &padded[2 * m..];
            let mut acc = [0f32; 8];
            for b in 0..blocks {
                for l in 0..8 {
                    acc[l] = base[b * 8 + l].mul_add(taps[b * 8 + l], acc[l]);
                }
            }
            acc.iter().fold(-0.0f32, |s, v| s + v)
        })
        .collect()
}

// MARK: BeatTracking

/// Tempo from Beat This!'s logits, as Phase 0 worked it out.
#[derive(Clone, Debug, PartialEq)]
pub struct Summary {
    /// Beat times, seconds (refined between frames).
    pub beats: Vec<f64>,
    /// Downbeat times, seconds (on the unrefined beat frames).
    pub downbeats: Vec<f64>,
    /// None with fewer than 4 beats.
    pub bpm: Option<f64>,
    /// 10th–90th percentile of the tempo over 8-beat stretches.
    pub bpm_range: Option<(f64, f64)>,
    /// "steady", "mostly steady", "variable" or "no steady beat".
    pub stability: String,
    pub beats_per_bar: Option<i64>,
    /// Half how regular the beats are, half how sure the model was of them (0…1).
    pub confidence: f64,
}

pub fn sigmoid(x: f32) -> f32 {
    1.0 / (1.0 + (-x).exp())
}

/// Beat and downbeat times (seconds) from the logits, Postprocessor(type="minimal"): peaks over ±3
/// frames above probability 0.5, adjacent peaks merged, each downbeat moved to the nearest beat.
pub fn peaks(beat_logits: &[f32], downbeat_logits: &[f32]) -> (Vec<f64>, Vec<f64>) {
    let beats: Vec<f64> = frames(beat_logits).iter().map(|f| f / FPS as f64).collect();
    let mut downbeats: Vec<f64> = frames(downbeat_logits)
        .iter()
        .map(|f| f / FPS as f64)
        .collect();
    if !beats.is_empty() {
        for d in downbeats.iter_mut() {
            let mut best = 0;
            for j in 0..beats.len() {
                if (beats[j] - *d).abs() < (beats[best] - *d).abs() {
                    best = j;
                }
            }
            *d = beats[best];
        }
    }
    downbeats.sort_by(f64::total_cmp);
    downbeats.dedup();
    (beats, downbeats)
}

/// Peak frames, adjacent ones merged into their mean.
fn frames(logits: &[f32]) -> Vec<f64> {
    let (lo, hi) = (1e-6f32, 1.0 - 1e-6f32);
    let p: Vec<f32> = logits.iter().map(|&x| sigmoid(x).max(lo).min(hi)).collect();
    let mut peaks: Vec<usize> = Vec::new();
    for t in 0..p.len() {
        if p[t] <= 0.5 {
            continue;
        }
        let window = t.saturating_sub(3)..=(t + 3).min(p.len() - 1);
        if !window.clone().any(|u| p[u] > p[t]) {
            peaks.push(t);
        }
    }
    // deduplicate_peaks(width=1): a running mean, compared against the next peak.
    let mut out = Vec::new();
    let Some(&first) = peaks.first() else {
        return out;
    };
    let (mut mean, mut count) = (first as f64, 1.0);
    for &next in &peaks[1..] {
        if next as f64 - mean <= 1.0 {
            count += 1.0;
            mean += (next as f64 - mean) / count;
        } else {
            out.push(mean);
            mean = next as f64;
            count = 1.0;
        }
    }
    out.push(mean);
    out
}

/// summarize_beats: tempo, its range and steadiness, beats per bar and a confidence.
/// `prob`: the beat sigmoid per frame.
pub fn summarize(raw_beats: &[f64], downbeats: &[f64], prob: &[f32]) -> Summary {
    let fps = FPS as f64;
    let beats = if raw_beats.is_empty() {
        raw_beats.to_vec()
    } else {
        refine(raw_beats, prob)
    };
    let mut out = Summary {
        beats: beats.clone(),
        downbeats: downbeats.to_vec(),
        bpm: None,
        bpm_range: None,
        stability: "no steady beat".into(),
        beats_per_bar: None,
        confidence: 0.0,
    };
    if beats.len() < 4 {
        return out;
    }
    let ibi: Vec<f64> = beats.windows(2).map(|w| w[1] - w[0]).collect();
    let med = median(&ibi);
    let regular = ibi
        .iter()
        .filter(|&&v| (v - med).abs() <= 0.06 * med)
        .count() as f64
        / ibi.len() as f64;
    // Tempo over 8-beat stretches shows whether it drifts or changes.
    let win = 8;
    let mut local: Vec<f64> = Vec::new();
    if beats.len() > win {
        for s in (0..beats.len() - win).step_by(win / 2) {
            local.push(60.0 / fit_period(&beats[s..beats.len().min(s + win + 1)], med));
        }
    }
    if local.is_empty() {
        local = vec![60.0 / med];
    }
    let (p10, p90, local_median) = (
        percentile(&local, 10.0),
        percentile(&local, 90.0),
        median(&local),
    );
    let spread = (p90 - p10) / local_median;
    let bpm = if spread < 0.02 {
        out.stability = "steady".into();
        60.0 / fit_period(&beats, med) // the whole song: precise for a steady tempo
    } else {
        out.stability = if spread < 0.06 {
            "mostly steady"
        } else {
            "variable"
        }
        .into();
        local_median
    };
    let strength = beats
        .iter()
        .map(|b| {
            let f = ((b * fps).round_ties_even() as i64).clamp(0, prob.len() as i64 - 1) as usize;
            prob[f] as f64
        })
        .fold(0.0, |s, v| s + v)
        / beats.len() as f64;
    if downbeats.len() >= 3 {
        let counts: Vec<i64> = downbeats
            .windows(2)
            .map(|w| {
                beats
                    .iter()
                    .filter(|&&b| b >= w[0] - 0.02 && b < w[1] - 0.02)
                    .count() as i64
            })
            .collect();
        // The most common count; the smallest on a tie (numpy.unique sorts).
        let mut tally: std::collections::BTreeMap<i64, usize> = std::collections::BTreeMap::new();
        for c in counts {
            *tally.entry(c).or_default() += 1;
        }
        out.beats_per_bar = tally
            .iter()
            .max_by(|a, b| a.1.cmp(b.1).then(b.0.cmp(a.0)))
            .map(|(k, _)| *k);
    }
    out.bpm = Some((bpm * 100.0).round() / 100.0);
    out.bpm_range = Some(((p10 * 10.0).round() / 10.0, (p90 * 10.0).round() / 10.0));
    out.confidence = ((0.5 * regular + 0.5 * strength) * 1000.0).round() / 1000.0;
    out
}

/// refine_peaks: sub-frame times by a parabola through the probability around each peak (in
/// single precision, as numpy computed it from the float32 probabilities).
fn refine(times: &[f64], prob: &[f32]) -> Vec<f64> {
    let fps = FPS as f64;
    if prob.len() < 3 {
        return times.to_vec();
    }
    times
        .iter()
        .map(|t| {
            let f = ((t * fps).round_ties_even() as i64).clamp(1, prob.len() as i64 - 2) as usize;
            let (a, b, c) = (prob[f - 1], prob[f], prob[f + 1]);
            let den = a - 2.0 * b + c;
            let delta = if den.abs() > 1e-9 {
                0.5 * (a - c) / den
            } else {
                0.0
            };
            (f as f64 + delta.clamp(-0.5, 0.5) as f64) / fps
        })
        .collect()
}

/// fit_period: a robust straight line through beat time against beat number; its slope is the
/// beat period.
fn fit_period(beats: &[f64], guess: f64) -> f64 {
    let mut n = vec![0f64; beats.len()];
    for i in 1..beats.len().max(1) {
        n[i] = n[i - 1] + 1f64.max(((beats[i] - beats[i - 1]) / guess).round_ties_even());
    }
    let mut keep = vec![true; beats.len()];
    let mut slope = 0.0;
    for _ in 0..4 {
        let (s, intercept) = fit_line(&n, beats, &keep);
        slope = s;
        let new_keep: Vec<bool> = (0..beats.len())
            .map(|i| (beats[i] - (s * n[i] + intercept)).abs() <= 0.15 * s)
            .collect();
        let kept = new_keep.iter().filter(|&&k| k).count();
        if (kept as f64) < 4f64.max(0.5 * beats.len() as f64) || new_keep == keep {
            break;
        }
        keep = new_keep;
    }
    slope
}

/// Least squares y = slope·x + intercept over the kept points (numpy.polyfit, degree 1).
fn fit_line(x: &[f64], y: &[f64], keep: &[bool]) -> (f64, f64) {
    let idx: Vec<usize> = (0..x.len()).filter(|&i| keep[i]).collect();
    let count = idx.len() as f64;
    let mx = idx.iter().fold(0.0, |s, &i| s + x[i]) / count;
    let my = idx.iter().fold(0.0, |s, &i| s + y[i]) / count;
    let (mut sxy, mut sxx) = (0.0, 0.0);
    for &i in &idx {
        sxy += (x[i] - mx) * (y[i] - my);
        sxx += (x[i] - mx) * (x[i] - mx);
    }
    let slope = if sxx > 0.0 { sxy / sxx } else { 0.0 };
    (slope, my - slope * mx)
}

fn median(v: &[f64]) -> f64 {
    percentile(v, 50.0)
}

/// numpy.percentile with linear interpolation.
fn percentile(v: &[f64], q: f64) -> f64 {
    let mut s = v.to_vec();
    s.sort_by(f64::total_cmp);
    if s.len() <= 1 {
        return s.first().copied().unwrap_or(f64::NAN);
    }
    let pos = q / 100.0 * (s.len() - 1) as f64;
    let i = pos.floor() as usize;
    let frac = pos - i as f64;
    if i + 1 < s.len() {
        s[i] + (s[i + 1] - s[i]) * frac
    } else {
        s[i]
    }
}

// MARK: KeyDetection

/// S-KEY's 24 outputs, in its order (skey.key_detection.key_map).
pub fn key_labels() -> &'static [MusicKey] {
    static LABELS: OnceLock<Vec<MusicKey>> = OnceLock::new();
    LABELS.get_or_init(|| {
        let names = [
            "A", "Bb", "B", "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "B", "C", "C#", "D",
            "D#", "E", "F", "F#", "G", "G#", "A", "Bb",
        ];
        names
            .iter()
            .enumerate()
            .map(|(i, n)| {
                MusicKey::parse(&format!("{n}{}", if i >= 12 { "m" } else { "" })).unwrap()
            })
            .collect()
    })
}

#[derive(Clone, Debug, PartialEq)]
pub struct KeyEstimate {
    pub key: MusicKey,
    pub confidence: f64,
    pub runner_up: MusicKey,
    pub runner_up_confidence: f64,
}

/// The most likely key with its probability, and the next most likely.
pub fn estimate_key(p: &[f32]) -> Option<KeyEstimate> {
    let labels = key_labels();
    if p.len() != labels.len() {
        return None;
    }
    let mut order: Vec<usize> = (0..p.len()).collect();
    order.sort_by(|&a, &b| {
        p[b].partial_cmp(&p[a])
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.cmp(&b))
    });
    Some(KeyEstimate {
        key: labels[order[0]],
        confidence: p[order[0]] as f64,
        runner_up: labels[order[1]],
        runner_up_confidence: p[order[1]] as f64,
    })
}
