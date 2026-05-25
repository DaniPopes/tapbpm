import "./styles.css";

import { BpmTracker, type BpmDisplay } from "./bpm";

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

const tracker = new BpmTracker();
let resetTimeout: number | undefined;

function render(display: BpmDisplay) {
  value.textContent = display.value;
  label.textContent = display.label;
}

function clearScheduledReset() {
  if (resetTimeout !== undefined) {
    window.clearTimeout(resetTimeout);
    resetTimeout = undefined;
  }
}

function reset() {
  render(tracker.reset());
  clearScheduledReset();
}

function scheduleReset() {
  clearScheduledReset();
  resetTimeout = window.setTimeout(reset, tracker.resetAfterMs);
}

function recordTap(now: number) {
  render(tracker.recordTap(now));
  scheduleReset();
}

function isTapKey(event: KeyboardEvent): boolean {
  return event.key === "Enter" || event.key === " " || event.key === "Spacebar";
}

function isResetKey(event: KeyboardEvent): boolean {
  return event.key === "Escape" || event.key.toLowerCase() === "r";
}

button.addEventListener("click", (event) => {
  if (event.detail === 0) {
    return;
  }

  recordTap(performance.now());
});

document.addEventListener("keydown", (event) => {
  if (isResetKey(event)) {
    event.preventDefault();
    button.focus();
    reset();
    return;
  }

  if (!isTapKey(event) || event.repeat) {
    return;
  }

  event.preventDefault();
  button.focus();
  recordTap(performance.now());
});
