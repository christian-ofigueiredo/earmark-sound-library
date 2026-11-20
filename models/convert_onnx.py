"""Convert the four models to ONNX for Windows, from the same PyTorch modules as the Core ML
conversions (convert_clap.py, convert_peav.py, convert_music.py), so the same rewrites apply.
Inputs and outputs have the same names and shapes as the Core ML models.

    .venv/bin/python -I convert_onnx.py clap            # build/onnx/CLAPAudio.onnx
    .venv/bin/python -I convert_onnx.py music           # build/onnx/BeatThis.onnx, SKey.onnx
    .venv/bin/python -I convert_onnx.py peav [--only PEAVLayers2]   # build/onnx/PEAV/*.onnx, 5 parts

Each file is checked against PyTorch with ONNX Runtime on the CPU before it's kept.
"""

from __future__ import annotations

import argparse
import gc
import os
import sys
from pathlib import Path

import numpy as np
import torch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

OUT = HERE / "build" / "onnx"
OPSET = 18


def export(module, example, path: Path, inputs, outputs, dynamic=None):
    """Writes one model in a single file (every part is under protobuf's 2 GB)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp.onnx")
    with torch.no_grad():
        torch.onnx.export(module, example, str(temporary), input_names=inputs, output_names=outputs,
                          dynamic_axes=dynamic, opset_version=OPSET, dynamo=False, do_constant_folding=True)
    return temporary


def session(path: Path):
    import onnxruntime as ort

    options = ort.SessionOptions()
    options.intra_op_num_threads = max(1, (os.cpu_count() or 4) // 2)
    return ort.InferenceSession(str(path), options, providers=["CPUExecutionProvider"])


def check(temporary: Path, path: Path, cases, limit: float):
    """`cases`: (inputs, expected outputs, label). Keeps the file only if they match."""
    s = session(temporary)
    worst = 0.0
    for inputs, expected, label in cases:
        got = s.run(None, inputs)
        difference = max(float(np.abs(a - b).max()) for a, b in zip(got, expected))
        worst = max(worst, difference)
        print(f"  {path.name} {label}: max |Δ| {difference:.2e}", flush=True)
    del s
    if worst > limit:
        temporary.unlink()
        raise SystemExit(f"{path.name} differs from PyTorch by {worst:.2e}")
    temporary.replace(path)
    print(f"{path}: {path.stat().st_size / 1e6:.0f} MB", flush=True)


def clap():
    from convert_clap import FRAMES, MELS, AudioEmbedder, load_model

    module = AudioEmbedder(load_model()).eval()
    torch.manual_seed(0)
    example = torch.randn(1, 1, FRAMES, MELS) * 20 - 50
    path = OUT / "CLAPAudio.onnx"
    probes = [torch.randn(1, 1, FRAMES, MELS) * 20 - 50 for _ in range(3)]
    with torch.no_grad():
        cases = [({"melspec": p.numpy()}, [module(p).numpy()], f"probe {i}") for i, p in enumerate(probes)]
    check(export(module, (example,), path, ["melspec"], ["embedding"]), path, cases, 1e-4)


def music():
    from convert_music import CHUNK, MELS, SR, BeatLogits, KeyProbs, chords, load_beat_this, load_skey

    torch.manual_seed(0)
    beat = BeatLogits(load_beat_this()).eval()
    path = OUT / "BeatThis.onnx"
    example, probe = torch.rand(1, CHUNK, MELS) * 4, torch.rand(1, CHUNK, MELS) * 4
    with torch.no_grad():
        cases = [({"spect": probe.numpy()}, [t.numpy() for t in beat(probe)], "probe")]
    check(export(beat, (example,), path, ["spect"], ["beat", "downbeat"]), path, cases, 1e-3)

    hcqt, net = load_skey()
    key = KeyProbs(hcqt, net).eval()
    path = OUT / "SKey.onnx"
    tests = {seconds: chords(seconds) for seconds in (10, 30, 200)}
    with torch.no_grad():
        cases = [({"audio": x[None]}, [key(torch.from_numpy(x)[None]).numpy()], f"{seconds} s") for seconds, x in tests.items()]
    example = torch.randn(1, SR * 30) * 0.1
    check(export(key, (example,), path, ["audio"], ["probs"], {"audio": {1: "samples"}, }), path, cases, 1e-4)


def peav(only):
    import convert_peav as cp
    import transformers.models.pe_audio.modeling_pe_audio as pe

    encoder, head = cp.load_audio_tower()
    parts = cp.build_parts(encoder, head)
    pe.apply_rotary_pos_emb = cp.rotate_pairs
    torch.manual_seed(0)
    # Three lengths, so a part that fixed its length in the export shows up.
    lengths = {"short": 1, "medium": 30, "full": 250}
    hidden = {k: torch.randn(1, 1, n * cp.HOP) * 0.1 for k, n in lengths.items()}
    for index, (name, module) in enumerate(parts):
        first, last = index == 0, index == len(parts) - 1
        input_name, output_name = "input_values" if first else "hidden", "embedding" if last else "hidden_out"
        path = OUT / "PEAV" / f"{name}.onnx"
        with torch.no_grad():
            outputs = {k: module(x) for k, x in hidden.items()}
        if (only and name != only) or (not only and path.exists()):
            hidden = outputs
            continue
        cases = [({input_name: hidden[k].numpy()}, [outputs[k].numpy()], k) for k in lengths]
        dynamic = {input_name: {2 if first else 1: "length"}}
        if not last:
            dynamic[output_name] = {1: "tokens"}
        temporary = export(module.eval(), (hidden["medium"],), path, [input_name], [output_name], dynamic)
        check(temporary, path, cases, 1e-2)
        hidden = outputs
        gc.collect()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model", choices=["clap", "music", "peav"])
    ap.add_argument("--only")
    args = ap.parse_args()
    {"clap": clap, "music": music}.get(args.model, lambda: peav(args.only))()


if __name__ == "__main__":
    main()
