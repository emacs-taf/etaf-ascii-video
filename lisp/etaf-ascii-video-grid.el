;;; etaf-ascii-video-grid.el --- Character canvas fitting for etaf-ascii-video -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Pure geometry shared by the application and its acceptance fixtures:
;; fitting a video frame into a character canvas.  Pixels, density mapping,
;; playback and publication belong to the native `etaf-video' Component.

;;; Code:

(require 'cl-lib)

(defun etaf-ascii-video--fit-grid (aspect max-columns max-rows &optional cell-aspect)
  "Return the largest (COLUMNS . ROWS) with ASPECT inside the canvas.
ASPECT is the video width divided by its height.  MAX-COLUMNS and MAX-ROWS are
the canvas limits in character cells.  CELL-ASPECT is one cell's
height divided by its width and defaults to 2.0, the usual terminal cell.
The result is at least 8 by 3 cells."
  (let* ((cell-aspect (or cell-aspect 2.0))
         (max-columns (max 8 (floor max-columns)))
         (max-rows (max 3 (floor max-rows)))
         (scale (* aspect cell-aspect))
         (columns (min max-columns (max 8 (floor (* max-rows scale)))))
         (rows (max 3 (min max-rows (floor (/ columns scale))))))
    (cons columns rows)))

(defun etaf-ascii-video--rows-for-columns (aspect columns &optional cell-aspect)
  "Return the row count of an ASPECT frame COLUMNS cells wide."
  (let ((scale (* aspect (or cell-aspect 2.0))))
    (max 3 (round (/ columns scale)))))

(provide 'etaf-ascii-video-grid)
;;; etaf-ascii-video-grid.el ends here
