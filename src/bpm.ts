export type BpmDisplay = {
  value: string;
  label: string;
};

export class BpmTracker {
  #taps: number[] = [];

  constructor(
    readonly maxSamples = 8,
    readonly resetAfterMs = 3_000,
  ) {}

  recordTap(now: number): BpmDisplay {
    const previousTap = this.#taps.at(-1);
    if (previousTap !== undefined && now - previousTap > this.resetAfterMs) {
      this.#taps = [];
    }

    this.#taps.push(now);
    this.#taps = this.#taps.slice(-this.maxSamples);

    const bpm = this.#averageBpm();
    if (bpm === null) {
      return { value: "Tap", label: "again" };
    }

    return { value: Math.round(bpm).toString(), label: "BPM" };
  }

  reset(): BpmDisplay {
    this.#taps = [];
    return { value: "Tap", label: "BPM" };
  }

  #averageBpm(): number | null {
    if (this.#taps.length < 2) {
      return null;
    }

    let intervalTotal = 0;
    for (let i = 1; i < this.#taps.length; i++) {
      intervalTotal += this.#taps[i] - this.#taps[i - 1];
    }

    const averageInterval = intervalTotal / (this.#taps.length - 1);
    return 60_000 / averageInterval;
  }
}
