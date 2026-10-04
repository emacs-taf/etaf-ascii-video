# Changelog

## Unreleased

### Added

- Character video playback in an ETAF buffer: the native `etaf-video`
  Component decodes and maps every frame, and this application fits a canvas
  to the window, keeps the status line, and publishes each frame as one
  incremental update of a fixed canvas Host.
- Local files, HTTP(S) streams and a generated built-in demo; play/pause,
  single-frame stepping, seeking, 0.5x to 8x rates, four grid presets and
  window fitting.
- Two character render modes: the default monochrome density ramp and
  true-color half blocks (`c`), which draw two full color pixels per cell with
  `▀`.  `etaf-ascii-video-color-columns` caps the fitted color width because
  each colored cell costs one `face` property per published frame.
- `etaf-ascii-video-state` exposes the live player as plain data for scripts
  and tests.
- Acceptance scenarios over fake ffmpeg and ffprobe fixtures plus one gated
  real-ffmpeg demo scenario, so the public path stays testable without a
  decoder installed.

### Changed

- Decoding, pixel mapping, display pacing, Retina-sharp image frames and the
  audio sidecar moved to the framework's native `etaf-video` Component (see
  the ETAF manual and changelog).  This package is now the character player
  only; `etaf-ascii-video-device-pixel-ratio`,
  `etaf-ascii-video-density-ramp`, `etaf-ascii-video-display-fps`,
  `etaf-ascii-video-ffmpeg-program` and `etaf-ascii-video-ffprobe-program`
  were removed in favor of the `etaf-video-*` variables, and the `graphics`
  render mode moved to the companion `etaf-video-player` application.
