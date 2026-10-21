"""Tempo (Beat This!, CPJKU, ISMIR 2024) and key (S-KEY, Deezer, ICASSP 2025),
plus a classic key-profile estimate as a second opinion."""

from __future__ import annotations

import contextlib
import inspect
import io
import json
import os
import re

import numpy as np

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

NOTE_MAJOR = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
NOTE_MINOR = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "G#", "A", "Bb", "B"]
PC = {"C": 0, "B#": 0, "C#": 1, "DB": 1, "D": 2, "D#": 3, "EB": 3, "E": 4, "FB": 4, "E#": 5, "F": 5, "F#": 6,
      "GB": 6, "G": 7, "G#": 8, "AB": 8, "A": 9, "A#": 10, "BB": 10, "B": 11, "CB": 11}

BEAT_SR = 22050
BEAT_CHECKPOINTS = ["final0", "final1", "final2"]  # three training seeds, averaged
BEAT_FALLBACK_REPO = "safe-models/beat-this-final0"  # community copy (weights-only safetensors)


# ---------------------------------------------------------------- key names

def key_label(pc: int, minor: bool) -> str:
    return f"{(NOTE_MINOR if minor else NOTE_MAJOR)[pc % 12]} {'minor' if minor else 'major'}"


def camelot(pc: int, minor: bool) -> str:
    major_pc = (pc + 3) % 12 if minor else pc
    n = ((major_pc * 7) % 12 + 7) % 12 + 1
    return f"{n}{'A' if minor else 'B'}"


def parse_key(s) -> tuple[int, bool] | None:
    """'Am', 'A minor', 'A min', 'C#m', 'Dbmaj', 'F# major', 'B♭m', '8A', '08B', '1d'/'1m' (Open Key)."""
    if s is None:
        return None
    t = str(s).strip().replace("♭", "b").replace("♯", "#")
    if not t:
        return None
    m = re.fullmatch(r"0?(\d{1,2})\s*([ABab])", t)
    if m and 1 <= int(m.group(1)) <= 12:  # Camelot
        n, minor = int(m.group(1)), m.group(2).upper() == "A"
        major_pc = next(pc for pc in range(12) if ((pc * 7) % 12 + 7) % 12 + 1 == n)
        return ((major_pc - 3) % 12 if minor else major_pc), minor
    m = re.fullmatch(r"0?(\d{1,2})\s*([dmDM])", t)
    if m and 1 <= int(m.group(1)) <= 12:  # Open Key
        n = (int(m.group(1)) + 6) % 12 + 1
        return parse_key(f"{n}{'A' if m.group(2).lower() == 'm' else 'B'}")
    m = re.fullmatch(r"([A-Ga-g])\s*([#b]?)\s*(.*)", t)
    if not m:
        return None
    note = m.group(1).upper() + (m.group(2).upper() if m.group(2) else "")
    if note not in PC:
        return None
    rest = m.group(3).strip().lower()
    if rest in ("", "maj", "major", "dur", "ionian"):
        return PC[note], False
    if rest in ("m", "min", "minor", "moll", "aeolian", "mi"):
        return PC[note], True
    return None


def key_relation(a: tuple[int, bool], b: tuple[int, bool]) -> str:
    """MIREX categories: same / fifth / relative / parallel / other."""
    if a == b:
        return "same"
    (pa, ma), (pb, mb) = a, b
    if ma == mb and (pa - pb) % 12 in (5, 7):
        return "fifth"
    if ma != mb:
        rel_a = (pa + 3) % 12 if ma else (pa - 3) % 12  # relative of a
        if rel_a == pb:
            return "relative"
        if pa == pb:
            return "parallel"
    return "other"


def mirex_score(est: tuple[int, bool], ref: tuple[int, bool]) -> float:
    """MIREX weighted key score (as mir_eval: fifth = estimate a fifth above)."""
    (pe, me), (pr, mr) = est, ref
    if est == ref:
        return 1.0
    if me == mr and (pe - pr) % 12 == 7:
        return 0.5
    if me != mr:
        if (not mr and me and pe == (pr - 3) % 12) or (mr and not me and pe == (pr + 3) % 12):
            return 0.3
        if pe == pr:
            return 0.2
    return 0.0


# ---------------------------------------------------------------- tempo

def _load_beat_model(name: str, device: str):
    from beat_this.inference import load_checkpoint
    from beat_this.model.beat_tracker import BeatThis

    allowed = set(inspect.signature(BeatThis).parameters)
    try:
        ckpt = load_checkpoint(name, "cpu")  # official JKU server, cached in ~/.cache/torch/hub
        hp = {k: v for k, v in ckpt["hyper_parameters"].items() if k in allowed}
        state = {k[len("model."):]: v for k, v in ckpt["state_dict"].items() if k.startswith("model.")}
        source = "official"
    except Exception:  # noqa: BLE001
        if name != "final0":
            return None, None
        from huggingface_hub import hf_hub_download
        from safetensors.torch import load_file

        cfg = json.load(open(hf_hub_download(BEAT_FALLBACK_REPO, "config.json")))
        hp = {k: v for k, v in cfg.items() if k in allowed}
        state = load_file(hf_hub_download(BEAT_FALLBACK_REPO, "model.safetensors"))
        source = f"community copy ({BEAT_FALLBACK_REPO})"
    model = BeatThis(**hp)
    missing, unexpected = model.load_state_dict(state, strict=False)
    bad = [k for k in list(missing) + list(unexpected) if "rotary_embed" not in k]
    if bad:
        raise RuntimeError(f"Beat This! weights don't match the model: {bad[:5]}")
    return model.to(device).eval(), source


class TempoEstimator:
    def __init__(self, device: str = "cpu", ensemble: bool = True):
        import torch
        from beat_this.preprocessing import LogMelSpect

        self.torch = torch
        self.device = device
        self.models, self.sources = [], []
        for name in (BEAT_CHECKPOINTS if ensemble else BEAT_CHECKPOINTS[:1]):
            m, src = _load_beat_model(name, device)
            if m is not None:
                self.models.append(m)
                self.sources.append(f"{name}: {src}")
        if not self.models:
            raise RuntimeError("Could not load any Beat This! model")
        self.spect = LogMelSpect(device=device)

    def describe(self) -> str:
        return "Beat This! " + ", ".join(self.sources)

    def to_cpu(self) -> None:
        from beat_this.preprocessing import LogMelSpect

        self.device = "cpu"
        self.models = [m.to("cpu") for m in self.models]
        self.spect = LogMelSpect(device="cpu")

    def __call__(self, x: np.ndarray) -> dict:
        """x: mono float32 at 22050 Hz."""
        torch = self.torch
        from beat_this.inference import split_predict_aggregate
        from beat_this.model.postprocessor import Postprocessor

        with torch.inference_mode():
            spect = self.spect(torch.tensor(x, dtype=torch.float32, device=self.device))
            beat_p, down_p = 0, 0
            for m in self.models:
                pred = split_predict_aggregate(spect=spect, chunk_size=1500, border_size=6,
                                               overlap_mode="keep_first", model=m)
                beat_p = beat_p + torch.sigmoid(pred["beat"].float())
                down_p = down_p + torch.sigmoid(pred["downbeat"].float())
            beat_p, down_p = beat_p / len(self.models), down_p / len(self.models)
            logit = lambda p: torch.log(p.clamp(1e-6, 1 - 1e-6)) - torch.log1p(-p.clamp(1e-6, 1 - 1e-6))  # noqa: E731
            beats, downbeats = Postprocessor(type="minimal")(logit(beat_p), logit(down_p))
        beat_p = beat_p.cpu().numpy()
        return summarize_beats(np.asarray(beats), np.asarray(downbeats), beat_p, fps=50)


def refine_peaks(times: np.ndarray, prob: np.ndarray, fps: int) -> np.ndarray:
    """Sub-frame beat times by parabolic interpolation of the activation peak
    (the model outputs 50 frames/s, i.e. a 20 ms grid)."""
    f = np.clip(np.round(times * fps).astype(int), 1, len(prob) - 2)
    a, b, c = prob[f - 1], prob[f], prob[f + 1]
    den = a - 2 * b + c
    delta = np.where(np.abs(den) > 1e-9, 0.5 * (a - c) / np.where(den == 0, 1, den), 0.0)
    return (f + np.clip(delta, -0.5, 0.5)) / fps


def fit_period(beats: np.ndarray, guess: float) -> tuple[float, np.ndarray]:
    """Robust straight-line fit of beat time vs beat number (handles a missed
    or extra beat). Returns (period, inlier mask)."""
    n = np.zeros(len(beats))
    for i in range(1, len(beats)):
        n[i] = n[i - 1] + max(1, round((beats[i] - beats[i - 1]) / guess))
    keep = np.ones(len(beats), bool)
    for _ in range(4):
        slope, icpt = np.polyfit(n[keep], beats[keep], 1)
        resid = np.abs(beats - (slope * n + icpt))
        new_keep = resid <= 0.15 * slope
        if new_keep.sum() < max(4, 0.5 * len(beats)) or (new_keep == keep).all():
            break
        keep = new_keep
    return float(slope), keep


def summarize_beats(beats: np.ndarray, downbeats: np.ndarray, beat_prob: np.ndarray, fps: int = 50) -> dict:
    if len(beats) >= 1:
        beats = refine_peaks(np.asarray(beats, float), beat_prob, fps)
    out = {"beats": [round(float(b), 3) for b in beats], "downbeats": [round(float(d), 3) for d in downbeats]}
    if len(beats) < 4:
        out.update(bpm=None, tempo_confidence=0.0, stability="no steady beat")
        return out
    ibi = np.diff(beats)
    med = float(np.median(ibi))
    regular = float(np.mean(np.abs(ibi - med) <= 0.06 * med))
    # local tempo over 8-beat windows shows whether the tempo drifts or changes
    win = 8
    local = []
    for s in range(0, len(beats) - win, win // 2):
        p, _ = fit_period(beats[s:s + win + 1], med)
        local.append(60.0 / p)
    local_bpm = np.array(local) if local else np.array([60.0 / med])
    spread = float((np.percentile(local_bpm, 90) - np.percentile(local_bpm, 10)) / np.median(local_bpm))
    if spread < 0.02:
        period, _ = fit_period(beats, med)  # whole-song fit: precise for steady tempo
        bpm = 60.0 / period
        stability = "steady"
    else:
        bpm = float(np.median(local_bpm))
        stability = "mostly steady" if spread < 0.06 else "variable"
    frames = np.clip(np.round(beats * fps).astype(int), 0, len(beat_prob) - 1)
    strength = float(np.mean(beat_prob[frames]))
    per_bar = None
    if len(downbeats) >= 3:
        counts = [int(np.sum((beats >= a - 0.02) & (beats < b - 0.02))) for a, b in zip(downbeats[:-1], downbeats[1:])]
        if counts:
            vals, freq = np.unique(counts, return_counts=True)
            per_bar = int(vals[np.argmax(freq)])
    out.update(
        bpm=round(bpm, 2),
        bpm_range=[round(float(np.percentile(local_bpm, 10)), 1), round(float(np.percentile(local_bpm, 90)), 1)],
        stability=stability,
        beats_per_bar=per_bar,
        tempo_confidence=round(0.5 * regular + 0.5 * strength, 3),
    )
    return out


# ---------------------------------------------------------------- key

class KeyEstimator:
    """S-KEY (Deezer). Returns all 24 probabilities so we get a confidence."""

    def __init__(self, device: str = "cpu"):
        import torch
        from skey.key_detection import key_map, load_checkpoint, load_model_components

        self.torch = torch
        self.device = device
        with contextlib.redirect_stdout(io.StringIO()):  # nnAudio prints setup chatter
            ckpt = load_checkpoint(None)
            self.sr = int(ckpt["audio"]["sr"])
            self.hcqt, self.net, self.crop = load_model_components(ckpt, torch.device(device))
        self.labels = []
        for i in range(24):
            note, mode = key_map[i].split()
            self.labels.append((PC[note.upper()], mode.lower() == "minor"))

    def to_cpu(self) -> None:
        self.device = "cpu"
        self.hcqt, self.net = self.hcqt.to("cpu"), self.net.to("cpu")

    def __call__(self, x: np.ndarray) -> dict:
        """x: mono float32 at self.sr."""
        torch = self.torch
        peak = float(np.max(np.abs(x))) or 1.0
        t = torch.tensor(x / peak, dtype=torch.float32, device=self.device)[None, None]
        with torch.inference_mode():
            p = self.net(self.crop(self.hcqt(t), torch.zeros(1, device=self.device))).mean(0).float().cpu().numpy()
        order = np.argsort(-p)
        best = self.labels[order[0]]
        return {"key": best, "confidence": float(p[order[0]]), "margin": float(p[order[0]] - p[order[1]]),
                "runner_up": self.labels[order[1]]}


# Krumhansl-Kessler key profiles
KK_MAJOR = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
KK_MINOR = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])


def classic_key(x: np.ndarray, sr: int) -> dict:
    """Second opinion: harmonic chroma correlated with key profiles."""
    import librosa

    y = x[: sr * 300]
    harm = librosa.effects.harmonic(y, margin=2.0)
    chroma = librosa.feature.chroma_cqt(y=harm, sr=sr, bins_per_octave=36)
    prof = chroma.mean(axis=1)
    scores = []
    for minor, base in ((False, KK_MAJOR), (True, KK_MINOR)):
        for pc in range(12):
            scores.append((float(np.corrcoef(prof, np.roll(base, pc))[0, 1]), (pc, minor)))
    scores.sort(reverse=True)
    return {"key": scores[0][1], "score": scores[0][0], "margin": scores[0][0] - scores[1][0]}
