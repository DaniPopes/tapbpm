import "./style.css";
import { BeatListener } from "./listener";
import { TapTempo } from "./tempo";
import { Tempos } from "./tempos";

/** What the screen shows at one instant, led by taps or by the music. */
interface Reading {
  status: string;
  bpm?: number;
  error?: number;
  fresh: boolean;
  /** Fill of the ring around the number, from 0 to 1. */
  ring: number;
  /** Time since the last tap, which drives the background flash. */
  sinceTap?: number;
  /** Position within the beat, which drives the beat dot. */
  phase?: number;
  /** The tempo from the other source, or a hint when it has none. */
  other: string;
}

const prompt = matchMedia("(pointer: coarse)").matches ? "TAP ANYWHERE TO THE BEAT" : "CLICK OR PRESS ANY KEY TO THE BEAT";
const format = (bpm: number) => bpm.toFixed(1);
const now = () => performance.now() / 1000;

const listener = new BeatListener();
const tempos = new Tempos(new TapTempo(), listener);

const element = (id: string) => document.getElementById(id) as HTMLElement;
const pad = element("pad");
const ui = {
  flash: element("flash"),
  status: element("status"),
  ring: element("ring"),
  bpm: element("bpm"),
  detail: element("detail"),
  dot: element("dot"),
  other: element("other"),
  reset: element("reset") as HTMLButtonElement,
  scales: [...document.querySelectorAll<HTMLButtonElement>("[data-scale]")],
};

function musicStatus() {
  switch (listener.state) {
    case "off":
    case "paused":
      return "PAUSED";
    case "loading":
      return "LOADING MODEL…";
    case "waiting":
      return "TAP TO START LISTENING";
    case "listening":
      if (listener.quiet) return "NO MUSIC";
      return listener.bpm === undefined ? "LISTENING…" : `MUSIC · ${listener.beatCount} BEATS`;
    case "denied":
      return "MICROPHONE ACCESS DENIED";
    case "unavailable":
      return "MICROPHONE UNAVAILABLE";
  }
}

function reading(time: number): Reading {
  const { taps } = tempos;
  if (tempos.leader(time) === "taps") {
    const live = taps.isLive(time);
    return {
      status: !live ? "TAP TO MEASURE AGAIN" : taps.tapCount === 1 ? "KEEP TAPPING" : `${taps.tapCount} TAPS`,
      bpm: taps.bpm,
      error: taps.bpmError,
      fresh: live && taps.liveBPM !== undefined,
      ring: taps.remaining(time),
      sinceTap: taps.anchor === undefined ? undefined : time - taps.anchor,
      phase: taps.beatPhase(time),
      other: listener.bpm === undefined ? musicStatus() : `MUSIC ${format(listener.bpm)}`,
    };
  }
  return {
    status: musicStatus(),
    bpm: listener.bpm,
    error: listener.bpmError,
    fresh: listener.fresh,
    ring: listener.isLive(time) ? 1 : 0,
    phase: listener.beatPhase(time),
    other: taps.bpm === undefined ? prompt : `TAPS ${format(taps.bpm)}`,
  };
}

/** Sets text only when it changed, so frames do not touch the DOM needlessly. */
function setText(node: HTMLElement, text: string) {
  if (node.textContent !== text) node.textContent = text;
}

function render() {
  const time = now();
  const r = reading(time);
  const flash = Math.max(0, 1 - (r.sinceTap ?? Infinity) / 0.15);
  ui.flash.style.opacity = String(0.2 * flash);
  setText(ui.status, r.status);
  ui.ring.style.strokeDashoffset = String(1 - r.ring);
  setText(ui.bpm, r.bpm === undefined ? "–" : String(Math.round(r.bpm)));
  ui.bpm.style.opacity = String(r.bpm === undefined ? 0.25 : r.fresh ? 1 : 0.45);
  setText(ui.detail, r.bpm === undefined ? "BPM" : `${format(r.bpm)} BPM${r.error === undefined ? "" : `  ±${format(r.error)}`}`);
  ui.dot.style.opacity = String(r.phase === undefined ? 0 : Math.exp(-5 * r.phase));
  setText(ui.other, r.other);
  ui.reset.disabled = !tempos.canReset;
  for (const button of ui.scales) button.disabled = !tempos.canScale(Number(button.dataset.scale), time);
  return r.ring > 0 || r.phase !== undefined || flash > 0;
}

let frame = 0;

/** Redraws every frame while something moves, and once otherwise. */
function wake() {
  if (frame) return;
  frame = requestAnimationFrame(function loop() {
    frame = render() ? requestAnimationFrame(loop) : 0;
  });
}

function tap(timeStamp: number) {
  listener.resume();
  tempos.taps.tap(timeStamp / 1000);
  wake();
}

pad.addEventListener("pointerdown", (event) => {
  if ((event.target as HTMLElement).closest("button")) return;
  event.preventDefault();
  tap(event.timeStamp);
});

document.addEventListener("keydown", (event) => {
  if (event.repeat || event.metaKey || event.ctrlKey || event.altKey) return;
  if (event.key === "Escape") {
    tempos.reset();
    wake();
  } else {
    event.preventDefault();
    tap(event.timeStamp);
  }
});

ui.reset.addEventListener("click", () => {
  tempos.reset();
  wake();
});

for (const button of ui.scales) {
  button.addEventListener("click", () => {
    tempos.scale(Number(button.dataset.scale), now());
    wake();
  });
}

listener.onChange = wake;
document.addEventListener("visibilitychange", () => {
  if (document.hidden) listener.pause();
  else void listener.start();
});

void listener.start();
wake();

if ("serviceWorker" in navigator && import.meta.env.PROD) {
  void navigator.serviceWorker.register("sw.js");
}
