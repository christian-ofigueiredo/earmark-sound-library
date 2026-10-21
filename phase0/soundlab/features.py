""""Shape" features: length, envelope, brightness and how they move over time.

The AI embedding captures what a sound *is* (texture, material). These
features capture its *shape*, which matters a lot for whooshes: a short
bright swish and a long dark pass-by can share a texture but sound different.
"""

from __future__ import annotations

import numpy as np

FEATURES_VERSION = 2  # bump when the feature set changes (invalidates caches)
N_ENV = 16
N_TRAJ = 8
BANDS = [(0, 150), (150, 600), (600, 2500), (2500, 8000), (8000, 24000)]
MAX_FEATURE_SECONDS = 120.0

# Groups of feature dimensions; each group gets equal total weight.
GROUPS = {
    "length": ["log_duration"],
    "envelope": [f"env_{i}" for i in range(N_ENV)],
    "dynamics": ["peak_pos", "log_attack", "log_release", "crest_db"],
    "brightness": ["centroid_oct", "bandwidth_oct"] + [f"band_{i}" for i in range(len(BANDS))],
    "movement": [f"traj_{i}" for i in range(N_TRAJ)] + ["centroid_slope"],
    "texture": ["tonality", "onset_rate"],
}
FEATURE_NAMES = [n for g in GROUPS.values() for n in g]


def _resample_curve(y: np.ndarray, n: int) -> np.ndarray:
    if len(y) == 0:
        return np.zeros(n)
    if len(y) == 1:
        return np.full(n, y[0])
    return np.interp(np.linspace(0, len(y) - 1, n), np.arange(len(y)), y)


def shape_features(x: np.ndarray, sr: int) -> dict:
    """x: trimmed, peak-normalized mono signal."""
    x = x[: int(MAX_FEATURE_SECONDS * sr)]
    duration = len(x) / sr
    n_fft, hop = 2048, 512
    if len(x) < n_fft:
        x = np.pad(x, (0, n_fft - len(x)))
    frames = np.lib.stride_tricks.sliding_window_view(x, n_fft)[::hop]
    win = np.hanning(n_fft).astype(np.float32)
    spec = np.abs(np.fft.rfft(frames * win, axis=1)) ** 2  # power
    freqs = np.fft.rfftfreq(n_fft, 1 / sr)
    energy = spec.sum(axis=1) + 1e-12
    rms = np.sqrt(np.mean(frames ** 2, axis=1)) + 1e-9
    rms_db = 20 * np.log10(rms / rms.max())
    t = np.arange(len(rms)) * hop / sr

    # envelope shape (time-normalized, 0..1 with a -48 dB floor)
    env = np.clip((rms_db + 48) / 48, 0, 1)
    env_curve = _resample_curve(env, N_ENV)

    peak_i = int(np.argmax(rms))
    peak_pos = peak_i / max(1, len(rms) - 1)
    above = np.nonzero(rms_db[: peak_i + 1] >= -20)[0]
    attack = t[peak_i] - (t[above[0]] if above.size else 0.0)
    after = np.nonzero(rms_db[peak_i:] < -20)[0]
    release = (t[peak_i + after[0]] - t[peak_i]) if after.size else (t[-1] - t[peak_i])
    crest_db = 20 * np.log10((np.max(np.abs(x)) + 1e-9) / (np.sqrt(np.mean(x ** 2)) + 1e-9))

    # brightness and its movement, weighted by loudness
    w = energy / energy.sum()
    centroid = (spec * freqs).sum(axis=1) / energy
    centroid_oct = np.log2(np.maximum(centroid, 20.0))
    bw = np.sqrt((spec * (freqs[None, :] - centroid[:, None]) ** 2).sum(axis=1) / energy)
    loud = rms_db > -30
    if loud.sum() < 2:
        loud = np.ones_like(loud)
    c_mean = float(np.sum(centroid_oct * w))
    traj = _resample_curve(centroid_oct[loud] - c_mean, N_TRAJ)
    tt = np.linspace(0, 1, len(centroid_oct))
    if loud.sum() >= 3:
        slope = float(np.polyfit(tt[loud], centroid_oct[loud], 1, w=np.sqrt(w[loud] + 1e-12))[0])
    else:
        slope = 0.0

    band_energy = np.array([spec[:, (freqs >= lo) & (freqs < hi)].sum() for lo, hi in BANDS]) + 1e-12
    band_frac = band_energy / band_energy.sum()
    # Tonality: share of energy in narrow spectral peaks standing well above
    # their neighbourhood. ~1 for tones, ~0 for noise (even band-limited noise,
    # which plain spectral flatness mistakes for tonal).
    from scipy.ndimage import median_filter

    local = median_filter(spec, size=(1, 15), mode="nearest")
    peaky = spec > 10.0 * (local + 1e-12)
    tonal_frac = (spec * peaky).sum(axis=1) / energy
    tonality = float(np.sum(tonal_frac * w))

    flux = np.maximum(0, np.diff(np.log(spec + 1e-10), axis=0)).mean(axis=1) if len(spec) > 1 else np.zeros(1)
    thr = np.median(flux) + 2 * np.std(flux)
    onsets = int(np.sum((flux[1:-1] > thr) & (flux[1:-1] >= flux[:-2]) & (flux[1:-1] >= flux[2:]))) if len(flux) > 2 else 0

    feats = {
        "log_duration": np.log(max(duration, 0.01)),
        "peak_pos": peak_pos,
        "log_attack": np.log(max(attack, 0.002)),
        "log_release": np.log(max(release, 0.002)),
        "crest_db": crest_db,
        "centroid_oct": c_mean,
        "bandwidth_oct": float(np.log2(max(np.sum(bw * w), 20.0))),
        "centroid_slope": slope,
        "tonality": tonality,
        "onset_rate": np.log1p(onsets / max(duration, 0.1)),
    }
    for i, v in enumerate(env_curve):
        feats[f"env_{i}"] = float(v)
    for i, v in enumerate(traj):
        feats[f"traj_{i}"] = float(v)
    for i, v in enumerate(band_frac):
        feats[f"band_{i}"] = float(v)
    feats["duration_s"] = duration
    feats["centroid_hz"] = float(2 ** c_mean)
    return {k: float(v) for k, v in feats.items()}


def feature_matrix(feature_dicts: list[dict]) -> np.ndarray:
    """Standardize across the set and balance the groups so that each group
    contributes equally; rows have roughly unit norm."""
    raw = np.array([[d[n] for n in FEATURE_NAMES] for d in feature_dicts], dtype=np.float64)
    mu = raw.mean(axis=0)
    sd = raw.std(axis=0)
    sd[sd < 1e-9] = 1.0
    z = np.clip((raw - mu) / sd, -4, 4)
    out = np.zeros_like(z)
    col = 0
    n_groups = len(GROUPS)
    for names in GROUPS.values():
        k = len(names)
        out[:, col:col + k] = z[:, col:col + k] / np.sqrt(k * n_groups)
        col += k
    return out


def describe_shape(feats: dict, ref: dict[str, tuple[float, float]]) -> list[str]:
    """Plain words for one group's average features, relative to the set.
    ref: feature -> (33rd percentile, 67th percentile)."""
    words = []
    # Relative words only when the set really varies (e.g. not for a set of
    # clips that are all exactly 5 s long).
    lo, hi = ref["duration_s"]
    if hi > 1.4 * lo:
        if feats["duration_s"] <= lo:
            words.append("short")
        elif feats["duration_s"] >= hi:
            words.append("long")
    lo, hi = ref["centroid_hz"]
    if hi > 1.3 * lo:
        if feats["centroid_hz"] <= lo:
            words.append("dark")
        elif feats["centroid_hz"] >= hi:
            words.append("bright")
    s = feats["centroid_slope"]
    if s > 0.6:
        words.append("rising")
    elif s < -0.6:
        words.append("falling")
    p = feats["peak_pos"]
    starts_quiet = feats["env_0"] < 0.5 and feats[f"env_{N_ENV - 1}"] < 0.5
    if p < 0.12 and feats["log_attack"] < np.log(0.03):
        words.append("hit")
    elif 0.3 <= p <= 0.75 and starts_quiet and feats["log_attack"] > np.log(0.08):
        words.append("swell / pass-by")
    if feats["tonality"] > 0.6:
        words.append("tonal")
    elif feats["tonality"] < 0.15:
        words.append("noisy")
    return words
