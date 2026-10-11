# ETAF ASCII Video manual

## Playing a video

`etaf-ascii-video-open-file` plays a local file; `etaf-ascii-video-open-url`
(`u`) plays an HTTP(S) URL as a stream: ffmpeg decodes it directly, so nothing
is downloaded first.  Seeking needs the server to support range requests, and
a dropped connection is retried for up to five seconds.  ffmpeg's HTTP reader
reads the lowercase `http_proxy` environment variable when a proxy is needed.
`etaf-ascii-video-demo` plays a generated 30 second test pattern and needs no
file.  All three create one buffer named `*ASCII Video*` and reuse it: opening
another source closes the previous player first.  `etaf-ascii-video-close`
(also `q`) cancels the status timer, destroys the native session and unmounts
the ETAF Runtime.

The player buffer hides its cursor, so no cursor frame flashes around the
canvas.

Playback starts immediately. `SPC` pauses and resumes, `n` pauses and presents
exactly one more frame, `f` and `b` seek five seconds, and `+`/`-` step through
0.5x, 1x, 2x, 4x and 8x. Pausing releases the producer, and resuming starts a
new one at the pause position, so a long pause never makes playback jump
forward to catch up. Seeking and rate changes restart the producer at the
current position too, so they are safe while paused. When the file ends the
last picture stays visible and the status line shows `ended`; `SPC` replays
from the start.

The producer's own frame rate may be lower or higher than
`etaf-video-display-fps` (30 by default). Display always claims only the newest
complete frame, so a slower display drops frames instead of replaying a
backlog; the status line's `dropped` counter reports how many. The rate shown
in the status line is the number of frames presented in the last sample
window, not the timer rate, so a canvas too large for the display cost reports
a lower number instead of a hopeful one.

## Rendering

Decoding, frame mapping and publication belong to the native `etaf-video`
Component, which this application places in a layout; see the ETAF manual for
the full contract.  Each frame is decoded at the canvas size by ffmpeg and
rendered in one of two character modes
(`etaf-ascii-video-set-render-mode`).  The default monochrome mode converts
the frame to raw grayscale bytes, and every byte picks one character of
`etaf-video-density-ramp` from darkest to lightest.  True-color half-block
mode (`c`) converts the frame to RGB24 at `columns` by `rows * 2` pixels: the
top pixel of each cell becomes the foreground of `▀` and the bottom pixel its
background, so one character cell shows two full color pixels.  Monochrome and
half-block lines and the status text are published through ETAF's retained
Host content boundary, so one displayed frame is one incremental Ebox
publication rather than an ordinary ETAF render.

The default ramp is ` .:-=+*#%@`; a longer or shorter ramp changes the number
of visible levels, and the change applies to the next frame. The ramp must be
nonempty and single-line and is configured through ETAF's
`etaf-video-density-ramp` variable.

The monochrome canvas carries no per-pixel properties.  Color mode carries one
`face` property per cell, so its publication cost grows with the cell count
(measured on the reference machine: about 53 ms per 48x14 frame and 132 ms per
80x24 frame, versus roughly 8 ms for a monochrome 160x45 frame).
`etaf-ascii-video-color-columns` (default 32) caps the fitted color width so a
new player stays responsive; raise it for a sharper but slower picture,
including with `etaf-ascii-video-set-grid`.

Character cells are about twice as tall as wide, so the default fitting keeps
the video aspect ratio by sampling `rows * aspect * 2` columns. The built-in
demo is 640x360; a file's real size comes from ffprobe, and the source
defaults are 640x360 when ffprobe is unavailable.

| Key | Action |
| --- | --- |
| `SPC` | play or pause |
| `n` | one frame while paused |
| `f`, `b` | +5 s / -5 s |
| `+`, `-` | next / previous rate |
| `1` .. `4` | 64, 96, 128, 176 columns |
| `c` | toggle true-color half-block rendering |
| `F` | fit to the window |
| `o`, `u`, `d` | open a file / open a URL / demo |
| `C-c h`, `q` | help / close |

`F` and `etaf-ascii-video-fit` reserve one row for the status line and refit
the ETAF viewport before changing the grid. The same fitting runs
automatically through `window-size-change-functions` when the window changes
size, so a resized frame keeps a canvas that fits.

## Sharp images and sound

Image frames, Retina-sharp decoding and the audio sidecar are capabilities of
the native `etaf-video` Component, not of this character player.  Use the
companion `etaf-video-player` application, or place `etaf-video` directly in
your own layout with `:mode 'image`.

## Scripting

`etaf-ascii-video-open` accepts a file name or a plist, so a session can be
built without prompts:

```elisp
(etaf-ascii-video-open '(:file "clip.mp4" :columns 100 :rows 28 :speed 2))
(etaf-ascii-video-seek 12.5)
(etaf-ascii-video-set-speed 0.5)
(etaf-ascii-video-set-grid 160 45)
(etaf-ascii-video-state)
;; => (:source "clip.mp4" :playing t :position 12.5 :duration 300.0 ...)
```

Every control function operates on the current buffer's player and signals
`user-error` elsewhere, so scripts should call them from the player buffer or
from an interactive command bound there. `etaf-ascii-video-state` returns a
detached plist; the interesting keys are `:playing`, `:position`, `:duration`,
`:received`, `:presented`, `:dropped`, `:presented-fps` and `:ended`.

| Variable | Meaning |
| --- | --- |
| `etaf-ascii-video-render-mode` | default mode for new players: `mono` or `color` |
| `etaf-ascii-video-color-columns` | color-mode fitted column cap, default 32; nil fits the window |
| `etaf-ascii-video-grid-presets` | character to canvas width, used by `1`-`4` |
| `etaf-video-density-ramp` | pixel characters, darkest to lightest (ETAF) |
| `etaf-video-display-fps` | display timer rate, default 30 (ETAF) |
| `etaf-video-ffmpeg-program` | ffmpeg name or path; use a wrapper to add decoder options (ETAF) |
| `etaf-video-ffprobe-program` | ffprobe name or path; optional (ETAF) |

The native Component passes ffmpeg the documented argument shape
`-hide_banner -loglevel error [-ss START] -readrate SPEED -i INPUT -vf
scale=COLUMNS:ROWS:flags=area -f rawvideo -pix_fmt gray -`, with
`-f lavfi -i testsrc2=size=640x360:rate=30 -t 30` for the demo instead of
`-i INPUT`. A wrapper set through `etaf-video-ffmpeg-program` receives these
arguments unchanged.

## Troubleshooting

- `ffmpeg is not available`: install ffmpeg or set
  `etaf-video-ffmpeg-program` to its absolute path.
- `Video file is not readable`: the path is wrong or the file is not a local
  readable file; use `etaf-ascii-video-open-url` for network streams.
- A URL does not play: check the network and, behind a proxy, `ffmpeg`'s
  lowercase `http_proxy` / `https_proxy` environment variables. Non-HTTP(S)
  schemes are rejected before any process starts.
- No total duration in the status line: ffprobe is missing or the container
  does not report one; playback still works.
- The picture looks squashed: the canvas no longer matches the video aspect
  ratio. Press `F` or call `etaf-ascii-video-fit`.
- The picture lags after resizing or switching monitors: the grid refits
  automatically, and a session restart is part of that change.
