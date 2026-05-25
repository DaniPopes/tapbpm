# Tap BPM

A single-button BPM tap app built with Tauri. Tap the button repeatedly; the app averages the latest taps and shows the current BPM inside the same button. A pause longer than 3 seconds starts a new measurement.

## Development

```sh
npm install
npm run tauri dev
```

## Verification

```sh
npm run verify
```

## Builds

```sh
npm run bundle:linux
npm run bundle:macos
npm run bundle:ios
```

Linux builds produce `.deb` and `.rpm` packages. macOS builds must be run on macOS with the required Apple toolchain installed.

The Arch Linux package is defined in `packaging/arch/` and can be built and installed locally with `makepkg -fi` from that directory.

The iOS app is generated under `ios/` with Capacitor and uses the same `dist/` web assets as the desktop app. Run `npm run ios:open` on macOS to open the project in Xcode.
