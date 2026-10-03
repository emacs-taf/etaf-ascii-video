;;; etaf-ascii-video.el --- Play video as ASCII pixels in an ETAF buffer -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.2.1"))
;; Keywords: multimedia, ui
;; URL: https://gitea.vhkd.top/geekinney/etaf-ascii-video

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-ascii-video) after adding this
;; repository and the ETAF and Ebox roots to `load-path'.  The player turns a
;; local video into a stream of raw grayscale frames, maps every pixel to one
;; character of a density ramp, and publishes each frame as the text of a
;; fixed ETAF canvas.  One displayed frame is one retained publication of the
;; canvas Host, so the picture keeps updating without an ordinary ETAF render.
;; ffmpeg and ffprobe must be installed; without ffprobe playback still works
;; with default dimensions and rate.
;;
;; A session is one buffer (`*ASCII Video*') with one player.  `etaf-ascii-video-open',
;; `etaf-ascii-video-open-file' and `etaf-ascii-video-demo' create it, the
;; functions below drive it, `etaf-ascii-video-state' reports it as plain
;; data, and `etaf-ascii-video-close' releases it.  The default keymap binds
;; the same commands: SPC play/pause, n step, f/b seek five seconds, +/- speed,
;; 1-4 grid presets, F fit, o open, d demo, ? help and q close.
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
;; SOURCE is nil for the built-in demo, a file name, or a plist: `(:file
;; PATH)' for a local video and `(:demo)' for the generated test pattern.
;; Both accept the display hints `:columns' and `:rows' (canvas size in
;; character cells) and `:speed' (playback rate).  The canvas is fitted to the
;; selected window unless both hints are given.  An existing player is closed
;; first; unreadable files and unsupported sources signal `user-error' before
;; any process starts.
;;
;; Function: etaf-ascii-video-open-file (file)
;;;###autoload (autoload 'etaf-ascii-video-open-file "etaf-ascii-video" nil t)
;; Play the local video FILE.
;;
;; Function: etaf-ascii-video-demo ()
;;;###autoload (autoload 'etaf-ascii-video-demo "etaf-ascii-video" nil t)
;; Play a generated 30 second test pattern that needs no file.
;;
;; Function: etaf-ascii-video-close ()
;;;###autoload (autoload 'etaf-ascii-video-close "etaf-ascii-video" nil t)
;; Close the player in the current buffer.
;; The display timer is cancelled, the producer terminated and the ETAF
;; Runtime unmounted before the buffer is killed.
;;
;; Function: etaf-ascii-video-toggle-playback ()
;; Toggle the current player between playing and paused.
;; Pausing suspends the producer; playing after the end restarts at zero.
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
;; The producer is restarted at the current position; the display rate stays
;; `etaf-ascii-video-display-fps' and extra decoded frames are dropped.
;;
;; Function: etaf-ascii-video-set-grid (columns rows)
;; Resize the canvas to COLUMNS by ROWS character cells.
;; The producer restarts at the current position with the new scale, so the
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
;; `:columns', `:rows', `:fps' (display timer rate), `:presented-fps' (frames
;; presented in the last second), `:source-fps', `:received', `:presented',
;; `:dropped', `:frame-ms' and `:ended'.  It reads the live player without
;; changing it, and signals `user-error' outside a player buffer.
;;
;; Variable: etaf-ascii-video-density-ramp
;; Characters used for one video pixel, darkest to lightest.
;; The default is " .:-=+*#%@"; it must be nonempty and single-line, and a
;; change takes effect on the next rendered frame.
;;
;; Variable: etaf-ascii-video-display-fps
;; Display timer rate in frames per second.
;; It caps the presented rate and defaults to 30.
;;
;; Variable: etaf-ascii-video-grid-presets
;; Canvas widths reached by the `1' to `4' keys.
;; Keys are characters and values are widths in character cells, so a user can
;; repoint the presets without touching the keymap.
;;
;; Variable: etaf-ascii-video-ffmpeg-program
;; Name or absolute path of the ffmpeg executable.
;; Point it at a wrapper script to add decoder options; the player appends the
;; scale filter and rawvideo output arguments.
;;
;; Variable: etaf-ascii-video-ffprobe-program
;; Name or absolute path of the ffprobe executable.
;; Missing metadata degrades to default dimensions, rate and no known
;; duration instead of failing playback.

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
