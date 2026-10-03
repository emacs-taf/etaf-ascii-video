# ETAF ASCII Video

ETAF ASCII Video plays a local video inside an Emacs buffer as pure ASCII
pixels. Every decoded frame is downsampled by ffmpeg to a small grayscale
grid, each pixel becomes one character of a density ramp, and the text is
published through [ETAF](https://gitea.vhkd.top/geekinney/etaf)'s retained
content boundary: one displayed frame is one incremental publication of a
fixed canvas Host, not a full re-render. The status line reports the frame
rate, the publication cost in milliseconds, dropped frames, the grid size and
the playback rate, so the incremental behavior is visible while it runs.

## Capabilities

- Playback of local video files through ffmpeg; the built-in demo generates a
  test pattern with ffmpeg's `lavfi` input, so no file is needed.
- HTTP(S) video URLs play as streams: ffmpeg decodes them directly, nothing is
  downloaded first, and a dropped connection is retried for five seconds.
- Three rendering modes. The default monochrome mode maps each pixel to one
  density-ramp character. True-color half-block mode (`c`) renders two full
  color pixels per character cell with `▀` (top pixel as foreground, bottom as
  background), keeping the video's colors at double the vertical resolution.
  Graphics mode (`i`) publishes one scaled JPEG per frame as an image display,
  which is the only mode that stays smooth at a full-window size.
- A canvas that fits the window (and follows resizes), four grid presets, and
  explicit `etaf-ascii-video-set-grid` for scripts.
- Play, pause, single frame stepping, seeking, and 0.5x to 8x rates.
- Latest-frame-wins display: when decoding outruns display, older frames are
  dropped instead of replayed as a backlog.
- `etaf-ascii-video-state` exposes the live player as plain data for scripts
  and tests.

## Prerequisites

| Requirement | Why | Check |
| --- | --- | --- |
| Emacs 29.1 or newer | the ETAF runtime | `emacs --version` |
| `etaf`, `ebox`, `ecss` | the framework; each root entry must be on `load-path` | every checkout is readable |
| ffmpeg | decoding and downsampling | `ffmpeg -version` |
| ffprobe | duration, frame rate and video size | `ffprobe -version` |

ffprobe is optional: without it playback uses the source defaults for
dimensions and rate and the status line shows no total duration.

## Installation

```elisp
(add-to-list 'load-path "/path/to/ecss")
(add-to-list 'load-path "/path/to/ebox")
(add-to-list 'load-path "/path/to/etaf")
(add-to-list 'load-path "/path/to/etaf-ascii-video")
(require 'etaf-ascii-video)

(global-set-key (kbd "C-c a") #'etaf-ascii-video-open-file)
```

## Minimal example

```elisp
(etaf-ascii-video-demo)                 ; generated test pattern, no file
(etaf-ascii-video-open-file "clip.mp4") ; a local video
(etaf-ascii-video-open-url "https://example.com/clip.mp4") ; a network stream
(etaf-ascii-video-open '(:file "clip.mp4" :columns 120 :rows 34 :speed 2))
(etaf-ascii-video-open '(:file "clip.mp4" :mode 'graphics)) ; image frames
```

## Keys

| Key | Action |
| --- | --- |
| `SPC` | play or pause |
| `n` | pause and present one more frame |
| `f` / `b` | seek five seconds forward or backward |
| `+` / `-` | raise or lower the playback rate |
| `1` .. `4` | grid presets (64, 96, 128, 176 columns, rows follow the aspect) |
| `c` | toggle true-color half-block rendering |
| `i` | toggle graphics (image) rendering |
| `F` | fit the canvas to the window |
| `o` / `u` / `d` | open a file / open a URL / replay the built-in demo |
| `?` / `q` | help / close |

## Checks

```sh
make check    # structure + byte compilation (warnings as errors) + acceptance + API boundary
make test     # the public acceptance scenarios only
```

The acceptance suite drives the repository's fake ffmpeg and ffprobe fixtures,
so it needs no real decoder, no network and no frame; one scenario runs the
real ffmpeg when one is installed.

## Documentation

- [The manual](docs/manual.md): playback, canvas fitting, scripting, variables
  and troubleshooting.
- [Architecture](docs/architecture.md): module responsibilities, data flow,
  invariants and measured behavior.
- [The root entry Commentary](etaf-ascii-video.el): the authoritative list of
  supported functions and variables.
