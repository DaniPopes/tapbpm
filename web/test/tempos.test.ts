import { expect, test } from "vitest";
import { TapTempo } from "../src/tempo";
import { type MusicTempo, Tempos } from "../src/tempos";

const silent: MusicTempo = { bpm: undefined, canScale: () => false, scale: () => {}, reset: () => {} };

test("music leads without taps", () => {
  const tempos = new Tempos(new TapTempo(), silent);
  expect(tempos.leader(100)).toBe("music");
  expect(tempos.canScale(2, 100)).toBe(false);
  expect(tempos.canReset).toBe(false);
});

test("taps lead while tapping or without music", () => {
  const tempos = new Tempos(new TapTempo(), silent);
  tempos.taps.tap(100);
  expect(tempos.leader(101)).toBe("taps");
  expect(tempos.canReset).toBe(true);
  tempos.taps.tap(100.5);
  tempos.scale(2, 101);
  expect(tempos.taps.bpm).toBe(240);
  // Without a music tempo, the held tap result keeps the lead.
  expect(tempos.leader(200)).toBe("taps");
  tempos.reset();
  expect(tempos.leader(200)).toBe("music");
});
