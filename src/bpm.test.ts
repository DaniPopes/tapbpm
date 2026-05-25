import { describe, expect, it } from "vitest";

import { BpmTracker } from "./bpm";

describe("BpmTracker", () => {
  it("prompts for a second tap before calculating BPM", () => {
    const tracker = new BpmTracker();

    expect(tracker.recordTap(0)).toEqual({ value: "Tap", label: "again" });
  });

  it("calculates BPM from the average interval", () => {
    const tracker = new BpmTracker();

    tracker.recordTap(0);
    tracker.recordTap(500);
    expect(tracker.recordTap(1_000)).toEqual({ value: "120", label: "BPM" });
  });

  it("keeps only the latest samples", () => {
    const tracker = new BpmTracker(3);

    tracker.recordTap(0);
    tracker.recordTap(1_000);
    tracker.recordTap(2_000);
    tracker.recordTap(2_500);

    expect(tracker.recordTap(3_000)).toEqual({ value: "120", label: "BPM" });
  });

  it("starts a new measurement after the idle reset window", () => {
    const tracker = new BpmTracker();

    tracker.recordTap(0);
    tracker.recordTap(500);

    expect(tracker.recordTap(3_501)).toEqual({ value: "Tap", label: "again" });
  });

  it("resets immediately", () => {
    const tracker = new BpmTracker();

    tracker.recordTap(0);
    tracker.recordTap(500);

    expect(tracker.reset()).toEqual({ value: "Tap", label: "BPM" });
    expect(tracker.recordTap(750)).toEqual({ value: "Tap", label: "again" });
  });
});
