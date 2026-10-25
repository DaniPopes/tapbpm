# TapBPM

Find the tempo of a song by tapping along, or let it listen. The [Beat This!](https://github.com/CPJKU/beat_this)
beat tracker runs on the device and streams the tempo of whatever it hears, alongside your taps.

## Web app

The web app runs on any phone or computer and installs from the browser, with nothing to sign.
On an iPhone, open it in Safari and choose Share → Add to Home Screen. Press Listen to detect
the tempo through the microphone; it works offline once loaded.

```sh
cd web
npm install
npm run dev     # local server
npm test        # tempo logic and the model on generated drums
npm run build   # static site in web/dist
```

## Native app

`TapBPM.xcodeproj` builds the same app for iOS and macOS. On a Mac it can also listen to
everything the Mac plays, which browsers and iOS do not allow.

## Model

Both apps bundle the three small Beat This! models and use the median of their tempos. These
scripts rebuild them from the published checkpoints:

```sh
uv run scripts/convert_beat_this.py   # Core ML, for the native app
uv run scripts/export_onnx.py         # ONNX, for the web app
```

The code and the Beat This! weights are MIT licensed.
