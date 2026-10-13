# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = [
#     "beat-this @ git+https://github.com/CPJKU/beat_this@b95c8ab0c58c2d9fcfd40508ae8dffbc05ac4f5c",
#     "coremltools==9.0",
#     "numpy",
#     "torch==2.7.0",
#     "torchaudio==2.7.0",
# ]
# ///
"""Converts the three small Beat This! beat trackers to Core ML.

The small models estimate tempo better than the large one, and the median of their tempos better
still (https://github.com/CPJKU/beat_this/issues/13). The output is one Core ML pipeline of two
models:

- A log-mel front-end takes 10 s of raw audio and rebuilds `LogMelSpect` with a strided
  convolution, in float32: the small models find different beats when it runs in float16.
- The three models then run on its spectrogram in float16.

Two rewrites let the transformers compile for the Neural Engine. The app runs them on the GPU
anyway, which is six times faster on an M-series Mac, but they leave the output unchanged.

The script checks the front-end against `LogMelSpect` and the pipeline against PyTorch.

    uv run scripts/convert_beat_this.py
"""

import math
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import torch.nn.functional as F
import torchaudio
from beat_this.inference import load_model
from beat_this.model import roformer
from beat_this.preprocessing import LogMelSpect

SAMPLE_RATE = 22050
N_FFT = 1024
HOP = 441
CHECKPOINTS = ["small0", "small1", "small2"]
FRAMES = 500  # 10 s at 50 frames per second.
SAMPLES = (FRAMES - 1) * HOP + N_FFT
OUTPUT = Path(__file__).resolve().parent.parent / "TapBPM"


class LogMel(torch.nn.Module):
    """`LogMelSpect` without centre padding, with the STFT as a convolution."""

    def __init__(self):
        super().__init__()
        bins = N_FFT // 2 + 1
        angle = 2 * math.pi * torch.arange(bins)[:, None] * torch.arange(N_FFT)[None] / N_FFT
        # normalized="frame_length" divides by sqrt(n_fft).
        window = torch.hann_window(N_FFT) / math.sqrt(N_FFT)
        basis = torch.cat([torch.cos(angle), -torch.sin(angle)]) * window
        self.register_buffer("basis", basis[:, None, :])
        mel = torchaudio.functional.melscale_fbanks(
            bins, 30, 11000, 128, SAMPLE_RATE, norm=None, mel_scale="slaney"
        )
        self.register_buffer("mel", mel)

    def forward(self, audio):
        frames = F.conv1d(audio[:, None, :], self.basis, stride=HOP)
        real, imag = frames.chunk(2, dim=1)
        magnitude = torch.sqrt(real * real + imag * imag)
        mel = magnitude.transpose(1, 2) @ self.mel
        return torch.log1p(1000 * mel)


def beat_logits(model, spect):
    x = model.transformer_blocks(model.frontend(spect))
    # SumHead without its autocast guard, which torch.export cannot trace.
    logits = model.task_heads.beat_downbeat_lin(x)
    return logits[..., 0] + logits[..., 1]


class BeatTracker(torch.nn.Module):
    """Runs each model on one log-mel spectrogram; returns (1, models, frames) logits."""

    def __init__(self, models):
        super().__init__()
        self.models = torch.nn.ModuleList(models)

    def forward(self, spect):
        return torch.stack([beat_logits(model, spect) for model in self.models], dim=1)


def rms_norm(self, x):
    """`roformer.RMSNorm` without `F.normalize`, which lowers to `reduce_l2_norm` and runs on the
    CPU, splitting the graph between devices. `F.rms_norm` converts to ops that drift further in
    float16 and fail to compile for the Neural Engine. The inputs stay within ±50 with an RMS
    above 0.08 on music, speech and silence, so `x * x` fits in float16."""
    return x * torch.rsqrt((x * x).mean(dim=self.dim, keepdim=True) + 1e-6) * self.gamma


def attend(self, q, k, v):
    """`roformer.Attend` with heads folded into the batch when both exceed one, as in the
    frequency and time attention of the front-end blocks, which the Neural Engine compiler
    rejects otherwise. Folding the main transformer as well makes it slower there."""
    b, h, n, d = q.shape
    if b == 1 or h == 1:
        return F.scaled_dot_product_attention(q, k, v)
    fold = lambda t: t.reshape(b * h, 1, n, d)
    return F.scaled_dot_product_attention(fold(q), fold(k), fold(v)).reshape(b, h, n, d)


def export(module, example):
    # Keep aten.linear: the default decompositions turn batched linears into matmuls with the
    # weights expanded per frame, which multiplies the model size by five.
    exported = torch.export.export(module, (example,)).run_decompositions({})
    # coremltools has no converter for aten.alias, a no-op view.
    graph = exported.graph_module.graph
    for node in list(graph.nodes):
        if node.target == torch.ops.aten.alias.default:
            node.replace_all_uses_with(node.args[0])
            graph.erase_node(node)
    exported.graph_module.recompile()
    return exported


def convert(module, example, name, output, precision, description):
    mlmodel = ct.convert(
        export(module, example),
        # Float32 at the boundaries; the iOS Simulator returns zeros for float16 inputs and outputs.
        inputs=[ct.TensorType(name=name, dtype=np.float32)],
        outputs=[ct.TensorType(name=output, dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=precision,
    )
    mlmodel.author = "Francesco Foscarin, Jan Schlüter, Gerhard Widmer (JKU Linz)"
    mlmodel.license = "MIT"
    mlmodel.short_description = description
    return mlmodel


def click_track(bpm, seconds):
    """Kick on every beat and a hi-hat on every off-beat, as a deterministic test signal."""
    t = np.arange(int(seconds * SAMPLE_RATE)) / SAMPLE_RATE
    audio = np.zeros_like(t)
    rng = np.random.default_rng(0)
    period = 60 / bpm
    for start in np.arange(0, seconds, period / 2):
        n = int(start * SAMPLE_RATE)
        length = min(4000, len(t) - n)
        decay = np.exp(-np.arange(length) / 600)
        if round(start / period * 2) % 2 == 0:
            audio[n : n + length] += np.sin(2 * np.pi * 60 * np.arange(length) / SAMPLE_RATE) * decay
        else:
            audio[n : n + length] += 0.3 * rng.standard_normal(length) * decay**3
    return (0.5 * audio / np.abs(audio).max()).astype(np.float32)


def main():
    models = [load_model(name, device="cpu") for name in CHECKPOINTS]
    logmel = LogMel().eval()
    tracker = BeatTracker(models).eval()

    audio = torch.from_numpy(click_track(120, SAMPLES / SAMPLE_RATE + 1)[:SAMPLES])[None]
    with torch.no_grad():
        # The reference pads by n_fft / 2 on each side, so pad the same way to align frames.
        padded = F.pad(audio[:, None], (N_FFT // 2, N_FFT // 2), mode="reflect")[:, 0]
        reference = LogMelSpect()(audio[0])
        print("log-mel max abs error:", (reference - logmel(padded)[0]).abs().max().item())
        spect = logmel(audio)
        expected = tracker(spect)
        for i, model in enumerate(models):
            assert torch.equal(expected[:, i], model(spect)["beat"])
        roformer.RMSNorm.forward = rms_norm
        roformer.Attend.forward = attend
        print("Neural Engine rewrites max abs error:", (tracker(spect) - expected).abs().max().item())

    frontend = convert(
        logmel, audio, "audio", "spectrogram", ct.precision.FLOAT32,
        "Beat This! log-mel spectrogram. Input: 10 s of mono audio at 22050 Hz. "
        "Output: 500 frames of 128 mel bands; frame i is centred on sample 441 i + 512.",
    )
    beats = convert(
        tracker, spect, "spectrogram", "beat", ct.precision.FLOAT16,
        f"Beat This! {', '.join(CHECKPOINTS)} beat trackers. Input: a log-mel spectrogram. "
        "Output: beat logits per model at 50 frames per second.",
    )
    pipeline = ct.utils.make_pipeline(frontend, beats)
    pipeline.short_description = (
        f"Beat This! {', '.join(CHECKPOINTS)} beat trackers. Input: 10 s of mono audio at 22050 Hz. "
        "Output: beat logits per model at 50 frames per second; frame i is centred on sample 441 i + 512."
    )
    pipeline.save(OUTPUT / "BeatThis.mlpackage")

    actual = torch.from_numpy(pipeline.predict({"audio": audio.numpy()})["beat"])
    print("Core ML beat logit max abs error:", (actual - expected).abs().max().item())
    peaks = lambda x: set(np.flatnonzero(((x == F.max_pool1d(x[None], 7, 1, 3)[0]) & (x > 0))[0].numpy()))
    for i, name in enumerate(CHECKPOINTS):
        print(f"{name} beat frames, PyTorch:", sorted(map(int, peaks(expected[:, i]))))
        print(f"{name} beat frames, Core ML:", sorted(map(int, peaks(actual[:, i]))))


if __name__ == "__main__":
    main()
