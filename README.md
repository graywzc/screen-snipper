# gif-snip

A tiny macOS screen-region recorder for GIFs and MP4 video.

`gif-snip` opens a click-through selection overlay with a draggable floating toolbar. Drag the rectangle frame to move the capture area, drag the blue handles to resize it, then start and stop recording with the toolbar or the keyboard shortcut.

## Build

```sh
swift build -c release
```

The executable is built at:

```sh
.build/release/gif-snip
```

## Test

```sh
swift run gif-snip-tests
```

## Use

Open the snipping overlay:

```sh
.build/release/gif-snip
```

Open it as a toggle, useful for a macOS keyboard shortcut:

```sh
.build/release/gif-snip --toggle
```

Recommended macOS shortcut command:

```sh
/Users/graywzc/projects/gif-snip/.build/release/gif-snip --toggle
```

While the overlay is open:

- `Command-Shift-Space`: start or stop recording.
- `Command-Shift-7`: close the app when it is focused, matching the suggested launcher shortcut.
- Floating toolbar: choose GIF or Video, output options, FPS, and max width.
- Rectangle frame: move the selected region.
- Blue handles: resize the selected region.

## Options

- `--fps <frames>`: frames per second. Defaults to `10`.
- `--max-width <pixels>`: downscale captures wider than this value.
- `--output <path>`: explicit output path. The toolbar folder setting is used when this is omitted.
- `--clipboard`: copy the recording to the clipboard after saving.
- `--no-save`: copy to clipboard without keeping a file.
- `--debug`: print selection and capture coordinate diagnostics.
- `--toggle`: start `gif-snip` if closed, or close the running instance.
- `--help`: show usage.

The toolbar remembers its selected format, folder, clipboard toggle, FPS, max width, and rectangle position between runs.

## Permissions

macOS requires Screen Recording permission before recording can begin. If capture returns a blank or black image, enable Screen Recording for the app that launches `gif-snip`, usually Terminal, iTerm, your shortcut runner, or the built executable, in System Settings > Privacy & Security > Screen & System Audio Recording. Quit and reopen that app before trying again.
