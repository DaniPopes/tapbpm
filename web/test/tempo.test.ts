import { describe, expect, test } from "vitest";
import { beatPhase, TapTempo } from "../src/tempo";

function tapped(times: number[]) {
  const tempo = new TapTempo();
  for (const time of times) tempo.tap(time);
  return tempo;
}

const steady = (count: number, start = 100, interval = 0.5) => Array.from({ length: count }, (_, i) => start + i * interval);

describe("TapTempo", () => {
  test("steady taps", () => {
    const tempo = tapped(steady(8));
    expect(tempo.bpm).toBeCloseTo(120, 9);
    expect(tempo.tapCount).toBe(8);
    expect(tempo.bpmError).toBeLessThan(1e-6);
  });

  test("no tempo from one tap", () => {
    const tempo = tapped([100]);
    expect(tempo.bpm).toBeUndefined();
    expect(tempo.isLive(102)).toBe(true);
    expect(tempo.isLive(103.1)).toBe(false);
  });

  test("jitter averages out", () => {
    const jitter = [0.012, -0.009, 0.004, -0.015, 0.01, -0.003, 0.008, -0.011, 0.002, -0.006, 0.013, -0.005];
    expect(Math.abs(tapped(jitter.map((j, i) => 100 + i * 0.5 + j)).bpm! - 120)).toBeLessThan(0.5);
  });

  test("sloppy tap is left out", () => {
    const times = steady(10);
    times[5] += 0.06;
    expect(tapped(times).bpm).toBeCloseTo(120, 6);
  });

  test("follows a gradual change", () => {
    const times: number[] = [];
    let time = 100;
    for (let k = 0; k < 40; k++) {
      times.push(time);
      time += 0.6 - (0.15 * k) / 39;
    }
    // The fit trails a drift by half its window: 16 taps read about 125 here, 32 about 118.
    expect(tapped(times).bpm).toBeGreaterThan(122);
  });

  test("missed beat counts as two", () => {
    const tempo = tapped([100, 100.5, 101, 102, 102.5]);
    expect(tempo.bpm).toBeCloseTo(120, 9);
    expect(tempo.taps.map((t) => t.beat)).toEqual([0, 1, 2, 4, 5]);
  });

  test("double tap ignored", () => {
    const tempo = tapped([100, 100.5, 101]);
    expect(tempo.tap(101.1)).toBe(false);
    tempo.tap(101.5);
    expect(tempo.bpm).toBeCloseTo(120, 9);
    expect(tempo.tapCount).toBe(4);
  });

  test("simultaneous touches count once", () => {
    const tempo = tapped([100]);
    expect(tempo.tap(100)).toBe(false);
    expect(tempo.tapCount).toBe(1);
  });

  test("tempo jump restarts", () => {
    const tempo = tapped([100, 100.5, 101, 101.5, 102.1667]);
    expect(Math.abs(tempo.bpm! - 90)).toBeLessThan(0.1);
    expect(tempo.tapCount).toBe(2);
  });

  test("timeout starts a new session and holds the result", () => {
    const tempo = tapped(steady(4));
    expect(tempo.isLive(103.6)).toBe(false);
    tempo.tap(110);
    expect(tempo.tapCount).toBe(1);
    expect(tempo.liveBPM).toBeUndefined();
    expect(tempo.bpm).toBeCloseTo(120, 9);
    tempo.tap(110.6);
    expect(tempo.bpm).toBeCloseTo(100, 9);
  });

  test("slow tempo", () => {
    expect(tapped([100, 102.4, 104.8, 107.2]).bpm).toBeCloseTo(25, 9);
  });

  test("remaining and beat phase", () => {
    const tempo = tapped([100, 100.5]);
    expect(tempo.remaining(101.5)).toBeCloseTo(0.5, 9);
    expect(tempo.remaining(103)).toBe(0);
    expect(tempo.beatPhase(100.75)).toBeCloseTo(0.5, 9);
    expect(beatPhase(1, undefined, 0)).toBeUndefined();
  });

  test("scale ends the session", () => {
    const tempo = tapped([100, 100.5, 101]);
    tempo.scale(0.5);
    expect(tempo.bpm).toBeCloseTo(60, 9);
    expect(tempo.taps).toEqual([]);
    tempo.scale(2);
    tempo.scale(2);
    expect(tempo.bpm).toBeCloseTo(240, 9);
    expect(tempo.canScale(4)).toBe(false);
    tempo.scale(4);
    expect(tempo.bpm).toBeCloseTo(240, 9);
  });

  test("reset", () => {
    const tempo = tapped([100, 100.5, 101]);
    tempo.reset();
    expect(tempo.bpm).toBeUndefined();
    expect(tempo.anchor).toBeUndefined();
    expect(tempo.tapCount).toBe(0);
  });
});
