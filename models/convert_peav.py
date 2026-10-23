"""Convert Meta PE-AV large's audio tower (the Phase 0 model) to Core ML, in parts.

The audio tower has 1.13 B parameters (4.5 GB in float32), too much to convert in
one go on a 16 GB Mac, so it's split into five models run one after another:

    PEAVEmbed      input_values (1, 1, N)  → hidden (1, N/1920 + 1, 1792)
                   DAC codec encoder, projection, class token + ResNet block
    PEAVLayers0    hidden → hidden          transformer layers 0–6
    PEAVLayers1    hidden → hidden          layers 7–13
    PEAVLayers2    hidden → hidden          layers 14–20
    PEAVLayers3    hidden → embedding (1, 1024), L2-normalised
                   layers 21–27, final norm, output, class token → audio head

N is the window length in samples at 48 kHz, a multiple of 1920 (≤ 480000 = 10 s);
the app reflect-pads to that multiple as PeAudioFeatureExtractor does. Lengths
are flexible, so short sounds are embedded at their own length, as in Phase 0.

    .venv/bin/python -I convert_peav.py            # build/PEAV/*.mlpackage, float32
    .venv/bin/python -I convert_peav.py --fp16     # build/PEAV-fp16/*.mlpackage

Only the audio weights are read from the checkpoint (no text or video tower).
"""

from __future__ import annotations

import argparse
import gc
import json
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from convert_clap import patch_coremltools  # noqa: E402

REPO = "facebook/pe-av-large"
HOP = 1920
MAX_SAMPLES = 480_000
PARTS = 4                     # transformer layer groups
OUT = HERE / "build"


def snapshot() -> Path:
    from huggingface_hub import snapshot_download

    return Path(snapshot_download(REPO, allow_patterns=["config.json", "model.safetensors"]))


def load_audio_tower():
    """PeAudioEncoder + audio head with only their weights loaded."""
    from safetensors import safe_open
    from transformers.models.pe_audio.configuration_pe_audio import PeAudioConfig
    from transformers.models.pe_audio.modeling_pe_audio import (
        PeAudioContrastiveHead,
        PeAudioEncoder,
        PeAudioEncoderRotaryEmbedding,
    )

    path = snapshot()
    # The same configuration Phase 0's PeAudioModel.from_pretrained used.
    config = PeAudioConfig.from_pretrained(REPO)
    audio_config, text_hidden = config.audio_config, config.text_config.hidden_size
    with torch.device("meta"):
        encoder = PeAudioEncoder(audio_config)
        head = PeAudioContrastiveHead(audio_config.hidden_size, text_hidden)
    state_enc, state_head = {}, {}
    with safe_open(str(path / "model.safetensors"), "pt") as f:
        for k in f.keys():
            if k.startswith("audio_model.audio_encoder."):
                state_enc[k[len("audio_model.audio_encoder."):]] = f.get_tensor(k)
            elif k.startswith("audio_model.audio_head."):
                state_head[k[len("audio_model.audio_head."):]] = f.get_tensor(k)
    missing = encoder.load_state_dict(state_enc, strict=False, assign=True)
    head.load_state_dict(state_head, strict=True, assign=True)
    # RoPE frequencies aren't in the checkpoint: rebuild that module on the CPU.
    encoder.rotary_emb = PeAudioEncoderRotaryEmbedding(audio_config)
    leftover = [k for k in missing.missing_keys if "inv_freq" not in k]
    meta = [n for n, t in list(encoder.named_parameters()) + list(encoder.named_buffers()) if t.is_meta]
    if meta:
        raise SystemExit(f"still on the meta device: {meta[:5]}")
    if leftover or missing.unexpected_keys:
        raise SystemExit(f"weights don't match: missing {leftover[:5]}, unexpected {missing.unexpected_keys[:5]}")
    return encoder.eval(), head.eval()


def rotate_pairs(q, k, cos, sin, unsqueeze_dim=1):
    """PE-AV's apply_rotary_pos_emb without its 2×2 matrices (whose `narrow` on a
    flexible length Core ML can't convert): each (x0, x1) pair is rotated by its
    angle. Takes the full-size cos/sin (as the original) or the half-size ones."""
    half = q.shape[-1] // 2
    if cos.shape[-1] != half:
        cos, sin = cos[..., :half], sin[..., :half]
    c, s = cos.unsqueeze(unsqueeze_dim), sin.unsqueeze(unsqueeze_dim)

    def rotate(x):
        pairs = x.unflatten(-1, (half, 2))
        x0, x1 = pairs[..., 0], pairs[..., 1]
        return torch.stack((x0 * c - x1 * s, x0 * s + x1 * c), dim=-1).flatten(-2)

    return rotate(q), rotate(k)


class Embed(torch.nn.Module):
    def __init__(self, encoder):
        super().__init__()
        self.embedder = encoder.embedder
        self.patch_embedder = encoder.patch_embedder

    def forward(self, input_values):
        x, _ = self.embedder(input_values)
        x, _ = self.patch_embedder(x)
        return x


class Layers(torch.nn.Module):
    def __init__(self, encoder, start, end, head=None):
        super().__init__()
        self.layers = torch.nn.ModuleList(encoder.layers[start:end])
        self.rotary_emb = encoder.rotary_emb
        self.final = head is not None
        if self.final:
            self.norm, self.output, self.head = encoder.norm, encoder.output, head

    def forward(self, hidden):
        # RoPE angles for each position (half the head size; see rotate_pairs()).
        positions = torch.arange(hidden.shape[1], dtype=torch.float32).unsqueeze(0)
        freqs = positions[..., None] * self.rotary_emb.inv_freq
        position_embeddings = (freqs.cos(), freqs.sin())
        for layer in self.layers:
            hidden = layer(hidden, attention_mask=None, position_embeddings=position_embeddings)
        if not self.final:
            return hidden
        hidden = self.output(self.norm(hidden))
        return F.normalize(self.head(hidden[:, 0]), dim=-1)


class Whole(torch.nn.Module):
    """Reference: the parts chained in PyTorch (checked against get_audio_embeds)."""

    def __init__(self, parts):
        super().__init__()
        self.parts = torch.nn.ModuleList(parts)

    def forward(self, x):
        for p in self.parts:
            x = p(x)
        return x


def build_parts(encoder, head):
    n = len(encoder.layers)
    step = n // PARTS
    parts = [("PEAVEmbed", Embed(encoder))]
    for i in range(PARTS):
        last = i == PARTS - 1
        parts.append((f"PEAVLayers{i}", Layers(encoder, i * step, n if last else (i + 1) * step, head if last else None)))
    return parts


def main():
    import coremltools as ct

    ap = argparse.ArgumentParser()
    ap.add_argument("--fp16", action="store_true")
    ap.add_argument("--only", help="convert just this part (e.g. PEAVLayers2)")
    args = ap.parse_args()
    patch_coremltools()

    encoder, head = load_audio_tower()
    parts = build_parts(encoder, head)
    out = OUT / ("PEAV-fp16" if args.fp16 else "PEAV")
    out.mkdir(parents=True, exist_ok=True)
    precision = ct.precision.FLOAT16 if args.fp16 else ct.precision.FLOAT32

    torch.manual_seed(0)
    example = torch.randn(1, 1, 30 * HOP) * 0.1
    # The parts chained, with RoPE rewritten, must equal the original encoder + head
    # (what get_audio_embeds does), computed before anything is patched.
    with torch.no_grad():
        official = F.normalize(head(encoder(input_values=example).pooler_output), dim=-1)
    import transformers.models.pe_audio.modeling_pe_audio as pe
    pe.apply_rotary_pos_emb = rotate_pairs
    with torch.no_grad():
        chained = Whole([m for _, m in parts])(example)
    diff = float((official - chained).abs().max())
    print(f"parts chained vs the original encoder: max difference {diff:.2e}", flush=True)
    if diff > 1e-5:
        raise SystemExit("the split doesn't reproduce the model")

    samples = ct.RangeDim(lower_bound=HOP, upper_bound=MAX_SAMPLES, default=30 * HOP)
    tokens = ct.RangeDim(lower_bound=2, upper_bound=MAX_SAMPLES // HOP + 1, default=31)
    hidden = example
    for index, (name, module) in enumerate(parts):
        first, last = index == 0, index == len(parts) - 1
        x = hidden
        with torch.no_grad():
            y = module(x)
        if args.only and name != args.only:
            hidden = y
            continue
        with torch.no_grad():
            traced = torch.jit.trace(module.eval(), x)
        ml = ct.convert(
            traced,
            inputs=[ct.TensorType(name="input_values" if first else "hidden",
                                  shape=(1, 1, samples) if first else (1, tokens, 1792), dtype=np.float32)],
            outputs=[ct.TensorType(name="embedding" if last else "hidden_out", dtype=np.float32)],
            convert_to="mlprogram",
            compute_precision=precision,
            minimum_deployment_target=ct.target.macOS14,
        )
        ml.short_description = f"Meta PE-AV large audio tower, part {index + 1} of {len(parts)} ({name}). Apache-2.0."
        ml.license = "Apache-2.0"
        ml.save(str(out / f"{name}.mlpackage"))
        got = ml.predict({("input_values" if first else "hidden"): x.numpy()})["embedding" if last else "hidden_out"]
        ref = y.numpy()
        rel = float(np.abs(got - ref).max() / (np.abs(ref).max() + 1e-12))
        print(f"{name}: saved; max relative difference to PyTorch {rel:.2e}", flush=True)
        hidden = y
        del ml, traced
        gc.collect()


if __name__ == "__main__":
    main()
