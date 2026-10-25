import { type Fit, fitBPM, TapTempo } from "./tempo";

/** These match `scripts/convert_beat_this.py`. */
export const model = {
  sampleRate: 22050,
  hop: 441,
  fftSize: 1024,
  frames: 500,
  samples: 499 * 441 + 1024,
};

/** A tempo and the beats it was fitted to. */
export interface Estimate {
  fit: Fit;
  beats: number[];
}

/** Frames at each window edge, which the model was not trained to predict. */
const border = 6;
/** Seconds of the newest beats that override the whole window when their tempo differs. */
const recent = 5;
/** How close the models' tempos must be to count as agreeing. */
const modelAgreement = 0.04;
/** Smallest tempo difference treated as a change rather than noise. */
const tempoChange = 0.03;

const agree = (a: number, b: number, tolerance: number) => Math.abs(a / b - 1) < tolerance;

/** Splits the model's (1, models, frames) output into one array per model. */
export function perModel(logits: Float32Array, models: number): Float32Array[] {
  const frames = logits.length / models;
  return Array.from({ length: models }, (_, i) => logits.subarray(i * frames, (i + 1) * frames));
}

/**
 * Beats as fractional frames: logits above 0 that are the maximum within ±3 frames (±60 ms), with
 * runs of adjacent peaks merged into their mean.
 */
export function beatFrames(logits: ArrayLike<number>, start: number, end: number): number[] {
  const runs: number[][] = [];
  for (let i = start; i < end; i++) {
    if (logits[i] <= 0) continue;
    let peak = true;
    for (let j = Math.max(0, i - 3); j <= Math.min(logits.length - 1, i + 3); j++) {
      if (logits[j] > logits[i]) peak = false;
    }
    if (!peak) continue;
    const run = runs.at(-1);
    if (run && i - run[run.length - 1] === 1) run.push(i);
    else runs.push([i]);
  }
  return runs.map((run) => run.reduce((a, b) => a + b, 0) / run.length);
}

/** Times of the beats in a window ending at `end`, of which the last `filled` samples hold audio and the rest is silence. */
export function beatTimes(logits: ArrayLike<number>, filled: number, end: number): number[] {
  const firstFull = Math.ceil((model.samples - filled) / model.hop);
  const lower = Math.max(firstFull, border);
  return beatFrames(logits, lower, logits.length - border).map((frame) => {
    const centre = frame * model.hop + model.fftSize / 2;
    return end - (model.samples - centre) / model.sampleRate;
  });
}

/**
 * The median of the models' tempos, which is more accurate than any one model
 * (https://github.com/CPJKU/beat_this/issues/13), if at least two of them agree. Each model alone
 * finds a tempo in most windows of speech or random clicks; they rarely agree on one.
 */
export function estimateFromLogits(logits: ArrayLike<number>[], filled: number, end: number): Estimate | undefined {
  const estimates = logits
    .map((l) => estimateFromBeats(beatTimes(l, filled, end)))
    .filter((e): e is Estimate => e !== undefined)
    .sort((a, b) => fitBPM(a.fit) - fitBPM(b.fit));
  if (estimates.length === 0) return undefined;
  const median = estimates[Math.floor(estimates.length / 2)];
  const agreeing = estimates.filter((e) => agree(fitBPM(e.fit), fitBPM(median.fit), modelAgreement)).length;
  return agreeing >= 2 ? median : undefined;
}

/**
 * Tempo of the beats, or of the last `recent` seconds of them when the two differ by more than 3%,
 * so a new song replaces the old tempo before the old one leaves the window.
 */
export function estimateFromBeats(beats: number[]): Estimate | undefined {
  const last = beats.at(-1);
  if (last === undefined) return undefined;
  const latest = fit(beats.filter((beat) => beat > last - recent));
  const all = fit(beats);
  if (!all) return latest;
  if (latest && !agree(fitBPM(latest.fit), fitBPM(all.fit), tempoChange)) return latest;
  return all;
}

/** Reads detected beats like taps, so missed and double beats follow the same rules. */
function fit(beats: number[]): Estimate | undefined {
  const tempo = new TapTempo(Infinity);
  for (const beat of beats) tempo.tap(beat);
  return tempo.tapCount >= 4 && tempo.fit ? { fit: tempo.fit, beats } : undefined;
}

/**
 * Accepts a tempo only when an estimate two to four intervals earlier agrees with it, which rejects
 * the chance agreements left on speech and noise.
 */
export class Confirmation {
  private recent: { time: number; bpm: number }[] = [];

  constructor(private readonly interval: number) {}

  confirm(bpm: number, time: number): boolean {
    const slack = this.interval / 5;
    this.recent = this.recent.filter((e) => time - e.time <= 4 * this.interval + slack);
    const confirmed = this.recent.some(
      (e) => time - e.time >= 2 * this.interval - slack && agree(bpm, e.bpm, tempoChange),
    );
    this.recent.push({ time, bpm });
    return confirmed;
  }
}
