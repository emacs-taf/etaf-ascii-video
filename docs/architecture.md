# ETAF ASCII Video architecture

## Responsibilities

`etaf-ascii-video` is an application. It owns the buffer, the fitted canvas
size, the render mode choice, the status line and the keys. Decoding, frame
mapping and publication belong to ETAF's native `etaf-video` Component, which
this application places in a View and drives through its public handle
control functions. No framework mechanism is re-implemented here.

| Module | Owns |
| --- | --- |
| `etaf-ascii-video-grid` | aspect fitting of a video size into a character canvas |
| `etaf-ascii-video-app` | player state (canvas, mode, speed, status), the View, the buffer, the keymap, window fitting and the public commands |

The root entry re-exports the supported subset; everything unlisted is
internal.

## Data flow

1. `etaf-ascii-video-open` normalizes and probes the source once through
   `etaf-video-source-info`, chooses the render mode, fits a canvas to the
   selected window and mounts a View with the native `etaf-video` Component
   plus a status text Host.
2. The Component owns the playback session: ffmpeg decodes at the canvas size,
   the session keeps only the newest complete frame, and each displayed frame
   is mapped to ramp characters or half-block cells and published through
   `etaf-runtime-update-host-content` on the canvas Host.
3. The application refreshes the status Host from `etaf-video-state` four
   times per second, so the frame path stays free of status work.
4. Controls are declarative or imperative depending on the fact: canvas size,
   render mode and rate are View props (changing a prop restarts the session
   at the current position), while play/pause, step and seek call the
   Component's handle functions.
5. `etaf-ascii-video-close` cancels the status timer and unmounts the Runtime,
   which destroys the session. A failed open runs the same teardown, so no
   partial player survives a `user-error`.

## Invariants

- **One owner per fact.** The native session owns decoding, position and
  pacing; the application owns canvas size, mode, rate and status text; ETAF
  owns publication. The View never decodes and commands never write buffer
  text directly.
- **One publication per displayed frame.** The canvas Host receives one
  retained content update per frame, not an ordinary ETAF render. The
  monochrome grid creates no per-pixel properties; the color grid carries one
  `face` property per cell, so its publication work is proportional to the
  cell count.
- **Probe once.** `etaf-video-source-info` returns authoritative metadata that
  the Component accepts as its source, so resizing or restarting a video does
  not repeat the ffprobe call.
- **Latest frame wins.** The session retains at most one complete frame; a slow
  display drops frames and the clock advances from delivered frames, so
  playback never replays a backlog.
- **Pause does not catch up.** Pausing releases the producer and remembers the
  position; resuming spawns a producer with `-ss POSITION` instead of
  continuing a wall-clock-paced one, so a long pause never produces a
  fast-forward burst.
- **Cleanup is unconditional.** Every open failure, close and buffer kill
  cancels the status timer and unmounts the Runtime, destroying the session,
  the producer and the audio sidecar with it.

## Measured behavior

The character player's costs are the native Component's costs. Batch probes on
the reference checkout measured roughly 8 ms for a monochrome 160x45 retained
publication and one `face` property operation per cell for color frames (about
53 ms per 48x14 frame and 132 ms per 80x24 frame), which is why
`etaf-ascii-video-color-columns` caps the fitted color width. Image frames,
Retina-sharp decoding and audio belong to the companion `etaf-video-player`
application and the framework's own measurements.
