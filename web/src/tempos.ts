import type { TapTempo } from "./tempo";

/** What `Tempos` needs from the music tempo. */
export interface MusicTempo {
  readonly bpm?: number;
  canScale(factor: number): boolean;
  scale(factor: number): void;
  reset(): void;
}

/** The tap tempo and the music tempo, and which of the two leads the screen. */
export class Tempos {
  constructor(
    readonly taps: TapTempo,
    readonly music: MusicTempo,
  ) {}

  get canReset() {
    return this.taps.anchor !== undefined || this.music.bpm !== undefined;
  }

  /** Taps lead while a tap session runs, or when the music has no tempo yet. */
  leader(now: number): "taps" | "music" {
    return this.taps.isLive(now) || (this.taps.bpm !== undefined && this.music.bpm === undefined) ? "taps" : "music";
  }

  canScale(factor: number, now: number) {
    return this.leader(now) === "taps" ? this.taps.canScale(factor) : this.music.canScale(factor);
  }

  scale(factor: number, now: number) {
    if (this.leader(now) === "taps") this.taps.scale(factor);
    else this.music.scale(factor);
  }

  reset() {
    this.music.reset();
    this.taps.reset();
  }
}
