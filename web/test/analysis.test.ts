import { InferenceSession, Tensor } from "onnxruntime-node";
import { describe, expect, test } from "vitest";
import { beatFrames, beatTimes, Confirmation, estimateFromBeats, estimateFromLogits, model, perModel } from "../src/analysis";
import { fitBPM } from "../src/tempo";

/** A rock beat: kick on 1 and 3, snare on 2 and 4, and hi-hats on every eighth note. */
function drums(bpm: number) {
  const audio = new Float32Array(model.samples);
  const add = (start: number, length: number, sample: (t: number) => number) => {
    for (let n = 0; n < Math.min(length, audio.length - start); n++) audio[start + n] += sample(n / model.sampleRate);
  };
  const noise = () => Math.random() * 2 - 1;
  const eighth = 30 / bpm;
  for (let index = 0; index * eighth * model.sampleRate < audio.length; index++) {
    const start = Math.floor(index * eighth * model.sampleRate);
    add(start, 2000, (t) => 0.15 * noise() * Math.exp(-t * 300));
    if (index % 8 === 0 || index % 8 === 4) {
      // Kick: a sine falling from 120 Hz to 50 Hz.
      add(start, 6000, (t) => Math.sin(2 * Math.PI * (50 * t + (70 / 30) * (1 - Math.exp(-30 * t)))) * Math.exp(-t * 12));
    } else if (index % 8 === 2 || index % 8 === 6) {
      add(start, 5000, (t) => 0.6 * (noise() + 0.5 * Math.sin(2 * Math.PI * 200 * t)) * Math.exp(-t * 25));
    }
  }
  const peak = audio.reduce((max, x) => Math.max(max, Math.abs(x)), 0);
  return audio.map((x) => (0.5 * x) / peak);
}

const logitsEvery = (spacing: number) => Float32Array.from({ length: model.frames }, (_, i) => (i % spacing === 0 ? 4 : -5));

describe("beat analysis", () => {
  test("peaks are local maxima above zero", () => {
    const logits = new Float32Array(100).fill(-5);
    logits[10] = 2;
    logits[12] = 1;
    logits[40] = -1;
    logits[60] = 3;
    logits[61] = 3;
    logits[90] = 1;
    expect(beatFrames(logits, 0, 100)).toEqual([10, 60.5, 90]);
    expect(beatFrames(logits, 20, 80)).toEqual([60.5]);
  });

  test("beat times skip silence and borders", () => {
    const logits = new Float32Array(model.frames).fill(-5);
    for (let frame = 2; frame < model.frames; frame += 25) logits[frame] = 4;
    const times = beatTimes(logits, Math.floor(model.samples / 2), 1000);
    expect(times).toHaveLength(10);
    expect(times.every((t) => t > 994.9 && t < 1000)).toBe(true);
    expect(times[1] - times[0]).toBeCloseTo(0.5, 9);
  });

  test("tempo counts missed beats", () => {
    expect(fitBPM(estimateFromBeats([10, 10.5, 11, 12, 12.5, 13, 13.5])!.fit)).toBeCloseTo(120, 9);
  });

  test("tempo needs four beats", () => {
    expect(estimateFromBeats([1, 1.5, 2])).toBeUndefined();
  });

  test("models must agree", () => {
    const agreeing = estimateFromLogits([logitsEvery(25), logitsEvery(25), logitsEvery(30)], model.samples, 0);
    expect(Math.abs(fitBPM(agreeing!.fit) - 120)).toBeLessThan(0.5);
    expect(estimateFromLogits([logitsEvery(25), logitsEvery(30), logitsEvery(36)], model.samples, 0)).toBeUndefined();
  });

  test("confirmation needs an earlier agreeing estimate", () => {
    const confirmation = new Confirmation(0.5);
    const results = [[120, 0], [120.5, 0.5], [121, 1], [150, 2], [150, 3], [150, 6]].map(([bpm, time]) =>
      confirmation.confirm(bpm, time),
    );
    expect(results).toEqual([false, false, true, false, true, false]);
  });

  test("tempo follows a recent change", () => {
    const old = Array.from({ length: 12 }, (_, i) => 100 + i * 0.5);
    const changed = Array.from({ length: 12 }, (_, i) => old[11] + ((i + 1) * 60) / 135);
    const estimate = estimateFromBeats([...old, ...changed])!;
    expect(Math.abs(fitBPM(estimate.fit) - 135)).toBeLessThan(0.5);
    expect(estimate.beats.every((t) => t > changed[0] - 1)).toBe(true);
  });

  test.each([90, 100, 128, 174])("model finds the tempo of drums at %d BPM", async (bpm) => {
    const session = await InferenceSession.create(new URL("../models/beat_this.onnx", import.meta.url).pathname);
    const { beat } = await session.run({ audio: new Tensor("float32", drums(bpm), [1, model.samples]) });
    expect(beat.dims).toEqual([1, 3, model.frames]);
    const estimate = estimateFromLogits(perModel(beat.data as Float32Array, 3), model.samples, 0);
    expect(Math.abs(fitBPM(estimate!.fit) - bpm)).toBeLessThan(1);
  }, 60_000);
});
