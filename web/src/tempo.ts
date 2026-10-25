/** A tap or detected beat: its time in seconds and its beat number in the session. */
export interface Tap {
  time: number;
  beat: number;
}

/** Seconds per beat and its standard error, which needs at least three taps. */
export interface Fit {
  period: number;
  error?: number;
}

export const fitBPM = (fit: Fit) => 60 / fit.period;

export const fitBPMError = (fit: Fit) => (fit.error === undefined ? undefined : (60 * fit.error) / fit.period ** 2);

/** Tempos that can be tapped or reached by scaling. */
const bpmRange = { lower: 20, upper: 600 };

export const inRange = (bpm: number) => bpm >= bpmRange.lower && bpm <= bpmRange.upper;

/** Position within the beat at `bpm`, from 0 on a beat towards 1, phased to a beat at `anchor`. */
export function beatPhase(now: number, bpm?: number, anchor?: number): number | undefined {
  if (bpm === undefined || anchor === undefined) return undefined;
  return (((now - anchor) * bpm) / 60) % 1;
}

export const canScale = (bpm: number | undefined, factor: number) => bpm !== undefined && inRange(bpm * factor);

/**
 * Estimates tempo from beat timestamps, tapped or detected, with a least-squares fit of tap time
 * against beat number.
 *
 * A fit uses every tap in the window, unlike averaging intervals, where all but the first and last
 * tap cancel out. Missed beats are tolerated, accidental double taps are dropped, and a sudden
 * tempo change or a pause starts a new session.
 */
export class TapTempo {
  /** How far, in beats, an interval may deviate from a whole number of beats. */
  static readonly beatTolerance = 0.25;
  /** Taps further than this fraction of a beat off the fitted line are left out of a refit. */
  static readonly slop = 0.1;

  taps: Tap[] = [];
  /** Taps in the current session, including those that fell out of the window. */
  tapCount = 0;
  /** Result of the last ended session, shown until the next session has a tempo. */
  held?: number;
  /** Time of the last counted tap, kept across sessions to phase the beat indicator. */
  anchor?: number;
  /** Fitted when a tap lands, since the screen reads it every frame. */
  fit?: Fit;

  /** Number of most recent taps used for the fit. Sixteen taps, four bars, follow a drifting tempo. */
  constructor(readonly window = 16) {}

  get liveBPM() {
    return this.fit && fitBPM(this.fit);
  }

  get bpm() {
    return this.liveBPM ?? this.held;
  }

  get bpmError() {
    return this.fit && fitBPMError(this.fit);
  }

  /** Time without a tap after which the next tap starts a new session; before a tempo is known, it allows the slowest tempo. */
  get timeout() {
    const period = this.fit?.period;
    return period === undefined ? 60 / bpmRange.lower : Math.max(2, 2.5 * period);
  }

  /** Fraction of the timeout left since the last tap, or 0 outside a session. */
  remaining(now: number) {
    const last = this.taps.at(-1);
    return last ? Math.max(0, 1 - (now - last.time) / this.timeout) : 0;
  }

  isLive(now: number) {
    return this.remaining(now) > 0;
  }

  beatPhase(now: number) {
    return beatPhase(now, this.bpm, this.anchor);
  }

  canScale(factor: number) {
    return canScale(this.bpm, factor);
  }

  /** Records a tap and returns whether it was counted. */
  tap(time: number): boolean {
    const last = this.taps.at(-1);
    if (!last || !this.isLive(time)) {
      this.endSession();
      this.append({ time, beat: 0 });
      return true;
    }
    const interval = time - last.time;
    if (interval < 60 / bpmRange.upper) return false;

    let beat = last.beat + 1;
    const period = this.fit?.period;
    if (period !== undefined) {
      const ratio = interval / period;
      if (ratio < 0.5) return false;
      const beats = Math.round(ratio);
      if (beats <= 2 && Math.abs(ratio - beats) <= TapTempo.beatTolerance) {
        beat = last.beat + beats;
      } else {
        this.endSession();
        this.append({ time: last.time, beat: 0 });
        beat = 1;
      }
    }
    this.append({ time, beat });
    return true;
  }

  /** Ends the session and multiplies the shown tempo, to fix half- or double-time tapping. */
  scale(factor: number) {
    const bpm = this.bpm;
    if (bpm === undefined || !this.canScale(factor)) return;
    this.endSession();
    this.held = bpm * factor;
  }

  reset() {
    this.endSession();
    this.held = undefined;
    this.anchor = undefined;
  }

  private endSession() {
    const live = this.liveBPM;
    if (live !== undefined) this.held = live;
    this.taps = [];
    this.tapCount = 0;
    this.fit = undefined;
  }

  private append(tap: Tap) {
    this.taps.push(tap);
    if (this.taps.length > this.window) this.taps.shift();
    this.tapCount += 1;
    this.anchor = tap.time;
    this.fit = TapTempo.fitTaps(this.taps);
  }

  private static fitTaps(taps: Tap[]): Fit | undefined {
    const line = TapTempo.line(taps);
    if (!line) return undefined;
    // Refit without taps far off the line, so one sloppy tap does not drag the tempo.
    const typical = line.residuals.map(Math.abs).sort((a, b) => a - b)[Math.floor(taps.length / 2)];
    const limit = Math.max(TapTempo.slop * line.fit.period, 4 * typical);
    const kept = taps.filter((_, i) => Math.abs(line.residuals[i]) <= limit);
    if (kept.length === taps.length || kept.length < 4) return line.fit;
    return TapTempo.line(kept)?.fit ?? line.fit;
  }

  private static line(taps: Tap[]): { fit: Fit; residuals: number[] } | undefined {
    if (taps.length < 2) return undefined;
    const n = taps.length;
    const meanBeat = taps.reduce((sum, tap) => sum + tap.beat, 0) / n;
    const meanTime = taps.reduce((sum, tap) => sum + tap.time, 0) / n;
    let sxx = 0;
    let sxy = 0;
    for (const tap of taps) {
      const dx = tap.beat - meanBeat;
      sxx += dx * dx;
      sxy += dx * (tap.time - meanTime);
    }
    const slope = sxy / sxx;
    const residuals = taps.map((tap) => tap.time - meanTime - slope * (tap.beat - meanBeat));
    const sse = residuals.reduce((sum, r) => sum + r * r, 0);
    const error = n >= 3 ? Math.sqrt(sse / (n - 2) / sxx) : undefined;
    return { fit: { period: slope, error }, residuals };
  }
}
