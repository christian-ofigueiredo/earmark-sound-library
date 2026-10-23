"""Convert LAION CLAP (larger_clap_general, the Phase 0 model) audio tower to Core ML.

Input:  "melspec"   float32 (1, 1, 1001, 64): the log-mel spectrogram of one ≤10 s
        window at 48 kHz, exactly as ClapFeatureExtractor makes it (repeat-padded
        to 10 s, Slaney mel, dB). The app computes this itself (EarmarkCore).
Output: "embedding" float32 (1, 512), L2-normalised, as in Phase 0.

    .venv/bin/python convert_clap.py            # writes build/CLAPAudio.mlpackage
    .venv/bin/python convert_clap.py --fp16     # half precision variant

The model's only op Core ML can't convert is a bicubic resize of the time axis
(1001 → 1024 frames). The frequency axis isn't resized, so the resize is a fixed
linear map; it is baked in as a 1024×1001 matrix multiply (checked to match).
"""

from __future__ import annotations

import argparse
import types
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

REPO = "laion/larger_clap_general"
FRAMES, MELS = 1001, 64
OUT = Path(__file__).resolve().parent / "build"


def bicubic_time_matrix(n_in: int, n_out: int) -> torch.Tensor:
    """W such that W @ x equals interpolate(x, (n_out, f), bicubic, align_corners) along time."""
    eye = torch.eye(n_in, dtype=torch.float64)[None, None]          # (1, 1, n_in, n_in): time × "freq"
    return F.interpolate(eye, (n_out, n_in), mode="bicubic", align_corners=True)[0, 0]


def load_model():
    from transformers import ClapModel

    model = ClapModel.from_pretrained(REPO).eval()
    enc = model.audio_model.audio_encoder
    if enc.enable_fusion:
        raise SystemExit("expected the non-fusion model")
    spec_width = int(enc.spec_size * enc.freq_ratio)
    W = bicubic_time_matrix(FRAMES, spec_width).float()

    def reshape_mel2img(self, x):
        # Same as transformers' version for (B, 1, 1001, 64) input, with the bicubic
        # time resize as a matmul.
        x = torch.matmul(W, x)
        batch, channels, time, freq = x.shape
        x = x.reshape(batch, channels * self.freq_ratio, time // self.freq_ratio, freq)
        x = x.permute(0, 1, 3, 2).contiguous()
        return x.reshape(batch, channels, freq * self.freq_ratio, time // self.freq_ratio)

    # Checked in double precision: there the matrix is exact (PyTorch's float32
    # bicubic itself is off by ~3e-4, the matmul by ~5e-7).
    probe = torch.randn(2, 1, FRAMES, MELS, dtype=torch.float64)
    W64 = bicubic_time_matrix(FRAMES, spec_width)
    with torch.no_grad():
        diff = (F.interpolate(probe, (spec_width, MELS), mode="bicubic", align_corners=True)
                - torch.matmul(W64, probe)).abs().max().item()
    if diff > 1e-9:
        raise SystemExit(f"matrix resize differs from bicubic by {diff}")
    enc.reshape_mel2img = types.MethodType(reshape_mel2img, enc)
    return model


class AudioEmbedder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, melspec):
        out = self.model.get_audio_features(input_features=melspec)
        e = out if torch.is_tensor(out) else out.pooler_output
        return F.normalize(e, dim=-1)


def patch_coremltools():
    """coremltools 9 casts constant 1-element arrays with int(x) / bool(x), which
    NumPy 2 rejects ("only 0-dimensional arrays…"). Take the single element first."""
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.frontend.torch import ops
    from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op

    def cast(context, node, dtype, dtype_name):
        x = ops._get_inputs(context, node, expected=1)[0]
        if x.can_be_folded_to_const() and np.size(x.val) == 1 and not isinstance(x.val, dtype):
            context.add(mb.const(val=dtype(np.asarray(x.val).reshape(-1)[0]), name=node.name), node.name)
        else:
            ops._cast(context, node, dtype, dtype_name)

    @register_torch_op(torch_alias=["int"], override=True)
    def _int(context, node):
        cast(context, node, int, "int32")

    @register_torch_op(torch_alias=["bool"], override=True)
    def _bool(context, node):
        cast(context, node, bool, "bool")


def main():
    import coremltools as ct

    patch_coremltools()

    ap = argparse.ArgumentParser()
    ap.add_argument("--fp16", action="store_true", help="half precision weights and compute")
    args = ap.parse_args()

    model = load_model()
    wrapper = AudioEmbedder(model).eval()
    example = torch.randn(1, 1, FRAMES, MELS) * 20 - 50
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example)
    precision = ct.precision.FLOAT16 if args.fp16 else ct.precision.FLOAT32
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="melspec", shape=(1, 1, FRAMES, MELS), dtype=np.float32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=precision,
        minimum_deployment_target=ct.target.macOS14,
    )
    ml.short_description = "LAION CLAP (larger_clap_general) audio embedding, L2-normalised. Apache-2.0."
    ml.author = "LAION (model); converted for Earmark"
    ml.license = "Apache-2.0"
    ml.version = "larger_clap_general"
    OUT.mkdir(exist_ok=True)
    path = OUT / ("CLAPAudio-fp16.mlpackage" if args.fp16 else "CLAPAudio.mlpackage")
    ml.save(str(path))

    with torch.no_grad():
        ref = wrapper(example).numpy()
    got = ml.predict({"melspec": example.numpy()})["embedding"]
    print(f"saved {path}; cosine to PyTorch on the trace input: {float((ref * got).sum()):.6f}")


if __name__ == "__main__":
    main()
