"""Synthetic test library for selftest.py: sound effects with vendor-style
metadata, and songs with known tempo and key. Only ever writes inside the
folder it is given."""

from __future__ import annotations

import csv
import struct
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy import signal

SR = 48000
NOTE_NAMES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]


# ---------------------------------------------------------------- WAV writing with metadata

def _chunk(cid: bytes, body: bytes) -> bytes:
    pad = b"\x00" if len(body) & 1 else b""
    return cid + struct.pack("<I", len(body)) + body + pad


def _bext(description: str, originator: str) -> bytes:
    b = struct.pack("<256s32s32s10s8sIIH64s", description.encode()[:256], originator.encode()[:32],
                    b"SELFTEST", b"2026-01-01", b"12:00:00", 0, 0, 1, b"")
    return b + b"\x00" * (602 - len(b)) + b"A=PCM,F=48000,W=24,M=mono\r\n"


def _ixml(user: dict) -> bytes:
    from xml.sax.saxutils import escape

    inner = "".join(f"<{k}>{escape(v)}</{k}>" for k, v in user.items())
    return (f'<?xml version="1.0" encoding="UTF-8"?><BWFXML><IXML_VERSION>2.1</IXML_VERSION>'
            f"<USER>{inner}</USER></BWFXML>").encode()


def write_wav(path: Path, x: np.ndarray, sr: int = SR, bext: tuple[str, str] | None = None,
              ixml_user: dict | None = None) -> None:
    """24-bit PCM WAV with optional bext + iXML chunks (written from scratch)."""
    x = np.clip(np.asarray(x, dtype=np.float64), -1, 1)
    ints = np.round(x * (2 ** 23 - 1)).astype("<i4")
    pcm = b"".join(int(v).to_bytes(4, "little", signed=True)[:3] for v in ints) if len(ints) < 2000 else \
        np.frombuffer(ints.tobytes(), dtype=np.uint8).reshape(-1, 4)[:, :3].tobytes()
    fmt = struct.pack("<HHIIHH", 1, 1, sr, sr * 3, 3, 24)
    chunks = _chunk(b"fmt ", fmt)
    if bext:
        chunks += _chunk(b"bext", _bext(*bext))
    if ixml_user:
        chunks += _chunk(b"iXML", _ixml(ixml_user))
    chunks += _chunk(b"data", pcm)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"RIFF" + struct.pack("<I", 4 + len(chunks)) + b"WAVE" + chunks)


# ---------------------------------------------------------------- sound effects

def _bandnoise(n, lo, hi, rng, sr=SR):
    sos = signal.butter(4, [lo, hi], btype="band", fs=sr, output="sos")
    return signal.sosfilt(sos, rng.standard_normal(n))


def _swell(n, peak_pos=0.5, sharp=2.0):
    t = np.linspace(0, 1, n)
    up = (t / peak_pos) ** sharp
    down = ((1 - t) / (1 - peak_pos)) ** sharp
    return np.where(t < peak_pos, up, down)


def _norm(x, peak=0.8):
    return x * (peak / (np.max(np.abs(x)) + 1e-9))


def sfx_airy_swish(rng):
    n = int(SR * rng.uniform(0.35, 0.6))
    return _norm(_bandnoise(n, 3000, 9000, rng) * _swell(n, rng.uniform(0.4, 0.6)))


def sfx_low_whoosh(rng):
    n = int(SR * rng.uniform(1.6, 2.4))
    sweep = _bandnoise(n, 80, 500, rng) * _swell(n, rng.uniform(0.5, 0.7), 1.5)
    return _norm(sweep)


def sfx_metal_whoosh(rng):
    n = int(SR * rng.uniform(0.9, 1.3))
    t = np.arange(n) / SR
    f0 = rng.uniform(300, 600)
    sweep = f0 * (1 + 2.5 * t / t[-1])
    tone = sum(np.sin(2 * np.pi * np.cumsum(sweep * r) / SR) / (k + 1) for k, r in enumerate([1, 2.76, 5.4, 8.93]))
    return _norm((0.6 * tone + 0.4 * _bandnoise(n, 1000, 6000, rng)) * _swell(n, 0.6))


def sfx_beep(rng):
    n = int(SR * rng.uniform(0.15, 0.35))
    t = np.arange(n) / SR
    env = np.minimum(1, np.minimum(t / 0.005, (t[-1] - t) / 0.01))
    return _norm(np.sin(2 * np.pi * rng.choice([880, 1000, 1200, 1500]) * t) * env, 0.6)


def sfx_thud(rng):
    n = int(SR * 0.8)
    t = np.arange(n) / SR
    body = np.sin(2 * np.pi * rng.uniform(45, 70) * t) * np.exp(-t / 0.18)
    click = _bandnoise(n, 500, 4000, rng) * np.exp(-t / 0.01)
    return _norm(body + 0.5 * click)


SFX_FAMILIES = {
    # family: (generator, CatID, FXName, description, keywords)
    "airy_swish": (sfx_airy_swish, "SWSH", "Airy Swish", "Short airy swish, fast pass", "swish, air, fast, short, whip"),
    "low_whoosh": (sfx_low_whoosh, "WHSH", "Heavy Low Whoosh", "Long heavy low whoosh pass-by", "whoosh, low, heavy, pass by"),
    "metal_whoosh": (sfx_metal_whoosh, "DSGNWhsh", "Metallic Whoosh", "Designed metallic rising whoosh",
                     "whoosh, metallic, sci-fi, designed, rising"),
    "beep": (sfx_beep, "UIBeep", "UI Beep", "Clean sine UI beep", "beep, ui, interface, tone"),
    "thud": (sfx_thud, "DSGNImpt", "Low Thud", "Deep low thud impact", "thud, impact, low, boom"),
}


def make_sfx_library(root: Path, per_family: int = 8, seed: int = 7) -> dict[str, str]:
    """Writes three 'packs' with different metadata styles. Returns {filename: family}."""
    rng = np.random.default_rng(seed)
    truth = {}
    vendor_rows = []
    for family, (gen, catid, fxname, desc, kw) in SFX_FAMILIES.items():
        for i in range(per_family):
            x = gen(rng)
            style = i % 4
            if style in (0, 1):  # Pack A: full Soundminer-style iXML + bext, UCS filename
                name = f"{catid}_{fxname} {i + 1:02d}_SLAB_PackA.wav"
                from . import ucs

                e = ucs.lookup_catid(catid)
                user = {"CATEGORY": e.category, "SUBCATEGORY": e.subcategory, "CATID": e.catid,
                        "CATEGORYFULL": f"{e.category}-{e.subcategory}", "FXNAME": f"{fxname} {i + 1:02d}",
                        "DESCRIPTION": f"{desc} {i + 1:02d}", "KEYWORDS": kw, "LIBRARY": "Pack A",
                        "MANUFACTURER": "SelfTest Audio", "DESIGNER": "Lab"}
                path = root / "Pack A" / name
                write_wav(path, x, bext=(f"{desc} {i + 1:02d}", "SelfTest Audio"), ixml_user=user)
            elif style == 2:  # Pack B: UCS filename only, plus vendor spreadsheet
                name = f"{catid}_{fxname.replace(' ', '')}{i + 1:02d}_SLAB_PackB.wav"
                path = root / "Pack B" / name
                write_wav(path, x)
                vendor_rows.append([name, f"{desc} (B{i + 1})", kw])
            else:  # Pack C: no metadata, unhelpful names
                name = f"take_{family[:2]}{i + 1:03d}.wav"
                path = root / "Pack C" / name
                write_wav(path, x)
            truth[path.name] = family
    with open(root / "Pack B" / "Pack B metadata.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Filename", "Description", "Keywords"])
        w.writerows(vendor_rows)
    return truth


# ---------------------------------------------------------------- music

def _tone(freq, n, sr, harmonics=6, decay=None):
    t = np.arange(n) / sr
    x = sum(np.sin(2 * np.pi * freq * k * t) / k ** 1.3 for k in range(1, harmonics + 1))
    env = np.minimum(1, t / 0.01)
    if decay:
        env = env * np.exp(-t / decay)
    return x * env


def make_song(bpm: float, tonic: int, minor: bool, seconds: float = 32.0, sr: int = 44100, seed: int = 0) -> np.ndarray:
    rng = np.random.default_rng(seed)
    beat = 60.0 / bpm
    n_total = int(seconds * sr)
    out = np.zeros(n_total + int(8 * beat * sr) + sr)
    # Unambiguous cadences (semitones above the tonic). The minor one uses the
    # harmonic-minor V chord (raised leading tone), so it can't be heard as the
    # relative major: i-iv-V-i and I-IV-V-I.
    prog = ([(0, 3, 7), (5, 8, 12), (7, 11, 14), (0, 3, 7)] if minor
            else [(0, 4, 7), (5, 9, 12), (7, 11, 14), (0, 4, 7)])
    bar_len = 4 * beat
    n_bars = int(np.ceil(seconds / bar_len))

    def midi_freq(m):
        return 440.0 * 2 ** ((m - 69) / 12)

    for b in range(n_bars):
        triad = list(prog[b % 4])
        bar_start = b * bar_len
        # pad chord
        n = int(bar_len * sr)
        s = int(bar_start * sr)
        for p in triad:
            out[s:s + n] += 0.12 * _tone(midi_freq(60 + tonic + p), n, sr, decay=bar_len * 0.9)
        # bass on every beat
        for q in range(4):
            sb = int((bar_start + q * beat) * sr)
            nb = int(beat * 0.9 * sr)
            out[sb:sb + nb] += 0.22 * _tone(midi_freq(36 + tonic + triad[0]), nb, sr, harmonics=4, decay=beat * 0.6)
        # arpeggio in eighths
        for e in range(8):
            se = int((bar_start + e * beat / 2) * sr)
            ne = int(beat / 2 * 0.95 * sr)
            p = triad[[0, 1, 2, 1, 0, 2, 1, 2][e]] + 12
            out[se:se + ne] += 0.07 * _tone(midi_freq(60 + tonic + p), ne, sr, harmonics=3, decay=beat * 0.3)
    # drums
    for k in range(int(seconds / beat)):
        s = int(k * beat * sr)
        n = int(0.3 * sr)
        t = np.arange(n) / sr
        f = 45 + 75 * np.exp(-t / 0.03)
        out[s:s + n] += 0.5 * np.sin(2 * np.pi * np.cumsum(f) / sr) * np.exp(-t / 0.12)
        if k % 2 == 1:
            nz = rng.standard_normal(n)
            sos = signal.butter(2, [1500, 6000], btype="band", fs=sr, output="sos")
            out[s:s + n] += 0.25 * signal.sosfilt(sos, nz) * np.exp(-t / 0.06)
        for h in (0, 1):
            sh = int((k * beat + h * beat / 2) * sr)
            nh = int(0.05 * sr)
            sos = signal.butter(2, 8000, btype="high", fs=sr, output="sos")
            out[sh:sh + nh] += 0.08 * signal.sosfilt(sos, rng.standard_normal(nh)) * np.exp(-np.arange(nh) / sr / 0.015)
    out = out[:n_total]
    return (out / (np.max(np.abs(out)) + 1e-9) * 0.9).astype(np.float32)


SONGS = [
    # (title, bpm, tonic pitch class, minor)
    ("Sunrise Drive", 120, 0, False),     # C major
    ("Night Shift", 128, 9, True),        # A minor
    ("Slow Burn", 92, 4, True),           # E minor
    ("Bright Lights", 140, 6, False),     # F# major
    ("Paper Planes", 104, 10, False),     # Bb major
    ("Rollers", 172, 2, True),            # D minor
]


def key_name(tonic: int, minor: bool) -> str:
    return f"{NOTE_NAMES[tonic]} {'minor' if minor else 'major'}"


def make_music_library(music_dir: Path, truth_csv: Path, tag_one: bool = True) -> None:
    music_dir.mkdir(parents=True, exist_ok=True)
    rows = []
    for i, (title, bpm, tonic, minor) in enumerate(SONGS):
        x = make_song(bpm, tonic, minor, seed=i)
        path = music_dir / f"{i + 1:02d} {title}.wav"
        sf.write(str(path), x, 44100, subtype="PCM_16")
        rows.append([path.name, bpm, key_name(tonic, minor)])
        if tag_one and i == 0:
            try:
                from mutagen.id3 import TBPM, TIT2, TKEY, TPE1
                from mutagen.wave import WAVE

                w = WAVE(str(path))
                w.add_tags()
                w.tags.add(TIT2(encoding=3, text=title))
                w.tags.add(TPE1(encoding=3, text="SelfTest Band"))
                w.tags.add(TBPM(encoding=3, text=str(bpm)))
                w.tags.add(TKEY(encoding=3, text="C"))
                w.save()
            except Exception:  # noqa: BLE001 - tags are optional in the test
                pass
    with open(truth_csv, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["file", "bpm", "key"])
        w.writerows(rows)
