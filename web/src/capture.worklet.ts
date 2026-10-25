// Runs in the AudioWorkletGlobalScope, which the DOM typings do not describe.
declare const currentFrame: number;
declare const sampleRate: number;
declare class AudioWorkletProcessor {
  readonly port: MessagePort;
}
declare function registerProcessor(name: string, processor: new (options: { processorOptions: { rate: number } }) => AudioWorkletProcessor): void;

/**
 * Forwards the first input channel to the main thread at `rate`, in chunks, each with the frame
 * after its last sample. Resamples linearly when the context runs at another rate, which some
 * browsers require for microphones.
 */
class Capture extends AudioWorkletProcessor {
  private chunk = new Float32Array(2048);
  private length = 0;
  private readonly step: number;
  private position = 0;
  private previous = 0;

  constructor(options: { processorOptions: { rate: number } }) {
    super();
    this.step = sampleRate / options.processorOptions.rate;
  }

  process(inputs: Float32Array[][]): boolean {
    const channel = inputs[0]?.[0];
    if (!channel) return true;
    for (; this.position < channel.length; this.position += this.step) {
      const i = Math.floor(this.position);
      const a = i === 0 ? this.previous : channel[i - 1];
      this.chunk[this.length++] = a + (channel[i] - a) * (this.position - i);
      if (this.length === this.chunk.length) {
        this.port.postMessage({ samples: this.chunk, end: currentFrame + i + 1 }, [this.chunk.buffer]);
        this.chunk = new Float32Array(2048);
        this.length = 0;
      }
    }
    this.position -= channel.length;
    this.previous = channel[channel.length - 1];
    return true;
  }
}

registerProcessor("capture", Capture);
