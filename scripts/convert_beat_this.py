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
"""Converts the Beat This! beat tracker to a Core ML model that takes raw audio.

The log-mel front-end is rebuilt from a strided convolution so the whole pipeline runs in Core ML;
the script checks it against the reference `LogMelSpect` and the converted model against PyTorch.

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
from beat_this.preprocessing import LogMelSpect

SAMPLE_RATE = 22050
N_FFT = 1024
HOP = 441
FRAMES = 500  # 10 s at 50 frames per second.
SAMPLES = (FRAMES - 1) * HOP + N_FFT
OUTPUT = Path(__file__).resolve().parent.parent / "TapBPM" / "BeatThis.mlpackage"


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
        # log1p(1000 x) rewritten so intermediate values fit in float16.
        return torch.log(mel + 1e-3) + math.log(1000)


class BeatTracker(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.logmel = LogMel()
        self.model = model

    def forward(self, audio):
        x = self.model.transformer_blocks(self.model.frontend(self.logmel(audio)))
        # SumHead without its autocast guard, which torch.export cannot trace.
        logits = self.model.task_heads.beat_downbeat_lin(x)
        return logits[..., 0] + logits[..., 1]


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
    model = load_model("final0", device="cpu")
    tracker = BeatTracker(model).eval()

    audio = torch.from_numpy(click_track(120, SAMPLES / SAMPLE_RATE + 1)[:SAMPLES])[None]
    with torch.no_grad():
        # The reference pads by n_fft / 2 on each side, so pad the same way to align frames.
        padded = F.pad(audio[:, None], (N_FFT // 2, N_FFT // 2), mode="reflect")[:, 0]
        reference = LogMelSpect()(audio[0])
        ours = tracker.logmel(padded)[0]
        print("log-mel max abs error:", (reference - ours).abs().max().item())
        expected = tracker(audio)
        assert torch.equal(expected, model(tracker.logmel(audio))["beat"])

    # Keep aten.linear: the default decompositions turn batched linears into matmuls with the
    # weights expanded per frame, which multiplies the model size by five.
    exported = torch.export.export(tracker, (audio,)).run_decompositions({})
    # coremltools has no converter for aten.alias, a no-op view.
    graph = exported.graph_module.graph
    for node in list(graph.nodes):
        if node.target == torch.ops.aten.alias.default:
            node.replace_all_uses_with(node.args[0])
            graph.erase_node(node)
    exported.graph_module.recompile()
    mlmodel = ct.convert(
        exported,
        inputs=[ct.TensorType(name="audio", dtype=np.float32)],
        outputs=[ct.TensorType(name="beat", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.author = "Francesco Foscarin, Jan Schlüter, Gerhard Widmer (JKU Linz)"
    mlmodel.license = "MIT"
    mlmodel.short_description = (
        "Beat This! final0 beat tracker. Input: 10 s of mono audio at 22050 Hz. "
        "Output: beat logits at 50 frames per second; frame i is centred on sample 441 i + 512."
    )
    mlmodel.save(OUTPUT)

    actual = torch.from_numpy(mlmodel.predict({"audio": audio.numpy()})["beat"])
    print("Core ML beat logit max abs error:", (actual - expected).abs().max().item())
    peaks = lambda x: set(np.flatnonzero(((x == F.max_pool1d(x[None], 7, 1, 3)[0]) & (x > 0))[0].numpy()))
    print("beat frames, PyTorch:", sorted(map(int, peaks(expected))))
    print("beat frames, Core ML:", sorted(map(int, peaks(actual))))
    print("saved", OUTPUT)


if __name__ == "__main__":
    main()
