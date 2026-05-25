import "./styles.css";

function requiredElement<T extends HTMLElement>(selector: string): T {
  const element = document.querySelector<T>(selector);
  if (!element) {
    throw new Error(`Missing element: ${selector}`);
  }

  return element;
}

const button = requiredElement<HTMLButtonElement>("#tap-button");
const value = requiredElement<HTMLSpanElement>("#bpm-value");
const label = requiredElement<HTMLSpanElement>("#bpm-label");

const maxSamples = 8;
const resetAfterMs = 2_500;
let taps: number[] = [];

function averageBpm(samples: number[]): number | null {
  if (samples.length < 2) {
    return null;
  }

  let intervalTotal = 0;
  for (let i = 1; i < samples.length; i++) {
    intervalTotal += samples[i] - samples[i - 1];
  }

  const averageInterval = intervalTotal / (samples.length - 1);
  return 60_000 / averageInterval;
}

function recordTap(now: number) {
  const previousTap = taps.at(-1);
  if (previousTap !== undefined && now - previousTap > resetAfterMs) {
    taps = [];
  }

  taps.push(now);
  taps = taps.slice(-maxSamples);

  const bpm = averageBpm(taps);
  if (bpm === null) {
    value.textContent = "Tap";
    label.textContent = "again";
    return;
  }

  value.textContent = Math.round(bpm).toString();
  label.textContent = "BPM";
}

function isTapKey(event: KeyboardEvent): boolean {
  return event.key === "Enter" || event.key === " " || event.key === "Spacebar";
}

button.addEventListener("click", (event) => {
  if (event.detail === 0) {
    return;
  }

  recordTap(performance.now());
});

document.addEventListener("keydown", (event) => {
  if (!isTapKey(event) || event.repeat) {
    return;
  }

  event.preventDefault();
  button.focus();
  recordTap(performance.now());
});
