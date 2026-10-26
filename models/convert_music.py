"""Convert the two music models Phase 0 used to Core ML: Beat This! (tempo, beats,
downbeats) and S-KEY (key).

BeatThis.mlpackage (Beat This! "final0", CPJKU, MIT: the checkpoint Phase 0 ran;
the other two seeds were never downloadable)
  Input:  "spect"    float32 (1, 1500, 128): one 30 s chunk of Beat This!'s log-mel
          spectrogram (22.05 kHz, 50 frames/s). The app makes the spectrogram and
          the chunks itself (EarmarkCore, as beat_this.inference.split_piece).
  Output: "beat", "downbeat" float32 (1, 1500): logits per frame.

SKey.mlpackage (S-KEY, Deezer, MIT)
  Input:  "audio"    float32 (1, N): the whole song, mono 22.05 kHz, peak-normalised.
  Output: "probs"    float32 (1, 24): key probabilities in S-KEY's order (key_map).
  The constant-Q front end (nnAudio VQT: convolutions) is part of the model.

    .venv/bin/python -I convert_music.py            # writes build/BeatThis.mlpackage, build/SKey.mlpackage
    .venv/bin/python -I convert_music.py --fp16     # half precision variants (for comparison)
"""

from __future__ import annotations

import argparse
import contextlib
import io
import sys
from pathlib import Path

import numpy as np
import torch

OUT = Path(__file__).resolve().parent / "build"
CHUNK = 1500
MELS = 128
SR = 22050
MAX_SECONDS = 20 * 60


def load_beat_this():
    """Phase 0's loader (soundlab.music._load_beat_model): the official final0 checkpoint."""
    import inspect

    from beat_this.inference import load_checkpoint
    from beat_this.model.beat_tracker import BeatThis

    allowed = set(inspect.signature(BeatThis).parameters)
    ckpt = load_checkpoint("final0", "cpu")
    hp = {k: v for k, v in ckpt["hyper_parameters"].items() if k in allowed}
    state = {k[len("model."):]: v for k, v in ckpt["state_dict"].items() if k.startswith("model.")}
    model = BeatThis(**hp)
    missing, unexpected = model.load_state_dict(state, strict=False)
    bad = [k for k in list(missing) + list(unexpected) if "rotary_embed" not in k]
    if bad:
        raise SystemExit(f"Beat This! weights don't match the model: {bad[:5]}")
    # The rotary position embedding caches its frequencies between calls: a trace would
    # then bake in the first call's length. Without the cache they follow the chunk length.
    # Its frequencies are an outer product written as an einsum Core ML can't convert:
    # the same product as a broadcast multiply (checked identical below).
    from rotary_embedding_torch import RotaryEmbedding

    original = RotaryEmbedding.forward

    def forward(self, t, seq_len=None, offset=0):
        freqs = t.type(self.freqs.dtype)[..., None] * self.freqs
        return torch.stack([freqs, freqs], dim=-1).flatten(-2)   # repeat "... n -> ... (n r)", r = 2

    for m in model.modules():
        if isinstance(m, RotaryEmbedding):
            m.cache_if_possible = False
            probe = torch.arange(1500, dtype=torch.float32)
            with torch.no_grad():
                if not torch.equal(original(m, probe), forward(m, probe)):
                    raise SystemExit("rotary frequencies differ from the original")
    RotaryEmbedding.forward = forward

    # Core ML's fused attention wants a fixed head size, which it can't see through the
    # flexible chunk length: the same attention written out (eval mode, no dropout).
    from beat_this.model import roformer

    head_dim = hp.get("head_dim", 32)

    def attend(self, q, k, v):
        scale = head_dim ** -0.5 if self.scale is None else self.scale
        weights = torch.softmax(torch.matmul(q, k.transpose(-2, -1)) * scale, dim=-1)
        return torch.matmul(weights, v)

    probe = torch.rand(1, 600, hp.get("spect_dim", MELS)) * 4
    model.eval()
    with torch.no_grad():
        before = model(probe)["beat"]
        roformer.Attend.forward = attend
        after = model(probe)["beat"]
    if (before - after).abs().max() > 1e-3:
        raise SystemExit(f"written-out attention differs by {(before - after).abs().max():.2e}")
    return model


class BeatLogits(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, spect):
        out = self.model(spect)
        return out["beat"], out["downbeat"]


class TimeMean(torch.nn.Module):
    def forward(self, x):
        assert x.shape[2] == 12
        return x.mean(dim=-1, keepdim=True)


def load_skey():
    from skey.key_detection import load_checkpoint, load_model_components

    with contextlib.redirect_stdout(io.StringIO()):  # nnAudio prints setup chatter
        ckpt = load_checkpoint(None)
        hcqt, net, _ = load_model_components(ckpt, torch.device("cpu"))
    if int(ckpt["audio"]["sr"]) != SR:
        raise SystemExit(f"S-KEY expects {ckpt['audio']['sr']} Hz, not {SR}")
    # Its blocks normalise with layer_norm(x, x.shape[1:]): over everything but the batch,
    # a shape Core ML can't take when the song's length varies. The same, written out
    # (checked below against the original).
    probe = hcqt(torch.randn(1, 1, SR * 20) * 0.1)[:, :, :84, :]
    net.eval()
    with torch.no_grad():
        before = net(probe)

        def norm(x, shape, eps=1e-5):
            mean = x.mean(dim=(1, 2, 3), keepdim=True)
            var = ((x - mean) ** 2).mean(dim=(1, 2, 3), keepdim=True)
            return (x - mean) / torch.sqrt(var + eps)

        for m in net.modules():
            if hasattr(m, "norm") and m.norm is torch.nn.functional.layer_norm:
                m.norm = norm
        # Its last pooling is adaptive to (12, 1), which Core ML can't do over a varying
        # length. The octave pool before it leaves 12 rows already: a plain mean over time.
        net.global_average_pool = TimeMean()
        after = net(probe)
    if (before - after).abs().max() > 1e-5:
        raise SystemExit(f"written-out layer norm and pooling differ by {(before - after).abs().max():.2e}")
    return hcqt.eval(), net


class KeyProbs(torch.nn.Module):
    """S-KEY as Phase 0 runs it: net(crop(hcqt(x), 0)), the crop being the lowest 84 bins."""

    def __init__(self, hcqt, net):
        super().__init__()
        self.hcqt, self.net = hcqt, net

    def forward(self, audio):
        h = self.hcqt(audio[:, None, :])
        return self.net(h[:, :, :84, :])


def chords(seconds: int) -> np.ndarray:
    """I–IV–V–I in A minor, two seconds a chord, plucked tones with harmonics and a little noise."""
    rng = np.random.default_rng(0)
    t = np.arange(SR * 2) / SR
    out = []
    for bar in range(seconds // 2):
        root = [57, 62, 64, 57][bar % 4]
        notes = [root, root + (3 if root != 64 else 4), root + 7]
        tone = sum(np.sin(2 * np.pi * 440 * 2 ** ((n - 69) / 12) * h * t) / h
                   for n in notes for h in (1, 2, 3)) * np.exp(-t * 1.5)
        out.append(tone)
    x = np.concatenate(out) + rng.normal(0, 0.01, SR * (seconds // 2) * 2)
    return (x / np.abs(x).max()).astype(np.float32)


def convert(ct, traced, inputs, outputs, precision, name, description, version):
    ml = ct.convert(
        traced,
        inputs=inputs,
        outputs=outputs,
        convert_to="mlprogram",
        compute_precision=precision,
        minimum_deployment_target=ct.target.macOS14,
    )
    ml.short_description = description
    ml.author = "CPJKU / Deezer (models); converted for Earmark"
    ml.license = "MIT"
    ml.version = version
    OUT.mkdir(exist_ok=True)
    path = OUT / name
    ml.save(str(path))
    return ml, path


def main():
    import coremltools as ct

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from convert_clap import patch_coremltools

    patch_coremltools()
    ap = argparse.ArgumentParser()
    ap.add_argument("--fp16", action="store_true", help="half precision weights and compute")
    args = ap.parse_args()
    precision = ct.precision.FLOAT16 if args.fp16 else ct.precision.FLOAT32
    suffix = "-fp16" if args.fp16 else ""

    # Beat This!: one 1500-frame chunk at a time. A flexible length converted but Core ML
    # couldn't plan it; songs under 30 s (none in the owner's library) are padded with silence.
    beat = BeatLogits(load_beat_this()).eval()
    example = torch.rand(1, CHUNK, MELS) * 4
    # References first: converting changes the PyTorch module's tensors in place
    # (S-KEY's output moved by 0.05 afterwards, while Core ML matched the original to 1e-6).
    x = torch.rand(1, CHUNK, MELS) * 4
    with torch.no_grad():
        ref_b, ref_d = (t.numpy() for t in beat(x))
        traced = torch.jit.trace(beat, example, check_trace=False)
    ml, path = convert(
        ct, traced,
        [ct.TensorType(name="spect", shape=(1, CHUNK, MELS), dtype=np.float32)],
        [ct.TensorType(name="beat", dtype=np.float32), ct.TensorType(name="downbeat", dtype=np.float32)],
        precision, f"BeatThis{suffix}.mlpackage",
        "Beat This! (final0): beat and downbeat logits for a chunk of log-mel frames (50 fps). MIT.",
        "beat_this 1.1.0 final0")
    got = ml.predict({"spect": x.numpy()})
    print(f"{path.name}: max |Δ| beat {np.abs(got['beat'] - ref_b).max():.5f}, "
          f"downbeat {np.abs(got['downbeat'] - ref_d).max():.5f}")

    # S-KEY: the whole song in one go (its network averages over time).
    hcqt, net = load_skey()
    key = KeyProbs(hcqt, net).eval()
    example = torch.randn(1, SR * 30) * 0.1
    # A test signal with harmony in it (on plain noise the 24 probabilities are close to a tie).
    tests = {seconds: chords(seconds) for seconds in (30, 200)}
    with torch.no_grad():
        refs = {seconds: key(torch.from_numpy(x)[None]).numpy() for seconds, x in tests.items()}
        traced = torch.jit.trace(key, example, check_trace=False)
    ml, path = convert(
        ct, traced,
        [ct.TensorType(name="audio", shape=(1, ct.RangeDim(lower_bound=SR * 2, upper_bound=SR * MAX_SECONDS,
                                                             default=SR * 30)), dtype=np.float32)],
        [ct.TensorType(name="probs", dtype=np.float32)],
        precision, f"SKey{suffix}.mlpackage",
        "S-KEY: probabilities of the 24 keys for a whole song (mono 22.05 kHz, peak-normalised). MIT.",
        "skey 918b83d")
    for seconds, x in tests.items():
        ref = refs[seconds]
        got = ml.predict({"audio": x[None]})["probs"]
        print(f"{path.name}, {seconds} s: max |Δ| {np.abs(got - ref).max():.5f}, "
              f"argmax {int(ref.argmax())} → {int(got.argmax())}")


if __name__ == "__main__":
    main()
