# gif-snip

A tiny macOS screen-region recorder that saves the selected area as a GIF and can also copy the GIF to the clipboard.

## Build

```sh
swift build -c release
```

The executable will be at:

```sh
.build/release/gif-snip
```

## Test

```sh
swift run gif-snip-tests
```

## Use

```sh
.build/release/gif-snip --duration 4 --fps 10 --output ~/Desktop/snip.gif
```

Copy the generated GIF to the clipboard too:

```sh
.build/release/gif-snip --clipboard
```

Small clipboard-friendly capture:

```sh
Scripts/gif-snip-small
```

Options:

- `--duration <seconds>`: recording length, defaults to `3`.
- `--fps <frames>`: capture frames per second, defaults to `10`.
- `--max-width <pixels>`: downscale GIF frames to this width when the capture is larger.
- `--output <path>`: GIF output path, defaults to `~/Desktop/Screenshot/gif-snip-YYYYMMDD-HHMMSS.gif`.
- `--clipboard`: put the GIF data on the macOS pasteboard after saving.
- `--no-save`: do not keep a file; implies clipboard mode and writes a temporary GIF.
- `--debug`: print selection and capture coordinate diagnostics.
- `--help`: show usage.

On first run, macOS may ask for Screen Recording permission. If capture returns a blank/black image, enable Screen Recording for the app that launches `gif-snip` -- usually Terminal, iTerm, or the built executable -- in System Settings > Privacy & Security > Screen & System Audio Recording. Quit and reopen that app, then run `gif-snip` again.
