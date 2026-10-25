# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = [
#     "beat-this @ git+https://github.com/CPJKU/beat_this@b95c8ab0c58c2d9fcfd40508ae8dffbc05ac4f5c",
#     "coremltools==9.0",
#     "numpy",
#     "onnx==1.19.0",
#     "onnxruntime==1.23.0",
#     "torch==2.7.0",
#     "torchaudio==2.7.0",
# ]
# ///
"""Exports the three small Beat This! beat trackers to ONNX for the web app.

Uses the same log-mel front-end and model ensemble as `convert_beat_this.py`: 10 s of mono audio
at 22050 Hz in, beat logits per model at 50 frames per second out. To keep the download small,
the STFT basis is computed in the graph, shared constants are stored once, and the models' weights
are stored in float16; ONNX Runtime folds them back into float32 constants when it loads the
model. The script checks the ONNX model against PyTorch with ONNX Runtime.

    uv run scripts/export_onnx.py
"""

from pathlib import Path

import math

import numpy as np
import onnx
import onnxruntime
import torch
from beat_this.inference import load_model
from onnx import helper, numpy_helper

from convert_beat_this import CHECKPOINTS, HOP, N_FFT, SAMPLE_RATE, SAMPLES, BeatTracker, LogMel, click_track

OUTPUT = Path(__file__).resolve().parent.parent / "web" / "models" / "beat_this.onnx"


def prepend(graph, nodes):
    all_nodes = nodes + list(graph.node)
    del graph.node[:]
    graph.node.extend(all_nodes)


def compute_stft_basis_in_graph(model):
    """Replaces the stored (1026, 1, 1024) STFT basis with nodes that compute it, which ONNX Runtime
    folds back into a constant when it loads the model. Saves 4 MB."""
    graph = model.graph
    basis = next(i for i in graph.initializer if list(i.dims) == [2 * (N_FFT // 2 + 1), 1, N_FFT])
    graph.initializer.remove(basis)
    c = lambda name, value: graph.initializer.append(numpy_helper.from_array(np.array(value, dtype=np.float32), name))
    # Shaped so that broadcasting gives the (1026, 1, 1024) basis directly.
    c("stft_n", np.arange(N_FFT)[None, None])
    c("stft_k", np.arange(N_FFT // 2 + 1)[:, None, None])
    c("stft_step", 2 * math.pi / N_FFT)
    c("stft_half", 0.5)
    c("stft_norm", 1 / math.sqrt(N_FFT))
    nodes = [
        helper.make_node("Mul", ["stft_k", "stft_n"], ["stft_kn"]),
        helper.make_node("Mul", ["stft_kn", "stft_step"], ["stft_angle"]),
        helper.make_node("Cos", ["stft_angle"], ["stft_cos"]),
        helper.make_node("Sin", ["stft_angle"], ["stft_sin"]),
        helper.make_node("Neg", ["stft_sin"], ["stft_negsin"]),
        helper.make_node("Concat", ["stft_cos", "stft_negsin"], ["stft_dft"], axis=0),
        # A periodic Hann window, divided by sqrt(n_fft) as normalized="frame_length" does.
        helper.make_node("Mul", ["stft_n", "stft_step"], ["stft_phase"]),
        helper.make_node("Cos", ["stft_phase"], ["stft_wcos"]),
        helper.make_node("Mul", ["stft_wcos", "stft_half"], ["stft_whalf"]),
        helper.make_node("Sub", ["stft_half", "stft_whalf"], ["stft_hann"]),
        helper.make_node("Mul", ["stft_hann", "stft_norm"], ["stft_window"]),
        helper.make_node("Mul", ["stft_dft", "stft_window"], [basis.name]),
    ]
    prepend(graph, nodes)


def deduplicate_constants(model):
    """Keeps one copy of identical Constant tensors. Every attention layer of every model gets its
    own copy of the same rotary position tables, 54 copies in all."""
    graph = model.graph
    first = {}
    renames = {}
    kept = []
    for node in graph.node:
        if node.op_type == "Constant" and node.attribute[0].name == "value":
            tensor = node.attribute[0].t
            key = tensor.SerializeToString()
            if key in first:
                renames[node.output[0]] = first[key]
                continue
            first[key] = node.output[0]
        kept.append(node)
    for node in kept:
        for i, name in enumerate(node.input):
            node.input[i] = renames.get(name, name)
    del graph.node[:]
    graph.node.extend(kept)


def store_weights_in_float16(model):
    """Stores the weights of the models' matrix products and convolutions in float16, cast back to
    float32 when ONNX Runtime loads the model. The log-mel front-end (module 0) keeps float32: the
    small models find different beats when its spectrogram is rounded. Int8 weights also changed
    their beats."""
    graph = model.graph
    weights = {node.input[1] for node in graph.node if node.op_type in ("MatMul", "Gemm", "Conv")}
    weights = {name for name in weights if not name.startswith("0.")}
    casts = []
    for initializer in list(graph.initializer):
        if initializer.data_type != onnx.TensorProto.FLOAT or initializer.name not in weights:
            continue
        half = numpy_helper.from_array(numpy_helper.to_array(initializer).astype(np.float16), initializer.name + "_fp16")
        graph.initializer.remove(initializer)
        graph.initializer.append(half)
        casts.append(helper.make_node("Cast", [half.name], [initializer.name], to=onnx.TensorProto.FLOAT))
    prepend(graph, casts)


def main():
    pipeline = torch.nn.Sequential(LogMel(), BeatTracker([load_model(name, device="cpu") for name in CHECKPOINTS]))
    pipeline.eval()
    audio = torch.from_numpy(click_track(120, SAMPLES / SAMPLE_RATE + 1)[:SAMPLES])[None]
    with torch.no_grad():
        expected = pipeline(audio).numpy()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    torch.onnx.export(
        pipeline, (audio,), OUTPUT, input_names=["audio"], output_names=["beat"], opset_version=17, dynamo=False
    )
    model = onnx.load(OUTPUT)
    compute_stft_basis_in_graph(model)
    deduplicate_constants(model)
    store_weights_in_float16(model)
    onnx.save(model, OUTPUT)
    session = onnxruntime.InferenceSession(OUTPUT, providers=["CPUExecutionProvider"])
    actual = session.run(["beat"], {"audio": audio.numpy()})[0]
    print("ONNX beat logit max abs error:", np.abs(actual - expected).max())
    # Logits above 0 that are the maximum within ±3 frames, as the app picks beats.
    pooled = lambda x: np.array([x[max(0, i - 3) : i + 4].max() for i in range(len(x))])
    peaks = lambda x: list(np.flatnonzero((x > 0) & (x == pooled(x))))
    for i, name in enumerate(CHECKPOINTS):
        print(f"{name} beats match PyTorch:", peaks(actual[0, i]) == peaks(expected[0, i]))
    print("saved", OUTPUT, f"{OUTPUT.stat().st_size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
