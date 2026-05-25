# Tap BPM

A single-button BPM tap app built with Tauri. Tap the button repeatedly; the app averages the latest taps and shows the current BPM inside the same button. A pause longer than 2.5 seconds starts a new measurement.

## Development

```sh
npm install
npm run tauri dev
```

## Builds

```sh
npm run bundle:linux
npm run bundle:macos
npm run bundle:ios
```

Linux builds produce `.deb` and `.rpm` packages. macOS and iOS builds must be run on macOS with the required Apple toolchain installed; initialize the iOS project once with `npx tauri ios init` before the first iOS build.
