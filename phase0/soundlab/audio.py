"""Finding, loading and preparing audio files. Never writes to the source folders."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf
import soxr

AUDIO_EXTS = {
    ".wav", ".wave", ".bwf", ".rf64", ".w64",
    ".aif", ".aiff", ".aifc",
    ".flac", ".ogg", ".oga", ".opus",
    ".mp3", ".m4a", ".aac", ".alac", ".caf", ".mp4",
}

DEFAULT_OUTPUT_ROOT = Path.home() / "SoundLab"


class AudioLoadError(Exception):
    pass


# ---------------------------------------------------------------- files

def find_audio_files(paths: list[Path], exts: set[str] = AUDIO_EXTS) -> list[Path]:
    """All audio files under the given files/folders, sorted, skipping hidden
    files and macOS AppleDouble ("._name") files."""
    found: set[Path] = set()
    for p in paths:
        p = Path(p).expanduser()
        if p.is_file():
            if p.suffix.lower() in exts:
                found.add(p.resolve())
            continue
        if not p.is_dir():
            raise FileNotFoundError(f"Not found: {p}")
        for root, dirs, files in os.walk(p):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            for name in files:
                if name.startswith(".") or name.startswith("._"):
                    continue
                if Path(name).suffix.lower() in exts:
                    found.add((Path(root) / name).resolve())
    return sorted(found)


def ensure_output_outside_inputs(output_dir: Path, inputs: list[Path]) -> Path:
    """Refuse to run if the output folder is inside one of the input folders,
    so nothing is ever written into a sound library."""
    out = Path(output_dir).expanduser().resolve()
    for inp in inputs:
        src = Path(inp).expanduser().resolve()
        src_dir = src if src.is_dir() else src.parent
        if out == src_dir or src_dir in out.parents:
            sys.exit(
                f"\nRefusing to run: the output folder\n  {out}\nis inside your sound folder\n  {src_dir}\n"
                "Results must go somewhere else so your library is never touched.\n"
                "Use --out to pick another folder (the default is ~/SoundLab).\n"
            )
    out.mkdir(parents=True, exist_ok=True)
    return out


def file_signature(path: Path) -> str:
    """Cheap identity for caching: size + modification time."""
    st = Path(path).stat()
    return f"{st.st_size}:{st.st_mtime_ns}"


def relative_label(path: Path, roots: list[Path]) -> str:
    """Path shown in reports: relative to whichever input folder contains it."""
    path = Path(path)
    for r in roots:
        r = Path(r).expanduser().resolve()
        r = r if r.is_dir() else r.parent
        try:
            return str(path.relative_to(r))
        except ValueError:
            continue
    return path.name


# ---------------------------------------------------------------- loading

def _mix_to_mono(block: np.ndarray) -> np.ndarray:
    if block.ndim == 1:
        return block
    return block.mean(axis=1)


def _read_soundfile(path: Path, sr: int | None, max_seconds: float | None,
                    start_seconds: float = 0.0) -> tuple[np.ndarray, int]:
    """Stream-decode with libsndfile, mixing to mono and resampling block by
    block so long multichannel files don't need much memory."""
    with sf.SoundFile(str(path)) as f:
        in_sr = f.samplerate
        if start_seconds > 0 and f.seekable():
            f.seek(min(int(start_seconds * in_sr), max(f.frames - 1, 0)))
        frames_left = int(max_seconds * in_sr) if max_seconds else -1
        out_sr = sr or in_sr
        resampler = None
        if out_sr != in_sr:
            resampler = soxr.ResampleStream(in_sr, out_sr, 1, dtype="float32", quality="VHQ")
        pieces = []
        block_size = 1 << 16
        while frames_left != 0:
            n = block_size if frames_left < 0 else min(block_size, frames_left)
            block = f.read(n, dtype="float32", always_2d=True)
            if len(block) == 0:
                break
            if frames_left > 0:
                frames_left -= len(block)
            mono = _mix_to_mono(block).astype(np.float32, copy=False)
            if resampler is not None:
                mono = resampler.resample_chunk(mono, last=False)
            pieces.append(mono)
        if resampler is not None:
            pieces.append(resampler.resample_chunk(np.zeros(0, dtype=np.float32), last=True))
    x = np.concatenate(pieces) if pieces else np.zeros(0, dtype=np.float32)
    return x.astype(np.float32, copy=False), out_sr


def _read_ffmpeg(path: Path, sr: int, max_seconds: float | None, start_seconds: float) -> tuple[np.ndarray, int]:
    cmd = ["ffmpeg", "-v", "error", "-nostdin"]
    if start_seconds > 0:
        cmd += ["-ss", f"{start_seconds:.3f}"]
    cmd += ["-i", str(path)]
    if max_seconds:
        cmd += ["-t", f"{max_seconds:.3f}"]
    cmd += ["-vn", "-ac", "1", "-ar", str(sr), "-f", "f32le", "-"]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if proc.returncode != 0:
        raise AudioLoadError(proc.stderr.decode(errors="replace").strip()[:300])
    return np.frombuffer(proc.stdout, dtype=np.float32).copy(), sr


def _read_afconvert(path: Path, sr: int | None, max_seconds: float | None, start_seconds: float) -> tuple[np.ndarray, int]:
    """macOS built-in decoder (handles AAC/ALAC/M4A). Decodes to a temp file in
    the system temp folder, never next to the source."""
    with tempfile.TemporaryDirectory(prefix="soundlab-") as tmp:
        out = Path(tmp) / "decoded.wav"
        proc = subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", "LEF32", str(path), str(out)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        if proc.returncode != 0 or not out.exists():
            raise AudioLoadError(proc.stderr.decode(errors="replace").strip()[:300])
        return _read_soundfile(out, sr, max_seconds, start_seconds)


def load_audio(path: Path, sr: int | None = None, max_seconds: float | None = None,
               start_seconds: float = 0.0) -> tuple[np.ndarray, int]:
    """Decode any supported file to mono float32. Tries libsndfile, then
    ffmpeg, then macOS afconvert."""
    path = Path(path)
    errors = []
    try:
        return _read_soundfile(path, sr, max_seconds, start_seconds)
    except Exception as e:  # noqa: BLE001 - try the next decoder
        errors.append(f"soundfile: {e}")
    if shutil.which("ffmpeg"):
        try:
            return _read_ffmpeg(path, sr or 48000, max_seconds, start_seconds)
        except Exception as e:  # noqa: BLE001
            errors.append(f"ffmpeg: {e}")
    if shutil.which("afconvert"):
        try:
            return _read_afconvert(path, sr, max_seconds, start_seconds)
        except Exception as e:  # noqa: BLE001
            errors.append(f"afconvert: {e}")
    raise AudioLoadError(f"Could not decode {path.name}: " + " | ".join(errors))


def audio_info(path: Path) -> dict:
    """Format facts without decoding the whole file (empty dict if unknown)."""
    try:
        i = sf.info(str(path))
        return {
            "samplerate": i.samplerate,
            "channels": i.channels,
            "duration": i.duration,
            "format": i.format,
            "subtype": i.subtype,
        }
    except Exception:  # noqa: BLE001
        pass
    try:
        import mutagen

        m = mutagen.File(str(path))
        if m is not None and m.info is not None:
            return {
                "samplerate": getattr(m.info, "sample_rate", None),
                "channels": getattr(m.info, "channels", None),
                "duration": getattr(m.info, "length", None),
                "format": type(m).__name__,
                "subtype": None,
            }
    except Exception:  # noqa: BLE001
        pass
    return {}


# ---------------------------------------------------------------- preparation

def trim_silence(x: np.ndarray, sr: int, threshold_db: float = -60.0, pad_s: float = 0.01) -> np.ndarray:
    """Cut leading/trailing parts quieter than threshold_db relative to the peak."""
    if x.size == 0:
        return x
    peak = float(np.max(np.abs(x)))
    if peak <= 0:
        return x
    hop = max(1, int(sr * 0.005))
    n = len(x) // hop
    if n < 2:
        return x
    frames = np.abs(x[: n * hop]).reshape(n, hop).max(axis=1)
    loud = np.nonzero(frames >= peak * 10 ** (threshold_db / 20))[0]
    if loud.size == 0:
        return x
    pad = int(pad_s * sr)
    start = max(0, loud[0] * hop - pad)
    end = min(len(x), (loud[-1] + 1) * hop + pad)
    return x[start:end]


def peak_normalize(x: np.ndarray, target: float = 0.9) -> np.ndarray:
    peak = float(np.max(np.abs(x))) if x.size else 0.0
    if peak <= 1e-9:
        return x
    return (x * (target / peak)).astype(np.float32, copy=False)


def pick_windows(x: np.ndarray, sr: int, window_s: float, max_windows: int) -> list[np.ndarray]:
    """Split a long signal into up to max_windows evenly spread windows, skipping
    near-silent ones. Short signals come back whole."""
    win = int(window_s * sr)
    if len(x) <= win:
        return [x]
    starts = np.linspace(0, len(x) - win, num=min(max_windows, int(np.ceil(len(x) / win))))
    windows = [x[int(s): int(s) + win] for s in starts]
    rms = np.array([np.sqrt(np.mean(w ** 2)) for w in windows])
    keep = [w for w, r in zip(windows, rms) if r >= 0.05 * rms.max()]
    return keep or windows


# ---------------------------------------------------------------- devices

def pick_device(preference: str = "auto") -> str:
    import torch

    if preference != "auto":
        return preference
    if torch.backends.mps.is_available():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


def file_uri(path: Path) -> str:
    return Path(path).resolve().as_uri()
