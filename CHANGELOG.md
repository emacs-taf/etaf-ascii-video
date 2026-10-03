# Changelog

## Unreleased

### Added

- Graphics rendering mode (`i`): ffmpeg emits one JPEG per frame at the
  canvas pixel size and the player publishes it as an image display. It needs
  a graphical frame and measured about 8.5 ms per frame at 136x48 (about 26
  frames per second), so full-window color playback is smooth.
- True-color half-block rendering: `c` (or `etaf-ascii-video-set-color`) draws
  two full color pixels per character cell with `▀`, so color mode doubles the
  vertical resolution and keeps the video's colors. `etaf-ascii-video-render-mode`
  picks the default mode for new players and `etaf-ascii-video-color-columns`
  caps the fitted width, because each colored cell costs one `face` property
  per published frame.
- Pure ASCII video playback in an ETAF buffer: ffmpeg decodes and downsamples
  each frame to raw grayscale bytes, the player maps every pixel to one
  character of a density ramp, and each displayed frame is published as one
  incremental update of a fixed canvas Host.
- Local files and a generated built-in demo, play/pause, single-frame
  stepping, seeking, 0.5x to 8x rates, window fitting, grid presets and a
  status line reporting frame rate, publication cost, drops and canvas size.
- Public API (`etaf-ascii-video-open`, `etaf-ascii-video-open-file`,
  `etaf-ascii-video-demo`, `etaf-ascii-video-close`, playback controls,
  `etaf-ascii-video-state`) and configurable density ramp, display rate,
  grid presets and ffmpeg/ffprobe programs.
- Acceptance scenarios over fake ffmpeg and ffprobe fixtures plus one gated
  real-ffmpeg demo scenario, so the public path stays testable without a
  decoder installed.
