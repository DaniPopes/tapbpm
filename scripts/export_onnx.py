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
at 22050 Hz in, beat logits per model at 50 frames per second out. Weights are stored in float16
and cast back to float32 when ONNX Runtime loads the model, which halves the download. The script
checks the ONNX model against PyTorch with ONNX Runtime.

    uv run scripts/export_onnx.py
"""

from pathlib import Path

import numpy as np
import onnx
import onnxruntime
import torch
from beat_this.inference import load_model
from onnx import helper, numpy_helper

from convert_beat_this import CHECKPOINTS, SAMPLE_RATE, SAMPLES, BeatTracker, LogMel, click_track

OUTPUT = Path(__file__).resolve().parent.parent / "web" / "models" / "beat_this.onnx"


def store_weights_in_float16(model):
    """Replaces the weights of the models' matrix products and convolutions with float16 copies
    followed by a Cast to float32. The log-mel front-end (module 0) keeps float32: the small models
    find different beats when its spectrogram is rounded."""
    graph = model.graph
    weights = {name for node in graph.node if node.op_type in ("MatMul", "Gemm", "Conv") for name in node.input}
    weights = {name for name in weights if not name.startswith("0.")}
    casts = []
    for initializer in list(graph.initializer):
        if initializer.data_type != onnx.TensorProto.FLOAT or initializer.name not in weights:
            continue
        half = numpy_helper.from_array(numpy_helper.to_array(initializer).astype(np.float16), initializer.name + "_fp16")
        graph.initializer.remove(initializer)
        graph.initializer.append(half)
        casts.append(helper.make_node("Cast", [half.name], [initializer.name], to=onnx.TensorProto.FLOAT))
    nodes = casts + list(graph.node)
    del graph.node[:]
    graph.node.extend(nodes)


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
    store_weights_in_float16(model)
    onnx.save(model, OUTPUT)
    session = onnxruntime.InferenceSession(OUTPUT, providers=["CPUExecutionProvider"])
    actual = session.run(["beat"], {"audio": audio.numpy()})[0]
    print("ONNX beat logit max abs error:", np.abs(actual - expected).max())
    print("saved", OUTPUT, f"{OUTPUT.stat().st_size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
