import modelUrl from "../models/beat_this.onnx?url";
import { perModel } from "./analysis";

/** Runs the bundled Beat This! models off the main thread. */
const webgpu = "gpu" in navigator;
// Fetch the model while the runtime loads. The WebGPU build ships a 27 MB runtime, so browsers
// without WebGPU get the 14 MB plain one.
const bytes = fetch(modelUrl).then((response) => response.arrayBuffer());
const runtime = webgpu ? import("onnxruntime-web/webgpu") : import("onnxruntime-web/wasm");
const session = Promise.all([runtime, bytes]).then(async ([ort, model]) => ({
  ort,
  session: await ort.InferenceSession.create(new Uint8Array(model), {
    executionProviders: webgpu ? ["webgpu", "wasm"] : ["wasm"],
  }),
}));

session.then(
  () => self.postMessage({ type: "ready" }),
  (error: unknown) => self.postMessage({ type: "error", message: String(error) }),
);

self.onmessage = async (event: MessageEvent<{ id: number; samples: Float32Array }>) => {
  const { id, samples } = event.data;
  try {
    const { ort, session: model } = await session;
    const { beat } = await model.run({ audio: new ort.Tensor("float32", samples, [1, samples.length]) });
    const logits = perModel(beat.data as Float32Array, beat.dims[1]);
    self.postMessage({ type: "logits", id, logits }, { transfer: [logits[0].buffer] });
  } catch (error) {
    self.postMessage({ type: "failed", id, message: String(error) });
  }
};
