;;; etaf-ascii-video.el --- Play video as ASCII pixels in an ETAF buffer -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.2.1") (etaf-ui "0.1.0"))
;; Keywords: multimedia, ui
;; URL: https://github.com/emacs-taf/etaf-ascii-video

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-ascii-video) after adding this
;; repository and the ETAF and Ebox roots to `load-path'.  The player shows a
;; local video or HTTP(S) stream as characters inside an ETAF buffer.  The
;; native `etaf-video' Component (see the ETAF manual) decodes the source and
;; publishes every frame through the retained Host content boundary; this
;; application owns the buffer, the fitted canvas size, the density and
;; half-block render modes, the status line and the keys.  ffmpeg and ffprobe
;; must be installed; without ffprobe playback still works with default
;; dimensions and rate.
;;
;; A session is one buffer (`*ASCII Video*') with one player.
;; `etaf-ascii-video-open', `etaf-ascii-video-open-file' and
;; `etaf-ascii-video-demo' create it, the functions below drive it,
;; `etaf-ascii-video-state' reports it as plain data, and
;; `etaf-ascii-video-close' releases it.  The default keymap binds the same
;; commands: SPC play/pause, n step, f/b seek five seconds, +/- speed, 1-4
;; grid presets, c color, F fit, o open, u url, d demo, ? help and q close.
;; The decoded density ramp, display rate and decoder programs are the
;; `etaf-video' variables documented by ETAF.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings remain beside their definitions, and
;; the manual contains workflows.
;;
;; Function: etaf-ascii-video-open (&optional source)
;;;###autoload (autoload 'etaf-ascii-video-open "etaf-ascii-video" nil t)
;; Open the player and return its buffer.
;; SOURCE is nil for the built-in demo, a file name, an HTTP(S) URL, or a
;; plist: `(:file PATH)' for a local video, `(:url URL)' for a network stream
;; and `(:demo)' for the generated test pattern.  All forms accept the display
;; hints `:columns' and `:rows' (canvas size in character cells), `:speed'
;; (playback rate) and `:mode' (`mono' or `color').  The canvas is fitted to
;; the selected window unless both size hints are given.  An existing player
;; is closed first; unreadable files, non-HTTP(S) URLs and unsupported
;; sources signal `user-error' before any process starts.
;;
;; Function: etaf-ascii-video-open-file (file)
;;;###autoload (autoload 'etaf-ascii-video-open-file "etaf-ascii-video" nil t)
;; Play the local video FILE.
;; The prompt reads FILE the way `find-file' does, so a pasted absolute or
;; `~' name is accepted and a relative one resolves against the calling
;; buffer's `default-directory'.
;;
;; Function: etaf-ascii-video-open-url (url)
;;;###autoload (autoload 'etaf-ascii-video-open-url "etaf-ascii-video" nil t)
;; Play the HTTP(S) video stream URL in the ASCII video player.
;; ffmpeg decodes the stream directly, so nothing is downloaded first.
;; Seeking needs server range support, and a dropped connection is retried
;; for up to five seconds.  The audio track is not played.
;;
;; Function: etaf-ascii-video-demo ()
;;;###autoload (autoload 'etaf-ascii-video-demo "etaf-ascii-video" nil t)
;; Play a generated 30 second test pattern that needs no file.
;;
;; Function: etaf-ascii-video-close ()
;;;###autoload (autoload 'etaf-ascii-video-close "etaf-ascii-video" nil t)
;; Close the player in the current buffer.
;; The status timer is cancelled, the native session destroyed and the ETAF
;; Runtime unmounted before the buffer is killed.
;;
;; Function: etaf-ascii-video-toggle-playback ()
;; Toggle the current player between playing and paused.
;; Pausing releases the producer; playing after the end restarts at zero.
;;
;; Function: etaf-ascii-video-step ()
;; Pause the current player and present exactly one more frame.
;;
;; Function: etaf-ascii-video-seek (seconds)
;; Move the current player to SECONDS and restart decoding there.
;; Negative targets are clamped to zero and targets beyond the known duration
;; to its end.  A paused player stays paused.
;;
;; Function: etaf-ascii-video-set-speed (speed)
;; Set the playback rate to SPEED, a positive number.
;; The native session restarts at the current position; the display rate
;; stays `etaf-video-display-fps' and extra decoded frames are dropped.
;;
;; Function: etaf-ascii-video-set-color (color)
;; Turn true-color half-block rendering on (non-nil) or off (nil).
;; Equivalent to `etaf-ascii-video-set-render-mode' with `color' or `mono'.
;;
;; Function: etaf-ascii-video-set-render-mode (mode)
;; Switch the current player to MODE: `mono' or `color'.
;; `mono' maps each pixel to one character of `etaf-video-density-ramp'.
;; `color' renders two full color pixels per character cell with `▀' (top
;; pixel as foreground, bottom pixel as background); it doubles the vertical
;; resolution and keeps the video's colors, at one `face' property per cell,
;; so `etaf-ascii-video-color-columns' caps the fitted width.  The session
;; restarts at the current position in the new mode.
;;
;; Function: etaf-ascii-video-set-grid (columns rows)
;; Resize the canvas to COLUMNS by ROWS character cells.
;; The session restarts at the current position with the new scale, so the
;; video aspect ratio follows the canvas only when the caller keeps it.
;;
;; Function: etaf-ascii-video-fit ()
;; Fit the current player's canvas to the window showing it.
;; One row is reserved for the status line; the window is refitted through
;; ETAF before the grid changes.
;;
;; Function: etaf-ascii-video-state ()
;; Return the current player's state as a detached plist.
;; Keys are `:source', `:playing', `:position', `:duration', `:speed',
;; `:columns', `:rows', `:mode', `:fps' (display timer rate), `:presented-fps'
;; (frames presented in the last sample window), `:source-fps', `:received',
;; `:presented', `:dropped' and `:ended'.  It reads the live player without
;; changing it, and signals `user-error' outside a player buffer.
;;
;; Variable: etaf-ascii-video-render-mode
;; Rendering mode for new players: `mono' or `color'.
;; `mono' is the default density-ramp mode and `color' renders two full color
;; pixels per cell with `▀'.  A `:mode' hint in the source plist overrides it.
;;
;; Variable: etaf-ascii-video-color-columns
;; Column limit used when a true-color player fits a new window.
;; Nil fits the window like the monochrome mode.  The default is 32, because
;; color content costs one `face' property per cell and EBox publishes one
;; property operation per run; raise it for sharper, slower color.
;;
;; Variable: etaf-ascii-video-grid-presets
;; Canvas widths reached by the `1' to `4' keys.
;; Keys are characters and values are widths in character cells, so a user can
;; repoint the presets without touching the keymap.

;;; Code:

;;;###autoload
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name "lisp"
                                 (file-name-directory
                                  (or load-file-name
                                      (bound-and-true-p byte-compile-current-file)
                                      buffer-file-name)))))

(require 'etaf-ascii-video-app)

(provide 'etaf-ascii-video)
;;; etaf-ascii-video.el ends here
