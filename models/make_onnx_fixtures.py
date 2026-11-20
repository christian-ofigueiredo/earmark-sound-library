"""Tiny ONNX models with the same inputs and outputs as the real ones, for the engine's tests
(engine/crates/earmark-models/tests/fixtures): simple sums, no weights, so CI can run the
runtime on every system without the real models.

    .venv/bin/python -I make_onnx_fixtures.py
"""

from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto as T
from onnx import helper as h
from onnx import numpy_helper

OUT = Path(__file__).resolve().parent.parent / "engine/crates/earmark-models/tests/fixtures"


def tensor(name, values, kind=np.int64):
    return numpy_helper.from_array(np.array(values, dtype=kind), name)


def save(name, nodes, inputs, outputs, constants=()):
    graph = h.make_graph(nodes, name, [h.make_tensor_value_info(n, T.FLOAT, s) for n, s in inputs],
                         [h.make_tensor_value_info(n, T.FLOAT, s) for n, s in outputs], list(constants))
    model = h.make_model(graph, opset_imports=[h.make_opsetid("", 18)], producer_name="earmark fixtures")
    model.ir_version = 9
    onnx.checker.check_model(model)
    path = OUT / f"{name}.onnx"
    path.parent.mkdir(parents=True, exist_ok=True)
    onnx.save(model, str(path))


def main():
    # CLAP: each mel band's mean, eight times over, normalised.
    save("CLAPAudio",
         [h.make_node("ReduceMean", ["melspec", "axes"], ["mean"], keepdims=0),
          h.make_node("Tile", ["mean", "repeats"], ["tiled"]),
          h.make_node("LpNormalization", ["tiled"], ["embedding"], axis=-1, p=2)],
         [("melspec", [1, 1, 1001, 64])], [("embedding", [1, 512])],
         [tensor("axes", [1, 2]), tensor("repeats", [1, 8])])
    # PE-AV: one token per 1920 samples, plus a class token of zeros.
    save("PEAV/PEAVEmbed",
         [h.make_node("AveragePool", ["input_values"], ["pooled"], kernel_shape=[1920], strides=[1920]),
          h.make_node("Transpose", ["pooled"], ["tokens"], perm=[0, 2, 1]),
          h.make_node("Tile", ["tokens", "repeats"], ["wide"]),
          h.make_node("Concat", ["class_token", "wide"], ["hidden_out"], axis=1)],
         [("input_values", [1, 1, "samples"])], [("hidden_out", [1, "tokens", 1792])],
         [tensor("repeats", [1, 1, 1792]), tensor("class_token", np.ones((1, 1, 1792)), np.float32)])
    for part in range(3):
        save(f"PEAV/PEAVLayers{part}",
             [h.make_node("Identity", ["hidden"], ["hidden_out"])],
             [("hidden", [1, "tokens", 1792])], [("hidden_out", [1, "tokens", 1792])])
    save("PEAV/PEAVLayers3",
         [h.make_node("ReduceMean", ["hidden", "axes"], ["mean"], keepdims=0),
          h.make_node("Slice", ["mean", "starts", "ends", "slice_axes"], ["cut"]),
          h.make_node("LpNormalization", ["cut"], ["embedding"], axis=-1, p=2)],
         [("hidden", [1, "tokens", 1792])], [("embedding", [1, 1024])],
         [tensor("axes", [1]), tensor("starts", [0]), tensor("ends", [1024]), tensor("slice_axes", [1])])
    # Beat This!: a frame's mean is its beat logit, and the opposite its downbeat logit.
    save("BeatThis",
         [h.make_node("ReduceMean", ["spect", "axes"], ["beat"], keepdims=0),
          h.make_node("Neg", ["beat"], ["downbeat"])],
         [("spect", [1, 1500, 128])], [("beat", [1, 1500]), ("downbeat", [1, 1500])],
         [tensor("axes", [2])])
    # S-KEY: always the same probabilities, the fourth label the likeliest.
    probabilities = np.full((1, 24), 0.02)
    probabilities[0, 3] = 0.54
    save("SKey",
         [h.make_node("ReduceMean", ["audio", "axes"], ["mean"], keepdims=1),
          h.make_node("Mul", ["mean", "zero"], ["nothing"]),
          h.make_node("Add", ["table", "nothing"], ["probs"])],
         [("audio", [1, "samples"])], [("probs", [1, 24])],
         [tensor("axes", [1]), tensor("zero", [0.0], np.float32), tensor("table", probabilities, np.float32)])


if __name__ == "__main__":
    main()
