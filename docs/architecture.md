# ETAF ASCII Video architecture

## Responsibilities

`etaf-ascii-video` is an application. It owns decoding arguments, playback
state, pixel-to-character mapping and display pacing; rendering and retained
publication stay with ETAF and Ebox. No framework mechanism is re-implemented
here: the hot path is ETAF's public retained Host content boundary
(`etaf-runtime-update-host-contents`).

| Module | Owns |
| --- | --- |
| `etaf-ascii-video-grid` | aspect fitting and the raw byte to ramp character mapping |
| `etaf-ascii-video-source` | source normalization, ffprobe metadata, ffmpeg arguments, the binary process and the latest-frame buffer |
| `etaf-ascii-video-player` | refs, display timer, frame presentation, playback controls, status line text |
| `etaf-ascii-video-app` | buffer, View, keymap, window fitting, mount/unmount, public commands |

The root entry re-exports the supported subset; everything unlisted is
internal.

## Data flow

1. `etaf-ascii-video-open` normalizes the source, probes a file with ffprobe,
   fits a canvas to the selected window and mounts a View whose grid box and
   status box read player refs.
2. `etaf-ascii-video-source-start` runs ffmpeg with
   `-readrate SPEED -vf scale=COLUMNS:ROWS:flags=area -f rawvideo -pix_fmt gray
   -`. A process filter with binary coding cuts the byte stream into
   COLUMNS x ROWS frames. Only the newest complete frame is retained; older
   ones increment the drop counter.
3. The display timer claims the newest frame at `etaf-ascii-video-display-fps`.
   The grid module translates bytes to ramp characters in a reusable unibyte
   work buffer, and the player publishes the grid text and the status text as
   one retained update of the two Hosts.
4. Controls mutate player state and, when ffmpeg must restart (seek, speed,
   grid), spawn a fresh producer at the current position. Returning from the
   end replays from zero.
5. `etaf-ascii-video-close` cancels the timer, terminates the producer and
   unmounts the Runtime. A failed open runs the same teardown, so no partial
   player survives a `user-error`.

## Invariants

- **One writer per fact.** The player owns playback state, the source owns the
  byte stream, ETAF owns the buffer text. Views never decode; commands never
  write buffer text directly.
- **One publication per displayed frame.** A frame updates the canvas Host and
  the status Host in one `etaf-runtime-update-host-contents` call, which is one
  retained Ebox publication rather than an ordinary ETAF render. No per-pixel
  text properties are created.
- **Latest frame wins.** The filter retains at most one complete frame; a slow
  display drops frames and the clock advances from delivered frames, so
  playback never replays a backlog.
- **Pause does not catch up.** Pausing closes the producer and remembers the
  position; resuming spawns a producer with `-ss POSITION` instead of
  continuing a wall-clock-paced one, so a long pause never produces a
  fast-forward burst when playback resumes.
- **Canvas resize is a normal publication.** Box dimensions read player refs;
  a resize sets the refs and flushes, then the producer restarts with the new
  scale. Frame updates continue through the retained content path afterwards.
- **Mapping is pure and bounded.** The work buffer and translation table are
  reused per player; mapping cost is proportional to the canvas, independent
  of the encoded frame.
- **Cleanup is unconditional.** Every open failure, close and buffer kill
  releases the timer, the process and both work buffers.

## Measured behavior

Batch probes (no redisplay) on the reference checkout, 160x45 canvas, 30
frames with 5%, 30% and 80% of cells changed, report a median retained
publication of 3-4 ms per frame with `span-patch` / `owner-scoped`, one dirty
node, one patch and no full-root publication, and 1-2 ms for the byte to
character mapping of 7200 bytes. The cost is roughly independent of the
changed-cell ratio, because the changed text is one declared patch of the
canvas Host; the framework's granularity is the Host, not individual character
runs.

A GUI session on the same machine (ffmpeg 9.0.2, a real local H.264 file,
the application's own status line) measures a median publication of about 24
ms with 11-14 presented frames per second on a 199x48 canvas, and about 23
presented frames per second on a forced 160x45 canvas; the display timer asks
for 30. The gap between the batch publication cost and the GUI session is
redisplay and font work outside the publication call. Quantifying and
reducing it is the framework-probe work this application exists to drive, not
a capability this application claims to have solved.
