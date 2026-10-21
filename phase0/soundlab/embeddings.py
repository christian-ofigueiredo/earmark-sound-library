"""Audio and text embeddings from Meta PE-AV (default) or LAION CLAP.

Both models put audio and text in the same space, so the same vectors give
"sounds like" similarity, plain-language search and zero-shot categories.
"""

from __future__ import annotations

import logging
import os
import pickle
import warnings
from pathlib import Path

import numpy as np

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

MODELS = {
    # name: (family, Hugging Face repo, note)
    "pe-av-large": ("pe", "facebook/pe-av-large", "Meta PE-AV large (Dec 2025), best quality, ~6 GB RAM"),
    "pe-av-base": ("pe", "facebook/pe-av-base", "Meta PE-AV base, for Macs with 8-16 GB RAM"),
    "pe-av-small": ("pe", "facebook/pe-av-small", "Meta PE-AV small, quick tests"),
    "clap-general": ("clap", "laion/larger_clap_general", "LAION CLAP (general audio), top ESC-50 score in MAEB 2026"),
    "clap-fused": ("clap", "laion/clap-htsat-fused", "LAION CLAP fused, top clustering score in MAEB 2026"),
}
DEFAULT_MODEL = "pe-av-large"
SAMPLE_RATE = 48000  # both model families use 48 kHz
WINDOW_S = 10.0
MAX_WINDOWS = 6


def _quiet_transformers():
    from transformers.utils import logging as hf_logging

    hf_logging.set_verbosity_error()
    hf_logging.disable_progress_bar()
    logging.getLogger("transformers").setLevel(logging.ERROR)
    warnings.filterwarnings("ignore", category=UserWarning)
    warnings.filterwarnings("ignore", category=FutureWarning)


def _l2(x: np.ndarray) -> np.ndarray:
    n = np.linalg.norm(x, axis=-1, keepdims=True)
    return x / np.maximum(n, 1e-12)


class Embedder:
    def __init__(self, name: str = DEFAULT_MODEL, device: str = "auto", half: bool = False):
        import torch

        from .audio import pick_device

        if name not in MODELS:
            raise SystemExit(f"Unknown model '{name}'. Choose from: {', '.join(MODELS)}")
        _quiet_transformers()
        self.name = name
        self.family, self.repo, _ = MODELS[name]
        self.device = pick_device(device)
        self.dtype = torch.float16 if half and self.device != "cpu" else torch.float32
        self.torch = torch
        print(f"Loading {name} ({self.repo}) on {self.device}… (first run downloads the model)")
        if self.family == "pe":
            from transformers import PeAudioModel, PeAudioProcessor

            self.model = PeAudioModel.from_pretrained(self.repo, dtype=self.dtype)
            self.processor = PeAudioProcessor.from_pretrained(self.repo)
        else:
            from transformers import ClapModel, ClapProcessor

            self.model = ClapModel.from_pretrained(self.repo, dtype=self.dtype)
            self.processor = ClapProcessor.from_pretrained(self.repo)
        self.model = self.model.to(self.device).eval()

    # ------------------------------------------------------------ audio

    def _embed_windows(self, windows: list[np.ndarray]) -> np.ndarray:
        """One embedding per window. Windows are run one at a time so padding
        never changes the result."""
        torch = self.torch
        out = []
        with torch.inference_mode():
            for w in windows:
                if self.family == "pe":
                    fe = self.processor.feature_extractor([w], sampling_rate=SAMPLE_RATE, return_tensors="pt")
                    iv = fe["input_values"].to(self.device, self.dtype)
                    pm = fe.get("padding_mask")
                    pm = pm.to(self.device) if pm is not None else None
                    e = self.model.get_audio_embeds(iv, pm)
                else:
                    fe = self.processor.feature_extractor([w], sampling_rate=SAMPLE_RATE, return_tensors="pt")
                    fe = {k: (v.to(self.device, self.dtype) if v.is_floating_point() else v.to(self.device))
                          for k, v in fe.items()}
                    e = self.model.get_audio_features(**fe)
                    e = e if torch.is_tensor(e) else e.pooler_output
                out.append(e[0].float().cpu().numpy())
        return _l2(np.stack(out))

    def to_cpu(self, reason: Exception) -> None:
        print(f"\n{self.name}: the {self.device} device failed ({str(reason)[:120]}); continuing on CPU.")
        self.device = "cpu"
        self.dtype = self.torch.float32
        self.model = self.model.to("cpu", self.dtype)

    def _with_fallback(self, fn, *args):
        try:
            return fn(*args)
        except (RuntimeError, NotImplementedError) as e:
            if self.device == "cpu":
                raise
            self.to_cpu(e)
            return fn(*args)

    def embed_audio(self, windows: list[np.ndarray]) -> np.ndarray:
        """Single vector for a file from its windows (mean of normalized window vectors)."""
        return _l2(self._with_fallback(self._embed_windows, windows).mean(axis=0))

    # ------------------------------------------------------------ text

    def embed_text(self, texts: list[str], batch_size: int = 64) -> np.ndarray:
        return self._with_fallback(self._embed_text, texts, batch_size)

    def _embed_text(self, texts: list[str], batch_size: int = 64) -> np.ndarray:
        torch = self.torch
        out = []
        with torch.inference_mode():
            for i in range(0, len(texts), batch_size):
                chunk = texts[i:i + batch_size]
                tok = self.processor.tokenizer(chunk, return_tensors="pt", padding=True, truncation=True)
                tok = {k: v.to(self.device) for k, v in tok.items()}
                if self.family == "pe":
                    # Called directly: transformers 5.20's get_text_audio_embeds forgets
                    # to request hidden states.
                    res = self.model.text_model(input_ids=tok["input_ids"], attention_mask=tok.get("attention_mask"),
                                                output_hidden_states=True, return_dict=True)
                    e = self.model.text_audio_head(res.hidden_states[-1][:, 0])
                else:
                    e = self.model.get_text_features(**tok)
                    e = e if torch.is_tensor(e) else e.pooler_output
                out.append(e.float().cpu().numpy())
        return _l2(np.concatenate(out))

    def embed_labels(self, prompts_per_label: list[list[str]]) -> np.ndarray:
        """Prompt ensembling: average several phrasings per label."""
        flat = [p for ps in prompts_per_label for p in ps]
        vecs = self.embed_text(flat)
        out, i = [], 0
        for ps in prompts_per_label:
            out.append(vecs[i:i + len(ps)].mean(axis=0))
            i += len(ps)
        return _l2(np.stack(out))


# ---------------------------------------------------------------- cache

class Cache:
    """Per-model cache of analysis results keyed by file path + size + mtime.
    Lives in the output root (default ~/SoundLab/cache), never in the library."""

    def __init__(self, root: Path, model_name: str):
        self.path = Path(root) / "cache" / f"{model_name}.pkl"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.data: dict = {}
        if self.path.exists():
            try:
                with open(self.path, "rb") as f:
                    self.data = pickle.load(f)
            except Exception:  # noqa: BLE001 - a broken cache is just rebuilt
                self.data = {}
        self._dirty = 0

    @staticmethod
    def emb_key(path: Path, signature: str) -> str:
        return f"emb|{Path(path).resolve()}|{signature}|w{WINDOW_S}x{MAX_WINDOWS}"

    @staticmethod
    def feat_key(path: Path, signature: str) -> str:
        from .features import FEATURES_VERSION

        return f"feat{FEATURES_VERSION}|{Path(path).resolve()}|{signature}"

    def get(self, key: str):
        return self.data.get(key)

    def put(self, key: str, value) -> None:
        self.data[key] = value
        self._dirty += 1
        if self._dirty >= 100:
            self.save()

    def save(self) -> None:
        if not self._dirty:
            return
        tmp = self.path.with_suffix(".tmp")
        with open(tmp, "wb") as f:
            pickle.dump(self.data, f, protocol=pickle.HIGHEST_PROTOCOL)
        os.replace(tmp, self.path)
        self._dirty = 0
