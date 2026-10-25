import { Confirmation, type Estimate, estimateFromLogits, model } from "./analysis";
import workletUrl from "./capture.worklet.ts?worker&url";
import { beatPhase, canScale, fitBPM, fitBPMError, inRange } from "./tempo";

export type ListenState = "off" | "loading" | "waiting" | "listening" | "denied" | "unavailable";

/** The latest `model.samples` samples at the model's rate, oldest first. */
class Window {
  readonly samples = new Float32Array(model.samples);
  private next = 0;
  filled = 0;
  /** Time in seconds just after the last sample. */
  end = 0;

  append(samples: Float32Array, end: number) {
    const size = this.samples.length;
    const newest = samples.subarray(Math.max(0, samples.length - size));
    const head = Math.min(newest.length, size - this.next);
    this.samples.set(newest.subarray(0, head), this.next);
    this.samples.set(newest.subarray(head), 0);
    this.next = (this.next + newest.length) % size;
    this.filled = Math.min(this.filled + newest.length, size);
    this.end = end;
  }

  /** Root mean square of the newest `count` samples. */
  level(count: number) {
    let sum = 0;
    for (let k = 1; k <= count; k++) {
      const sample = this.samples[(this.next - k + this.samples.length) % this.samples.length];
      sum += sample * sample;
    }
    return Math.sqrt(sum / count);
  }

  snapshot() {
    const samples = new Float32Array(this.samples.length);
    samples.set(this.samples.subarray(this.next));
    samples.set(this.samples.subarray(0, this.next), this.samples.length - this.next);
    return { samples, filled: this.filled, end: this.end };
  }
}

/** The inference worker, with one promise per request. */
class Inference {
  readonly ready: Promise<void>;
  private readonly worker = new Worker(new URL("./inference.worker.ts", import.meta.url), { type: "module" });
  private readonly requests = new Map<number, { resolve(logits: Float32Array[]): void; reject(error: Error): void }>();
  private next = 0;

  constructor() {
    this.ready = new Promise((resolve, reject) => {
      this.worker.onmessage = (event) => {
        const message = event.data;
        const request = this.requests.get(message.id);
        this.requests.delete(message.id);
        if (message.type === "ready") resolve();
        else if (message.type === "error") reject(new Error(message.message));
        else if (message.type === "logits") request?.resolve(message.logits);
        else request?.reject(new Error(message.message));
      };
    });
  }

  run(samples: Float32Array): Promise<Float32Array[]> {
    const id = this.next++;
    return new Promise((resolve, reject) => {
      this.requests.set(id, { resolve, reject });
      this.worker.postMessage({ id, samples }, [samples.buffer]);
    });
  }
}

/**
 * Streams the tempo of music heard by the microphone, re-estimated twice a second from the last
 * 10 s of audio with the bundled Beat This! models.
 */
export class BeatListener {
  /** Seconds between estimates. */
  static readonly interval = 0.5;
  /** Seconds of audio needed before the first estimate. */
  static readonly warmUp = 3;
  /** Level of the last second below which the model is skipped, about -54 dBFS. */
  static readonly silence = 0.002;

  state: ListenState = "off";
  /** Whether the latest window had a beat. */
  fresh = false;
  /** Whether the last second was too quiet to hold music. */
  quiet = false;
  /** Called whenever anything shown changes. */
  onChange = () => {};

  private estimate?: Estimate;
  /** Factor from ½× and 2×, to fix half- or double-time detection. */
  private multiplier = 1;
  private confirmation = new Confirmation(BeatListener.interval);
  private inference?: Inference;
  private window = new Window();
  private context?: AudioContext;
  private stream?: MediaStream;
  /** Changes on every start and stop, so a stopped loop ends. */
  private session = 0;

  get bpm() {
    return this.estimate && fitBPM(this.estimate.fit) * this.multiplier;
  }

  get bpmError() {
    const error = this.estimate && fitBPMError(this.estimate.fit);
    return error === undefined ? undefined : error * this.multiplier;
  }

  get beatCount() {
    return this.estimate?.beats.length ?? 0;
  }

  /** Time of the latest detected beat. */
  get lastBeat() {
    return this.estimate?.beats.at(-1);
  }

  /** Whether beats are still arriving. Detected beats lag by up to a beat plus the time between estimates. */
  isLive(now: number) {
    const { bpm, lastBeat } = this;
    if (!this.fresh || bpm === undefined || lastBeat === undefined) return false;
    return now - lastBeat < Math.max(2.5, 120 / bpm);
  }

  /** Position within the beat while beats are arriving, so the pulse stops with the music. */
  beatPhase(now: number) {
    return this.isLive(now) ? beatPhase(now, this.bpm, this.lastBeat) : undefined;
  }

  canScale(factor: number) {
    return canScale(this.bpm, factor);
  }

  scale(factor: number) {
    if (this.canScale(factor)) this.multiplier *= factor;
  }

  /** Forgets the estimate and keeps listening. */
  reset() {
    this.fresh = false;
    this.quiet = false;
    this.estimate = undefined;
    this.multiplier = 1;
    this.confirmation = new Confirmation(BeatListener.interval);
  }

  async start() {
    if (this.state === "loading" || this.state === "listening" || this.state === "waiting") return;
    const session = ++this.session;
    this.setState("loading");
    // The model loads while the microphone starts and the first seconds of audio arrive.
    this.inference ??= new Inference();
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false },
      });
      this.window = new Window();
      await this.startAudio(this.stream);
      await this.inference.ready;
    } catch (error) {
      this.stop();
      this.setState(error instanceof DOMException && error.name === "NotAllowedError" ? "denied" : "unavailable");
      return;
    }
    if (session !== this.session) return;
    this.setState(this.context?.state === "running" ? "listening" : "waiting");
    await this.listen(session);
  }

  /** Resumes audio that the browser kept suspended until a user gesture. */
  resume() {
    if (this.state !== "waiting" || !this.context) return;
    void this.context.resume().then(() => this.setState("listening"));
  }

  stop() {
    this.session++;
    for (const track of this.stream?.getTracks() ?? []) track.stop();
    this.stream = undefined;
    void this.context?.close();
    this.context = undefined;
    this.fresh = false;
    if (this.state !== "denied" && this.state !== "unavailable") this.setState("off");
  }

  private async listen(session: number) {
    const inference = this.inference!;
    while (session === this.session) {
      await new Promise((resolve) => setTimeout(resolve, BeatListener.interval * 1000));
      if (this.state !== "listening" || this.window.filled < BeatListener.warmUp * model.sampleRate) continue;
      this.quiet = this.window.level(model.sampleRate) < BeatListener.silence;
      if (this.quiet) {
        this.fresh = false;
        this.onChange();
        continue;
      }
      const { samples, filled, end } = this.window.snapshot();
      const logits = await inference.run(samples).catch(() => []);
      if (session === this.session) this.update(estimateFromLogits(logits, filled, end), end);
    }
  }

  private async startAudio(stream: MediaStream) {
    let context: AudioContext;
    let source: MediaStreamAudioSourceNode;
    try {
      context = new AudioContext({ sampleRate: model.sampleRate });
      source = context.createMediaStreamSource(stream);
    } catch {
      // Some browsers cannot connect a microphone to a context at another rate; the worklet resamples.
      context = new AudioContext();
      source = context.createMediaStreamSource(stream);
    }
    this.context = context;
    await context.audioWorklet.addModule(workletUrl);
    const capture = new AudioWorkletNode(context, "capture", { processorOptions: { rate: model.sampleRate } });
    capture.port.onmessage = (event: MessageEvent<{ samples: Float32Array; end: number }>) => {
      this.window.append(event.data.samples, this.timeOfFrame(context, event.data.end));
    };
    source.connect(capture);
  }

  /** Converts an audio frame number to the clock of `performance.now()`, in seconds. */
  private timeOfFrame(context: AudioContext, frame: number) {
    const stamp = context.getOutputTimestamp?.();
    if (stamp?.contextTime === undefined || stamp.performanceTime === undefined) return performance.now() / 1000;
    return stamp.performanceTime / 1000 + (frame / context.sampleRate - stamp.contextTime);
  }

  private update(estimate: Estimate | undefined, time: number) {
    const bpm = estimate && fitBPM(estimate.fit);
    if (bpm !== undefined && inRange(bpm) && this.confirmation.confirm(bpm, time)) {
      this.estimate = estimate;
      this.fresh = true;
    } else {
      this.fresh = false;
    }
    this.onChange();
  }

  private setState(state: ListenState) {
    this.state = state;
    this.onChange();
  }
}
