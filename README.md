# screen-snipper

A tiny macOS screen-region recorder for GIFs and MP4 video.

`screen-snipper` opens a click-through selection overlay with a draggable floating toolbar. Drag the rectangle frame to move the capture area, drag the blue handles to resize it, then start and stop recording with the toolbar or the keyboard shortcut.

## Build

```sh
swift build -c release
```

The executable is built at:

```sh
.build/release/screen-snipper
```

## Test

```sh
swift run screen-snipper-tests
```

## Release

Releases are tag-driven. Pushing a `v*` tag builds a universal macOS binary,
publishes a GitHub release asset, then opens a matching Homebrew tap PR in
`graywzc/homebrew-tap`.

```sh
git switch main
git pull
git tag v0.1.4
git push origin v0.1.4
```

After the workflow finishes, review and merge the generated Homebrew tap PR.

The workflow requires the `HOMEBREW_TAP_TOKEN` repository secret: a fine-grained
PAT scoped to `graywzc/homebrew-tap` with Contents and Pull requests write access.
The tap lives in a different repository, so the automatic `GITHUB_TOKEN` — which is
scoped to this repository alone — cannot reach it. The first step verifies the token
against the API and fails the run immediately if it has expired, before anything is
built or published.

The run is safe to re-run. Publishing is skipped when the release already exists, and
the formula checksum is taken from the published asset rather than the freshly built
one, so a re-run cannot point the formula at a hash users never receive.

## Use

Open the snipping overlay:

```sh
.build/release/screen-snipper
```

Open it as a toggle, useful for a macOS keyboard shortcut:

```sh
.build/release/screen-snipper --toggle
```

Recommended macOS shortcut command:

```sh
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" screen-snipper --toggle
```

`Shortcuts/ScreenSnipper.shortcut` is the prebuilt macOS Shortcut that runs the
command above. Installing via Homebrew imports it automatically; otherwise
double-click the file to add it, then bind a hotkey from the Shortcut details
panel in Shortcuts.app.

While the overlay is open:

- `Command-Shift-Space`: start or stop recording.
- `Command-Shift-M`: jump the capture area to the next monitor.
- `Command-Shift-7`: close the app when it is focused, matching the suggested launcher shortcut.
- Floating toolbar: choose GIF or Video, output options, FPS, and max width.
- Rectangle frame: move the selected region.
- Blue handles: resize the selected region.

## Options

- `--fps <frames>`: frames per second. Defaults to `10`.
- `--max-width <pixels>`: downscale captures wider than this value.
- `--output <path>`: explicit output path. The toolbar folder setting is used when this is omitted.
- `--clipboard`: copy the recording to the clipboard after saving.
- `--no-save`: skip the output folder and keep the recording in `/tmp/screen-snipper` instead.
- `--debug`: print selection and capture coordinate diagnostics.
- `--toggle`: start `screen-snipper` if closed, or close the running instance.
- `--help`: show usage.

The toolbar remembers its selected format, folder, clipboard toggle, FPS, max width, and rectangle position between runs.

### How the clipboard copy works

Copying puts a **file URL** on the clipboard, not the recording's bytes. That is the
only format macOS apps actually paste video in — Finder, Messages, Mail, and Slack all
read `public.file-url`, and nothing reads raw `public.mpeg-4` data. GIFs additionally
carry their image data, so apps that inline images can take the bytes directly.

Because the paste is a file reference, the file has to exist when you press Cmd+V. With
`--no-save` (or the toolbar's folder toggle off) the recording is written to
`/tmp/screen-snipper/` and left there rather than deleted.

macOS reaps these on its own: `com.apple.tmp_cleaner` runs daily and deletes anything
under `/tmp` whose access, modification, and change times are all older than three days.
Reading a file counts as access, so pasting a clip pushes its expiry back. Treat the
recordings as good for a few days, not as an archive — turn the folder toggle on for
anything worth keeping.

## Permissions

macOS requires Screen Recording permission before recording can begin. If capture returns a blank or black image, enable Screen Recording for the app that launches `screen-snipper`, usually Terminal, iTerm, your shortcut runner, or the built executable, in System Settings > Privacy & Security > Screen & System Audio Recording. Quit and reopen that app before trying again.
